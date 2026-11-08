import HasalaMocks
import HasalaModels
import Testing

@MainActor
@Suite("Bill lifecycle")
struct BillLifecycleTests {
  static func gym(
    cadence: BillCadence = .monthly, every: Int = 1, usualDay: Int = 5, nextDue: LocalDate = LocalDate(2026, 10, 5),
    state: Bill.State = .tracked
  ) -> Bill {
    Bill(id: "gym", name: "Gym", kind: "Fitness", categoryID: "healthcare", amount: .aed(100_00), usualDay: usualDay,
         nextDue: nextDue, state: state, cadence: cadence, every: every)
  }

  static func ledger(with bill: Bill) -> InMemoryLedger {
    var s = MayaLedger.state
    s.bills.append(bill)
    return InMemoryLedger(state: s)
  }

  @Test func markPaidMovesOneStepOfTheBillsOwnCadence() throws {
    let cases: [(BillCadence, Int, LocalDate)] = [
      (.weekly, 1, LocalDate(2026, 10, 12)),
      (.weekly, 2, LocalDate(2026, 10, 19)),
      (.monthly, 1, LocalDate(2026, 11, 5)),
      (.monthly, 3, LocalDate(2027, 1, 5)),
      (.yearly, 1, LocalDate(2027, 10, 5)),
    ]
    for (cadence, every, next) in cases {
      let ledger = Self.ledger(with: Self.gym(cadence: cadence, every: every))
      try ledger.apply(.markBillPaid("gym"))
      let b = try #require(ledger.state.bill("gym"))
      #expect(b.nextDue == next)
      #expect(b.payments.first?.due == LocalDate(2026, 10, 5))
      #expect(b.payments.first?.link == .marked)
    }
  }

  @Test func undoOfMarkPaidPutsTheDueBack() throws {
    let bill = Self.gym(cadence: .weekly)
    let ledger = Self.ledger(with: bill)
    let token = try #require(try ledger.apply(.markBillPaid("gym")))
    ledger.undo(token)
    #expect(ledger.state.bill("gym") == bill)
  }

  @Test func markPaidTakesOnlyARunningExpense() {
    let refused: [(Bill.State, ActionError)] = [(.paused, .invalidBill), (.ended, .invalidBill), (.dismissed, .notFound)]
    for (state, error) in refused {
      let bill = Self.gym(state: state)
      let ledger = Self.ledger(with: bill)
      #expect(throws: error) { try ledger.apply(.markBillPaid("gym")) }
      #expect(ledger.state.bill("gym") == bill)
    }
    let ledger = InMemoryLedger()
    #expect(throws: ActionError.notFound) { try ledger.apply(.markBillPaid("salary")) }
    #expect(throws: ActionError.notFound) { try ledger.apply(.markBillPaid("nope")) }
    #expect(ledger.state.bill("salary") == MayaLedger.state.bill("salary"))
  }

  @Test func notNowOnANewPriceKeepsTheUsualAmountAndEndsTheOffer() throws {
    let ledger = InMemoryLedger()
    #expect(try ledger.apply(.dismissBillNotice("du", noticeID: "priceChange.du")) == nil)
    let du = try #require(ledger.state.bill("du"))
    #expect(du.notices.isEmpty)
    #expect(du.priceChangeFrom == nil)
    #expect(du.amount == .aed(389_00))
    #expect(!BillsEngine.snapshot(ledger.state, now: ledger.now).needsALook.contains { $0.id == "du" })
    #expect(throws: ActionError.notFound) { try ledger.apply(.acceptBillAmount("du")) }
  }

  @Test func dismissingAnotherNoticeLeavesTheNewPriceOpen() throws {
    var s = MayaLedger.state
    let i = try #require(s.bills.firstIndex { $0.id == "du" })
    s.bills[i].notices.append(BillNotice(id: "chargedAfterEnd.x", kind: .chargedAfterEnd(charged: .aed(5_00), on: LocalDate(2026, 10, 1))))
    let ledger = InMemoryLedger(state: s)
    try ledger.apply(.dismissBillNotice("du", noticeID: "chargedAfterEnd.x"))
    let du = try #require(ledger.state.bill("du"))
    #expect(du.notices.map(\.id) == ["priceChange.du"])
    #expect(du.priceChangeFrom == .aed(389_00))
    #expect(du.amount == .aed(427_90))
    try ledger.apply(.acceptBillAmount("du"))
    #expect(ledger.state.bill("du")?.priceChangeFrom == nil)
  }

  @Test func dismissingAnUnknownNoticeChangesNothing() throws {
    let ledger = InMemoryLedger()
    #expect(throws: ActionError.notFound) { try ledger.apply(.dismissBillNotice("du", noticeID: "nope")) }
    #expect(throws: ActionError.notFound) { try ledger.apply(.dismissBillNotice("nope", noticeID: "priceChange.du")) }
    #expect(ledger.state.bill("du") == MayaLedger.state.bill("du"))
  }

  @Test func aPaymentAfterTheBillEndedCannotBeLinked() throws {
    var s = MayaHistory.state
    let i = try #require(s.bills.firstIndex { $0.id == "netflix" })
    s.bills[i].state = .ended
    s.bills[i].endedOn = LocalDate(2026, 8, 6)
    let ledger = InMemoryLedger(state: s)
    #expect(throws: ActionError.invalidBill) { try ledger.apply(.linkBillPayments("netflix", ["h-netflix-9"])) }
    #expect(ledger.state.bill("netflix") == s.bill("netflix"))
    #expect(ledger.state.txn("h-netflix-9")?.billID == nil)
    #expect(throws: ActionError.invalidBill) {
      try ledger.apply(.linkBillPayments("netflix", ["h-netflix-8", "h-netflix-9"]))
    }
    #expect(ledger.state.txn("h-netflix-8")?.billID == nil)
    let token = try #require(try ledger.apply(.linkBillPayments("netflix", ["h-netflix-8"])))
    #expect(ledger.state.txn("h-netflix-8")?.billID == "netflix")
    ledger.undo(token)
    #expect(ledger.state.txn("h-netflix-8")?.billID == nil)
    #expect(ledger.state.bill("netflix") == s.bill("netflix"))
  }
}
