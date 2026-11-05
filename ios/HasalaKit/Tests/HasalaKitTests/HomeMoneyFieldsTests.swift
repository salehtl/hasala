import HasalaMocks
@testable import HasalaModels
import Testing

@Suite("Home · month end, over and pace marks")
struct HomeMoneyFieldsTests {
  @Test func theFirstDaysSayHowLastMonthEnded() throws {
    let home = HomeEngine.snapshot(MayaLedger.state, now: LocalDateTime(2026, 11, 2, 9, 0))
    let closed = try #require(home.monthClosed)
    #expect(closed.month == YearMonth(2026, 10))
    #expect(closed.word.rendered(hidden: false).hasPrefix("October ended "))
    #expect(closed.toSort == 6 && closed.toSortLine == "6 October payments still to sort, which can change this result")
    #expect(HomeEngine.snapshot(MayaLedger.state, now: LocalDateTime(2026, 11, 6, 9, 0)).monthClosed == nil)
  }

  @Test func overSpendingNamesTheCategory() throws {
    var s = MayaLedger.state
    s.txns.append(RefundCountingTests.row("big", 2_000_00, .out, category: "dining"))
    let home = HomeEngine.snapshot(s, now: MayaLedger.now)
    #expect(home.hero.overCategory == "dining")
    let item = try #require(home.notifications.needsALook.first { $0.id == "over.dining" })
    #expect(item.title == "\u{2068}Dining\u{2069} is over budget" && item.destination == .category("dining"))
    #expect(item.line.rendered(hidden: false) == "AED 1,042.75 over")
  }

  @Test func onTrackNamesNoCategory() {
    #expect(HomeEngine.snapshot(MayaLedger.state, now: MayaLedger.now).hero.overCategory == nil)
  }

  @Test func theTickIsSpokenAndPlaced() throws {
    let hero = HomeEngine.snapshot(MayaLedger.state, now: MayaLedger.now).hero
    let tick = try #require(hero.tick)
    #expect(hero.tickShare == Permille.ratio(tick.minor, of: hero.plan.minor))
    #expect(hero.tickPhrase?.spoken(hidden: true) == "today's mark Amount hidden")
  }

  @Test func theBudgetPaceWidgetCountsUnsortedApart() throws {
    let home = HomeEngine.snapshot(MayaLedger.state, now: MayaLedger.now)
    guard case .budgetPace(let w)? = home.widgets.first else { Issue.record("no pace widget"); return }
    #expect(w.unsorted == .aed(827_28))
    #expect(w.unsortedCaption?.rendered(hidden: false) == "Not in a bucket yet: AED 827")
    #expect(home.hero.tiles.filter(\.isApart).map(\.label) == ["Savings"])
    #expect(HomeEngine.defaultLayout(MayaLedger.state, now: MayaLedger.now).showsBudgetPace)
  }

  @Test func aSalaryNotSeenThreeDaysAfterPaydayIsNamed() throws {
    var s = MayaLedger.state
    s.plan.payday = 5
    s.plan.incomeExpectedByMonth[YearMonth(2026, 10)] = .aed(25_000_00)
    s.plan.incomeReceivedByMonth[YearMonth(2026, 10)] = .aed(0)
    let bell = NotificationsEngine.snapshot(s, now: MayaLedger.now)
    let item = try #require(bell.needsALook.first { $0.id == "salary" })
    #expect(item.title == "Salary not seen yet" && item.status == nil)
    #expect(NotificationsEngine.snapshot(MayaLedger.state, now: MayaLedger.now).needsALook.allSatisfy { $0.id != "salary" })
  }
}

@Suite("Home · estimates and no rate")
struct EstimateMarkTests {
  @Test func theHeroSaysHowManyAreEstimated() {
    var s = MayaLedger.state
    s.rates = [CurrencyRate(currency: "USD", rateMicro: 3_672_500)]
    var t = RefundCountingTests.row("usd", 10_00, .out, category: "shopping", home: .some(36_73))
    t.amount = Money(minor: 10_00, currency: "USD")
    t.homeMinor = 36_73
    t.homeSource = .rate
    s.txns.append(t)
    let mark = Spending.unrated(s, in: .month(YearMonth(2026, 10)))
    #expect(mark?.estimated == 1 && mark?.estimateLine == "Includes 1 estimated")
    #expect(mark?.line == nil)
  }

  @Test func aRowWithNoRateSaysWhy() {
    let a = HomeAmount(shown: Money(minor: 25_00, currency: "USD"), notCounted: true, original: Money(minor: 25_00, currency: "USD"))
    #expect(a.notCountedLine == "Not counted. No exchange rate for USD yet.")
    #expect(a.notCountedFigure?.rendered(hidden: false) == "USD 25.00")
    #expect(a.notCountedFigure?.rendered(hidden: true) == "USD •••")
  }
}
