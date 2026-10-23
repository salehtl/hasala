import HasalaMocks
import HasalaModels
import Testing

@MainActor
@Suite("In-memory ledger · Always use reaches every payment but the person's own")
struct AlwaysUseReachTests {
  static let earlier = LocalDateTime(2026, 9, 14, 9, 0)

  static func state() throws -> LedgerState {
    var s = Scenario.mayaBacklog.state
    let base = try #require(s.txn("bl-ts-01"))
    func add(_ id: String, _ change: (inout Txn) -> Void) {
      var t = base
      t.id = id
      t.postedAt = LocalDateTime(2026, 6, 3, 3, 10)
      t.needsReview = false
      t.categorizedAt = earlier
      change(&t)
      s.txns.append(t)
    }
    add("ts-dict") { t in
      t.categoryID = "shopping"
      t.categorySource = .dictionary
    }
    add("ts-rule") { t in
      t.categoryID = "dining"
      t.categorySource = .rule(pattern: "tailscale.com")
      t.ruleID = "r-old"
    }
    add("ts-model") { t in
      t.categoryID = "shopping"
      t.categorySource = .model(tag: "cf-clef/1")
    }
    add("ts-user") { t in
      t.categoryID = "dining"
      t.categorySource = .user
    }
    add("ts-held") { t in
      t.needsReview = true
      t.heldCopy = HeldCopy(of: "bl-ts-02", fromOtherInbox: true)
    }
    add("ts-split") { t in
      t.categoryID = "shopping"
      t.categorySource = .dictionary
      t.splits = [
        SplitLine(id: 0, categoryID: "shopping", amount: Money(minor: 3_00, currency: "USD")),
        SplitLine(id: 1, categoryID: "dining", amount: Money(minor: 3_00, currency: "USD")),
      ]
    }
    add("ts-already") { t in
      t.categoryID = "subscriptions"
      t.categorySource = .dictionary
    }
    add("ts-archived") { t in
      t.categoryID = "shopping"
      t.categorySource = .dictionary
      t.archived = true
    }
    return s
  }

  static let refiled = ["ts-dict", "ts-rule", "ts-model"]
  static let untouched = ["ts-user", "ts-held", "ts-split", "ts-already", "ts-archived", "bl-ts-unverified", "bl-ts-refund"]

  @Test func alwaysUseReFilesDictionaryRuleAndModelRowsInEveryMonthButNotThePersonsOwn() throws {
    let before = try Self.state()
    let l = InMemoryLedger(state: before)
    let token = try #require(try l.apply(.categorize("bl-ts-01", "subscriptions", learnRule: true, project: nil)))
    #expect(token.title == "Subscriptions for all 33 Tailscale payments")
    let receipt = try #require(l.state.sortReceipt)
    #expect(receipt.count == 33 && !receipt.txnIDs.contains("ts-already"))
    let rule = try #require(l.state.rules.first { $0.id.hasPrefix("learned-") })
    for id in Self.refiled {
      let t = try #require(l.state.txn(id))
      #expect(t.categoryID == "subscriptions" && t.filedByRule && t.ruleID == rule.id && !t.needsReview, "\(id)")
      #expect(t.priorFiling == before.txn(id)?.filing, "\(id)")
    }
    for id in Self.untouched {
      #expect(l.state.txn(id)?.categoryID == before.txn(id)?.categoryID, "\(id)")
      #expect(l.state.txn(id)?.categorySource == before.txn(id)?.categorySource, "\(id)")
      #expect(l.state.txn(id)?.needsReview == before.txn(id)?.needsReview, "\(id)")
    }
    #expect(l.state.txn("bl-ts-01")?.categorySource == .user)

    l.undo(token)
    for id in Self.refiled + Self.untouched + ["bl-ts-01", "bl-ts-02"] {
      let now = try #require(l.state.txn(id))
      let was = try #require(InMemoryLedger(state: before).state.txn(id))
      #expect(now == was, "\(id)")
    }
    #expect(!l.state.rules.contains { $0.id == rule.id })
  }

  @Test func undoAllPutsEachRowBackAsItWas() throws {
    let before = try Self.state()
    let l = InMemoryLedger(state: before)
    try l.apply(.categorize("bl-ts-01", "subscriptions", learnRule: true, project: nil))
    let item = try #require(SortedForYouEngine.snapshot(l.state, now: l.now).items.first { $0.category.id == "subscriptions" })
    #expect(item.count == 32 && !item.txnIDs.contains("bl-ts-01"))
    let token = try #require(try l.apply(item.undoAll))
    #expect(token.title == "32 payments put back as they were")
    for id in Self.refiled {
      let t = try #require(l.state.txn(id))
      let was = try #require(before.txn(id))
      #expect(t.categoryID == was.categoryID && t.categorySource == was.categorySource, "\(id)")
      #expect(t.ruleID == was.ruleID && t.needsReview == false && !t.inReview && t.priorFiling == nil, "\(id)")
      #expect(t.categorizedAt == Self.earlier, "\(id)")
    }
    let shown = SortedForYouEngine.snapshot(l.state, now: l.now).items
    #expect(shown.allSatisfy { Set($0.txnIDs).isDisjoint(with: Self.refiled) }, "\(shown.map(\.title))")
    for id in item.txnIDs where !Self.refiled.contains(id) {
      let t = try #require(l.state.txn(id))
      #expect(t.inReview && t.categoryID == nil && t.categorySource == nil && t.reachable, "\(id)")
    }
    #expect(!SortedForYouEngine.snapshot(l.state, now: l.now).items.contains { $0.category.id == "subscriptions" })
    l.undo(token)
    #expect(item.txnIDs.allSatisfy { l.state.txn($0)?.categoryID == "subscriptions" && l.state.txn($0)?.filedByRule == true })
  }

