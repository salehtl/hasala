import HasalaMocks
import HasalaModels
import Testing

@MainActor
@Suite("In-memory ledger · sorting by merchant")
struct GroupSortingLedgerTests {
  func ledger() -> InMemoryLedger { InMemoryLedger(state: Scenario.mayaBacklog.state) }

  func tailscaleRows(_ l: InMemoryLedger) -> [Txn] { l.state.txns.filter { $0.groupRef == MayaBacklog.tailscale } }

  @Test func alwaysUseFromOneSpellingReachesAllThreeTailscaleSpellingsWithExactPatterns() throws {
    let l = ledger()
    let first = try #require(l.state.txn("bl-ts-01"))
    #expect(first.spelling == "TAILSCALE.COM")
    let token = try #require(try l.apply(.categorize("bl-ts-01", "subscriptions", learnRule: true, project: nil)))
    #expect(token.title == "Subscriptions for all 30 Tailscale payments" && token.batch)
    let rule = try #require(l.state.rules.first { $0.id.hasPrefix("learned-") })
    #expect(rule.match == .exact && rule.patterns == ["tailscale.com", "tailscale inc", "paypal *tailscale"])
    #expect(!rule.matches("paypal *netflix") && !rule.matches("tailscale"))
    #expect(l.state.txn("bl-ts-unverified")?.categoryID == nil && l.state.txn("bl-ts-refund")?.categoryID == nil)
    #expect(tailscaleRows(l).filter { $0.id != "bl-ts-unverified" }.allSatisfy { $0.categoryID == "subscriptions" })
  }

  @Test func aNineSpellingGroupGetsARuleOfTheEightMostUsed() throws {
    var s = Scenario.mayaBacklog.state
    let ref = MerchantGroupRef(key: "n:some shop", direction: .out)
    var n = 0
    for spelling in 1...9 {
      for k in 0..<(10 - spelling) {
        n += 1
        var t = try #require(s.txn("bl-saffron"))
        t.id = "shop-\(n)"
        t.merchant = "Some Shop"
        t.merchantKey = "some shop*ref \(spelling)"
        t.merchantGroup = ref.key
        t.provenance?.rawMerchant = "SOME SHOP*REF \(spelling)"
        t.postedAt = LocalDateTime(2026, 10, 1 + k, 12, spelling)
        s.txns.append(t)
      }
    }
    let l = InMemoryLedger(state: s)
    #expect(l.state.txns.filter { $0.groupRef == ref && $0.reachable }.count == 45)
    try l.apply(.categorize("shop-1", "shopping", learnRule: true, project: nil))
    let rule = try #require(l.state.rules.first { $0.id.hasPrefix("learned-") })
    #expect(rule.patterns == (1...8).map { "some shop*ref \($0)" })
    #expect(GroupRule.patterns(filed: nil, members: []).isEmpty)
    #expect(GroupRule.pattern(String(repeating: "x", count: 129)) == nil && GroupRule.pattern("A  B ") == "a b")
  }

  @Test func alwaysUseFromOneCardReachesBackWithinItsGroup() throws {
    let l = ledger()
    let token = try #require(try l.apply(.categorize("bl-qasr-1", "groceries", learnRule: true, project: nil)))
    #expect(token.title == "Groceries for all 6 Qasr Corner Store payments" && token.batch)
    let open = (1...6).map { "bl-qasr-\($0)" }
    #expect(open.allSatisfy { l.state.txn($0)?.categoryID == "groceries" && l.state.txn($0)?.needsReview == false })
    #expect(l.state.txn("bl-qasr-1")?.categorySource == .user)
    #expect(open.dropFirst().allSatisfy { l.state.txn($0)?.filedByRule == true })
    #expect(l.state.txn("bl-qasr-filed-2")?.categoryID == "shopping")

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
    func guesses() -> Int { ReviewEngine.queue(l.state).filter { $0.reviewSuggestion != nil }.count }
    let before = guesses()
    try l.apply(.returnToReview(snap.items[0].txnIDs))
    #expect(guesses() == before + 3)
    #expect(l.state.txn("bl-bright-8")?.categoryID == MayaBacklog.wrongGuess)
    #expect(l.state.txn("bl-bright-8")?.needsReview == true)
    #expect(l.state.txn("bl-bright-7")?.needsReview == false)
    #expect(l.state.txn("dictionary-filed")?.needsReview == false)
  }

