import HasalaMocks
import HasalaModels
import Testing

@Suite("Period")
struct PeriodTests {
  let oct = YearMonth(2026, 10)

  @Test func monthArithmeticCrossesYears() {
    #expect(YearMonth(2026, 1).adding(months: -1) == YearMonth(2025, 12))
    #expect(YearMonth(2025, 11).adding(months: 3) == YearMonth(2026, 2))
    #expect(YearMonth(2025, 11).months(until: YearMonth(2026, 2)) == 3)
    #expect(YearMonth(index: YearMonth(2026, 12).index) == YearMonth(2026, 12))
    #expect(YearMonth(2026, 2).lastDay == LocalDate(2026, 2, 28))
  }

  @Test func titlesReadLikeThePill() {
    #expect(Period.month(oct).title == "October 2026")
    #expect(Period(YearMonth(2026, 8), oct).title == "Aug – Oct 2026")
    #expect(Period(oct, YearMonth(2026, 8)).title == "Aug – Oct 2026")
    #expect(Period(YearMonth(2025, 11), YearMonth(2026, 2)).title == "Nov 2025 – Feb 2026")
    #expect(Period(YearMonth(2026, 8), oct).span == "Aug to Oct")
    #expect(Period(YearMonth(2026, 8), oct).months == [YearMonth(2026, 8), YearMonth(2026, 9), oct])
  }

  @Test func presetsEndThisMonth() {
    #expect(PeriodPreset.thisMonth.period(today: oct) == .month(oct))
    #expect(PeriodPreset.lastMonth.period(today: oct) == .month(YearMonth(2026, 9)))
    #expect(PeriodPreset.last3Months.period(today: oct) == Period(YearMonth(2026, 8), oct))
    #expect(PeriodPreset.thisYear.period(today: oct) == Period(YearMonth(2026, 1), oct))
    #expect(PeriodPreset.last3Months.period(today: YearMonth(2026, 1)) == Period(YearMonth(2025, 11), YearMonth(2026, 1)))
    #expect(Period(YearMonth(2026, 8), oct).preset(today: oct) == .last3Months)
    #expect(Period(YearMonth(2026, 7), oct).preset(today: oct) == nil)
  }

  @Test func nothingReachesPastToday() {
    #expect(Period(YearMonth(2026, 9), YearMonth(2026, 12)).clamped(to: oct) == Period(YearMonth(2026, 9), oct))
    #expect(Period.month(YearMonth(2027, 1)).clamped(to: oct) == .month(oct))
  }

  @Test func aTapPicksAMonthAndASecondMakesARange() {
    var p = PeriodPicking(period: .month(oct), today: oct)
    #expect(p.preset == .thisMonth)
    #expect(p.hint == "Tap a month, or two for a range.")
    #expect(p.confirmTitle == "Show October 2026")
    p.tap(YearMonth(2026, 8))
    #expect(p.period == .month(YearMonth(2026, 8)))
    p.tap(oct)
    #expect(p.period == Period(YearMonth(2026, 8), oct))
    #expect(p.preset == .last3Months)
    #expect(p.hint == "Aug to Oct. Tap a month to start again.")
    #expect(p.confirmTitle == "Show Aug – Oct 2026")
    #expect(p.cell(YearMonth(2026, 8)) == .end)
    #expect(p.cell(YearMonth(2026, 9)) == .between)
    #expect(p.cell(oct) == .end)
    #expect(p.cell(YearMonth(2026, 7)) == .open)
    #expect(p.cell(YearMonth(2026, 11)) == .future)
    p.tap(YearMonth(2026, 3))
    #expect(p.period == .month(YearMonth(2026, 3)))
    p.tap(YearMonth(2026, 11))
    #expect(p.period == .month(YearMonth(2026, 3)))
  }

  @Test func aRangeCanCrossAYear() {
    var p = PeriodPicking(period: .month(oct), today: oct, earliest: YearMonth(2025, 6))
    #expect(!p.canGoForward && p.canGoBack)
    p.previousYear()
    #expect(p.year == 2025 && !p.canGoBack)
    p.tap(YearMonth(2025, 11))
    p.nextYear()
    p.tap(YearMonth(2026, 2))
    #expect(p.period == Period(YearMonth(2025, 11), YearMonth(2026, 2)))
    #expect(p.hint == "Nov 2025 to Feb 2026. Tap a month to start again.")
  }

  @Test func aPresetResetsTheTaps() {
    var p = PeriodPicking(period: .month(oct), today: oct)
    p.tap(YearMonth(2026, 2))
    p.choose(.lastMonth)
    p.tap(YearMonth(2026, 5))
    #expect(p.period == .month(YearMonth(2026, 5)))
    p.choose(.thisYear)
    #expect(p.period == Period(YearMonth(2026, 1), oct))
    #expect(p.year == 2026)
  }
}

