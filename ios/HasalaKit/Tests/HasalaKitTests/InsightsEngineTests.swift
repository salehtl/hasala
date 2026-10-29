import HasalaMocks
import HasalaModels
import Testing

enum InsightsFixture {
  static let june = YearMonth(2026, 6)
  static let july = YearMonth(2026, 7)
  static let afterJune = LocalDateTime(2026, 8, 15, 12, 0)

  static let categories: [Category] = [
    Category(id: "1", name: "Groceries", bucket: .needs, glyph: .groceries),
    Category(id: "2", name: "Dining", bucket: .wants, glyph: .dining),
    Category(id: "3", name: "Gifts", bucket: .wants, glyph: .shopping),
    Category(id: "4", name: "Travel", bucket: .wants, glyph: .travel),
    Category(id: "5", name: "Subscriptions", bucket: .wants, glyph: .subscriptions),
    Category(id: "8", name: "Furniture", bucket: .wants, glyph: .shopping),
    Category(id: "rent", name: "Rent", bucket: .needs, glyph: .rent, role: .bill),
    Category(id: "savings", name: "Savings", bucket: .savings, glyph: .savingsJar, role: .saving),
    Category(id: "salary", name: "Salary", kind: .income, bucket: .income, glyph: .salary, role: .none),
    Category(id: "consulting", name: "Consulting income", kind: .income, bucket: .income, glyph: .freelance,
             role: .none),
    Category(id: "transfer", name: "Transfer", kind: .excluded, bucket: .other, glyph: .transfer, role: .none),
  ]

  static func ledger(_ txns: [Txn], projects: [Project] = []) -> LedgerState {
    LedgerState(
      categories: categories, accounts: [], txns: txns,
      plan: PlanState(income: .aed(0), payday: 28, startingSplit: [50, 30, 20], budgets: [:]),
      projects: projects, profile: ProfileInfo(displayName: "Test", email: "test@example.com"),
      mailbox: MailboxHealth(status: .working, lastEmail: "now", banks: "Test Bank"))
  }

  nonisolated(unsafe) static var counter = 0

  static func txn(_ category: CategoryID?, _ minor: Int64, _ month: YearMonth = june, day: Int = 10,
                  merchant: String = "M", direction: Direction = .out, id: String? = nil,
                  splits: [SplitLine] = [], projectID: ProjectID? = nil, needsReview: Bool = false,
                  archived: Bool = false, isTransfer: Bool = false) -> Txn {
    counter += 1
    return Txn(id: id ?? "t\(counter)", merchant: merchant, amount: .aed(minor), direction: direction,
               postedAt: LocalDateTime(month.year, month.month, day, 12, 0), categoryID: category,
               needsReview: needsReview, splits: splits, isTransfer: isTransfer, archived: archived,
               projectID: projectID)
  }

  static func totals(_ s: LedgerState, _ month: YearMonth = june) -> InsightsEngine.Totals {
    InsightsEngine.Totals(InsightsEngine.lines(s, in: InsightsEngine.wholeMonth(month)))
  }
}

@Suite("Insights · delta badge")
struct InsightsDeltaTests {
  @Test func anIncreaseShowsAnUpPercentAndSaysItInFull() {
    let d = InsightsDelta.between(1320, 1000)!
    #expect(d.kind == .up(percent: 32))
    #expect(d.text == "\u{2191} 32%")
    #expect(d.tone == .warning)
    #expect(d.spoken(against: "August") == "up 32 percent from August")
  }

  @Test func newWhenThereWasNothingBefore() {
    let d = InsightsDelta.between(300, 0)!
    #expect(d.kind == .new)
    #expect(d.text == "new")
    #expect(d.tone == .neutral)
  }

  @Test func goneWhenSpendingStopped() {
    let d = InsightsDelta.between(0, 600)!
    #expect(d.kind == .gone)
    #expect(d.text == "gone")
    #expect(d.tone == .success)
  }