  @Test func stopThisRuleKeepsWhatItSorted() throws {
    let l = ledger()
    try l.apply(.categorize("bl-ts-01", "subscriptions", learnRule: true, project: nil))
    let ruleID = try #require(l.state.rules.first { $0.id.hasPrefix("learned-") }?.id)
    let token = try #require(try l.apply(.stopRule(ruleID)))
    #expect(token.title == "Stopped sorting Tailscale as Subscriptions" && !token.batch)
    #expect(l.state.rule(ruleID) == nil)
    #expect(l.state.txn("bl-ts-02")?.categoryID == "subscriptions")
    l.undo(token)
    #expect(l.state.rule(ruleID) != nil)
    #expect(throws: ActionError.notFound) { try l.apply(.stopRule("no-such-rule")) }
  }

  @Test func alwaysUseFromOneCardFilesASkippedPaymentToo() throws {
    let l = ledger()
    try l.apply(.skipReview("bl-qasr-2"))
    let token = try #require(try l.apply(.categorize("bl-qasr-1", "groceries", learnRule: true, project: nil)))
    #expect(token.title == "Groceries for all 6 Qasr Corner Store payments")
    #expect(l.state.txn("bl-qasr-2")?.inReview == false)
    #expect(l.state.txn("bl-qasr-2")?.categoryID == "groceries")
  }

  @Test func aRuleLearnedAgainAfterStopGetsItsOwnID() throws {
    let l = ledger()
    try l.apply(.categorize("bl-qasr-1", "groceries", learnRule: true, project: nil))
    let first = try #require(l.state.rules.first { $0.id.hasPrefix("learned-") }?.id)
    #expect(first == "learned-bl-qasr-1")
    try l.apply(.stopRule(first))
    try l.apply(.categorize("bl-qasr-1", "shopping", learnRule: true, project: nil))
    let second = try #require(l.state.rules.first { $0.categoryID == "shopping" && $0.learnedToday })
    #expect(second.id != first)
    #expect(l.state.rule(first) == nil)
    let items = SortedForYouEngine.snapshot(l.state, now: l.now).items
    #expect(!items.contains { $0.category.id == "groceries" })
    let refiled = try #require(items.first { $0.category.id == "shopping" })
    #expect(refiled.count == 5 && refiled.ruleID == second.id && refiled.canStopRule)
    #expect(l.state.txns.filter { $0.ruleID == second.id }.count == 5)
    #expect(l.state.txns.filter { $0.ruleID == first }.isEmpty)
  }

  @Test func reachableFollowsEveryEdit() throws {
    let l = ledger()
    #expect(l.state.txn("bl-ts-01")?.reachable == true)
    #expect(l.state.txn("bl-ts-unverified")?.reachable == false)
    #expect(l.state.txn("bl-qasr-filed-1")?.reachable == false)
    let token = try #require(try l.apply(.categorize("bl-ts-01", "subscriptions", learnRule: false, project: nil)))
    #expect(token.title == "Sorted into Subscriptions" && !token.batch)
    #expect(l.state.txn("bl-ts-01")?.reachable == false)
    l.undo(token)
    #expect(l.state.txn("bl-ts-01")?.reachable == true)
  }

