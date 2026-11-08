import HasalaMocks
@testable import HasalaModels
import Testing

@Suite("Refunds count against spending")
struct RefundCountingTests {
  static let now = MayaLedger.now
  static let october = Period.month(YearMonth(2026, 10))

  static func with(_ rows: Txn...) -> LedgerState {
    var s = MayaLedger.state
    s.txns.append(contentsOf: rows)
    return s
  }

  static func row(
    _ id: TxnID, _ minor: Int64, _ direction: Direction, category: CategoryID?, refundOf: TxnID? = nil, home: Int64?? = nil
  ) -> Txn {
    Txn(
      id: id, merchant: "Test Store", amount: .aed(minor), homeMinor: home, direction: direction,
      postedAt: LocalDateTime(2026, 10, 8, 9, 0), categoryID: category, categorySource: .user,
      isRefund: category == "refunds", refundOf: refundOf)
  }

  @Test func aCreditFiledAsRefundsLowersTheTotal() {
    let base = Spending.total(MayaLedger.state, in: Self.october)
    let s = Self.with(Self.row("r1", 500_00, .in, category: "refunds"))
    #expect(Spending.total(s, in: Self.october) == base - 500_00)
  }

  @Test func aRefundLinkedToAPurchaseNetsInThatCategory() {
    let purchase = Self.row("p1", 800_00, .out, category: "shopping")
    let refund = Self.row("r1", 500_00, .in, category: "refunds", refundOf: "p1")
    let before = Self.with(purchase)
    let after = Self.with(purchase, refund)
    #expect(
      Spending.spent(after, category: "shopping", in: Self.october)
        == Spending.spent(before, category: "shopping", in: Self.october) - 500_00)
    #expect(Spending.total(after, in: Self.october) == Spending.total(before, in: Self.october) - 500_00)
    let parts = Spending.parts(refund, in: after)
    #expect(parts.count == 1 && parts[0].category?.id == "shopping" && parts[0].minor == -500_00)
  }

  @Test func aRefundCreditInASpendingCategoryNets() {
    let base = Spending.spent(MayaLedger.state, category: "shopping", in: Self.october)
    let s = Self.with(Self.row("r1", 500_00, .in, category: "shopping"))
    #expect(Spending.spent(s, category: "shopping", in: Self.october) == base - 500_00)
  }

  @Test func aPurchaseMarkedAsARefundStillCounts() {
    let base = Spending.total(MayaLedger.state, in: Self.october)
    let s = Self.with(Self.row("d1", 500_00, .out, category: "refunds"))
    #expect(Spending.total(s, in: Self.october) == base + 500_00)
  }

  @Test func aRefundWithNoRateIsMarkedNotCounted() {
    let s = Self.with(Self.row("r1", 500_00, .in, category: "refunds", home: .some(nil)))
    #expect(Spending.unrated(s.txns.last!, in: s))
  }
}

@MainActor
@Suite("Refund and transfer edits")
struct RefundEditTests {
  static let october = Period.month(YearMonth(2026, 10))

  static func ledger() -> InMemoryLedger {
    var s = MayaLedger.state
    s.txns.append(RefundCountingTests.row("p1", 800_00, .out, category: "shopping"))
    s.txns.append(RefundCountingTests.row("c1", 500_00, .in, category: nil))
    s.txns[s.txns.count - 1].needsReview = true
    return InMemoryLedger(state: s)
  }

  @Test func markingAPurchaseAsARefundIsRefused() {
    let l = Self.ledger()
    let before = Spending.total(l.state, in: Self.october)
    #expect(throws: ActionError.refused(RefundEdit.refusedOut)) { try l.apply(.markRefund("p1")) }
    #expect(l.state.txn("p1")?.direction == .out)
    #expect(Spending.total(l.state, in: Self.october) == before)
  }

  @Test func aRefundFiledToThePurchaseNetsThere() throws {
    let l = Self.ledger()
    let before = Spending.spent(l.state, category: "shopping", in: Self.october)
    let token = try #require(try l.apply(.fileRefund("c1", into: "shopping", of: "p1")))
    #expect(token.title == "Refund · Shopping")
    let t = try #require(l.state.txn("c1"))
    #expect(t.direction == .in && t.isRefund && t.refundOf == "p1" && !t.needsReview)
    #expect(Spending.spent(l.state, category: "shopping", in: Self.october) == before - 500_00)
  }

  @Test func markingACreditWithNoCategoryUsesTheRefundsFallbackAndStillNets() throws {
    let l = Self.ledger()
    let before = Spending.total(l.state, in: Self.october)
    try l.apply(.markRefund("c1"))
    #expect(l.state.txn("c1")?.categoryID == "refunds")
    #expect(Spending.total(l.state, in: Self.october) == before - 500_00)
    try l.apply(.markRefund("c1"))
    let t = try #require(l.state.txn("c1"))
    #expect(!t.isRefund && t.categoryID == nil && t.needsReview)
  }