  @Test func sameWhenNothingChanged() {
    #expect(InsightsDelta.between(500, 500)?.text == "same")
    #expect(InsightsDelta.between(0, 0)?.kind == .same)
  }

  @Test func onlyAChangeOfTenPercentOrMoreIsColoured() {
    #expect(InsightsDelta.between(1099, 1000)?.tone == .neutral)
    #expect(InsightsDelta.between(1100, 1000)?.tone == .warning)
    #expect(InsightsDelta.between(901, 1000)?.tone == .neutral)
    #expect(InsightsDelta.between(900, 1000)?.tone == .success)
  }

  @Test func percentRoundsHalfUpAndATinyChangeIsNotZero() {
    #expect(InsightsDelta.between(1005, 1000)?.kind == .up(percent: 1))
    #expect(InsightsDelta.between(1004, 1000)?.kind == .up(percent: 0))
    #expect(InsightsDelta.between(1004, 1000)?.text == "\u{2191} <1%")
    #expect(InsightsDelta.between(77_99, 100_00)?.kind == .down(percent: 22))
  }

  @Test func aHugeIncreaseIsCappedInTheBadgeButSpokenInFull() {
    let d = InsightsDelta.between(16_990, 1000)!
    #expect(d.kind == .up(percent: 1599))
    #expect(d.text == "\u{2191} 999%+")
    #expect(d.spoken(against: "August") == "up 1599 percent from August")
    #expect(InsightsDelta.between(10_990, 1000)?.text == "\u{2191} 999%")
    #expect(InsightsDelta.between(11_000, 1000)?.text == "\u{2191} 999%+")
  }

  @Test func noBadgeWhenNothingWasSpentEitherTime() {
    #expect(InsightsDelta.between(-500, 0) == nil)
  }
}

@Suite("Insights · arithmetic")
struct InsightsArithmeticTests {
  @Test func shareIsAPercentOfTheTotalAndZeroWithNoTotal() {
    #expect(InsightsEngine.percent(250, of: 1000) == 25)
    #expect(InsightsEngine.percent(750, of: 1000) == 75)
    #expect(InsightsEngine.percent(0, of: 0) == 0)
    #expect(InsightsEngine.percent(2, of: 3) == 67)
  }

  @Test func keptIsNetOverIncomeAndNoneWithoutIncome() {
    #expect(InsightsEngine.percent(1000 - 800, of: 1000) == 20)
    #expect(InsightsEngine.percent(-300, of: 1000) == -30)
    let s = InsightsFixture.ledger([InsightsFixture.txn("1", 500)])
    let snap = InsightsEngine.snapshot(s, months: InsightsFixture.june...InsightsFixture.june,
                                       now: InsightsFixture.afterJune)
    #expect(snap.summary.kept == nil)
    #expect(snap.summary.isNet == false)
    #expect(snap.summary.figure == .aed(500))
  }

  @Test func averageRoundsTheLastFilHalfUp() {
    #expect(InsightsEngine.average([1, 2]) == 2)
    #expect(InsightsEngine.average([1, 1, 2]) == 1)
    #expect(InsightsEngine.average([]) == 0)
  }

  @Test func topChangesAreTheBiggestByAbsoluteFilsWithoutZeros() {
    let res = InsightsEngine.topChanges(current: ["1": 300, "2": 0, "3": 500, "4": 100],
                                        previous: ["2": 900, "3": 500], limit: 2)
    #expect(res.map(\.category) == ["2", "1"])
  }

  @Test func topChangesBreakTiesByCategoryID() {
    let res = InsightsEngine.topChanges(current: ["5": 200, "8": 200], previous: ["2": 200], limit: 3)
    #expect(res.map(\.category) == ["2", "5", "8"])
  }
}

@Suite("Insights · what counts")
struct InsightsCountingTests {
  typealias F = InsightsFixture

