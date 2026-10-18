import Foundation
import HasalaMocks
import HasalaModels
import Testing

@testable import Hasala

@MainActor
@Suite("Home layout persistence")
struct HomeLayoutPersistenceTests {
  let defaults: UserDefaults

  init() {
    let suite = "test.homeLayout.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
  }

  func store(_ account: String) -> HomeLayoutStore { HomeLayoutStore(defaults: defaults, account: account) }

  @Test func eachAccountKeepsItsOwnLayout() {
    let maya = store("digest-maya")
    let omar = store("digest-omar")
    maya.save(HomeLayout([HomeLayout.Entry(.today)]))
    #expect(omar.load() == nil)
    omar.save(HomeLayout([HomeLayout.Entry(.toReview), HomeLayout.Entry(.budgetPace)]))
    #expect(maya.load()?.ids == ["today"])
    #expect(omar.load()?.ids == ["toReview", "budgetPace"])
    maya.forget()
    #expect(maya.load() == nil)
    #expect(omar.load() != nil)
    HomeLayoutStore.forgetAll(defaults)
    #expect(omar.load() == nil)
  }

  @Test func aStoredLayoutWithRetiredKindsLoadsWhatIsLeft() {
    let json = #"{"version":1,"entries":[{"kind":"crypto","size":"small"},{"kind":"today","size":"medium"}]}"#
    defaults.set(Data(json.utf8), forKey: store("a").key)
    #expect(store("a").load()?.ids == ["today"])
    defaults.set(Data("not json".utf8), forKey: store("a").key)
    #expect(store("a").load() == nil)
  }

  @Test func theLayoutSurvivesARelaunchAndGoesAtSignOut() {
    let first = AppModel(store: InMemoryLedger(), layouts: store("maya"))
    let start = first.homeCanvas.map(\.id)
    #expect(start == ["budgetPace", "nextBill", "netWorth", "project.japan", "goal.emergency", "today"])
    #expect(first.homeLayout == nil)
    #expect(first.removeWidget("netWorth"))
    #expect(first.moveWidget("today", to: 0))
    #expect(first.addWidget(HomeLayout.Entry(.categoryWatch, config: .category("dining"))))
    #expect(!first.addWidget(HomeLayout.Entry(.today)))
    #expect(first.moveWidget("today", by: 1))
    let edited = ["budgetPace", "today", "nextBill", "project.japan", "goal.emergency", "categoryWatch.dining"]
    #expect(first.homeCanvas.map(\.id) == edited)

    let relaunched = AppModel(store: InMemoryLedger(), layouts: store("maya"))
    #expect(relaunched.homeCanvas.map(\.id) == edited)
    #expect(AppModel(store: InMemoryLedger(), layouts: store("omar")).homeCanvas.map(\.id) == start)

    relaunched.editingHome = true
    relaunched.forgetHomeLayout()
    #expect(!relaunched.editingHome)
    #expect(relaunched.homeCanvas.map(\.id) == start)
    #expect(AppModel(store: InMemoryLedger(), layouts: store("maya")).homeCanvas.map(\.id) == start)
  }

  @Test func removingTheLastWidgetLeavesEditMode() {
    let app = AppModel(store: InMemoryLedger(), layouts: store("maya"))
    app.editingHome = true
    for id in app.currentHomeLayout.ids { app.removeWidget(id) }
    #expect(app.homeCanvas.isEmpty)
    #expect(!app.editingHome)
    #expect(AppModel(store: InMemoryLedger(), layouts: store("maya")).homeCanvas.isEmpty)
  }

  @Test func theCanvasFollowsTheLedgerAndKeepsTheSystemWidgetsAsTheyWere() throws {
    let ledger = InMemoryLedger()
    let app = AppModel(store: ledger, layouts: store("maya"))
    let before = GlanceEngine.snapshot(ledger.state, now: ledger.now, home: app.thisMonthSnapshot, amountsHidden: false)
    for id in app.currentHomeLayout.ids { app.removeWidget(id) }
    app.addWidget(HomeLayout.Entry(.nextBill))
    let after = GlanceEngine.snapshot(ledger.state, now: ledger.now, home: app.thisMonthSnapshot, amountsHidden: false)
    #expect(before == after)
    #expect(app.homeCanvas.first?.isWaiting == false)
    try ledger.apply(.markBillPaid("axa"))
    #expect(app.homeCanvas.map(\.id) == ["nextBill"])
  }

  @Test func widgetTapsGoWhereTheWidgetPoints() {
    let app = AppModel(store: InMemoryLedger())
    let home = HomeViewModel(app: app)
    #expect(home.openWidget("comingUp") == .bills)
    #expect(home.openWidget("categoryWatch.dining") == nil)
    #expect(app.tab == .plan)
    #expect(app.router.plan == [.category("dining")])
    #expect(home.widgetOpens("categoryWatch.dining"))
    #expect(!home.widgetOpens("spentSoFar"))
    _ = home.openWidget("toReview")
    #expect(app.cover == .review)
  }

  @Test func theReleaseGalleryOffersOnlyWorkingKinds() {
    #expect(HomeGallery.kinds(showsUnfinished: true) == HomeWidgetKind.allCases)
    #expect(HomeGallery.kinds(showsUnfinished: false) == HomeWidgetKind.allCases.filter(\.worksInRelease))
  }
}