  @Test func aRefundCannotPointAtMoneyIn() {
    let l = Self.ledger()
    #expect(throws: ActionError.refused(RefundEdit.refusedTarget)) {
      try l.apply(.fileRefund("c1", into: "shopping", of: "c1"))
    }
  }

  @Test func markTransferTogglesBackToReview() throws {
    let l = Self.ledger()
    try l.apply(.markTransfer("p1"))
    #expect(l.state.txn("p1")?.isTransfer == true)
    let token = try #require(try l.apply(.markTransfer("p1")))
    #expect(token.title == "No longer a transfer")
    let t = try #require(l.state.txn("p1"))
    #expect(!t.isTransfer && t.categoryID == nil && t.needsReview)
  }

  static func ledger(with row: Txn) -> InMemoryLedger {
    var s = MayaLedger.state
    s.txns.append(RefundCountingTests.row("p1", 800_00, .out, category: "shopping"))
    s.txns.append(row)
    return InMemoryLedger(state: s)
  }

  static func markedTransfer(_ id: TxnID) -> Txn {
    var t = RefundCountingTests.row(id, 500_00, .in, category: "transfer")
    t.isTransfer = true
    return t
  }

  static func matchedTransfer(_ id: TxnID, category: CategoryID?) -> Txn {
    var t = RefundCountingTests.row(id, 500_00, .in, category: category)
    t.isTransfer = true
    t.isMatchedTransfer = true
    return t
  }

  static func filedByRule(_ id: TxnID, _ direction: Direction) -> Txn {
    var t = RefundCountingTests.row(id, 500_00, direction, category: "shopping")
    t.categorySource = .rule(pattern: "TEST STORE")
    t.ruleID = "r"
    t.priorFiling = PriorFiling(categoryID: nil, categorySource: nil, ruleID: nil, needsReview: true)
    return t
  }

  @Test func aCreditMarkedATransferBecomesARefundThatCounts() throws {
    let l = Self.ledger(with: Self.markedTransfer("c1"))
    let before = Spending.total(l.state, in: Self.october)
    try l.apply(.markRefund("c1"))
    let t = try #require(l.state.txn("c1"))
    #expect(t.isRefund && !t.isTransfer && t.categoryID == "refunds" && t.countsInPlan)
    #expect(Spending.total(l.state, in: Self.october) == before - 500_00)
  }

  @Test func aRefundFiledFromATransferIsNoLongerATransfer() throws {
    let l = Self.ledger(with: Self.markedTransfer("c1"))
    try l.apply(.fileRefund("c1", into: "shopping", of: "p1"))
    let t = try #require(l.state.txn("c1"))
    #expect(t.isRefund && !t.isTransfer && t.categoryID == "shopping" && t.countsInPlan)
  }

  @Test func undoPutsATransferBackAfterARefund() throws {
    let l = Self.ledger(with: Self.markedTransfer("c1"))
    let token = try #require(try l.apply(.markRefund("c1")))
    l.undo(token)
    let t = try #require(l.state.txn("c1"))
    #expect(t.isTransfer && !t.isRefund && t.categoryID == "transfer")
  }

  @Test func aMatchedTransferIsNotARefund() throws {
    for category in ["transfer", nil] as [CategoryID?] {
      let l = Self.ledger(with: Self.matchedTransfer("c1", category: category))
      let before = try #require(l.state.txn("c1"))
      #expect(throws: ActionError.refused(RefundEdit.refusedMatchedTransfer)) { try l.apply(.markRefund("c1")) }
      #expect(throws: ActionError.refused(RefundEdit.refusedMatchedTransfer)) {
        try l.apply(.fileRefund("c1", into: "shopping", of: "p1"))
      }
      #expect(l.state.txn("c1") == before)
    }
  }

  @Test func aMatchedTransferAlreadyMarkedARefundCanBeTakenBackAndStaysATransfer() throws {
    var row = Self.matchedTransfer("c1", category: "refunds")
    row.isRefund = true
    let l = Self.ledger(with: row)
    try l.apply(.markRefund("c1"))
    let t = try #require(l.state.txn("c1"))
    #expect(!t.isRefund && t.isTransfer && t.isMatchedTransfer && t.categoryID == nil && t.needsReview)
  }

  @Test func aRefundMarkedATransferIsNoLongerARefund() throws {
    let l = Self.ledger()
    try l.apply(.markRefund("c1"))
    try l.apply(.markTransfer("c1"))
    let t = try #require(l.state.txn("c1"))
    #expect(t.isTransfer && !t.isRefund)
  }

  @Test func aRefundOrTransferFilingLeavesNoRuleFilingToPutBack() throws {
    let edits: [(Direction, LedgerEdit)] = [
      (.in, .markRefund("c1")), (.in, .fileRefund("c1", into: "shopping", of: "p1")), (.out, .markTransfer("c1")),
    ]
    for (direction, edit) in edits {
      let row = Self.filedByRule("c1", direction)
      let l = Self.ledger(with: row)
      let token = try #require(try l.apply(edit))
      #expect(l.state.txn("c1")?.priorFiling == nil, "\(edit)")
      l.undo(token)
      #expect(l.state.txn("c1")?.priorFiling == row.priorFiling, "\(edit)")
    }
  }
}