  @Test func categorySpendGroupsByCategoryHighestFirst() {
    let s = F.ledger([F.txn("1", 5000, merchant: "SPINNEYS"), F.txn("1", 3000, merchant: "CARREFOUR"),
                      F.txn("5", 4000, merchant: "NETFLIX")])
    let snap = InsightsEngine.snapshot(s, months: F.june...F.june, now: F.afterJune)
    #expect(snap.categories.map(\.title) == ["Groceries", "Subscriptions"])
    #expect(snap.categories.map(\.amount) == [.aed(8000), .aed(4000)])
    #expect(snap.categories[0].bucket == .needs)
    #expect(snap.categories[0].bar == Permille(1000))
    #expect(snap.categories[1].bar == Permille(500))
  }

  @Test func refundsNetAgainstTheirCategoryAndAreNotIncome() {
    let s = F.ledger([F.txn("1", 10000, day: 1), F.txn("1", 4000, day: 2, direction: .in)])
    let t = F.totals(s)
    #expect(t.byCategory["1"] == 6000)
    #expect(t.spent == 6000)
    #expect(t.income == 0)
  }

  @Test func incomeIsCreditsInIncomeCategories() {
    let s = F.ledger([F.txn("1", 5000, day: 5), F.txn("1", 3000, day: 20), F.txn("salary", 100000, day: 1,
                                                                                    direction: .in)])
    let t = F.totals(s)
    #expect(t.spent == 8000)
    #expect(t.income == 100000)
  }

  @Test func splittingNeverChangesTheTotals() {
    let whole = F.ledger([F.txn("1", 20_000, id: "x")])
    let split = F.ledger([F.txn("1", 20_000, id: "x", splits: [
      SplitLine(id: 1, categoryID: "1", amount: .aed(15_000)), SplitLine(id: 2, categoryID: "2", amount: .aed(5_000)),
    ])])
    #expect(F.totals(whole).spent == 20_000)
    #expect(F.totals(split).spent == 20_000)
    #expect(F.totals(split).byCategory == ["1": 15_000, "2": 5_000])
  }

  @Test func projectSpendOutsideTheMonthlyBudgetIsCarvedOut() {
    var reno = Project(id: "reno", name: "Reno", glyph: .shopping, budget: .aed(0), starts: LocalDate(2026, 6, 1),
                       ends: LocalDate(2026, 6, 30))
    let txns = [F.txn("8", 100_000), F.txn("8", 40_000, projectID: "reno")]
    #expect(F.totals(F.ledger(txns, projects: [reno])).byCategory["8"] == 100_000)
    reno.countInPlan = true
    #expect(F.totals(F.ledger(txns, projects: [reno])).byCategory["8"] == 140_000)
  }

  @Test func incomeIsNeverCarvedOut() {
    let gig = Project(id: "gig", name: "Side gig", glyph: .freelance, budget: .aed(0), starts: LocalDate(2026, 6, 1),
                      ends: LocalDate(2026, 6, 30))
    let s = F.ledger([F.txn("consulting", 500_000, direction: .in, projectID: "gig")], projects: [gig])
    #expect(F.totals(s).income == 500_000)
  }

  @Test func everyExpenseCountsIncludingReviewAndUncategorized() {
    let s = F.ledger([
      F.txn("1", 1000), F.txn("1", 2000, needsReview: true), F.txn("1", 3000, archived: true),
      F.txn("transfer", 4000, isTransfer: true), F.txn(nil, 5000), F.txn("transfer", 6000),
      F.txn(nil, 7000, direction: .in), F.txn("salary", 8000),
    ])
    let t = F.totals(s)
    #expect(t.spent == 8000)
    #expect(t.needs == 3000)
    #expect(t.unsorted == 5000)
  }

  @Test func anUncategorizedRefundIsSubtracted() {
    var refund = F.txn(nil, 400, direction: .in)
    refund.isRefund = true
    let s = F.ledger([F.txn(nil, 1000), refund])
    #expect(F.totals(s).unsorted == 600)
  }

