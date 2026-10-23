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
    #expect(CategoriesEngine.snapshot(ledger.state).archived.first?.supporting == "Counts as Wants")
    try ledger.apply(.restoreCategory(coffee))
    #expect(ledger.state.category(coffee)?.archived == false)
  }

  @Test func countsAsOffersTheThreeBuckets() {
    let s = MayaLedger.state
    let fresh = CategoriesEngine.countsAsOptions(s, keeping: [nil])
    #expect(fresh.map(\.title) == ["Needs", "Wants", "Savings"])
    #expect(fresh.map(\.id) == ["needs", "wants", "savings"])
    #expect(fresh.map(\.parent) == ["rent", "dining", "savings"])
    #expect(fresh.allSatisfy { CategoriesEngine.isOfferedParent($0.parent, in: s) })
    let travel = CategoriesEngine.countsAsOptions(s, keeping: ["travel"])
    #expect(travel.map(\.parent) == ["rent", "travel", "savings"])
    let income = CategoriesEngine.countsAsOptions(s, keeping: ["rent", "freelance"])
    #expect(income.map(\.title) == ["Needs", "Wants", "Savings", "Income"])
    #expect(income.map(\.parent) == ["rent", "dining", "savings", "freelance"])
    let hidden = CategoriesEngine.countsAsOptions(s, keeping: ["debt"])
    #expect(hidden.map(\.parent) == ["rent", "dining", "debt"])
    #expect(CategoriesEngine.countsAsTitle("freelance", in: s) == "Income")
    #expect(CategoriesEngine.countsAsTitle(nil, in: s) == nil)
  }

  @Test func restoringRefusesANameThatAnActiveCategoryHas() throws {
    let ledger = InMemoryLedger()
    let old = try add(ledger, "Coffee")
    try ledger.apply(.archiveCategory(old, moveTo: nil))
    _ = try add(ledger, "coffee")
    #expect(throws: ActionError.refused(CategoryLimits.nameTaken("coffee"))) { try ledger.apply(.restoreCategory(old)) }
    #expect(ledger.state.category(old)?.archived == true)
    try ledger.apply(.archiveCategory("dining", moveTo: nil))
    _ = try add(ledger, "Dining", parent: "travel")
    #expect(throws: ActionError.refused(CategoryLimits.nameTaken("Dining"))) { try ledger.apply(.restoreCategory("dining")) }
  }

  @Test func aHiddenBuiltInIsNotOfferedAsAParentButItsChildrenKeepWorking() throws {
    var state = MayaLedger.state
    state.categories.append(
      Category(id: "loan", name: "Loan", bucket: .savings, glyph: .debt, role: .saving, parent: "debt"))
    let ledger = InMemoryLedger(state: state)
    #expect(state.category("debt")?.archived == true)
    #expect(!CategoriesEngine.isOfferedParent("debt", in: state) && CategoriesEngine.isOfferedParent("savings", in: state))
    #expect(throws: ActionError.refused(CategoryLimits.parentNotAllowed)) {
      try ledger.apply(.addCategory(CategoryDraft(name: "Car loan", parent: "debt")))
    }
    let coffee = try add(ledger, "Coffee")
    #expect(throws: ActionError.refused(CategoryLimits.parentNotAllowed)) {
      try ledger.apply(.editCategory(coffee, CategoryDraft(name: "Coffee", parent: "debt")))
    }
    try ledger.apply(.editCategory("loan", CategoryDraft(name: "Car loan", glyph: .debt, parent: "debt")))
    let loan = try #require(ledger.state.category("loan"))
    #expect(loan.name == "Car loan" && loan.parent == "debt" && loan.bucket == .savings)
  }

  @Test func editingAParentlessCustomKeepsItsTypeWithoutAParent() throws {
    var state = MayaLedger.state
    state.categories.append(Category(id: "house-fund", name: "House fund", bucket: .savings, glyph: .savingsJar, role: .saving))
    state.categories.append(Category(id: "rent-in", name: "Rent in", kind: .income, bucket: .income, glyph: .salary, role: .none))
    let ledger = InMemoryLedger(state: state)
    try ledger.apply(.editCategory("house-fund", CategoryDraft(name: "Home fund", glyph: .rent)))
    let c = try #require(ledger.state.category("house-fund"))
    #expect(c.name == "Home fund" && c.glyph == .rent && c.parent == nil && c.kind == .spending && c.bucket == .savings && c.role == .saving)
    try ledger.apply(.editCategory("rent-in", CategoryDraft(name: "Rental income", glyph: .salary)))
    let d = try #require(ledger.state.category("rent-in"))
    #expect(d.kind == .income && d.bucket == .income && d.parent == nil)
  }

  @Test func theLimitsAreTheCoreTaxonomyValues() {
    #expect(CategoryLimits.maxActiveCustom == 20 && CategoryLimits.maxName == 24)
    #expect(CategoryLimits.systemIDs == ["transfer", "refunds", "salary"])
    #expect(
      CategoryLimits.parentIDs == [
        "rent", "utilities", "groceries", "transport", "healthcare", "insurance", "dining", "entertainment", "shopping", "travel",
        "subscriptions", "savings", "investments", "debt", "salary", "freelance",
      ])
    #expect(CategoryLimits.atCap == "You have 20 categories. Archive one to add another.")
    #expect(CategoryLimits.nameTooLong == "Use 24 characters or fewer.")
  }

  func waiting(_ ledger: InMemoryLedger) throws -> Txn {
    try #require(ledger.state.txns.first { $0.groupRef == MayaBacklog.tailscale && $0.reachable })
  }

  @Test func aClientMadeIDIsKept() throws {
    let ledger = InMemoryLedger()
    let made = ledger.newCategoryID()
    #expect(made == "c_mock1" && ledger.newCategoryID() == "c_mock2")
    try ledger.apply(.addCategory(CategoryDraft(id: made, name: "Coffee", parent: "dining")))
    #expect(ledger.state.category(made)?.name == "Coffee")
    #expect(try add(ledger, "Tea") == "c_mock3")
    for id in [made, "dining", "c_Juice", "juice", "c-juice"] {
      #expect(throws: ActionError.refused(CategoryLimits.cannotAdd)) {
        try ledger.apply(.addCategory(CategoryDraft(id: id, name: "Juice", parent: "dining")))
      }
    }
    #expect(!ledger.state.categories.contains { $0.name == "Juice" })
  }

  @Test func anIDLessAddSkipsAnIDAnotherDraftAlreadyUsed() throws {
    let ledger = InMemoryLedger()
    try ledger.apply(.addCategory(CategoryDraft(id: "c_mock1", name: "Coffee", parent: "dining")))
    try ledger.apply(.addCategory(CategoryDraft(id: "c_mock3", name: "Juice", parent: "dining")))
    #expect(try add(ledger, "Tea") == "c_mock2")
    #expect(try add(ledger, "Water") == "c_mock4")
    #expect(ledger.state.category("c_mock1")?.name == "Coffee" && ledger.state.category("c_mock3")?.name == "Juice")
    #expect(ledger.newCategoryID() == "c_mock5")
  }

  @Test func addingAndSortingFilesThePaymentInOneEdit() throws {
    let ledger = InMemoryLedger(state: Scenario.mayaBacklog.state)
    let row = try waiting(ledger)
    let id = ledger.newCategoryID()
    let draft = CategoryDraft(id: id, name: "VPN", glyph: .subscriptions, parent: "subscriptions")
    let token = try #require(try ledger.apply(.addCategoryAndSort(draft, row.id, alwaysUse: false, project: nil)))
    #expect(token.title == "Sorted into VPN")
    let c = try #require(ledger.state.category(id))
    #expect(c.name == "VPN" && c.parent == "subscriptions" && c.glyph == .subscriptions && !c.builtin)
    let filed = try #require(ledger.state.txn(row.id))
    #expect(filed.categoryID == id && filed.categorySource == .user && !filed.needsReview)
    #expect(ledger.state.rules == Scenario.mayaBacklog.state.rules)
    ledger.undo(token)
    let back = try #require(ledger.state.txn(row.id))
    #expect(back.categoryID == row.categoryID && back.needsReview == row.needsReview && back.categorySource == row.categorySource)
    #expect(ledger.state.category(id) != nil)
  }

  @Test func addingAndSortingMakesItsOwnIDWhenTheDraftHasNone() throws {
    let ledger = InMemoryLedger(state: Scenario.mayaBacklog.state)
    let row = try waiting(ledger)
    try ledger.apply(.addCategoryAndSort(CategoryDraft(name: "VPN", parent: "subscriptions"), row.id, alwaysUse: false, project: nil))
    let c = try #require(ledger.state.categories.first { $0.name == "VPN" })
    #expect(c.id == "c_mock1" && ledger.state.txn(row.id)?.categoryID == c.id)
  }

  @Test func alwaysUseWritesWhatAddingThenSortingWould() throws {
    let combined = InMemoryLedger(state: Scenario.mayaBacklog.state)
    let steps = InMemoryLedger(state: Scenario.mayaBacklog.state)
    let row = try waiting(combined)
    let id = combined.newCategoryID()
    let draft = CategoryDraft(id: id, name: "VPN", glyph: .subscriptions, parent: "subscriptions")
    let token = try #require(try combined.apply(.addCategoryAndSort(draft, row.id, alwaysUse: true, project: nil)))
    try steps.apply(.addCategory(draft))
    let expected = try #require(try steps.apply(.categorize(row.id, id, learnRule: true, project: nil)))
    #expect(combined.state == steps.state)
    #expect(token == expected)
    #expect(combined.state.rules.contains { $0.categoryID == id })
    #expect(combined.state.txns.filter { $0.categoryID == id }.count > 1)
    combined.undo(token)
    #expect(!combined.state.rules.contains { $0.categoryID == id })
    #expect(!combined.state.txns.contains { $0.categoryID == id })
    #expect(combined.state.category(id) != nil)
  }

  @Test func aRefusedAddAndSortWritesNothing() throws {
    let ledger = InMemoryLedger(state: Scenario.mayaBacklog.state)
    let before = ledger.state
    let row = try waiting(ledger)
    #expect(throws: ActionError.refused(CategoryLimits.nameTaken("Subscriptions"))) {
      try ledger.apply(.addCategoryAndSort(CategoryDraft(name: " subscriptions", parent: "subscriptions"), row.id, alwaysUse: true, project: nil))
    }
    #expect(throws: ActionError.refused(CategoryLimits.nameEmpty)) {
      try ledger.apply(.addCategoryAndSort(CategoryDraft(name: " ", parent: "subscriptions"), row.id, alwaysUse: false, project: nil))
    }
    #expect(throws: ActionError.refused(CategoryLimits.cannotAdd)) {
      try ledger.apply(.addCategoryAndSort(CategoryDraft(id: "subscriptions", name: "VPN", parent: "subscriptions"), row.id, alwaysUse: false, project: nil))
    }
    #expect(throws: ActionError.refused(CategoryLimits.cannotAdd)) {
      try ledger.apply(.addCategoryAndSort(CategoryDraft(id: "c_VPN", name: "VPN", parent: "subscriptions"), row.id, alwaysUse: false, project: nil))
    }
    #expect(throws: ActionError.notFound) {
      try ledger.apply(.addCategoryAndSort(CategoryDraft(name: "VPN", parent: "subscriptions"), "no-such-row", alwaysUse: false, project: nil))
    }
    #expect(throws: ActionError.notFound) {
      try ledger.apply(.addCategoryAndSort(CategoryDraft(name: "VPN", parent: "subscriptions"), row.id, alwaysUse: false, project: "no-such-project"))
    }
    #expect(ledger.state == before)
    for i in 0..<(CategoryLimits.maxActiveCustom - CategoriesEngine.activeCustomCount(before)) { _ = try add(ledger, "Custom \(i)") }
    let full = ledger.state
    #expect(throws: ActionError.refused(CategoryLimits.atCap)) {
      try ledger.apply(.addCategoryAndSort(CategoryDraft(name: "VPN", parent: "subscriptions"), row.id, alwaysUse: true, project: nil))
    }
    #expect(ledger.state == full)
  }
}
