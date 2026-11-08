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
}
