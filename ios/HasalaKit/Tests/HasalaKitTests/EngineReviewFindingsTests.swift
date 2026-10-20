import HasalaModels
import Testing

@Suite("Engines · money that never traps")
struct EngineOverflowTests {
  let month = InsightsFixture.june
  let now = LocalDateTime(2026, 6, 20, 12, 0)

  func ledger(_ txns: [Txn]) -> LedgerState {
    var s = InsightsFixture.ledger(txns)
    s.plan.budgets[PlanState.key("1", month)] = .aed(2_000_00)
    s.plan.budgets[PlanState.key("2", month)] = .aed(1_000_00)
    return s
  }

  @Test func helpersClampAtTheEdges() {
    #expect(Fils.sum([Int64.max, 1, 5]) == Int64.max)
    #expect(Fils.sum([Int64.min, -1]) == Int64.min)
    #expect(Int64.max.plus(1) == Int64.max)
    #expect(Int64.min.minus(1) == Int64.min)
    #expect(Int64.min.negated == Int64.max)
    #expect(Fils.mulDiv(Int64.max, 1000, 1) == Int64.max)
    #expect(Fils.mulDiv(10, 3, 0) == 0)
    #expect(Fils.percentRounded(Int64.max, of: Int64.max) == 100)
    #expect(Fils.percentRounded(-1, of: 2) == -50)
    #expect(Permille.ratio(Int64.max, of: 1).value > 1000)
    #expect(Pace.projected(Int64.max, day: 1, days: 31) == Int64.max)
  }

  @Test func aHugeMailAmountInReviewDoesNotTrapAnyScreen() {
    let huge = InsightsFixture.txn("1", Int64.max, month, day: 12, needsReview: true)
    let more = InsightsFixture.txn("1", Int64.max, month, day: 13)
    let unsorted = InsightsFixture.txn(nil, Int64.max, month, day: 14, needsReview: true)
    let s = ledger([huge, more, unsorted])

    #expect(Spending.total(s, in: month) == Int64.max)
    let plan = PlanEngine.snapshot(s, now: now)
    #expect(plan.row("1")?.spent == .aed(Int64.max))
    let home = HomeEngine.snapshot(s, now: now)
    #expect(home.hero.spent == .aed(Int64.max))
    #expect(home.hero.verdict == .overBudget)
    _ = HomeEngine.snapshot(s, now: now, period: Period(YearMonth(2026, 4)...month))
    _ = GlanceEngine.snapshot(s, now: now, home: home, amountsHidden: false)
    _ = InsightsEngine.snapshot(s, months: month...month, now: now)
    _ = ActivityEngine.snapshot(s, now: now, filter: TxnFilter(), period: .month(month))
    _ = ActivityEngine.snapshot(s, now: now, filter: TxnFilter(category: "1"), period: .month(month))
    _ = PlanEngine.category("1", s, now: now)
    _ = TransactionEngine.detail(huge.id, s, now: now)
    _ = AskEngine.answer(s, filter: AskFilter(merchants: ["M"]))
    _ = BillsEngine.snapshot(s, now: now)
  }
}

@Suite("Plan · Ready to assign")
struct ReadyToAssignTests {
  @Test func receivedIncomeAboveTheSourceCounts() {
    let month = InsightsFixture.june
    var s = InsightsFixture.ledger([])
    s.plan.income = .aed(25_000_00)
    s.plan.incomeByMonth[month] = .aed(27_000_00)
    s.plan.budgets[PlanState.key("1", month)] = .aed(24_000_00)
    let plan = PlanEngine.snapshot(s, now: LocalDateTime(2026, 6, 20, 12, 0))
    #expect(plan.readyToAssign == .aed(3_000_00))
    #expect(plan.incomeLine.rendered(hidden: false) == "Income 27,000 · planned 24,000")
  }

  @Test func withoutAMonthFigureTheSourcesStand() {
    let month = InsightsFixture.june
    var s = InsightsFixture.ledger([])
    s.plan.income = .aed(25_000_00)
    s.plan.budgets[PlanState.key("1", month)] = .aed(24_000_00)
    #expect(PlanEngine.snapshot(s, now: LocalDateTime(2026, 6, 20, 12, 0)).readyToAssign == .aed(1_000_00))
  }
}

@Suite("Insights and Ask · held copies and rows with no rate")
struct HeldCopyTotalsTests {
  let month = InsightsFixture.june

  func salary(_ id: String, copyOf: TxnID? = nil) -> Txn {
    var t = InsightsFixture.txn("salary", 25_000_00, month, day: 1, merchant: "ACME", direction: .in, id: id)
    t.heldCopy = copyOf.map { HeldCopy(of: $0, fromOtherInbox: true) }
    return t
  }

  @Test func aHeldSalaryCopyIsNotIncomeTwice() {
    let s = InsightsFixture.ledger([salary("a"), salary("b", copyOf: "a")])
    #expect(InsightsFixture.totals(s).income == 25_000_00)
  }

  @Test func aHeldSavingsCopyIsNotSavedTwice() {
    let a = InsightsFixture.txn("savings", 1_000_00, month, id: "s1")
    var b = InsightsFixture.txn("savings", 1_000_00, month, id: "s2")
    b.heldCopy = HeldCopy(of: "s1", fromOtherInbox: false)
    #expect(InsightsFixture.totals(InsightsFixture.ledger([a, b])).saved == 1_000_00)
  }

