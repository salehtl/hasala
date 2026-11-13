import HasalaMocks
@testable import HasalaModels
import Testing

@Suite("Plan · turn of month and income")
struct PlanTurnOfMonthTests {
  static let june = YearMonth(2026, 6)

  static func ledger(budget: Int64 = 24_000_00) -> LedgerState {
    var s = InsightsFixture.ledger([])
    s.plan.budgets[PlanState.key("1", june)] = .aed(budget)
    return s
  }

  @Test func noIncomeIsUnknownNotOverPlanned() {
    var s = Self.ledger(budget: 2_000_00)
    s.plan.incomeByMonth[Self.june] = .aed(0)
    s.plan.incomeExpectedByMonth[Self.june] = .aed(0)
    s.plan.incomeReceivedByMonth[Self.june] = .aed(0)
    let plan = PlanEngine.snapshot(s, now: LocalDateTime(2026, 6, 1, 9, 0))
    #expect(!plan.incomeKnown)
    #expect(plan.readyToAssign == .aed(0))
    #expect(plan.incomeLine.rendered(hidden: false) == "No income set · planned 2,000")
  }

  @Test func beforePaydayTheLineSaysExpected() {
    var s = Self.ledger()
    s.plan.income = .aed(25_000_00)
    s.plan.payday = 28
    s.plan.incomeExpectedByMonth[Self.june] = .aed(25_000_00)
    s.plan.incomeReceivedByMonth[Self.june] = .aed(0)
    let plan = PlanEngine.snapshot(s, now: LocalDateTime(2026, 6, 10, 9, 0))
    #expect(plan.incomeLine.rendered(hidden: false) == "Expected 25,000 on 28 Jun · planned 24,000")
    #expect(plan.readyToAssign == .aed(1_000_00))
  }

  @Test func aShortSalaryCountsOnceThePaydayWindowHasPassed() {
    var s = Self.ledger()
    s.plan.income = .aed(25_000_00)
    s.plan.payday = 20
    s.plan.incomeByMonth[Self.june] = .aed(25_000_00)
    s.plan.incomeExpectedByMonth[Self.june] = .aed(25_000_00)
    s.plan.incomeReceivedByMonth[Self.june] = .aed(23_000_00)
    let early = PlanEngine.snapshot(s, now: LocalDateTime(2026, 6, 22, 9, 0))
    #expect(early.readyToAssign == .aed(1_000_00))
    #expect(early.incomeLine.rendered(hidden: false) == "23,000 landed so far · 25,000 expected")
    let late = PlanEngine.snapshot(s, now: LocalDateTime(2026, 6, 25, 9, 0))
    #expect(late.readyToAssign == .aed(-1_000_00))
    #expect(late.incomeLine.rendered(hidden: false) == "23,000 landed · 25,000 expected")
  }

  @Test func aLandedSalarySaysSo() {
    var s = Self.ledger()
    s.plan.incomeExpectedByMonth[Self.june] = .aed(25_000_00)
    s.plan.incomeReceivedByMonth[Self.june] = .aed(25_000_00)
    s.plan.incomeByMonth[Self.june] = .aed(25_000_00)
    let plan = PlanEngine.snapshot(s, now: LocalDateTime(2026, 6, 29, 9, 0))
    #expect(plan.incomeLine.rendered(hidden: false) == "Salary landed · 25,000 · planned 24,000")
  }

  @Test func aBillDueLastMonthStaysLateAcrossTheFirst() throws {
    var s = MayaLedger.state
    for i in s.bills.indices where s.bills[i].id == "axa" { s.bills[i].nextDue = LocalDate(2026, 10, 30) }
    let plan = PlanEngine.snapshot(s, now: LocalDateTime(2026, 11, 1, 9, 0))
    let row = try #require(plan.row("insurance"))
    #expect(row.detail.contains { if case .status(let t, .error) = $0 { t.hasPrefix("AXA") } else { false } })
  }

  @Test func billsStillDueBeyondWhatIsLeftAreAboutShort() throws {
    let plan = PlanEngine.snapshot(MayaLedger.state, now: MayaLedger.now)
    let row = try #require(plan.row("utilities"))
    #expect(row.shortfall?.rendered(hidden: false) == "About 17 short")
    #expect(row.shortfall?.rendered(hidden: true).contains("17") == false)
  }
}

