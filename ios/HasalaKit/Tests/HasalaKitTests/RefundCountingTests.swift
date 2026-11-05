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
