import HasalaDesign
import HasalaMocks
import HasalaModels
import Testing

@testable import Hasala

@MainActor
@Suite("App shell")
struct AppModelTests {
  @Test func hidingAmountsShowsTheToastAndShowingClearsIt() {
    let app = AppModel(store: InMemoryLedger())
    #expect(!app.amountsHidden)
    app.toggleAmountsHidden()
    #expect(app.amountsHidden)
    #expect(app.toast?.title == "Amounts hidden")
    app.toastAction()
    #expect(!app.amountsHidden)
    #expect(app.toast == nil)
  }

  @Test func theHiddenScenarioStartsHidden() {
    #expect(Scenario.mayaHidden.startsWithAmountsHidden)
    #expect(!Scenario.maya.startsWithAmountsHidden)
  }

  @Test func interIsRegisteredInTheApp() {
    #expect(HasalaFonts.register())
    #expect(HasalaFonts.allFacesAvailable)
  }

  @Test func anEditShowsUndoAndUndoRevertsIt() throws {
    let app = AppModel(store: InMemoryLedger())
    #expect(app.perform(.categorize("lulu", "groceries", learnRule: false, project: nil)))
    let toast = try #require(app.toast)
    #expect(toast.title == "Sorted into Groceries")
    #expect(toast.actionTitle == "Undo")
    #expect(ReviewEngine.queue(app.store.state).count == 5)
    app.toastAction()
    #expect(ReviewEngine.queue(app.store.state).count == 6)
    #expect(app.toast == nil)
  }

  @Test func aRefusalSaysWhy() {
    let app = AppModel(store: InMemoryLedger())
    #expect(!app.perform(.moveMoney(from: nil, to: "dining", YearMonth(2026, 10), .aed(9_999_00))))
    #expect(app.toast?.title == "There isn't enough to move")
    #expect(app.toast?.undo == nil)
  }

  @Test func snapshotsAreReusedUntilTheLedgerChanges() {
    let app = AppModel(store: InMemoryLedger())
    let plan = PlanViewModel(app: app)
    let before = plan.snapshot
    #expect(plan.snapshot == before)
    #expect(app.perform(.moveMoney(from: nil, to: "groceries", YearMonth(2026, 10), .aed(318_00))))
    #expect(plan.snapshot.readyToAssign == .aed(682_00))
    #expect(app.avatarInitial == app.snapshot.header.avatarInitial)
  }

  // MARK: Routing (plan B7.2)

  /// Never two sheets at once: a second waits for the first to go, then opens with its
  /// profile path; a sheet that went takes its pushed pages with it.
  @Test func sheetsQueueAndTakeTheirPagesWithThem() {
    let app = AppModel(store: InMemoryLedger())
    let router = app.router
    router.open(.notifications)
    #expect(app.sheet == .notifications)
    router.open(.profile, profile: [.bankAlerts])
    #expect(app.sheet == nil)
    router.sheetDismissed()
    #expect(app.sheet == .profile && router.profile == [.bankAlerts])
    router.profile.append(.mailbox("gmail"))
    app.sheet = nil
    router.sheetDismissed()
    #expect(router.profile.isEmpty && router.nextSheet == nil)
    app.open("carrefour")
    #expect(app.sheet == .transaction("carrefour") && router.transaction.isEmpty)
  }

  @Test func theSelectedTabTappedAgainGoesToItsRoot() {
    let router = AppModel(store: InMemoryLedger()).router
    router.home = [.bills, .bill("axa")]
    router.plan = [.category("dining")]
    router.popToRoot(.home)
    #expect(router.home.isEmpty && router.plan == [.category("dining")])
    router.sheet = .profile
    router.cover = .review
    router.clearPresentation()
    #expect(router.sheet == nil && router.cover == nil)
  }

  /// The Review tab's badge is the queue (6 on Maya), and follows the ledger.
  @Test func theReviewBadgeCountsTheQueue() {
    let app = AppModel(store: InMemoryLedger())
    #expect(app.reviewCount == 6)
    app.perform(.categorize("lulu", "groceries", learnRule: false, project: nil))
    #expect(app.reviewCount == 5)
    #expect(ReviewTabView.countLine(6) == "6 to sort · about a minute")
    #expect(ReviewTabView.countLine(13) == "13 to sort · about 3 minutes")
    #expect(ReviewTabView.countLine(0) == "All caught up")
  }
}
