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
    #expect(!BillsEngine.snapshot(ledger.state, now: ledger.now).needsALook.contains { $0.billID == "du" })
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

  static func withRentalIncome() -> LedgerState {
    var s = MayaLedger.state
    s.bills.append(Bill(id: "rental", name: "Rental", kind: "Rent", categoryID: "salary", amount: .aed(5_000_00), isIncome: true,
                        usualDay: 1, nextDue: LocalDate(2026, 11, 1)))
    s.plan.income = .aed(30_000_00)
    return s
  }

  @Test func editingOneIncomeLeavesTheOthersInThePlan() throws {
    let ledger = InMemoryLedger(state: Self.withRentalIncome())
    try ledger.apply(.editIncome(id: "rental", amount: .aed(6_000_00), payday: 1, active: true))
    #expect(ledger.state.plan.income == .aed(31_000_00))
    try ledger.apply(.editIncome(id: "rental", amount: .aed(6_000_00), payday: 1, active: false))
    #expect(ledger.state.plan.income == .aed(25_000_00))
    try ledger.apply(.editIncome(id: "rental", amount: .aed(7_000_00), payday: 1, active: false))
    #expect(ledger.state.plan.income == .aed(25_000_00))
    try ledger.apply(.editIncome(id: "rental", amount: .aed(7_000_00), payday: 1, active: true))
    #expect(ledger.state.plan.income == .aed(32_000_00))
  }

  @Test func editingIncomeReplacesEveryFigureFromThisMonthOn() throws {
    let october = MayaLedger.october, september = YearMonth(2026, 9), november = YearMonth(2026, 11)
    var s = MayaLedger.state
    for m in [september, october, november] {
      s.plan.incomeByMonth[m] = .aed(25_000_00)
      s.plan.incomeExpectedByMonth[m] = .aed(25_000_00)
    }
    s.plan.incomeReceivedByMonth[september] = .aed(25_000_00)
    s.plan.incomeReceivedByMonth[october] = .aed(1_000_00)
    let ledger = InMemoryLedger(state: s)
    let token = try #require(try ledger.apply(.editIncome(id: "salary", amount: .aed(26_000_00), payday: 25, active: true)))
    let plan = ledger.state.plan
    #expect(plan.income(in: october) == .aed(26_000_00))
    #expect(plan.expectedIncome(in: october) == .aed(26_000_00))
    #expect(plan.expectedIncome(in: november) == .aed(26_000_00))
    #expect(plan.income(in: september) == .aed(25_000_00))
    #expect(plan.expectedIncome(in: september) == .aed(25_000_00))
    #expect(plan.receivedIncome(in: september) == .aed(25_000_00))
    #expect(plan.receivedIncome(in: october) == .aed(1_000_00))
    ledger.undo(token)
    #expect(ledger.state.plan.expectedIncome(in: october) == .aed(25_000_00))
    #expect(ledger.state.plan.income(in: october) == .aed(25_000_00))
    #expect(ledger.state.plan == s.plan)
  }

  @Test func undoOfAnIncomeEditKeepsALaterForecast() throws {
    let october = MayaLedger.october
    var s = MayaLedger.state
    s.plan.incomeExpectedByMonth[october] = .aed(25_000_00)
    let ledger = InMemoryLedger(state: s)
    let token = try #require(try ledger.apply(.editIncome(id: "salary", amount: .aed(26_000_00), payday: 25, active: true)))
    let later = try #require(try ledger.apply(.editIncome(id: "salary", amount: .aed(27_000_00), payday: 25, active: true)))
    ledger.undo(later)
    #expect(ledger.state.plan.income == .aed(26_000_00))
    ledger.undo(token)
    #expect(ledger.state.plan.income == .aed(25_000_00))
    #expect(ledger.state.plan.expectedIncome(in: october) == .aed(25_000_00))
  }

  @Test func aBudgetSetToZeroIsNotOfferedForCopyingUntilItIsSetAgain() throws {
    let october = MayaLedger.october
    let ledger = InMemoryLedger()
    let token = try #require(try ledger.apply(.setBudget("dining", october, .aed(0))))
    #expect(ledger.state.plan.budget("dining", october) == .aed(0))
    #expect(ledger.state.plan.setToZero("dining", october))
    #expect(PlanEngine.snapshot(ledger.state, now: ledger.now).lastMonthBudgets["dining"] == nil)
    ledger.undo(token)
    #expect(!ledger.state.plan.setToZero("dining", october))
    #expect(ledger.state.plan.budget("dining", october) == MayaLedger.state.plan.budget("dining", october))
  }

  @Test func aLaterAmountEndsTheSetToZero() throws {
    let october = MayaLedger.october
    let ledger = InMemoryLedger()
    let zero = try #require(try ledger.apply(.setBudget("dining", october, .aed(0))))
    let later = try #require(try ledger.apply(.setBudget("dining", october, .aed(100_00))))
    #expect(!ledger.state.plan.setToZero("dining", october))
    ledger.undo(later)
    #expect(ledger.state.plan.setToZero("dining", october))
    ledger.undo(zero)
    #expect(!ledger.state.plan.setToZero("dining", october))
  }

  @Test func undoOfASetToZeroLeavesALaterAmountAlone() throws {
    let october = MayaLedger.october
    let ledger = InMemoryLedger()
    let first = try #require(try ledger.apply(.setBudget("dining", october, .aed(0))))
    try ledger.apply(.setBudget("dining", october, .aed(100_00)))
    ledger.undo(first)
    #expect(ledger.state.plan.budget("dining", october) == .aed(100_00))
    #expect(!ledger.state.plan.setToZero("dining", october))
  }

  @Test func aMoveThatEmptiesABudgetIsNotASetToZero() throws {
    let november = YearMonth(2026, 11)
    let ledger = InMemoryLedger()
    try ledger.apply(.setBudget("entertainment", november, .aed(100_00)))
    try ledger.apply(.moveMoney(from: "entertainment", to: "dining", november, .aed(100_00)))
    #expect(ledger.state.plan.budget("entertainment", november) == .aed(0))
    #expect(!ledger.state.plan.setToZero("entertainment", november))
  }

  @Test func aTrackedCandidateKeepsItsIDAndReplacesAWithdrawnRecord() throws {
    var s = MayaLedger.state
    s.bills.append(Bill(id: "apple-bill", name: "Apple.com/bill", kind: "Subscriptions", categoryID: "subscriptions",
                        amount: .aed(14_99), usualDay: 8, nextDue: LocalDate(2026, 11, 8), state: .dismissed,
                        keys: ["apple-bill"]))
    let ledger = InMemoryLedger(state: s)
    let token = try #require(try ledger.apply(.trackCandidate("apple-bill")))
    let tracked = ledger.state.bills.filter { $0.id == "apple-bill" }
    #expect(tracked.count == 1)
    #expect(tracked.first?.state == .tracked)
    #expect(tracked.first?.keys == ["apple.com/bill"])
    #expect(!ledger.state.billCandidates.contains { $0.id == "apple-bill" })
    ledger.undo(token)
    #expect(ledger.state.bills.filter { $0.id == "apple-bill" }.map(\.state) == [.dismissed])
    #expect(ledger.state.billCandidates.contains { $0.id == "apple-bill" })
  }
}
