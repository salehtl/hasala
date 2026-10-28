import HasalaMocks
import HasalaModels
import Testing

@Suite("Activity · the chosen period")
struct ActivityPeriodTests {
  let now = MayaLedger.now
  let history = MayaHistory.state

  func ids(_ a: ActivitySnapshot) -> [TxnID] { a.days.flatMap(\.rows).map(\.id) }

  @Test func withoutAPeriodItIsThisMonth() {
    let a = ActivityEngine.snapshot(history, now: now, filter: .all)
    let b = ActivityEngine.snapshot(history, now: now, filter: .all, period: .month(MayaLedger.october))
    #expect(a == b)
    #expect(a.isThisMonth && a.period == .month(MayaLedger.october))
    #expect(a.countLine == "26 transactions this month")
    #expect(ids(a).allSatisfy { !$0.hasPrefix("h-") })
  }

  @Test func aPastMonthListsOnlyItsOwnDays() {
    let a = ActivityEngine.snapshot(history, now: now, filter: .all, period: .month(YearMonth(2026, 9)))
    #expect(!a.isThisMonth)
    #expect(a.days.allSatisfy { $0.date.yearMonth == YearMonth(2026, 9) })
    #expect(ids(a).contains("h-rent-9") && !ids(a).contains("h-rent-8"))
    #expect(a.review == nil && a.comingUp.isEmpty)
    #expect(a.chips.first { $0.kind == .toReview }?.count == 0)
    let n = history.txns.filter { $0.postedAt.date.yearMonth == YearMonth(2026, 9) && !$0.archived }.count
    #expect(a.countLine == "\(n) transactions · September 2026")
    #expect(a.rowCount == n)
    let total = a.days.reduce(Int64(0)) { $0 + $1.total.minor }
    let want = history.txns.filter { $0.postedAt.date.yearMonth == YearMonth(2026, 9) }
      .reduce(Int64(0)) { $0 + ($1.direction == .out ? $1.amount.minor : -$1.amount.minor) }
    #expect(total == want)
  }

  @Test func aRangeTakesEveryMonthAndItsReviewRows() {
    let s = Scenario.mayaRange.state
    let range = Period(YearMonth(2026, 8), YearMonth(2026, 10))
    let a = ActivityEngine.snapshot(s, now: now, filter: .all, period: range)
    let months = Set(a.days.map(\.date.yearMonth))
    #expect(months == [YearMonth(2026, 8), YearMonth(2026, 9), YearMonth(2026, 10)])
    #expect(a.days.first?.title == "Today")
    #expect(zip(a.days, a.days.dropFirst()).allSatisfy { $0.date > $1.date })
    #expect(!ids(a).contains("h-rent-7"))
    let inRange = s.txns.filter { range.contains($0.postedAt.date) && !$0.archived }
    #expect(a.countLine == "\(inRange.count) transactions · Aug – Oct 2026")
    #expect(a.chips.first { $0.kind == .toReview }?.count == 9)
    #expect(a.review?.count == 9)
    #expect(!a.comingUp.isEmpty)
    let toReview = ActivityEngine.snapshot(s, now: now, filter: TxnFilter(kind: .toReview), period: range)
    #expect(Set(ids(toReview)).isSuperset(of: ["aug-corner-shop", "sep-steam", "aug-talabat-copy", "steam"]))
    let october = ActivityEngine.snapshot(s, now: now, filter: TxnFilter(kind: .toReview))
    #expect(!ids(october).contains("aug-corner-shop") && october.review == nil)
    #expect(october.chips.first { $0.kind == .toReview }?.count == 6)
  }

  @Test func theBillsChipCountsTheRange() {
    let range = Period(YearMonth(2026, 8), YearMonth(2026, 10))
    let one = ActivityEngine.snapshot(history, now: now, filter: TxnFilter(kind: .bills))
    let three = ActivityEngine.snapshot(history, now: now, filter: TxnFilter(kind: .bills), period: range)
    let oneCount = one.chips.first { $0.kind == .bills }?.count ?? 0
    let threeCount = three.chips.first { $0.kind == .bills }?.count ?? 0
    #expect(threeCount > oneCount)
    #expect(three.rowCount == threeCount)
  }

