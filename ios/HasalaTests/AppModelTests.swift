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
}