  @Test func splitsCountLineByLineAndSavingsPartsStayOut() {
    let s = F.ledger([F.txn("1", 1000, id: "x", splits: [
      SplitLine(id: 1, categoryID: "1", amount: .aed(600)), SplitLine(id: 2, categoryID: "savings", amount: .aed(400)),
    ])])
    let t = F.totals(s)
    #expect(t.spent == 600)
    #expect(t.saved == 400)
  }

  @Test func uncategorizedSpendingHasItsOwnRowSoThePartsAddUp() {
    let s = F.ledger([F.txn("1", 1000, F.july), F.txn(nil, 500, F.july, needsReview: true), F.txn(nil, 200)])
    let snap = InsightsEngine.snapshot(s, months: F.july...F.july, now: F.afterJune)
    #expect(snap.summary.spent == .aed(1500))
    #expect(snap.categories.map(\.title) == ["Groceries", "Uncategorized"])
    #expect(snap.buckets.map(\.title) == ["Needs", "Not yet sorted"])
    #expect(snap.categories.reduce(Int64(0)) { $0 + $1.amount.minor } == 1500)
    #expect(snap.buckets.reduce(Int64(0)) { $0 + $1.amount.minor } == 1500)
    #expect(snap.summary.legend.map(\.kind) == [.needs, .wants, .unsorted])
    #expect(snap.categories[1].delta?.kind == .up(percent: 150))
    let d = InsightsEngine.drill(s, target: .unsorted, months: F.july...F.july, now: F.afterJune)
    #expect(d.total == .aed(500))
    #expect(d.title == "Not yet sorted · July")
    #expect(d.rows.first?.detail.hasPrefix("Uncategorized · ") == true)
  }

  @Test func spentIsHomesTotal() {
    let s = MayaHistory.state
    for m in Period(YearMonth(2026, 4), MayaLedger.october).months {
      let snap = InsightsEngine.snapshot(s, months: m...m, now: MayaLedger.now)
      #expect(snap.summary.spent == .aed(Spending.total(s, in: m)), "\(m)")
    }
  }

  @Test func savingsIsMovedToSavingsNeverSpending() {
    let s = F.ledger([F.txn("1", 1000), F.txn("savings", 3000), F.txn("salary", 10000, direction: .in)])
    let snap = InsightsEngine.snapshot(s, months: F.june...F.june, now: F.afterJune)
    #expect(snap.summary.spent == .aed(1000))
    #expect(snap.summary.saved == .aed(3000))
    #expect(snap.summary.figure == .aed(9000))
    #expect(snap.summary.kept == "90%")
    #expect(snap.summary.split == InsightsSplit(needs: 1000, wants: 0, savings: 3000, unspent: 6000))
    #expect(!snap.categories.contains { $0.title == "Savings" })
  }

  @Test func notYetSpentIsFlooredAtZero() {
    let s = F.ledger([F.txn("1", 9000), F.txn("savings", 3000), F.txn("salary", 10000, direction: .in)])
    let snap = InsightsEngine.snapshot(s, months: F.june...F.june, now: F.afterJune)
    #expect(snap.summary.split?.unspent == 0)
    #expect(snap.summary.figure == .aed(1000))
  }
}

@Suite("Insights · lenses and changes")
struct InsightsLensTests {
  typealias F = InsightsFixture

  static let state = F.ledger([
    F.txn("1", 2000, F.july), F.txn("2", 500, F.july), F.txn("3", 300, F.july),
    F.txn("1", 1000), F.txn("2", 800), F.txn("4", 600),
  ])

  var snap: InsightsSnapshot {
    InsightsEngine.snapshot(Self.state, months: F.july...F.july, now: F.afterJune)
  }

