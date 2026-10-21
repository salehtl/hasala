import HasalaMocks
import HasalaModels
import Testing

@MainActor
@Suite("Category management")
struct CategoryManagementTests {
  func add(_ ledger: InMemoryLedger, _ name: String, parent: CategoryID = "dining", glyph: Glyph = .tag) throws -> CategoryID {
    try ledger.apply(.addCategory(CategoryDraft(name: name, glyph: glyph, parent: parent)))
    return try #require(ledger.state.categories.first { $0.name == name.trimmedSpaces && !$0.archived }?.id)
  }

  @Test func theListGroupsBySectionWithCustomsUnderTheirParent() {
    let snap = CategoriesEngine.snapshot(MayaLedger.state)
    #expect(snap.capLine == "1 of 20 custom categories")
    #expect(snap.canAdd)
    #expect(snap.sections.map(\.title) == ["Needs", "Wants", "Savings", "Income", "Not spending"])
    let savings = snap.sections[2].rows
    #expect(savings.map(\.id) == ["savings", "investments", "debt", "emergency-fund"])
    #expect(savings.first { $0.id == "emergency-fund" }?.supporting == "Counts as Savings")
    #expect(savings.first { $0.id == "debt" }?.hidden == true)
    #expect(snap.archived.isEmpty)
  }

  @Test func addingPlacesTheCategoryAfterItsParentAndInheritsItsBucket() throws {
    let ledger = InMemoryLedger()
    let coffee = try add(ledger, "  Coffee ")
    let c = try #require(ledger.state.category(coffee))
    #expect(c.bucket == .wants && c.kind == .spending && c.parent == "dining" && !c.builtin && c.name == "Coffee")
    #expect(ledger.state.categories(in: .wants).map(\.id).prefix(2) == ["dining", coffee])
    let tea = try add(ledger, "Tea")
    #expect(ledger.state.categories(in: .wants).map(\.id).prefix(3) == ["dining", coffee, tea])
    #expect(CategoriesEngine.snapshot(ledger.state).capLine == "3 of 20 custom categories")
  }

