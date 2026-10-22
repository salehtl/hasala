import HasalaMocks
import HasalaModels
import Testing

@MainActor
@Suite("In-memory ledger · group sorting")
struct GroupSortingLedgerTests {
  let october = ReviewWindow.month(MayaLedger.october)

  func ledger() -> InMemoryLedger { InMemoryLedger(state: Scenario.mayaBacklog.state) }

  func tailscaleRows(_ l: InMemoryLedger) -> [Txn] { l.state.txns.filter { $0.groupRef == MayaBacklog.tailscale } }

  @Test func sortingAGroupFilesEveryWaitingPaymentInOneEdit() throws {
    let l = ledger()
    let token = try #require(try l.apply(.sortGroup(MayaBacklog.tailscale, "subscriptions", alwaysUse: false, project: nil)))
    #expect(token.title == "Sorted 30 Tailscale as Subscriptions")
    let filed = tailscaleRows(l).filter { $0.id != "bl-ts-unverified" }
    #expect(filed.count == 30)
    #expect(filed.allSatisfy { $0.categoryID == "subscriptions" && $0.categorySource == .user && !$0.needsReview })
    #expect(filed.allSatisfy { $0.categorizedAt == MayaLedger.now && !$0.reachable })
    let unverified = try #require(l.state.txn("bl-ts-unverified"))
    #expect(unverified.needsReview && unverified.categoryID == nil && unverified.reviewReason == .senderUnverified)
    #expect(l.state.txn("bl-ts-refund")?.inReview == true)
    #expect(l.state.rules == Scenario.mayaBacklog.state.rules)
    #expect(ReviewEngine.groupCard(MayaBacklog.tailscale, l.state) == nil)

    let row = try #require(SortResultEngine.row(l.state, in: october))
    #expect(row.line == "Sorted 30 Tailscale as Subscriptions")
    #expect(row.detail == "Including 22 from other months")
    #expect(row.spoken == "Sorted 30 Tailscale payments as Subscriptions, including 22 from other months.")
    #expect(SortResultEngine.row(l.state)?.spoken == "Sorted 30 Tailscale payments as Subscriptions.")
    #expect(!row.canStopRule)
    #expect(row.undo == token)
    #expect(SortResultEngine.row(l.state)?.detail == nil)

    l.undo(token)
    #expect(l.state.sortReceipt == nil)
    #expect(try #require(ReviewEngine.groupCard(MayaBacklog.tailscale, l.state)).count == 30)
    #expect(tailscaleRows(l).allSatisfy { $0.categoryID == nil && $0.categorizedAt == nil })
  }