  @Test func categoryRowsCarryDeltaAndShare() {
    let rows = snap.categories
    #expect(rows.map(\.title) == ["Groceries", "Dining", "Gifts"])
    #expect(rows[0].delta?.kind == .up(percent: 100))
    #expect(rows[1].delta?.kind == .down(percent: 38))
    #expect(rows[2].delta?.kind == .new)
    #expect(rows.map(\.sharePercent) == [71, 18, 11])
  }

  @Test func bucketRowsRankBySpendWithDeltas() {
    let s = F.ledger([F.txn("1", 400, F.july), F.txn("2", 600, F.july), F.txn("1", 500)])
    let rows = InsightsEngine.snapshot(s, months: F.july...F.july, now: F.afterJune).buckets
    #expect(rows.map(\.title) == ["Wants", "Needs"])
    #expect(rows[0].sharePercent == 60)
    #expect(rows[0].delta?.kind == .new)
    #expect(rows[1].delta?.kind == .down(percent: 20))
  }

  @Test func biggestChangesIncludeAGoneCategory() {
    let changes = snap.changes
    #expect(changes.map(\.title) == ["Groceries", "Travel", "Dining"])
    #expect(changes[1].delta.kind == .gone)
    #expect(changes[1].change == .aed(-600))
    #expect(changes[1].before.rendered(hidden: false) == "6.00 in June")
    #expect(changes.first { $0.title == "Groceries" }?.change == .aed(1000))
  }

  @Test func aNewCategorySaysNoneBefore() {
    let s = F.ledger([F.txn("3", 70_000, F.july), F.txn("1", 100)])
    let change = InsightsEngine.snapshot(s, months: F.july...F.july, now: F.afterJune).changes
      .first { $0.title == "Gifts" }
    #expect(change?.before.rendered(hidden: false) == "None in June")
    #expect(change?.delta.kind == .new)
  }

  @Test func merchantsRankBySpendWithShareAndNoDelta() {
    let s = F.ledger([
      F.txn("2", 300, F.july, merchant: "Deliveroo"), F.txn("2", 200, F.july, merchant: "Deliveroo"),
      F.txn("2", 1000, F.july, merchant: "Noon"),
    ])
    let rows = InsightsEngine.snapshot(s, months: F.july...F.july, now: F.afterJune).merchants
    #expect(rows.map(\.title) == ["Noon", "Deliveroo"])
    #expect(rows.map(\.amount) == [.aed(1000), .aed(500)])
    #expect(rows.map(\.count) == [1, 2])
    #expect(rows[0].sharePercent == 67)
    #expect(rows.allSatisfy { $0.delta == nil })
    #expect(rows[1].target == .merchant("Deliveroo"))
  }

  @Test func aMerchantMonogramIsItsFirstLetterOrNone() {
    let s = F.ledger([
      F.txn("2", 600, F.july, merchant: "7-Eleven"), F.txn("2", 500, F.july, merchant: "(Rakuten) Viki"),
      F.txn("2", 400, F.july, merchant: "*talabat"), F.txn("2", 300, F.july, merchant: "1234"),
      F.txn("2", 200, F.july, merchant: ""),
    ])
    let rows = InsightsEngine.snapshot(s, months: F.july...F.july, now: F.afterJune).merchants
    #expect(rows.map(\.monogram) == ["E", "R", "T", nil, nil])
    #expect(rows.map(\.title) == ["7-Eleven", "(Rakuten) Viki", "*talabat", "1234", "Unknown merchant"])
    #expect(rows[4].target == .merchant(""))
    let d = InsightsEngine.drill(s, target: .merchant(""), months: F.july...F.july, now: F.afterJune)
    #expect(d.title == "Unknown merchant · July")
  }

  @Test func merchantsAreCappedAtTwenty() {
    let s = F.ledger((1...25).map { F.txn("2", Int64($0 * 100), F.july, merchant: "M\($0)") })
    let rows = InsightsEngine.snapshot(s, months: F.july...F.july, now: F.afterJune).merchants
    #expect(rows.count == 20)
    #expect(rows.first?.title == "M25")
  }