@MainActor
@Suite("Plan · assign, copy and moves")
struct PlanAssignTests {
  @Test func assignAddsToTheBudgetOnward() throws {
    let l = InMemoryLedger()
    let m = MayaLedger.october
    let before = l.state.plan.budget("dining", m).minor
    try l.apply(LedgerEdit.assign("dining", m, .aed(100_00), in: l.state))
    #expect(l.state.plan.budget("dining", m).minor == before + 100_00)
  }

  @Test func copyLastMonthOffersOnlyEmptyCategories() {
    var s = PlanTurnOfMonthTests.ledger()
    let may = YearMonth(2026, 5), june = PlanTurnOfMonthTests.june
    s.plan.budgets[PlanState.key("1", may)] = .aed(500_00)
    s.plan.budgets[PlanState.key("2", may)] = .aed(300_00)
    s.plan.budgets[PlanState.key("3", may)] = .aed(200_00)
    s.plan.zeroSet = [PlanState.key("3", june)]
    let plan = PlanEngine.snapshot(s, now: LocalDateTime(2026, 6, 1, 9, 0))
    #expect(Set(plan.lastMonthBudgets.keys) == ["2"])
    #expect(plan.copyLastMonthLabel == "Copy 1 from May")
  }

  @Test func endedMovesAreNamedAndCanBeKept() {
    var s = PlanTurnOfMonthTests.ledger()
    s.plan.expiredMoves = ["2": .aed(318_00), "4": .aed(100_00)]
    let plan = PlanEngine.snapshot(s, now: LocalDateTime(2026, 6, 1, 9, 0))
    #expect(plan.expiredMovesLine == "2 moves from May have ended")
    #expect(plan.keepExpiredMoves(s) == [.setBudget("2", PlanTurnOfMonthTests.june, .aed(318_00)), .setBudget("4", PlanTurnOfMonthTests.june, .aed(100_00))])
  }

  @MainActor @Test func keptMovesAreNotOfferedAgain() throws {
    var s = PlanTurnOfMonthTests.ledger()
    s.plan.expiredMoves = ["2": .aed(318_00), "4": .aed(100_00)]
    let now = LocalDateTime(2026, 6, 1, 9, 0)
    let ledger = InMemoryLedger(state: s, now: now)
    for edit in PlanEngine.snapshot(ledger.state, now: now).keepExpiredMoves(ledger.state) { try ledger.apply(edit) }
    let kept = PlanEngine.snapshot(ledger.state, now: now)
    #expect(kept.expiredMovesLine == nil)
    #expect(kept.keepExpiredMoves(ledger.state).isEmpty)
    #expect(ledger.state.plan.budget("2", PlanTurnOfMonthTests.june) == .aed(318_00))
    #expect(ledger.state.plan.budget("4", PlanTurnOfMonthTests.june) == .aed(100_00))

    var plan = s.plan
    plan.setBudget("2", PlanTurnOfMonthTests.june.next, to: .aed(50_00), thisMonth: PlanTurnOfMonthTests.june)
    #expect(plan.expiredMoves["2"] == .aed(318_00))
    plan.setBudget("2", PlanTurnOfMonthTests.june, to: .aed(0), thisMonth: PlanTurnOfMonthTests.june)
    #expect(plan.expiredMoves["2"] == nil && plan.expiredMoves["4"] == .aed(100_00))
  }

  @Test func onlyTheMovesKeepCanKeepAreNamed() {
    var s = PlanTurnOfMonthTests.ledger()
    s.plan.expiredMoves = ["2": .aed(318_00), "3": .aed(-318_00)]
    let plan = PlanEngine.snapshot(s, now: LocalDateTime(2026, 6, 1, 9, 0))
    #expect(plan.expiredMovesLine == "1 move from May has ended")
    #expect(plan.keepExpiredMoves(s) == [.setBudget("2", PlanTurnOfMonthTests.june, .aed(318_00))])
    s.plan.expiredMoves = ["3": .aed(-318_00)]
    #expect(PlanEngine.snapshot(s, now: LocalDateTime(2026, 6, 1, 9, 0)).expiredMovesLine == nil)
    s.plan.expiredMoves = ["2": .aed(318_00)]
    #expect(PlanEngine.snapshot(s, now: LocalDateTime(2026, 7, 1, 9, 0), month: PlanTurnOfMonthTests.june).expiredMovesLine == nil)
  }
}

@Suite("Pace · fewer false alarms")
struct PaceRuleTests {
  @Test func noOverPaceBeforeDaySeven() {
    #expect(Pace.verdict(spent: 215_40, budget: 2_200_00, day: 3, days: 31, paced: true) == .onTrack)
  }