  @Test func alwaysUseItMakesARuleThatReachesBackOnlyInTheGroup() throws {
    let l = ledger()
    let token = try #require(
      try l.apply(.sortGroup(MayaBacklog.alNoorTradingGroup, "groceries", alwaysUse: true, project: nil)))
    let rule = try #require(l.state.rules.first { $0.id.hasPrefix("group-") })
    #expect(rule.match == .exact)
    #expect(rule.patterns == ["al noor trading llc"])
    #expect(rule.categoryID == "groceries")
    #expect(l.state.sortReceipt?.ruleID == rule.id)
    #expect(SortResultEngine.row(l.state)?.canStopRule == true)
    for id in ["bl-alnoor-p-1", "bl-alnoor-p-2"] {
      #expect(l.state.txn(id)?.inReview == true)
      #expect(l.state.txn(id)?.categoryID == nil)
    }
    l.undo(token)
    #expect(!l.state.rules.contains { $0.id == rule.id })
    #expect(l.state.txn("bl-alnoor-t-1")?.inReview == true)
  }

  @Test func theRuleLeavesWaitingPaymentsTheOtherWay() throws {
    let l = ledger()
    let token = try #require(try l.apply(.sortGroup(MayaBacklog.tailscale, "subscriptions", alwaysUse: true, project: nil)))
    #expect(token.title == "Sorted 30 Tailscale as Subscriptions")
    let refund = try #require(l.state.txn("bl-ts-refund"))
    #expect(refund.inReview && refund.categoryID == nil && refund.reachable)
    #expect(l.state.sortReceipt?.count == 30)
    let rule = try #require(l.state.rules.first { $0.id.hasPrefix("group-") })
    #expect(Set(rule.patterns) == ["tailscale.com", "tailscale inc", "paypal *tailscale"])
    let unverified = try #require(l.state.txn("bl-ts-unverified"))
    #expect(unverified.needsReview && unverified.categoryID == nil)
  }

  @Test func alwaysUseFromOneCardReachesBackWithinItsGroup() throws {
    let l = ledger()
    let token = try #require(try l.apply(.categorize("bl-qasr-1", "groceries", learnRule: true, project: nil)))
    #expect(token.title == "Sorted 6 Qasr Corner Store as Groceries")
    let open = (1...6).map { "bl-qasr-\($0)" }
    #expect(open.allSatisfy { l.state.txn($0)?.categoryID == "groceries" && l.state.txn($0)?.needsReview == false })
    #expect(l.state.txn("bl-qasr-1")?.categorySource == .user)
    #expect(open.dropFirst().allSatisfy { l.state.txn($0)?.filedByRule == true })
    #expect(l.state.txn("bl-qasr-filed-2")?.categoryID == "shopping")
    #expect(l.state.sortReceipt?.txnIDs.count == 6)

    let mine = SortedForYouEngine.snapshot(l.state, now: l.now)
    #expect(mine.items.count == 1)
    #expect(mine.payments == 5)
    #expect(mine.homeLine == "5 sorted for you this week")
    let item = try #require(mine.items.first)
    #expect(item.merchant == "Qasr Corner Store")
    #expect(item.sourceLine == "Sorted by your rule")
    #expect(item.undoAllLabel == "Undo all 5")
    #expect(item.canStopRule)
    #expect(item.detail == "5 payments · Groceries")

    l.undo(token)
    #expect(open.allSatisfy { l.state.txn($0)?.inReview == true && l.state.txn($0)?.reachable == true })
    #expect(SortedForYouEngine.snapshot(l.state, now: l.now).isEmpty)
  }

  @Test func undoAllPutsRuleFilingsBackInReview() throws {
    let l = ledger()
    try l.apply(.categorize("bl-qasr-1", "groceries", learnRule: true, project: nil))
    let item = try #require(SortedForYouEngine.snapshot(l.state, now: l.now).items.first)
    let token = try #require(try l.apply(item.undoAll))
    #expect(token.title == "5 payments back in Review")
    for id in item.txnIDs {
      let t = try #require(l.state.txn(id))
      #expect(t.inReview && t.categoryID == nil && t.categorySource == nil && t.ruleID == nil && t.reachable)
    }
    #expect(l.state.txn("bl-qasr-1")?.categoryID == "groceries")
    #expect(SortedForYouEngine.snapshot(l.state, now: l.now).isEmpty)
    #expect(throws: ActionError.notFound) { try l.apply(.returnToReview(item.txnIDs)) }
    l.undo(token)
    #expect(item.txnIDs.allSatisfy { l.state.txn($0)?.filedByRule == true })
  }

  @Test func undoAllTurnsACloudflareFilingBackIntoACheck() throws {
    var s = Scenario.mayaBacklog.state
    let recent = LocalDateTime(2026, 10, 8, 9, 0)
    for i in s.txns.indices where s.txns[i].merchantGroup == "n:brightwell academy" {
      s.txns[i].needsReview = false
      s.txns[i].categorizedAt = s.txns[i].id == "bl-bright-7" ? LocalDateTime(2026, 10, 2, 9, 0) : recent
    }
    var dictionary = try #require(s.txn("lulu"))
    dictionary.id = "dictionary-filed"
    dictionary.categorySource = .dictionary
    dictionary.needsReview = false
    dictionary.categorizedAt = recent
    s.txns.append(dictionary)
    let l = InMemoryLedger(state: s)
    let snap = SortedForYouEngine.snapshot(l.state, now: l.now)
    #expect(snap.items.map(\.source) == [.cloudflare])
    #expect(snap.payments == 3)
    #expect(snap.items.first?.sourceLine == "Sorted by Cloudflare AI")
    #expect(snap.items.first?.canStopRule == false)
    let before = SuggestionsEngine.count(l.state)
    try l.apply(.returnToReview(snap.items[0].txnIDs))
    #expect(SuggestionsEngine.count(l.state) == before + 3)
    #expect(l.state.txn("bl-bright-8")?.categoryID == MayaBacklog.wrongGuess)
    #expect(l.state.txn("bl-bright-8")?.needsReview == true)
    #expect(l.state.txn("bl-bright-7")?.needsReview == false)
    #expect(l.state.txn("dictionary-filed")?.needsReview == false)
  }

  @Test func notThisForgetsTheGuessForTheWholeGroup() throws {
    let l = ledger()
    let before = SuggestionsEngine.count(l.state)
    let token = try #require(try l.apply(.notThis(MayaBacklog.brightwellGroup, MayaBacklog.wrongGuess)))
    #expect(token.title == "Hasala won't suggest Shopping for Brightwell Academy again")
    let rows = l.state.txns.filter { $0.merchantGroup == "n:brightwell academy" }
    #expect(rows.count == 4)
    for t in rows {
      #expect(t.categoryID == nil && t.categorySource == nil && t.needsReview && t.reachable)
      #expect(t.rejectedCategories == [MayaBacklog.wrongGuess])
      #expect(t.reviewSuggestion == nil)
    }
    #expect(SuggestionsEngine.count(l.state) == before - 4)
    let card = try #require(ReviewEngine.groupCard(MayaBacklog.brightwellGroup, l.state))
    #expect(card.suggestion == nil && card.count == 4)
    #expect(l.state.txn("bl-saffron")?.rejectedCategories.isEmpty == true)

    l.undo(token)
    for t in l.state.txns where t.merchantGroup == "n:brightwell academy" {
      #expect(t.categoryID == MayaBacklog.wrongGuess && t.isModelSourced && t.rejectedCategories.isEmpty)
    }
    #expect(SuggestionsEngine.count(l.state) == before)
  }

  @Test func undoingTheFirstOfTwoNotThisBringsItsGuessBack() throws {
    let l = ledger()
    let first = try #require(try l.apply(.notThis(MayaBacklog.brightwellGroup, MayaBacklog.wrongGuess)))
    try l.apply(.notThis(MayaBacklog.brightwellGroup, "entertainment"))
    l.undo(first)
    for t in l.state.txns where t.merchantGroup == "n:brightwell academy" {
      #expect(t.categoryID == MayaBacklog.wrongGuess && t.isModelSourced)
      #expect(t.rejectedCategories == ["entertainment"])
      #expect(t.reviewSuggestion == MayaBacklog.wrongGuess)
    }
    let card = try #require(ReviewEngine.groupCard(MayaBacklog.brightwellGroup, l.state))
    #expect(card.suggestion?.id == MayaBacklog.wrongGuess)
  }

  @Test func aRejectedPairStaysRejectedForANewGuess() throws {
    let l = ledger()
    try l.apply(.notThis(MayaBacklog.qasrGroup, "groceries"))
    #expect(l.state.txn("bl-qasr-filed-1")?.categoryID == "groceries")
    #expect(l.state.txn("bl-qasr-filed-1")?.rejectedCategories == ["groceries"])
    var s = l.state
    for i in s.txns.indices where s.txns[i].id == "bl-qasr-2" {
      s.txns[i].categoryID = "groceries"
      s.txns[i].categorySource = .model(tag: "apple-fm/1")
    }
    #expect(s.txn("bl-qasr-2")?.reviewSuggestion == nil)
  }

  @Test func notThisWorksOnACardWithoutAGroup() throws {
    let l = InMemoryLedger()
    #expect(l.state.txn("lulu")?.reviewSuggestion == "groceries")
    let lulu = try #require(l.state.txn("lulu"))
    let ref = try #require(ReviewEngine.card(lulu, l.state).group)
    #expect(ref.key == "lulu hypermarket")
    try l.apply(.notThis(ref, "groceries"))
    #expect(l.state.txn("lulu")?.reviewSuggestion == nil)
    #expect(l.state.txn("lulu")?.inReview == true)
  }

  @Test func stopThisRuleKeepsWhatItSorted() throws {
    let l = ledger()
    try l.apply(.sortGroup(MayaBacklog.tailscale, "subscriptions", alwaysUse: true, project: nil))
    let ruleID = try #require(l.state.sortReceipt?.ruleID)
    let token = try #require(try l.apply(.stopRule(ruleID)))
    #expect(token.title == "Stopped sorting Tailscale as Subscriptions")
    #expect(l.state.rule(ruleID) == nil)
    #expect(l.state.txn("bl-ts-01")?.categoryID == "subscriptions")
    #expect(SortResultEngine.row(l.state)?.canStopRule == false)
    l.undo(token)
    #expect(l.state.rule(ruleID) != nil)
    #expect(throws: ActionError.notFound) { try l.apply(.stopRule("no-such-rule")) }
  }

  @Test func theResultRowStaysUntilDismissedOrReplaced() throws {
    let l = ledger()
    try l.apply(.sortGroup(MayaBacklog.tailscale, "subscriptions", alwaysUse: false, project: nil))
    try l.apply(.categorize("steam", "entertainment", learnRule: false, project: nil))
    #expect(l.state.sortReceipt?.merchant == "Tailscale")
    try l.apply(.sortGroup(MayaBacklog.qasrGroup, "groceries", alwaysUse: false, project: nil))
    #expect(l.state.sortReceipt?.merchant == "Qasr Corner Store")
    #expect(try l.apply(.dismissSortReceipt) == nil)
    #expect(l.state.sortReceipt == nil)
    #expect(SortResultEngine.row(l.state) == nil)
  }

  @Test func aGroupSortLeavesSkippedPaymentsAndRefusesAnEmptyGroup() throws {
    let l = ledger()
    try l.apply(.skipReview("bl-ts-01"))
    let token = try #require(try l.apply(.sortGroup(MayaBacklog.tailscale, "subscriptions", alwaysUse: false, project: nil)))
    #expect(token.title == "Sorted 29 Tailscale as Subscriptions")
    #expect(l.state.txn("bl-ts-01")?.inReview == true)
    #expect(throws: ActionError.notFound) {
      try l.apply(.sortGroup(MayaBacklog.brightwellGroup, "no-such-category", alwaysUse: false, project: nil))
    }
    #expect(throws: ActionError.notFound) {
      try l.apply(.sortGroup(MerchantGroupRef(key: "nobody", direction: .out), "groceries", alwaysUse: false, project: nil))
    }
    #expect(throws: ActionError.notFound) {
      try l.apply(.notThis(MerchantGroupRef(key: "nobody", direction: .out), "groceries"))
    }
  }

  @Test func alwaysUseItFilesExactlyWhatTheCardCounted() throws {
    let l = ledger()
    try l.apply(.skipReview("bl-ts-01"))
    let card = try #require(ReviewEngine.groupCard(MayaBacklog.tailscale, l.state))
    #expect(card.total == 29)
    let token = try #require(try l.apply(.sortGroup(MayaBacklog.tailscale, "subscriptions", alwaysUse: true, project: nil)))
    #expect(token.title == "Sorted 29 Tailscale as Subscriptions")
    #expect(l.state.sortReceipt?.count == card.total)
    #expect(Set(l.state.sortReceipt?.txnIDs ?? []) == Set(card.txnIDs))
    let skipped = try #require(l.state.txn("bl-ts-01"))
    #expect(skipped.inReview && skipped.categoryID == nil)
    #expect(l.state.txn("bl-ts-refund")?.inReview == true)
  }

  @Test func reachBackFromOneCardLeavesSkippedPayments() throws {
    let l = ledger()
    try l.apply(.skipReview("bl-qasr-2"))
    let token = try #require(try l.apply(.categorize("bl-qasr-1", "groceries", learnRule: true, project: nil)))
    #expect(token.title == "Sorted 5 Qasr Corner Store as Groceries")
    #expect(l.state.txn("bl-qasr-2")?.inReview == true)
    #expect(l.state.txn("bl-qasr-2")?.categoryID == nil)
  }

  @Test func aRuleLearnedAgainAfterStopGetsItsOwnID() throws {
    let l = ledger()
    try l.apply(.categorize("bl-qasr-1", "groceries", learnRule: true, project: nil))
    let first = try #require(l.state.sortReceipt?.ruleID)
    #expect(first == "learned-bl-qasr-1")
    try l.apply(.stopRule(first))
    try l.apply(.categorize("bl-qasr-1", "shopping", learnRule: true, project: nil))
    let second = try #require(l.state.rules.first { $0.categoryID == "shopping" && $0.learnedToday })
    #expect(second.id != first)
    #expect(l.state.rule(first) == nil)
    let items = SortedForYouEngine.snapshot(l.state, now: l.now).items
    let old = try #require(items.first { $0.category.id == "groceries" })
    #expect(old.count == 5)
    #expect(!old.canStopRule)
    #expect(old.ruleID == nil)
    #expect(l.state.txns.filter { $0.ruleID == second.id }.isEmpty)
  }

  @Test func aGroupSortCanAddToAProject() throws {
    let l = ledger()
    try l.apply(.sortGroup(MayaBacklog.nimbusGroup, "subscriptions", alwaysUse: false, project: "japan"))
    #expect(l.state.txns.filter { $0.merchantGroup == "n:nimbusnotes" }.allSatisfy { $0.projectID == "japan" })
  }

  @Test func reachableFollowsEveryEdit() throws {
    let l = ledger()
    #expect(l.state.txn("bl-ts-01")?.reachable == true)
    #expect(l.state.txn("bl-ts-unverified")?.reachable == false)
    #expect(l.state.txn("bl-qasr-filed-1")?.reachable == false)
    let token = try #require(try l.apply(.categorize("bl-ts-01", "subscriptions", learnRule: false, project: nil)))
    #expect(l.state.txn("bl-ts-01")?.reachable == false)
    l.undo(token)
    #expect(l.state.txn("bl-ts-01")?.reachable == true)
  }

  @Test func trackingTheBillKeepsTheGroupRepeatingMonthly() throws {
    let l = ledger()
    #expect(ReviewEngine.groupCard(MayaBacklog.tailscale, l.state)?.repeatsMonthly == true)
    try l.apply(.trackCandidate(MayaBacklog.candidate.id))
    #expect(!l.state.billCandidates.contains { $0.id == MayaBacklog.candidate.id })
    #expect(l.state.bills.first { $0.id == "bill-\(MayaBacklog.candidate.id)" }?.keys == ["tailscale.com"])
    #expect(ReviewEngine.groupCard(MayaBacklog.tailscale, l.state)?.repeatsMonthly == true)
  }

  @Test func undoingTheBatchThatReplacedARowBringsTheEarlierRowBack() throws {
    let l = ledger()
    let first = try #require(try l.apply(.sortGroup(MayaBacklog.tailscale, "subscriptions", alwaysUse: false, project: nil)))
    let second = try #require(try l.apply(.sortGroup(MayaBacklog.qasrGroup, "groceries", alwaysUse: false, project: nil)))
    #expect(l.state.sortReceipt?.merchant == "Qasr Corner Store")
    l.undo(second)
    let row = try #require(SortResultEngine.row(l.state))
    #expect(row.line == "Sorted 30 Tailscale as Subscriptions")
    #expect(row.undo == first)
    l.undo(try #require(row.undo))
    #expect(l.state.sortReceipt == nil)
    #expect(tailscaleRows(l).allSatisfy { $0.categoryID == nil })
  }

  @Test func anEarlierRowWhoseBatchIsGoneDoesNotComeBack() throws {
    let l = ledger()
    let first = try #require(try l.apply(.sortGroup(MayaBacklog.tailscale, "subscriptions", alwaysUse: false, project: nil)))
    l.undo(first)
    let second = try #require(try l.apply(.sortGroup(MayaBacklog.qasrGroup, "groceries", alwaysUse: false, project: nil)))
    l.undo(second)
    #expect(l.state.sortReceipt == nil)
    try l.apply(.sortGroup(MayaBacklog.tailscale, "subscriptions", alwaysUse: false, project: nil))
    try l.apply(.dismissSortReceipt)
    let third = try #require(try l.apply(.sortGroup(MayaBacklog.qasrGroup, "groceries", alwaysUse: false, project: nil)))
    l.undo(third)
    #expect(l.state.sortReceipt == nil)
  }

  @Test func anAutoFiledGuessThatWasRejectedComesBackToReview() throws {
    var s = Scenario.mayaBacklog.state
    for i in s.txns.indices where s.txns[i].merchantGroup == "n:brightwell academy" {
      s.txns[i].needsReview = false
      s.txns[i].categorizedAt = LocalDateTime(2026, 10, 8, 9, 0)
    }
    let filed = InMemoryLedger(state: s)
    #expect(SortedForYouEngine.snapshot(filed.state, now: filed.now).items.flatMap(\.txnIDs).contains("bl-bright-10"))
    for i in s.txns.indices where s.txns[i].merchantGroup == "n:brightwell academy" {
      s.txns[i].rejectedCategories = [MayaBacklog.wrongGuess]
    }
    let l = InMemoryLedger(state: s)
    let row = try #require(l.state.txn("bl-bright-10"))
    #expect(row.modelGuessRejected && row.inReview && !row.autoFiledByCloudflare && !row.reachable)
    let cards = ReviewEngine.items(l.state).filter { $0.txnIDs.contains("bl-bright-10") }
    #expect(cards.count == 1)
    guard case .single(let card) = try #require(cards.first) else {
      Issue.record("expected a single card")
      return
    }
    #expect(card.suggestion == nil && card.suggestedBy == nil)
    let snap = SortedForYouEngine.snapshot(l.state, now: l.now)
    #expect(!snap.items.flatMap(\.txnIDs).contains { $0.hasPrefix("bl-bright") })
    #expect(ActivityEngine.row(row, l.state).toReview)
    #expect(ActivityEngine.row(row, l.state).glyph == .review)
  }
}