@Suite("Total spent")
struct SpendingTests {
  let oct = MayaLedger.october
  let day = LocalDateTime(2026, 10, 9, 12, 0)

  func total(_ s: LedgerState) -> Int64 { Spending.total(s, in: oct) }

  func with(_ txns: Txn...) -> LedgerState {
    var s = MayaLedger.state
    s.txns.append(contentsOf: txns)
    return s
  }

  @Test func mayasOctoberIsEveryExpenseIncludingWhatIsNotSorted() {
    #expect(total(MayaLedger.state) == 11_115_62)
    let s = MayaLedger.state
    let unsorted = s.txns.filter { $0.categoryID == nil && $0.direction == .out && $0.postedAt.date.yearMonth == oct }
    #expect(unsorted.reduce(Int64(0)) { $0 + $1.amount.minor } == 827_28)
  }

  @Test func transfersArchivedAndExcludedKindsDoNotCount() {
    let base = total(MayaLedger.state)
    #expect(total(with(Txn(id: "x1", merchant: "Own account", amount: .aed(900_00), postedAt: day, isTransfer: true))) == base)
    #expect(total(with(Txn(id: "x2", merchant: "Old", amount: .aed(90_00), postedAt: day, categoryID: "dining",
                           archived: true))) == base)
    #expect(total(with(Txn(id: "x3", merchant: "Move", amount: .aed(70_00), postedAt: day, categoryID: "transfer"))) == base)
    #expect(total(with(Txn(id: "x4", merchant: "Pay", amount: .aed(70_00), direction: .in, postedAt: day,
                           categoryID: "salary"))) == base)
    #expect(total(with(Txn(id: "x5", merchant: "Transfer in", amount: .aed(40_00), direction: .in, postedAt: day))) == base)
  }

  @Test func savingsMovesDoNotCount() {
    let base = total(MayaLedger.state)
    #expect(total(with(Txn(id: "s1", merchant: "Jar", amount: .aed(1_000_00), postedAt: day, categoryID: "emergency-fund"))) == base)
    #expect(total(with(Txn(id: "s2", merchant: "Old debt", amount: .aed(100_00), postedAt: day, categoryID: "debt"))) == base)
    var noSavings = MayaLedger.state
    noSavings.txns.removeAll { ["standing-order", "sarwa"].contains($0.id) }
    #expect(total(noSavings) == base)
  }

  @Test func projectsKeptOutOfThePlanDoNotCount() {
    let base = total(MayaLedger.state)
    #expect(total(with(Txn(id: "p1", merchant: "Hotel", amount: .aed(800_00), postedAt: day, categoryID: "travel",
                           projectID: "japan"))) == base)
    var counted = with(Txn(id: "p2", merchant: "Hotel", amount: .aed(800_00), postedAt: day, categoryID: "travel",
                           projectID: "japan"))
    counted.projects[0].countInPlan = true
    #expect(total(counted) == base + 800_00)
  }

  @Test func refundsNetAndSplitsCountByLine() {
    let base = total(MayaLedger.state)
    #expect(total(with(Txn(id: "r1", merchant: "Zuma", amount: .aed(50_00), direction: .in, postedAt: day,
                           categoryID: "dining", isRefund: true))) == base - 50_00)
    #expect(total(with(Txn(id: "r2", merchant: "Noon", amount: .aed(20_00), direction: .in, postedAt: day,
                           isRefund: true))) == base - 20_00)
    let split = Txn(id: "sp", merchant: "Mall", amount: .aed(300_00), postedAt: day, splits: [
      SplitLine(id: 1, categoryID: "shopping", amount: .aed(200_00)),
      SplitLine(id: 2, categoryID: "savings", amount: .aed(100_00)),
    ])
    #expect(total(with(split)) == base + 200_00)
  }

  @Test func archivedCategoriesStillCountAndOtherMonthsDoNot() {
    var s = with(Txn(id: "a1", merchant: "Gym", amount: .aed(30_00), postedAt: day, categoryID: "dining"))
    s.categories[s.categories.firstIndex { $0.id == "dining" }!].archived = true
    #expect(total(s) == 11_115_62 + 30_00)
    #expect(Spending.total(MayaLedger.state, in: YearMonth(2026, 9)) == 689_80)
    #expect(Spending.total(MayaLedger.state, in: Period(YearMonth(2026, 8), oct)) == 11_805_42)
  }
}

@Suite("Home · period")
struct HomePeriodTests {
  let s = MayaLedger.state
  let now = MayaLedger.now
  let sep = YearMonth(2026, 9)