  @Test func namesAreCheckedBeforeAnythingIsWritten() throws {
    let ledger = InMemoryLedger()
    #expect(throws: ActionError.refused("You already have a category named Dining.")) {
      try ledger.apply(.addCategory(CategoryDraft(name: "dining", parent: "travel")))
    }
    #expect(throws: ActionError.refused("Enter a name.")) {
      try ledger.apply(.addCategory(CategoryDraft(name: "  ", parent: "travel")))
    }
    #expect(throws: ActionError.refused("Use 24 characters or fewer.")) {
      try ledger.apply(.addCategory(CategoryDraft(name: String(repeating: "a", count: 25), parent: "travel")))
    }
    #expect(throws: ActionError.refused(CategoryLimits.parentNotAllowed)) {
      try ledger.apply(.addCategory(CategoryDraft(name: "Gifts", parent: "transfer")))
    }
    #expect(throws: ActionError.refused(CategoryLimits.parentNotAllowed)) {
      try ledger.apply(.addCategory(CategoryDraft(name: "Gifts")))
    }
    #expect(throws: ActionError.refused(CategoryLimits.builtinLocked)) {
      try ledger.apply(.editCategory("dining", CategoryDraft(name: "Dining", glyph: .dining, parent: "groceries")))
    }
    #expect(ledger.state.categories == MayaLedger.state.categories)
  }

  @Test func theCapCountsActiveCustomsOnly() throws {
    let ledger = InMemoryLedger()
    for i in 1...19 { _ = try add(ledger, "Custom \(i)") }
    let snap = CategoriesEngine.snapshot(ledger.state)
    #expect(snap.capLine == "20 of 20 custom categories")
    #expect(!snap.canAdd)
    #expect(throws: ActionError.refused(CategoryLimits.atCap)) {
      try ledger.apply(.addCategory(CategoryDraft(name: "One more", parent: "travel")))
    }
    let first = try #require(ledger.state.categories.first { $0.name == "Custom 1" }?.id)
    try ledger.apply(.archiveCategory(first, moveTo: nil))
    #expect(CategoriesEngine.snapshot(ledger.state).archived.map(\.id) == [first])
    _ = try add(ledger, "One more")
    #expect(throws: ActionError.refused(CategoryLimits.atCap)) { try ledger.apply(.restoreCategory(first)) }
  }

  @Test func changingTheParentMovesTheCategoryAndItsSection() throws {
    let ledger = InMemoryLedger()
    let coffee = try add(ledger, "Coffee")
    try ledger.apply(.editCategory(coffee, CategoryDraft(name: "Coffee beans", glyph: .groceries, parent: "groceries")))
    let c = try #require(ledger.state.category(coffee))
    #expect(c.bucket == .needs && c.parent == "groceries" && c.name == "Coffee beans" && c.glyph == .groceries)
    let needs = ledger.state.categories(in: .needs).map(\.id)
    #expect(needs.firstIndex(of: coffee) == needs.firstIndex(of: "groceries").map { $0 + 1 })
    try ledger.apply(.editCategory("dining", CategoryDraft(name: "Eating out", glyph: .flag)))
    #expect(ledger.state.category("dining")?.name == "Eating out")
    #expect(ledger.state.category("dining")?.bucket == .wants)
  }

  @Test func systemCategoriesAndGoalCategoriesCannotBeHidden() {
    let ledger = InMemoryLedger()
    #expect(throws: ActionError.refused(CategoryLimits.systemCannotHide)) {
      try ledger.apply(.archiveCategory("transfer", moveTo: nil))
    }
    #expect(throws: ActionError.refused(CategoryLimits.goalUses)) {
      try ledger.apply(.archiveCategory("emergency-fund", moveTo: nil))
    }
  }

  @Test func hidingABuiltInShowsItsImpactAndFreesItsBudget() throws {
    let ledger = InMemoryLedger()
    let impact = try #require(CategoriesEngine.impact(ledger.state, "dining", month: MayaLedger.october))
    #expect(impact.rules == 2)
    #expect(impact.assigned == .aed(1_600_00))
    #expect(!impact.blockedByGoal)
    #expect(impact.transactions > 0)
    #expect(impact.lines(hidden: false).last == "AED 1,600.00 assigned this month goes to Ready to assign.")
    #expect(impact.lines(hidden: true).last == "The money assigned this month goes to Ready to assign.")
    try ledger.apply(.archiveCategory("dining", moveTo: nil))
    #expect(PlanEngine.snapshot(ledger.state, now: ledger.now).readyToAssign == .aed(2_600_00))
    #expect(ledger.state.category("dining")?.archived == true)
    #expect(!ledger.state.categories(in: .wants).contains { $0.id == "dining" })
    let row = CategoriesEngine.snapshot(ledger.state).sections[1].rows.first { $0.id == "dining" }
    #expect(row?.hidden == true)
    try ledger.apply(.restoreCategory("dining"))
    #expect(ledger.state.category("dining")?.archived == false)
  }

  @Test func archiveAndMoveRefilesTheRowsAndTheBudget() throws {
    let ledger = InMemoryLedger()
    let coffee = try add(ledger, "Coffee")
    try ledger.apply(.categorize("talabat", coffee, learnRule: false, project: nil))
    try ledger.apply(.setBudget(coffee, MayaLedger.october, .aed(100_00)))
    #expect(CategoriesEngine.movableCount(ledger.state, coffee) == 1)
    #expect(CategoriesEngine.moveTargets(ledger.state, from: coffee).flatMap(\.rows).contains { $0.id == "dining" })
    #expect(!CategoriesEngine.moveTargets(ledger.state, from: coffee).flatMap(\.rows).contains { $0.id == coffee })
    #expect(
      CategoriesEngine.toast(.archiveCategory(coffee, moveTo: "dining"), before: ledger.state)
        == "Moved to Dining and archived Coffee")
    try ledger.apply(.archiveCategory(coffee, moveTo: "dining"))
    #expect(ledger.state.txn("talabat")?.categoryID == "dining")
    #expect(ledger.state.plan.budget("dining", MayaLedger.october) == .aed(1_700_00))
    #expect(ledger.state.plan.budget(coffee, MayaLedger.october) == .aed(0))
    #expect(CategoriesEngine.snapshot(ledger.state).archived.map(\.id) == [coffee])
    #expect(CategoriesEngine.snapshot(ledger.state).archived.first?.supporting == "Counts as Dining")
    try ledger.apply(.restoreCategory(coffee))
    #expect(ledger.state.category(coffee)?.archived == false)
  }

  @Test func theParentPickerOffersTheBuiltInParentsBySection() {
    let groups = CategoriesEngine.parentGroups(MayaLedger.state)
    #expect(groups.map(\.title) == ["Needs", "Wants", "Savings", "Income"])
    let ids = groups.flatMap(\.rows).map(\.id)
    #expect(ids.count == 16)
    #expect(!ids.contains("transfer") && !ids.contains("refunds") && !ids.contains("emergency-fund"))
    #expect(ids.contains("debt"))
  }
}