  @Test func aCategoryAddsUpTheRange() {
    let range = Period(YearMonth(2026, 8), YearMonth(2026, 10))
    let a = ActivityEngine.snapshot(history, now: now, filter: TxnFilter(category: "dining"), period: range)
    let spent = range.months.reduce(Int64(0)) { $0 + history.spent("dining", in: $1).minor }
    let budget = range.months.reduce(Int64(0)) { $0 + history.plan.budget("dining", $1).minor }
    #expect(a.summary?.total == .aed(spent))
    #expect(a.summary?.progress == Permille.ratio(spent, of: budget))
    #expect(a.rows.contains { $0.id == "h-tashas-8" })
    #expect(ActivityEngine.elapsed(range, today: now.date) == (31 + 30 + 10, 31 + 30 + 31))
    #expect(ActivityEngine.elapsed(.month(YearMonth(2026, 9)), today: now.date) == (30, 30))
  }

  @Test func searchingStillLooksAtEveryMonth() {
    let a = ActivityEngine.snapshot(history, now: now, filter: TxnFilter(text: "pierchic"), period: .month(MayaLedger.october))
    #expect(Set(ids(a)) == ["h-pierchic-8", "h-pierchic-9"])
  }

  @Test func aRangeCrossesTheYear() {
    var s = MayaLedger.state
    s.txns = [
      Txn(id: "nov", merchant: "Spinneys", amount: .aed(10_00), postedAt: LocalDateTime(2025, 11, 30, 23, 59),
          accountID: "dib", categoryID: "groceries", categorySource: .user),
      Txn(id: "dec-1", merchant: "Spinneys", amount: .aed(20_00), postedAt: LocalDateTime(2025, 12, 1, 0, 0),
          accountID: "dib", categoryID: "groceries", categorySource: .user),
      Txn(id: "dec-31", merchant: "Corner Shop", amount: .aed(30_00), postedAt: LocalDateTime(2025, 12, 31, 23, 59),
          accountID: "dib"),
      Txn(id: "jan-1", merchant: "Talabat", amount: .aed(40_00), postedAt: LocalDateTime(2026, 1, 1, 0, 0),
          accountID: "dib", categoryID: "dining", categorySource: .user),
      Txn(id: "jan-31", merchant: "Talabat", amount: .aed(50_00), postedAt: LocalDateTime(2026, 1, 31, 23, 59),
          accountID: "dib", categoryID: "dining", categorySource: .user),
      Txn(id: "feb", merchant: "Talabat", amount: .aed(60_00), postedAt: LocalDateTime(2026, 2, 1, 0, 0),
          accountID: "dib", categoryID: "dining", categorySource: .user),
    ]
    let today = LocalDateTime(2026, 2, 10, 12, 0)
    let range = Period(YearMonth(2026, 1), YearMonth(2025, 12))
    let a = ActivityEngine.snapshot(s, now: today, filter: .all, period: range)
    #expect(a.period.title == "Dec 2025 – Jan 2026")
    #expect(ids(a) == ["jan-31", "jan-1", "dec-31", "dec-1"])
    #expect(a.rowCount == 4)
    #expect(a.countLine == "4 transactions · Dec 2025 – Jan 2026")
    #expect(a.chips.first { $0.kind == .toReview }?.count == 1)
    #expect(a.review?.count == 1)
    #expect(a.comingUp.isEmpty)
    let toReview = ActivityEngine.snapshot(s, now: today, filter: TxnFilter(kind: .toReview), period: range)
    #expect(ids(toReview) == ["dec-31"])
    #expect(ActivityEngine.elapsed(range, today: today.date) == (62, 62))
  }

  @Test func aFutureMonthIsClampedToToday() {
    let a = ActivityEngine.snapshot(history, now: now, filter: .all, period: .month(YearMonth(2026, 12)))
    #expect(a.isThisMonth && a.countLine == "26 transactions this month")
  }
}