  @Test func trackingTheBillKeepsTheGroupRepeatingMonthly() throws {
    let l = ledger()
    #expect(ReviewEngine.repeatsMonthly(MayaBacklog.tailscale, l.state))
    try l.apply(.trackCandidate(MayaBacklog.candidate.id))
    #expect(!l.state.billCandidates.contains { $0.id == MayaBacklog.candidate.id })
    #expect(l.state.bills.first { $0.id == "bill-\(MayaBacklog.candidate.id)" }?.keys == ["tailscale.com"])
    #expect(ReviewEngine.repeatsMonthly(MayaBacklog.tailscale, l.state))
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
    let cards = ReviewEngine.cards(l.state).filter { $0.id == "bl-bright-10" }
    #expect(cards.count == 1)
    let card = try #require(cards.first)
    #expect(card.suggestion == nil && card.suggestedBy == nil)
    let snap = SortedForYouEngine.snapshot(l.state, now: l.now)
    #expect(!snap.items.flatMap(\.txnIDs).contains { $0.hasPrefix("bl-bright") })
    #expect(ActivityEngine.row(row, l.state).toReview)
    #expect(ActivityEngine.row(row, l.state).glyph == .review)
  }
}

@MainActor
@Suite("Sorted for you · source lines")
struct SortedForYouLineTests {
  @Test func automaticFilingsNameTheirSourceInActivityAndTheSheet() throws {
    let l = InMemoryLedger(state: Scenario.mayaBacklog.state)
    try l.apply(.categorize("bl-qasr-1", "groceries", learnRule: true, project: nil))
    let ruled = try #require(l.state.txn("bl-qasr-2"))
    #expect(ruled.autoSourceLabel == "Your rule" && ruled.autoSourceSpoken == "sorted by your rule")
    #expect(ActivityEngine.row(ruled, l.state).detail.hasPrefix("Groceries · Your rule · "))
    let spoken = try #require(ActivityEngine.row(ruled, l.state).spokenDetail)
    #expect(spoken.hasPrefix("Groceries · ") && spoken.hasSuffix(", sorted by your rule") && !spoken.contains("Your rule"))
    #expect(ActivityEngine.dated(ruled, l.state).spokenDetail == nil)
    let person = try #require(l.state.txn("bl-qasr-1"))
    #expect(person.autoSourceLabel == nil)
    #expect(!ActivityEngine.row(person, l.state).detail.contains("Your rule"))
    #expect(ActivityEngine.row(person, l.state).spokenDetail == nil)
    let detail = try #require(TransactionEngine.detail("bl-qasr-2", l.state, now: l.now))
    #expect(detail.sortedBy?.title == "Sorted by your rule")
    #expect(detail.sortedBy?.detail == "Qasr Corner Store → Groceries")

    var s = Scenario.mayaBacklog.state
    for i in s.txns.indices where s.txns[i].merchantGroup == "n:brightwell academy" {
      s.txns[i].needsReview = false
      s.txns[i].categorizedAt = LocalDateTime(2026, 10, 8, 21, 10)
    }
    let cloud = try #require(s.txn("bl-bright-10"))
    #expect(cloud.autoSourceLabel == "Cloudflare AI")
    #expect(ActivityEngine.row(cloud, s).detail.hasPrefix("Shopping · Cloudflare AI · "))
    #expect(ActivityEngine.row(cloud, s).spokenDetail?.hasSuffix(", sorted by Cloudflare AI") == true)
    let snapshot = SortedForYouEngine.snapshot(s, now: MayaLedger.now)
    let item = try #require(snapshot.items.first { $0.source == .cloudflare })
    #expect(item.overline == "CLOUDFLARE AI · THU 8 OCT")
    #expect(item.title == "Brightwell Academy → Shopping")
    #expect(item.spokenHeader == "Cloudflare AI, Thursday 8 October. Brightwell Academy to Shopping, \(ReviewEngine.payments(item.count)).")
    #expect(snapshot.homeSpoken == "\(snapshot.payments) payments sorted for you this week. Look.")
  }
}