  @Test func undoAllAfterUndoingAnUndoAllPutsEachRowBackAgain() throws {
    let before = try Self.state()
    let l = InMemoryLedger(state: before)
    try l.apply(.categorize("bl-ts-01", "subscriptions", learnRule: true, project: nil))
    let item = try #require(SortedForYouEngine.snapshot(l.state, now: l.now).items.first { $0.category.id == "subscriptions" })
    l.undo(try #require(try l.apply(item.undoAll)))
    #expect(Self.refiled.allSatisfy { l.state.txn($0)?.filedByRule == true && l.state.txn($0)?.priorFiling != nil })
    let token = try #require(try l.apply(item.undoAll))
    #expect(token.title == "32 payments put back as they were")
    for id in Self.refiled {
      let t = try #require(l.state.txn(id))
      let was = try #require(before.txn(id))
      #expect(t.categoryID == was.categoryID && t.categorySource == was.categorySource && !t.inReview, "\(id)")
    }
  }

  @Test func aRowWaitsAsRuleReachWaitingDecides() throws {
    let s = MockReach.refreshed(try Self.state())
    func waits(_ id: String, _ change: (inout Txn) -> Void) throws -> Bool {
      var t = try #require(s.txn(id))
      change(&t)
      return t.waits
    }
    #expect(try waits("ts-dict") { $0.needsReview = true } == false)
    #expect(try waits("ts-dict") { $0.categoryID = nil } == true)
    #expect(try waits("ts-rule") { $0.needsReview = true } == false)
    #expect(try waits("ts-model") { $0.needsReview = true } == true)
    #expect(try waits("ts-model") { _ in } == false)
    #expect(try waits("ts-model") { $0.categorySource = .model(tag: "apple-fm/1") } == true)
    #expect(try waits("ts-user") { $0.needsReview = true } == false)
    #expect(try waits("ts-split") { $0.needsReview = true } == false)
    #expect(s.txns.allSatisfy { $0.reachable == $0.waits })
  }

  @Test func aGroupCardsAlwaysUseFilesOnlyTheRowsTheCardCounts() throws {
    let before = try Self.state()
    let l = InMemoryLedger(state: before)
    let card = try #require(ReviewEngine.groupCard(MayaBacklog.tailscale, l.state))
    let token = try #require(try l.apply(.sortGroup(MayaBacklog.tailscale, "subscriptions", alwaysUse: true, project: nil)))
    #expect(token.title == "Sorted \(card.total) Tailscale as Subscriptions")
    #expect(l.state.sortReceipt?.count == card.total && l.state.sortReceipt?.ruleID != nil)
    for id in Self.refiled + Self.untouched {
      #expect(l.state.txn(id)?.categoryID == before.txn(id)?.categoryID, "\(id)")
      #expect(l.state.txn(id)?.categorySource == before.txn(id)?.categorySource, "\(id)")
    }
  }

  static func spellings(_ s: inout LedgerState, _ names: [(String, Int, CategoryID)]) throws {
    let base = try #require(s.txn("bl-ts-01"))
    for (name, count, category) in names {
      for k in 0..<count {
        var t = base
        t.id = "\(name.lowercased().replacingOccurrences(of: " ", with: "-"))-\(k)"
        t.provenance?.rawMerchant = name
        t.postedAt = LocalDateTime(2026, 7, 1 + k, 9, 0)
        t.needsReview = false
        t.categoryID = category
        t.categorySource = .dictionary
        t.categorizedAt = earlier
        s.txns.append(t)
      }
    }
    MockReach.refresh(&s)
  }

  @Test func theSpellingsTheRuleFilesComeBeforeTheOnesAlreadyThere() throws {
    var s = Scenario.mayaBacklog.state
    try Self.spellings(&s, (1...8).map { ("TAILSCALE REF \($0)", 3, "subscriptions") } + [("TAILSCALE REF 9", 1, "shopping")])
    let l = InMemoryLedger(state: s)
    let token = try #require(try l.apply(.categorize("bl-ts-01", "subscriptions", learnRule: true, project: nil)))
    let rule = try #require(l.state.rules.first { $0.id.hasPrefix("learned-") })
    #expect(rule.patterns.count == 8 && rule.patterns.contains("tailscale ref 9"), "\(rule.patterns)")
    #expect(Array(rule.patterns.prefix(4)) == ["tailscale.com", "tailscale inc", "paypal *tailscale", "tailscale ref 9"])
    #expect(l.state.txn("tailscale-ref-9-0")?.categoryID == "subscriptions")
    #expect(token.title == "Subscriptions for all 31 Tailscale payments", "\(token.title)")
  }

  @Test func aSpellingLeftOutOfTheRuleDropsAll() throws {
    var s = Scenario.mayaBacklog.state
    try Self.spellings(&s, (1...9).map { ("TAILSCALE REF \($0)", 1, "shopping") })
    let l = InMemoryLedger(state: s)
    let token = try #require(try l.apply(.categorize("bl-ts-01", "subscriptions", learnRule: true, project: nil)))
    let rule = try #require(l.state.rules.first { $0.id.hasPrefix("learned-") })
    #expect(rule.patterns.count == 8)
    let left = (1...9).map { "tailscale-ref-\($0)-0" }.filter { l.state.txn($0)?.categoryID == "shopping" }
    #expect(left.count == 4)
    #expect(token.title == "Subscriptions for 35 Tailscale payments", "\(token.title)")
  }

  @Test func theWordsForAReachAndItsUndo() {
    #expect(SortResultRow.reachTitle(count: 14, merchant: "Tailscale", category: "Software") == "Software for all 14 Tailscale payments")
    #expect(SortResultRow.reachTitle(count: 1, merchant: "Tailscale", category: "Software") == "Software for 1 Tailscale payment")
    #expect(
      SortResultRow.reachTitle(count: 14, merchant: "Tailscale", category: "Software", all: false) == "Software for 14 Tailscale payments")
    #expect(SortedForYouItem.undoneLine(count: 5, settled: 0) == "5 payments back in Review")
    #expect(SortedForYouItem.undoneLine(count: 1, settled: 0) == "1 payment back in Review")
    #expect(SortedForYouItem.undoneLine(count: 5, settled: 2) == "5 payments put back as they were")
    #expect(SortedForYouItem.undoneLine(count: 1, settled: 1) == "1 payment put back as it was")
  }