  @Test func aSmallLeadWithinTheMarginStaysOnTrack() {
    #expect(Pace.verdict(spent: 1_040_00, budget: 3_100_00, day: 10, days: 31, paced: true) == .onTrack)
    #expect(Pace.verdict(spent: 1_100_00, budget: 3_100_00, day: 10, days: 31, paced: true) == .overPace)
  }

  @Test func oneBigPaymentIsProjectedFlat() {
    #expect(Pace.projected(642_75, day: 10, days: 31, largest: 412_00) / 100 * 100 == 1_127_00)
    #expect(Pace.projected(642_75, day: 10, days: 31) / 100 * 100 == 1_992_00)
  }
}

@Suite("Plan · other months")
struct PlanOtherMonthTests {
  @Test func nextMonthOpensFromPayday() {
    var s = MayaLedger.state
    s.plan.payday = 28
    #expect(PlanEngine.selectableMonths(s, today: LocalDate(2026, 10, 10)) == [YearMonth(2026, 8), YearMonth(2026, 9), YearMonth(2026, 10)])
    #expect(PlanEngine.selectableMonths(s, today: LocalDate(2026, 10, 28)).last == YearMonth(2026, 11))
    s.plan.payday = 1
    #expect(PlanEngine.selectableMonths(s, today: LocalDate(2026, 10, 2)).last == YearMonth(2026, 11))
  }

  @Test func aPastMonthIsReadOnlyAndAFutureOneHasNoPace() throws {
    let past = PlanEngine.snapshot(MayaLedger.state, now: MayaLedger.now, month: YearMonth(2026, 9))
    #expect(past.phase == .past && !past.canAssign && past.month == YearMonth(2026, 9))
    let next = PlanEngine.snapshot(MayaLedger.state, now: MayaLedger.now, month: YearMonth(2026, 11))
    #expect(next.phase == .future && next.canAssign)
    #expect(next.sections.flatMap(\.rows).allSatisfy { $0.verdict != .overPace })
  }
}

@Suite("Plan · category details")
struct PlanCategoryDetailTests {
  @Test func aPaidBillLeadsWithWhatWasPaid() throws {
    let rent = try #require(PlanEngine.category("rent", MayaLedger.state, now: MayaLedger.now))
    let paid = try #require(rent.paidBill)
    #expect(paid.total == .aed(7_500_00) && paid.paidOn == LocalDate(2026, 10, 1))
    #expect(paid.line.hasPrefix("Paid · next due about "))
  }

  @Test func utilitiesSaysItIsAboutShort() throws {
    let d = try #require(PlanEngine.category("utilities", MayaLedger.state, now: MayaLedger.now))
    #expect(d.billShort?.rendered(hidden: false) == "About 17 short")
  }

  @Test func theChartRunsUpToToday() throws {
    let d = try #require(PlanEngine.category("dining", MayaLedger.state, now: MayaLedger.now))
    #expect(d.chart.monthDays == 31 && d.chart.running.count == 10)
    #expect(d.chart.running.last == .aed(642_75))
    #expect(d.chart.budget == .aed(1_600_00))
    #expect(d.chart.projection == .aed(1_127_00))
    #expect(d.chart.captionHidden == "\u{2068}Zuma\u{2069} on Wed 7 Oct was the biggest dining payment this month.")
  }

  @Test func noProjectionBeforeDaySeven() throws {
    let d = try #require(PlanEngine.category("dining", MayaLedger.state, now: LocalDateTime(2026, 10, 5, 9, 0)))
    #expect(d.chart.projection == nil)
    #expect(d.verdictFact == nil)
  }
}

@Suite("Plan · payday from imported salary")
struct LastSalaryTests {
  @Test func theNewestSalaryInNinetyDaysNamesTheDay() {
    let s = InsightsFixture.ledger([
      InsightsFixture.txn("salary", 1_000_00, InsightsFixture.june, day: 25, direction: .in),
      InsightsFixture.txn("1", 50_00, InsightsFixture.july, day: 2),
    ])
    #expect(PlanEngine.lastSalary(s, today: LocalDate(2026, 7, 10)) == LocalDate(2026, 6, 25))
    #expect(PlanEngine.lastSalaryLine(s, today: LocalDate(2026, 7, 10)) == "Your last salary came on the 25th.")
    #expect(PlanEngine.lastSalary(s, today: LocalDate(2026, 12, 10)) == nil)
  }
}
