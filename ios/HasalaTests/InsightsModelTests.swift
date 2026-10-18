import HasalaMocks
import HasalaModels
import Testing

@testable import Hasala

@MainActor
@Suite("Insights model")
struct InsightsModelTests {
  @Test func opensWithHomesPeriod() {
    let app = AppModel(store: InMemoryLedger(state: MayaHistory.state))
    let model = InsightsModel(app: app)
    #expect(model.months == MayaLedger.october...MayaLedger.october)
    #expect(model.snapshot.status == "Day 10 of 31")
    #expect(model.snapshot.summary.spent == .aed(11_115_62))
    #expect(model.earliest == YearMonth(2026, 4))
  }

  @Test func choosingAPeriodRecomputesAndALedgerChangeFollows() {
    let app = AppModel(store: InMemoryLedger(state: MayaHistory.state))
    let model = InsightsModel(app: app)
    model.showsAllCategories = true
    app.period = .month(YearMonth(2026, 9))
    model.periodChanged()
    #expect(model.snapshot.status == "Closed month")
    #expect(model.snapshot.summary.figure == .aed(6_587_40))
    #expect(!model.showsAllCategories)
    app.period = .month(MayaLedger.october)
    let before = model.snapshot.summary.spent
    app.perform(.markTransfer("atm"))
    #expect(model.snapshot.summary.spent == .aed(before.minor - 500_00))
  }

  @Test func followsHomesPeriodAndOpensTheSharedPicker() {
    let app = AppModel(store: InMemoryLedger(state: MayaHistory.state))
    app.period = Period(YearMonth(2026, 8), MayaLedger.october)
    let model = InsightsModel(app: app)
    #expect(model.months == YearMonth(2026, 8)...MayaLedger.october)
    #expect(model.snapshot.title == app.period.title)
    app.period = .month(YearMonth(2026, 9))
    #expect(model.months == YearMonth(2026, 9)...YearMonth(2026, 9))
    #expect(model.snapshot.status == "Closed month")
    #expect(model.snapshot.summary.spent == app.snapshot.hero.spent)
    model.choosePeriod()
    #expect(app.sheet == .period)
  }

  @Test func theDrillDownTotalIsTheRowItCameFrom() {
    let app = AppModel(store: InMemoryLedger(state: MayaHistory.state))
    let model = InsightsModel(app: app)
    for row in model.snapshot.categories + model.snapshot.buckets + model.snapshot.merchants {
      #expect(model.drill(row.target).total == row.amount, "\(row.title)")
    }
  }

  @Test func netWorthOpensAccountsAndTheOthersDoNotNavigate() {
    let app = AppModel(store: InMemoryLedger(state: MayaHistory.state))
    let model = InsightsModel(app: app)
    model.openReport(.netWorth)
    #expect(app.router.home == [.accounts])
    model.openReport(.ageOfMoney)
    #expect(app.router.home == [.accounts])
    #expect(model.snapshot.reports.filter(\.opens).map(\.kind) == [.netWorth])
  }
}