  @Test func zeroChangesAreLeftOutOfBiggestChanges() {
    let s = F.ledger([F.txn("1", 100, F.july), F.txn("1", 100)])
    let snap = InsightsEngine.snapshot(s, months: F.july...F.july, now: F.afterJune)
    #expect(snap.changes.isEmpty)
    #expect(snap.changesNotice?.title == "Nothing changed")
  }
}

@Suite("Insights · drill-down")
struct InsightsDrillTests {
  typealias F = InsightsFixture

  static let state = F.ledger([
    F.txn("2", 600, F.july, day: 3, merchant: "Deliveroo"), F.txn("5", 400, F.july, day: 4, merchant: "Noon"),
    F.txn("rent", 1000, F.july, day: 1, merchant: "Landlord"),
    F.txn("2", 900, F.july, day: 5, merchant: "Deliveroo", splits: [
      SplitLine(id: 1, categoryID: "2", amount: .aed(500)), SplitLine(id: 2, categoryID: "1", amount: .aed(400)),
    ]),
    F.txn("2", 50, F.july, day: 6, merchant: "Deliveroo", direction: .in),
    F.txn("2", 700, merchant: "Deliveroo"),
  ])

  func drill(_ t: InsightsTarget) -> InsightsDrill {
    InsightsEngine.drill(Self.state, target: t, months: F.july...F.july, now: F.afterJune)
  }

  @Test func aBucketListsItsCategoriesThenItsTransactions() {
    let d = drill(.bucket(.wants))
    #expect(d.categories.map(\.title) == ["Dining", "Subscriptions"])
    #expect(d.categories.map(\.count) == [3, 1])
    #expect(d.rows.map(\.merchant).contains("Deliveroo"))
    #expect(!d.rows.map(\.merchant).contains("Landlord"))
    #expect(d.title == "Wants · July")
  }

  @Test func aMerchantListsOnlyItsTransactions() {
    let d = drill(.merchant("Deliveroo"))
    #expect(Set(d.rows.map(\.merchant)) == ["Deliveroo"])
    #expect(d.transactions == 3)
  }

  @Test func theSheetTotalIsTheSumOfTheSamePartsAsItsRow() {
    let snap = InsightsEngine.snapshot(Self.state, months: F.july...F.july, now: F.afterJune)
    for row in snap.buckets + snap.categories + snap.merchants {
      #expect(drill(row.target).total == row.amount, "\(row.title)")
    }
    for row in snap.summary.legend {
      if let t = row.target { #expect(drill(t).total == row.amount, "\(row.title)") }
    }
    #expect(drill(.category("2")).total == .aed(1050))
    #expect(drill(.category("1")).total == .aed(400))
  }

  @Test func theLineSaysHowManyAndTheChange() {
    let d = drill(.category("2"))
    #expect(d.line.rendered(hidden: false) == "3 transactions · 3.50 more than June")
    #expect(d.rows.first?.amount == .aed(-50))
  }

  @Test func aLongBucketShowsTheLatestTen() {
    let s = F.ledger((1...15).map { F.txn("2", 100, F.july, day: $0, merchant: "M\($0)") })
    let d = InsightsEngine.drill(s, target: .bucket(.wants), months: F.july...F.july, now: F.afterJune)
    #expect(d.rowsTitle == "Latest of 15")
    #expect(d.rows.count == 10)
    #expect(d.rows.first?.merchant == "M15")
    #expect(d.total == .aed(1500))
  }
}

@Suite("Insights · periods")
struct InsightsPeriodTests {
  typealias F = InsightsFixture

  @Test func labels() {
    #expect(InsightsEngine.title(of: F.june...F.june) == "June 2026")
    #expect(InsightsEngine.title(of: YearMonth(2026, 3)...F.june) == "Mar – Jun 2026")
    #expect(InsightsEngine.title(of: YearMonth(2025, 12)...YearMonth(2026, 2)) == "Dec 2025 – Feb 2026")
  }