@Suite("Possible repeats are held out until answered")
struct HeldOutTests {
  static let october = Period.month(YearMonth(2026, 10))

  @Test func aSamePurchaseRowAndAMayRepeatRowDoNotCount() {
    var aed = RefundCountingTests.row("sp", 93_00, .out, category: "shopping")
    aed.samePurchase = SamePurchaseMatch(of: "usd")
    var mail = RefundCountingTests.row("mr", 4_321_09, .out, category: nil)
    mail.needsReview = true
    mail.mayRepeat = MayRepeat(of: "text", line: "")
    let base = Spending.total(MayaLedger.state, in: Self.october)
    let s = RefundCountingTests.with(aed, mail)
    #expect(Spending.total(s, in: Self.october) == base)
    #expect(Spending.heldOut(s, in: Self.october) == 93_00 + 4_321_09)
    let hero = HomeEngine.snapshot(s, now: MayaLedger.now).hero
    #expect(hero.heldOutLine?.rendered(hidden: false) == "Maybe a repeat: AED 4,414.09 not counted until you answer")
  }

  @Test func aSortedMayRepeatRowCounts() {
    var mail = RefundCountingTests.row("mr", 100_00, .out, category: "shopping")
    mail.mayRepeat = MayRepeat(of: "text", line: "")
    let base = Spending.total(MayaLedger.state, in: Self.october)
    #expect(Spending.total(RefundCountingTests.with(mail), in: Self.october) == base + 100_00)
  }
}

@Suite("Reversals")
struct ReversalTests {
  static let october = Period.month(YearMonth(2026, 10))

  static func pair() -> LedgerState {
    var hold = RefundCountingTests.row("h1", 500_00, .out, category: "shopping")
    hold.merchantGroup = "hotel"
    var back = RefundCountingTests.row("h2", 500_00, .in, category: "refunds", refundOf: "h1")
    back.isReversal = true
    back.merchantGroup = "hotel"
    var final = RefundCountingTests.row("h3", 480_00, .out, category: "shopping")
    final.merchantGroup = "hotel"
    return RefundCountingTests.with(hold, back, final)
  }

  @Test func aReversedPurchaseNetsToTheFinalCharge() {
    let base = Spending.total(MayaLedger.state, in: Self.october)
    #expect(Spending.total(Self.pair(), in: Self.october) == base + 480_00)
  }

  @Test func bothRowsSayWhatHappened() throws {
    let s = Self.pair()
    #expect(ActivityEngine.row(try #require(s.txn("h1")), s).detail.hasPrefix("Reversed · Shopping"))
    #expect(ActivityEngine.row(try #require(s.txn("h2")), s).detail.hasPrefix("Reversal · Shopping"))
  }

  @Test func aReversalFindsItsOnePurchase() throws {
    var s = Self.pair()
    var lone = RefundCountingTests.row("h4", 480_00, .in, category: nil)
    lone.merchantGroup = "hotel"
    s.txns.append(lone)
    #expect(RefundEdit.reversalCandidates(for: lone, in: s).map(\.id) == ["h3"])
    let first = try #require(s.txn("h2"))
    #expect(RefundEdit.reversalCandidates(for: first, in: s).isEmpty)
  }
}

@Suite("Transaction detail · what can change")
struct TransactionEditFactsTests {
  @Test func aBankRowCannotChangeItsAmountAndAManualOneCan() throws {
    var s = MayaLedger.state
    var bank = RefundCountingTests.row("bank", 50_00, .out, category: "shopping")
    bank.provenance = Provenance(title: "Bank transaction alert", readAt: "Read automatically", rawMerchant: "TEST STORE")
    let hand = RefundCountingTests.row("hand", 20_00, .out, category: "shopping")
    s.txns += [bank, hand]
    let b = try #require(TransactionEngine.detail("bank", s, now: MayaLedger.now))
    #expect(!b.canEditAmount && b.canEditDate && !b.isManual)
    let h = try #require(TransactionEngine.detail("hand", s, now: MayaLedger.now))
    #expect(h.canEditAmount && h.isManual)
  }

  @Test func aReversalPairPointsBothWays() throws {
    let s = ReversalTests.pair()
    #expect(try #require(TransactionEngine.detail("h1", s, now: MayaLedger.now)).reversedBy == "h2")
    #expect(try #require(TransactionEngine.detail("h2", s, now: MayaLedger.now)).reversalOf == "h1")
  }
}
