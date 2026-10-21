import HasalaMocks
import HasalaModels
import Testing

@testable import Hasala

@MainActor
@Suite("Projects · view models")
struct ProjectsModelTests {
  @Test func planReachesTheListAndTheEditor() {
    let app = AppModel(store: InMemoryLedger())
    let plan = PlanViewModel(app: app)
    plan.openProjects()
    #expect(app.router.plan == [.projects])
    plan.newProject()
    #expect(app.router.sheet == .project(nil))
  }

  @Test func creatingAProjectOpensIt() throws {
    let app = AppModel(store: InMemoryLedger())
    app.router.open(.project(nil))
    let editor = ProjectEditorModel(app: app, project: nil)
    editor.name = "Kitchen refresh"
    editor.budgetText = "8,000"
    editor.glyph = .rent
    editor.save()
    let made = try #require(app.store.state.projects.first { $0.name == "Kitchen refresh" })
    #expect(made.budget == .aed(8_000_00) && made.glyph == .rent && made.starts == nil)
    #expect(app.router.sheet == nil)
    #expect(app.router.projects == [.project(made.id)])
  }

  @Test func theEditorRefusesWhatCantBeSaved() {
    let app = AppModel(store: InMemoryLedger())
    let editor = ProjectEditorModel(app: app, project: nil)
    editor.save()
    #expect(editor.refusal == "Give the project a name")
    editor.name = "Trip"
    editor.budgetText = "12.345"
    editor.save()
    #expect(editor.refusal == "Enter the money set aside as an amount, like 8,000")
    #expect(app.store.state.projects.count == 1)
  }

  @Test func editingKeepsTheStatus() throws {
    let app = AppModel(store: InMemoryLedger())
    #expect(app.perform(.completeProject("japan", true)))
    let editor = ProjectEditorModel(app: app, project: "japan")
    #expect(editor.name == "Japan trip" && editor.budgetText == "12000.00" && editor.hasStart && editor.hasEnd)
    editor.name = "Japan"
    editor.save()
    let p = try #require(app.store.state.project("japan"))
    #expect(p.name == "Japan" && p.complete)
  }

  @Test func addingTransactionsAssignsTheChosenOnes() throws {
    let app = AppModel(store: InMemoryLedger())
    app.router.projects = [.project("japan"), .addToProject("japan")]
    let add = ProjectAddModel(app: app, project: "japan")
    add.filter.merchant = "carrefour"
    let rows = add.candidates
    let first = try #require(rows.first)
    add.toggle(first.id)
    add.add(rows)
    #expect(app.store.state.txn(first.id)?.projectID == "japan")
    #expect(app.router.projects == [.project("japan")])
    #expect(ProjectDetailViewModel(app: app, project: "japan").detail?.transactions.contains { $0.id == first.id } == true)
  }

  @Test func addingWaitsForANarrowedFilterAndUndoes() throws {
    let app = AppModel(store: InMemoryLedger())
    app.router.projects = [.project("japan"), .addToProject("japan")]
    let add = ProjectAddModel(app: app, project: "japan")
    #expect(!add.narrowed && add.shown.isEmpty && !add.candidates.isEmpty)
    add.filter.merchant = "carrefour"
    let rows = add.shown
    #expect(add.narrowed && rows.count >= 2)
    add.selectAll(rows)
    #expect(add.selected == Set(rows.map(\.id)))
    add.toggle(try #require(rows.first).id)
    #expect(add.selected.count == rows.count - 1)
    add.add(rows)
    let moved = rows.dropFirst().map(\.id)
    #expect(moved.allSatisfy { app.store.state.txn($0)?.projectID == "japan" })
    #expect(app.toast?.actionTitle == "Undo")
    app.toastAction()
    #expect(moved.allSatisfy { app.store.state.txn($0)?.projectID == nil })
  }

  @Test func theDetailCompletesCountsAndRemoves() {
    let app = AppModel(store: InMemoryLedger())
    app.router.projects = [.project("japan")]
    let japan = ProjectDetailViewModel(app: app, project: "japan")
    japan.setCountInPlan(true)
    #expect(japan.detail?.countInPlan == true)
    japan.setComplete(true)
    #expect(japan.detail?.complete == true)
    #expect(PlanViewModel(app: app).snapshot.projects.isEmpty)
    japan.setComplete(false)
    #expect(japan.detail?.complete == false)
    japan.edit()
    #expect(app.router.sheet == .project("japan"))
    app.router.sheet = nil
    app.router.sheetDismissed()
    japan.remove()
    #expect(app.store.state.project("japan") == nil)
    #expect(app.router.projects.isEmpty)
  }

  @Test func aQuickStartPrefillsTheEditor() throws {
    let app = AppModel(store: InMemoryLedger())
    let list = ProjectsListModel(app: app)
    let trip = try #require(ProjectStarter.quickStarts.first)
    list.start(trip)
    #expect(app.router.sheet == .newProject(trip))
    let editor = ProjectEditorModel(app: app, project: nil, starter: trip)
    #expect(editor.name == "Trip" && editor.glyph == .travel && editor.isNew)
    #expect(ProjectStarter.quickStarts.map(\.name) == ["Trip", "Move", "Eid gifts"])
    #expect(ProjectStarter.quickStarts.map(\.glyph) == [.travel, .rent, .shopping])
  }

  @Test func removingFromTheEditorClosesItAndLeavesTheProject() {
    let app = AppModel(store: InMemoryLedger())
    app.router.tab = .projects
    app.router.projects = [.project("japan")]
    app.editProject("japan")
    #expect(app.router.sheet == .project("japan"))
    let editor = ProjectEditorModel(app: app, project: "japan")
    editor.remove()
    #expect(app.store.state.project("japan") == nil)
    #expect(app.router.sheet == nil)
    #expect(app.router.projects.isEmpty)
    #expect(app.toast?.title == "Japan trip removed")
  }

  @Test func removingFromTheEditorInTheProfilePopsBoth() {
    let app = AppModel(store: InMemoryLedger())
    app.router.open(.profile, profile: [.plan, .project("japan")])
    app.editProject("japan")
    #expect(app.router.profile == [.plan, .project("japan"), .editProject("japan")])
    ProjectEditorModel(app: app, project: "japan").remove()
    #expect(app.router.profile == [.plan])
    #expect(app.router.sheet == .profile)
  }

  @Test func inTheProfileProjectsPushInsideTheSheet() {
    let app = AppModel(store: InMemoryLedger())
    app.router.open(.profile, profile: [.projects])
    app.editProject(nil)
    #expect(app.router.profile == [.projects, .editProject(nil)])
    let editor = ProjectEditorModel(app: app, project: nil)
    editor.name = "Eid gifts"
    editor.save()
    let id = app.store.state.projects.first { $0.name == "Eid gifts" }?.id
    #expect(app.router.profile == [.projects, .project(id ?? "")])
    #expect(app.router.sheet == .profile)
  }

  @Test func theTransactionPickerSetsAndClearsTheProject() {
    let app = AppModel(store: InMemoryLedger())
    #expect(app.perform(.assignProject(["emirates"], nil)))
    #expect(app.store.state.txn("emirates")?.projectID == nil)
    #expect(app.perform(.assignProject(["emirates"], "japan")))
    #expect(app.store.state.txn("emirates")?.projectID == "japan")
  }
}
