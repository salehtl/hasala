import HasalaMocks
import HasalaModels
import Testing

@testable import Hasala

@MainActor
@Suite("Category editor")
struct CategoryEditorModelTests {
  func app() -> AppModel {
    let app = AppModel(store: InMemoryLedger())
    app.router.profile = [.rules]
    return app
  }

  @Test func addingNeedsANameAndACountsAs() throws {
    let app = app()
    app.router.profile.append(.categoryEditor(nil))
    let m = CategoryEditorModel(app: app, category: nil)
    #expect(m.isNew && !m.isBuiltin && !m.canHide)
    m.name = "Coffee"
    m.save()
    #expect(m.refusal == CategoryLimits.parentNotAllowed)
    m.parent = "dining"
    #expect(m.parentNote == "Its spending counts in Wants.")
    m.name = "dining"
    m.save()
    #expect(m.refusal == "You already have a category named Dining.")
    m.name = "Coffee"
    m.glyph = .dining
    m.save()
    #expect(m.refusal == nil)
    #expect(app.store.state.categories.contains { $0.name == "Coffee" && $0.parent == "dining" && $0.glyph == .dining })
    #expect(app.toast?.title == "Coffee added")
    #expect(app.router.profile == [.rules])
  }

  @Test func aBuiltInKeepsItsTypeAndMayBeHidden() throws {
    let app = app()
    let dining = CategoryEditorModel(app: app, category: "dining")
    #expect(dining.isBuiltin && dining.canHide && dining.parentNote == nil)
    #expect(!CategoryEditorModel(app: app, category: "transfer").canHide)
    #expect(!CategoryEditorModel(app: app, category: "salary").canHide)
    dining.setHidden(true)
    #expect(dining.confirmArchive)
    #expect(dining.archiveTitle == "Hide \u{201C}Dining\u{201D}?")
    #expect(dining.impactMessage.contains("2 rules stop matching."))
    #expect(dining.impactMessage.contains("AED 1,600.00 assigned this month goes to Ready to assign."))
    dining.archive()
    #expect(app.store.state.category("dining")?.archived == true)
    #expect(app.toast?.title == "Dining hidden")
    dining.setHidden(false)
    #expect(app.store.state.category("dining")?.archived == false)
  }

  @Test func aGoalBlocksArchive() {
    let app = app()
    let m = CategoryEditorModel(app: app, category: "emergency-fund")
    m.requestArchive()
    #expect(!m.confirmArchive)
    #expect(m.refusal == CategoryLimits.goalUses)
  }

  @Test func archivingACustomCategoryAndMovingItsRows() throws {
    let app = app()
    try app.store.apply(.addCategory(CategoryDraft(name: "Coffee", parent: "dining")))
    let id = try #require(app.store.state.categories.first { $0.name == "Coffee" }?.id)
    try app.store.apply(.categorize("talabat", id, learnRule: false, project: nil))
    app.router.profile += [.categoryEditor(id)]
    let m = CategoryEditorModel(app: app, category: id)
    m.parent = "groceries"
    #expect(m.parentNote == "Past spending moves to Needs.")
    m.parent = "travel"
    #expect(m.parentNote == "Past spending stays in Wants.")
    m.parent = "dining"
    m.requestArchive()
    #expect(m.confirmArchive)
    #expect(m.impactMessage.hasPrefix("1 transaction keeps it and still counts in Wants."))
    #expect(m.moveTargets.flatMap(\.rows).contains { $0.id == "dining" })
    m.chooseMoveTarget()
    #expect(app.router.profile == [.rules, .categoryEditor(id), .categoryMove(id)])
    m.archive(moveTo: "dining")
    #expect(app.router.profile == [.rules])
    #expect(app.store.state.txn("talabat")?.categoryID == "dining")
    #expect(app.store.state.category(id)?.archived == true)
    #expect(app.toast?.title == "Moved to Dining and archived Coffee")
    CategoriesViewModel(app: app).restore(id)
    #expect(app.store.state.category(id)?.archived == false)
  }
}