  @Test func aRangeShowsItsLatestMonth() {
    let s = F.ledger([F.txn("1", 100, YearMonth(2026, 4)), F.txn("1", 200)])
    let snap = InsightsEngine.snapshot(s, months: YearMonth(2026, 4)...F.june, now: F.afterJune)
    #expect(snap.focus == F.june)
    #expect(snap.status == "Jun · latest in range")
    #expect(snap.summary.spent == .aed(200))
  }

  @Test func aClosedMonthComparesWithTheWholeMonthBefore() {
    let s = F.ledger([F.txn("1", 100, F.july, day: 2), F.txn("1", 100, day: 2), F.txn("1", 300, day: 28)])
    let snap = InsightsEngine.snapshot(s, months: F.july...F.july, now: F.afterJune)
    #expect(snap.status == "Closed month")
    #expect(snap.lensNote == "vs June")
    #expect(snap.categories.first?.delta?.kind == .down(percent: 75))
  }

  @Test func theCurrentMonthComparesWithTheSameDayOfTheMonthBefore() {
    let now = LocalDateTime(2026, 7, 10, 9, 0)
    let s = F.ledger([F.txn("1", 100, F.july, day: 2), F.txn("1", 100, day: 2), F.txn("1", 300, day: 28)])
    let snap = InsightsEngine.snapshot(s, months: F.july...F.july, now: now)
    #expect(snap.status == "Day 10 of 31")
    #expect(snap.lensNote == "vs Jun at day 10")
    #expect(snap.categories.first?.delta?.kind == .same)
    #expect(snap.comparison?.window.through == LocalDate(2026, 6, 10))
  }

  @Test func theSameDayIsClampedToAShortMonth() {
    let w = InsightsEngine.comparisonWindow(YearMonth(2026, 3), now: LocalDateTime(2026, 3, 31, 9, 0))
    #expect(w.window.through == LocalDate(2026, 2, 28))
    #expect(w.day == 31)
  }

  @Test func moneyInVsOutIsSixMonthsEndingAtTheChosenMonthWithGapsAtZero() {
    let s = F.ledger([F.txn("1", 100, YearMonth(2026, 1)), F.txn("1", 800, F.june),
                      F.txn("salary", 100_000, F.june, direction: .in)])
    let flow = InsightsEngine.snapshot(s, months: F.june...F.june, now: F.afterJune).flow
    #expect(flow.months.map(\.month) == (1...6).map { YearMonth(2026, $0) })
    #expect(flow.months.map(\.out.minor) == [100, 0, 0, 0, 0, 800])
    #expect(flow.months.last?.income == .aed(100_000))
    #expect(flow.span == "Jan\u{2013}Jun")
    #expect(flow.averageOut == .aed(150))
  }
}

@Suite("Insights · Maya")
struct InsightsMayaTests {
  let s = MayaHistory.state
  let september = YearMonth(2026, 9)

  var snap: InsightsSnapshot {
    InsightsEngine.snapshot(s, months: september...september, now: MayaLedger.now)
  }

  @Test func septemberIsThePaperBoard() {
    let sum = snap.summary
    #expect(snap.title == "September 2026")
    #expect(snap.status == "Closed month")
    #expect(sum.label == "Net · in minus spent")
    #expect(sum.figure == .aed(6_587_40))
    #expect(sum.kept == "26%")
    #expect(sum.income == .aed(25_000_00))
    #expect(sum.legend.map(\.amount) == [.aed(12_580_50), .aed(5_832_10), .aed(5_000_00), .aed(1_587_40)])
    #expect(sum.legend[2].delta?.kind == .same)
    #expect(sum.note.rendered(hidden: false) == "Where 25,000.00 of income went")
    #expect(snap.lensFooter.rendered(hidden: false)
      == "Share of 18,412.60 spent on needs and wants. Tap a row to see its transactions.")
    #expect(snap.flow.span == "Apr\u{2013}Sep")
    #expect(snap.flow.averageOut == .aed(18_774_13))
    #expect(snap.categories.prefix(3).map(\.title) == ["Rent", "Groceries", "Entertainment"])
    #expect(snap.categories.count == 9)
    #expect(snap.categories[0].delta?.kind == .same)
    #expect(snap.categories[1].delta?.kind == .up(percent: 6))
    #expect(snap.changes.map(\.title) == ["Travel", "Healthcare", "Dining"])
    #expect(snap.changes.map(\.delta.kind) == [.gone, .new, .down(percent: 22)])
  }