  @Test func askLeavesHeldCopiesOutAndMarksRowsWithNoRate() {
    let a = InsightsFixture.txn("1", 100_00, month, merchant: "Carrefour", id: "c1")
    var copy = InsightsFixture.txn("1", 100_00, month, merchant: "Carrefour", id: "c2")
    copy.heldCopy = HeldCopy(of: "c1", fromOtherInbox: true)
    let usd = Txn(id: "u1", merchant: "Carrefour", amount: Money(minor: 40_00, currency: "JPY"),
                  postedAt: LocalDateTime(2026, 6, 11, 12, 0), categoryID: "1")
    let answer = AskEngine.answer(InsightsFixture.ledger([a, copy, usd]), filter: AskFilter(merchants: ["Carrefour"]))
    #expect(answer.total == .aed(100_00))
    #expect(answer.rows.map(\.id).contains("c2") == false)
    #expect(answer.mark?.leftOut == ["JPY": 1])
    #expect(answer.mark?.line == "Not counted: 1 in JPY")
  }

  @Test func askKeepsANetRefundNegative() {
    let spent = InsightsFixture.txn("1", 30_00, month, merchant: "Shop", id: "p")
    var refund = InsightsFixture.txn("1", 80_00, month, merchant: "Shop", direction: .in, id: "r")
    refund.isRefund = true
    let answer = AskEngine.answer(InsightsFixture.ledger([spent, refund]), filter: AskFilter(merchants: ["Shop"]))
    #expect(answer.total == .aed(-50_00))
    #expect(answer.refundedMore)
  }
}

@Suite("Totals · foreign rows with no rate")
struct UnratedTotalsTests {
  let month = InsightsFixture.june
  let now = LocalDateTime(2026, 6, 20, 12, 0)

  func yen(_ id: String, project: ProjectID? = nil, needsReview: Bool = false) -> Txn {
    Txn(id: id, merchant: "Lawson", amount: Money(minor: 5_000_00, currency: "JPY"),
        postedAt: LocalDateTime(2026, 6, 15, 12, 0), categoryID: "4", needsReview: needsReview, projectID: project)
  }

  @Test func aProjectSaysWhatItLeftOut() {
    let trip = Project(id: "japan", name: "Japan", glyph: .travel, budget: .aed(12_000_00), starts: nil, ends: nil)
    let aed = InsightsFixture.txn("4", 1_000_00, month, projectID: "japan")
    var s = InsightsFixture.ledger([aed, yen("y1", project: "japan"), yen("y2", project: "japan", needsReview: true)],
                                   projects: [trip])
    s.rates = []
    let card = PlanEngine.snapshot(s, now: now).projects.first { $0.id == "japan" }
    #expect(card?.spent == .aed(1_000_00))
    #expect(card?.mark?.leftOut == ["JPY": 2])
    #expect(PlanEngine.project("japan", s, now: now)?.mark?.line == "Not counted: 2 in JPY")
  }

  @Test func theHomeHeroSaysWhatItLeftOut() {
    var s = InsightsFixture.ledger([InsightsFixture.txn("1", 100_00, month), yen("y1")])
    s.rates = []
    let hero = HomeEngine.snapshot(s, now: now).hero
    #expect(hero.spent == .aed(100_00))
    #expect(hero.unrated?.line == "Not counted: 1 in JPY")
  }

  @Test func aCarvedOutOrArchivedRowIsNotMarked() {
    let trip = Project(id: "japan", name: "Japan", glyph: .travel, budget: nil, starts: nil, ends: nil)
    var archived = yen("y2")
    archived.archived = true
    var s = InsightsFixture.ledger([yen("y1", project: "japan"), archived], projects: [trip])
    s.rates = []
    #expect(HomeEngine.snapshot(s, now: now).hero.unrated == nil)
  }

  @Test func reviewAndBillsSayWhatTheyLeftOut() {
    var s = InsightsFixture.ledger([yen("y1", needsReview: true)])
    s.rates = []
    #expect(ActivityEngine.reviewSummary(s, now: now).mark?.caption == "1 not counted")
  }
}

@Suite("Glance · short money")
struct ShortMoneyTests {
  @Test func roundsOnceAndPicksTheUnitAfterRounding() {
    #expect(MoneyFormat.short(99_949) == "999")
    #expect(MoneyFormat.short(99_950) == "1K")
    #expect(MoneyFormat.short(1_044_950) == "10.4K")
    #expect(MoneyFormat.short(9_995_000) == "100K")
    #expect(MoneyFormat.short(99_950_000) == "1M")
    #expect(MoneyFormat.short(99_999_900) == "1M")
    #expect(MoneyFormat.short(Int64.max).hasSuffix("M"))
    #expect(MoneyFormat.short(Int64.min).hasSuffix("M"))
  }
}

@Suite("Plan · a category that got money back")
struct NegativeSpendRowTests {
  @Test func aNetRefundReadsAsMoneyBack() {
    let month = InsightsFixture.june
    var refund = InsightsFixture.txn("2", 50_00, month, direction: .in)
    refund.isRefund = true
    var s = InsightsFixture.ledger([refund])
    s.plan.budgets[PlanState.key("2", month)] = .aed(1_600_00)
    let row = PlanEngine.snapshot(s, now: LocalDateTime(2026, 6, 20, 12, 0)).row("2")
    let text = row?.detail.compactMap { part -> String? in
      if case .text(let p) = part { return p.rendered(hidden: false) }
      return nil
    }.joined()
    #expect(text == "+50.00 back · 1,600 planned")
  }
}
