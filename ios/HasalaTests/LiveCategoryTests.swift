import CoreCategorize
import CoreDomain
import CoreProjection
import CoreTime
import Foundation
import HasalaMocks
import HasalaModels
import Testing

@testable import Hasala

@MainActor
@Suite("Live categories")
struct LiveCategoryTests {
  typealias Mapper = LiveLedgerMapperTests

  static func custom(_ a: Mapper.Account, _ name: String) throws -> CategoryInfo? {
    try a.projection.reader.taxonomy().ordered.first { !$0.builtin && $0.name == name }
  }

  @Test func createEditArchiveAndRestoreAreAuthored() async throws {
    let a = try Mapper.account()
    let store = try await LiveUndoTests.store(a, suite: "categories.live.tests")
    var failed = false
    store.onWriteFailed = { failed = true }

    #expect(try store.apply(.addCategory(CategoryDraft(name: "Coffee", glyph: .dining, parent: "dining"))) == nil)
    try await Mapper.eventually { try Self.custom(a, "Coffee") != nil && store.state.categories.contains { $0.name == "Coffee" && !$0.id.hasPrefix("pending") } }
    let coffee = try #require(try Self.custom(a, "Coffee"))
    #expect(coffee.parent == "dining" && coffee.kind == .spending && coffee.bucket == .want && coffee.icon == "fork_knife" && coffee.active)
    let ids = store.state.categories.map(\.id)
    #expect(ids.firstIndex(of: coffee.id) == ids.firstIndex(of: "dining").map { $0 + 1 })
    #expect(store.state.category(coffee.id)?.parent == "dining")
    #expect(store.state.category("dining")?.builtin == true)

    #expect(throws: ActionError.refused("You already have a category named Coffee.")) {
      try store.apply(.addCategory(CategoryDraft(name: "coffee", parent: "travel")))
    }
    #expect(throws: ActionError.refused("This category is needed and cannot be hidden.")) {
      try store.apply(.archiveCategory("transfer", moveTo: nil))
    }

    try store.apply(.editCategory(coffee.id, CategoryDraft(name: "Coffee beans", glyph: .groceries, parent: "groceries")))
    try await Mapper.eventually { try Self.custom(a, "Coffee beans")?.parent == "groceries" }
    let edited = try #require(try Self.custom(a, "Coffee beans"))
    #expect(edited.id == coffee.id && edited.bucket == .need && edited.icon == "basket")

    let row = try #require(store.state.txns.first { !$0.archived && $0.splits.isEmpty && $0.categoryID != nil && !$0.isHeldCopy })
    try store.apply(.categorize(row.id, coffee.id, learnRule: false, project: nil))
    try store.apply(.setBudget(coffee.id, MayaLedger.october, .aed(50_00)))
    try await Mapper.eventually { try a.projection.reader.txn(row.id)?.category == coffee.id }
    try await Mapper.eventually { try LiveUndoTests.assigned(a, coffee.id, LiveUndoTests.october) == 50_00 }
    let groceries = try LiveUndoTests.assigned(a, "groceries", LiveUndoTests.october)

    try store.apply(.archiveCategory(coffee.id, moveTo: "groceries"))
    try await Mapper.eventually { try Self.custom(a, "Coffee beans")?.active == false }
    #expect(try Self.custom(a, "Coffee beans")?.active == false)
    #expect(try a.projection.reader.txn(row.id)?.category == "groceries")
    #expect(try LiveUndoTests.assigned(a, coffee.id, LiveUndoTests.october) == 0)
    #expect(try LiveUndoTests.assigned(a, coffee.id, LiveUndoTests.november) == 0)
    #expect(try LiveUndoTests.assigned(a, "groceries", LiveUndoTests.october) == groceries + 50_00)
    try await Mapper.eventually { store.state.category(coffee.id)?.archived == true }
    #expect(CategoriesEngine.snapshot(store.state).archived.map(\.id) == [coffee.id])

    try store.apply(.restoreCategory(coffee.id))
    try await Mapper.eventually { try Self.custom(a, "Coffee beans")?.active == true }
    #expect(try Self.custom(a, "Coffee beans")?.active == true)
    #expect(!failed)
  }

  @Test func hidingABuiltInMovesItsBudgetToReadyToAssign() async throws {
    let a = try Mapper.account()
    let store = try await LiveUndoTests.store(a, suite: "categories.hide.tests")
    try store.apply(.setBudget("travel", MayaLedger.october, .aed(120_00)))
    try await Mapper.eventually { try LiveUndoTests.assigned(a, "travel", LiveUndoTests.october) == 120_00 }
    try store.apply(.archiveCategory("travel", moveTo: nil))
    try await Mapper.eventually { try a.projection.reader.taxonomy().info("travel")?.active == false }
    #expect(try a.projection.reader.taxonomy().info("travel")?.active == false)
    #expect(try LiveUndoTests.assigned(a, "travel", LiveUndoTests.october) == 0)
    #expect(try a.projection.reader.planState().moves.values.contains { $0.from == "travel" && $0.to == nil })
    try store.apply(.restoreCategory("travel"))
    try await Mapper.eventually { try a.projection.reader.taxonomy().info("travel")?.active == true }
    #expect(try a.projection.reader.taxonomy().info("travel")?.name == "Travel")
  }

  @Test func customCategoriesFollowTheirParent() {
    func info(_ id: String, builtin: Bool, parent: String? = nil) -> CategoryInfo {
      CategoryInfo(id: id, name: id, kind: .spending, bucket: .want, icon: "tag", active: true, builtin: builtin, sortKey: 0, parent: parent)
    }
    let ordered = [
      info("dining", builtin: true), info("travel", builtin: true), info("c_a", builtin: false, parent: "travel"),
      info("c_b", builtin: false, parent: "dining"), info("c_old", builtin: false),
    ]
    #expect(LedgerStateMapper.byParent(ordered).map(\.id) == ["dining", "c_b", "travel", "c_a", "c_old"])
  }

  @Test func liveRulesKeepAParentlessCustomAndRefuseADuplicateRestore() {
    let parentless = CategoryInfo(
      id: "c_fund", name: "House fund", kind: .spending, bucket: .saving, icon: "jar", active: true, builtin: false, sortKey: 100)
    let old = CategoryInfo(
      id: "c_old", name: "Coffee", kind: .spending, bucket: .want, icon: "tag", active: false, builtin: false, sortKey: 101, parent: "dining")
    let new = CategoryInfo(
      id: "c_new", name: "Coffee", kind: .spending, bucket: .want, icon: "tag", active: true, builtin: false, sortKey: 102, parent: "dining")
    let view = TaxonomyView(TaxonomyV1.builtins + [parentless, old, new])
    let state = MayaLedger.state
    #expect(LedgerEditAuthor.categoryRefusal(.editCategory("c_fund", CategoryDraft(name: "Home fund", glyph: .savingsJar)), view: view, state: state) == nil)
    #expect(LedgerEditAuthor.changedParent(CategoryDraft(name: "Home fund"), of: parentless) == nil)
    #expect(
      LedgerEditAuthor.categoryRefusal(.restoreCategory("c_old"), view: view, state: state) == CategoryRefusal.nameTaken("Coffee").message)
  }

  @Test func theAppLimitsMatchTheCore() {
    #expect(CategoryLimits.maxActiveCustom == TaxonomyV1.maxActiveCustom)
    #expect(CategoryLimits.maxName == TaxonomyV1.maxNameScalars)
    #expect(CategoryLimits.systemIDs == Set(TaxonomyV1.systemIDs))
    #expect(CategoryLimits.parentIDs == TaxonomyV1.parentCandidates)
    #expect(CategoryLimits.atCap == CategoryRefusal.atCap(max: TaxonomyV1.maxActiveCustom).message)
    #expect(CategoryLimits.nameEmpty == CategoryRefusal.nameEmpty.message)
    #expect(CategoryLimits.nameTooLong == CategoryRefusal.nameTooLong(max: TaxonomyV1.maxNameScalars).message)
    #expect(CategoryLimits.parentNotAllowed == CategoryRefusal.parentNotAllowed.message)
    #expect(CategoryLimits.unknown == CategoryRefusal.unknownCategory.message)
    #expect(CategoryLimits.builtinLocked == CategoryRefusal.builtinLocked.message)
    #expect(CategoryLimits.systemCannotHide == CategoryRefusal.systemCannotHide.message)
    #expect(CategoryLimits.nameTaken("Coffee") == CategoryRefusal.nameTaken("Coffee").message)
  }
}