  @Test func septemberWantsDrillMatchesTheLegend() {
    let d = InsightsEngine.drill(s, target: .bucket(.wants), months: september...september, now: MayaLedger.now)
    #expect(d.total == .aed(5_832_10))
    #expect(d.title == "Wants · September")
    #expect(d.rows.first?.merchant == "Talabat")
    #expect(d.rows.first?.detail == "Dining · Tue 29 Sep")
  }

  @Test func octoberSoFarHasNoIncomeYetAndComparesWithSeptemberAtDayTen() {
    let oct = InsightsEngine.snapshot(s, months: MayaLedger.october...MayaLedger.october, now: MayaLedger.now)
    #expect(oct.status == "Day 10 of 31")
    #expect(oct.summary.label == "Spent so far")
    #expect(oct.summary.figure == .aed(11_115_62))
    #expect(oct.summary.legend.first { $0.kind == .unsorted }?.amount == .aed(827_28))
    #expect(oct.categories.contains { $0.target == .unsorted && $0.amount == .aed(827_28) })
    #expect(oct.summary.kept == nil)
    #expect(oct.lensNote == "vs Sep at day 10")
    #expect(oct.reports.first?.value == .money(.aed(227_568_00)))
    #expect(oct.flow.months.last?.inProgress == true)
    #expect(oct.flow.months.count == 6)
  }

  @Test func netWorthAtTheEndOfLastMonthIsTodayLessThisMonthsChange() {
    #expect(snap.reports.first?.value == .money(.aed(225_428_00)))
    #expect(snap.reports.first?.caption == "End of September")
  }

  @Test func theFirstDaysHaveNothingToCompare() {
    let fresh = InsightsEngine.snapshot(MayaHistory.firstDays, months: MayaLedger.october...MayaLedger.october,
                                        now: MayaHistory.firstDaysNow)
    #expect(fresh.comparison == nil)
    #expect(fresh.status == "Day 3 of 31")
    #expect(fresh.lensNote == "October so far")
    #expect(fresh.summary.figure == .aed(486_75))
    #expect(fresh.summary.legend.map(\.title) == ["Needs", "Wants"])
    #expect(fresh.summary.legend.allSatisfy { $0.delta == nil })
    #expect(fresh.categories.allSatisfy { $0.delta == nil })
    #expect(fresh.categories.map(\.sharePercent) == [70, 15, 15])
    #expect(fresh.changesNotice?.title == "Nothing to compare yet")
    #expect(fresh.changesNotice?.message
      == "Your first scan went back to 2 October. Changes show here once a month has a month before it.")
    #expect(fresh.flowEmpty
      == "Your first full month shows here on 1 November. Each month after that adds a bar, up to six.")
    #expect(fresh.reports.map(\.caption)
      == ["Needs a check-in", "Once income lands", "Needs more history", "Builds with history"])
    #expect(fresh.reports.allSatisfy { $0.value == .missing })
  }

  @Test func theSampleScenarioKeepsTheSeedLedger() {
    #expect(Scenario.mayaSample.state.txns.count == MayaLedger.state.txns.count)
    #expect(Scenario.maya.state.txns.count > MayaLedger.state.txns.count)
  }
}