  @Test func aRuleForOneMerchantNeverReachesAnotherGroup() throws {
    var s = Scenario.maya.state
    var mart = try #require(s.txn("talabat"))
    mart.id = "talabat-mart"
    mart.merchant = "Talabat Mart"
    mart.merchantKey = "talabat mart"
    mart.merchantGroup = "n:talabat mart"
    mart.categoryID = "groceries"
    mart.categorySource = .dictionary
    s.txns.append(mart)
    var other = try #require(s.txn("talabat"))
    other.id = "talabat-2"
    other.categorySource = .dictionary
    s.txns.append(other)
    let l = InMemoryLedger(state: s)
    let token = try #require(try l.apply(.categorize("talabat", "shopping", learnRule: true, project: nil)))
    #expect(token.title == "Shopping for all 3 Talabat payments", "\(token.title)")
    #expect(l.state.txn("talabat-2")?.categoryID == "shopping" && l.state.txn("talabat-3")?.categoryID == "shopping")
    #expect(l.state.txn("talabat-mart")?.categoryID == "groceries" && l.state.txn("talabat-mart")?.categorySource == .dictionary)
  }

  @Test func aRowWithoutAGroupOrWithASplitShowsNoAlwaysUse() throws {
    let l = InMemoryLedger(state: Scenario.mayaSuggestions.state)
    let tim = try #require(l.state.txn("sug-tim-8"))
    #expect(tim.merchantGroup == nil && !tim.canAlwaysUse)
    #expect(TransactionEngine.detail("sug-tim-8", l.state, now: l.now)?.canAlwaysUse == false)
    #expect(!ReviewEngine.card(tim, l.state).canAlwaysUse)
    let lulu = try #require(l.state.txn("lulu"))
    #expect(lulu.canAlwaysUse && ReviewEngine.card(lulu, l.state).canAlwaysUse)
    #expect(TransactionEngine.detail("lulu", l.state, now: l.now)?.canAlwaysUse == true)
    let rules = l.state.rules
    let token = try #require(try l.apply(.categorize("sug-tim-8", "dining", learnRule: true, project: nil)))
    #expect(token.title == "Sorted into Dining")
    #expect(l.state.rules == rules)

    let lines = [
      SplitLine(id: 0, categoryID: "groceries", amount: .aed(297_00)),
      SplitLine(id: 1, categoryID: "shopping", amount: .aed(45_15)),
    ]
    try l.apply(.split("carrefour", lines))
    #expect(l.state.txn("carrefour")?.canAlwaysUse == false)
    #expect(TransactionEngine.detail("carrefour", l.state, now: l.now)?.canAlwaysUse == false)
  }
}