  @Test func thisMonthIsTheDefaultHome() {
    #expect(HomeEngine.snapshot(s, now: now, period: .month(MayaLedger.october)) == HomeEngine.snapshot(s, now: now))
    #expect(HomeEngine.snapshot(s, now: now, period: .month(YearMonth(2027, 1))) == HomeEngine.snapshot(s, now: now))
    #expect(HomeEngine.snapshot(s, now: now).isThisMonth)
  }

  @Test func aClosedMonthEnds() {
    let home = HomeEngine.snapshot(s, now: now, period: .month(sep))
    let h = home.hero
    #expect(!home.isThisMonth && home.period == .month(sep))
    #expect(h.state == .ended)
    #expect(h.overline == "Month ended")
    #expect(h.spent == .aed(689_80))
    #expect(h.caption.rendered(hidden: false) == "spent of 19,000 planned")
    #expect(h.word.rendered(hidden: false) == "Ended 18,310.20 under")
    #expect(h.word.rendered(hidden: true) == "Ended ••• under")
    #expect(h.verdict == .onTrack && h.tick == nil && h.wash == .sky)
    #expect(h.tiles.map(\.value) == [.aed(689_80), .aed(0), .aed(0)])
    #expect(h.note == nil)
    #expect(home.canvasTitle == "September")
    guard case .budgetPace(let pace) = home.widgets.first, home.widgets.count == 1 else {
      Issue.record("a closed month shows Budget pace alone")
      return
    }
    #expect(pace.monthGone == "Ended 30 Sep")
    #expect(home.aboutNow.map(\.title) == ["Next bill · DEWA", "To review"])
    #expect(home.aboutNow.map { $0.detail.rendered(hidden: false) } == ["~489.15 · in 4 days", "6 waiting"])
    #expect(home.aboutNow.map(\.destination) == [.bills, .review])
  }

  @Test func aClosedMonthOverItsPlanNamesTheTopWant() {
    var over = s
    over.txns.append(Txn(id: "big", merchant: "Zuma", amount: .aed(19_000_00), postedAt: LocalDateTime(2026, 9, 20, 21, 0),
                         categoryID: "dining"))
    over.txns.append(Txn(id: "film", merchant: "VOX", amount: .aed(80_00), postedAt: LocalDateTime(2026, 9, 21, 21, 0),
                         categoryID: "entertainment"))
    let h = HomeEngine.snapshot(over, now: now, period: .month(sep)).hero
    #expect(h.verdict == .overBudget && h.wash == .rose)
    #expect(h.word.rendered(hidden: false) == "Ended 769.80 over")
    #expect(h.note?.rendered(hidden: false) == "Dining 19,000.00 · your top want")
  }

  @Test func aClosedMonthWithoutAPlan() {
    let h = HomeEngine.snapshot(s, now: now, period: .month(YearMonth(2026, 7))).hero
    #expect(h.state == .ended && h.verdict == nil)
    #expect(h.word.rendered(hidden: false) == "No plan for July")
    #expect(h.caption.rendered(hidden: false) == "spent in July")
  }

  @Test func aRangeHasABarPerMonth() {
    let home = HomeEngine.snapshot(s, now: now, period: Period(YearMonth(2026, 8), MayaLedger.october))
    let h = home.hero
    #expect(h.state == .range)
    #expect(h.overline == "3 months · Oct to day 10")
    #expect(h.spent == .aed(11_805_42))
    #expect(h.plan == .aed(57_000_00))
    #expect(h.caption.rendered(hidden: false) == "spent of 57,000 planned")
    #expect(h.bars.map(\.label) == ["Aug", "Sep", "Oct"])
    #expect(h.bars.map(\.spent) == [.aed(0), .aed(689_80), .aed(11_115_62)])
    #expect(h.bars.map(\.verdict) == [.onTrack, .onTrack, .onTrack])
    #expect(h.word.rendered(hidden: false) == "Average 344.90")
    #expect(h.fact?.rendered(hidden: false) == "full months only")
    #expect(h.tiles.map { MoneyFormat.string($0.value.minor, style: $0.style) } == ["9,731", "1,248", "5,000"])
    #expect(home.widgets.isEmpty)
    #expect(home.aboutNow.map { $0.detail.rendered(hidden: false) }.last == "6 waiting")
  }

  @Test func aPastRangeHasNoToday() {
    let h = HomeEngine.snapshot(s, now: now, period: Period(YearMonth(2026, 8), sep)).hero
    #expect(h.overline == "2 months")
    #expect(h.word.rendered(hidden: false) == "Average 344.90")
  }
}
