import XCTest

final class ProjectsUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  @MainActor
  private func launchProjects(arguments: [String] = []) -> XCUIApplication {
    let app = launch(scenario: "maya", motion: "off", arguments: arguments)
    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: 15))
    app.tabBars.firstMatch.buttons["Projects"].tap()
    XCTAssertTrue(el(app, "projects.new").waitForExistence(timeout: uiWait))
    return app
  }

  @MainActor
  private func first(_ app: XCUIApplication, prefix: String) -> XCUIElement {
    app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix)).firstMatch
  }

  @MainActor
  private func makeKitchen(_ app: XCUIApplication, large: Bool = false) throws {
    let new = el(app, "projects.new")
    XCTAssertTrue(reveal(app, new))
    attach(app, large ? "AX3 · Projects tab" : "Projects tab")
    new.tap()
    let name = el(app, "projectEditor.name")
    XCTAssertTrue(name.waitForExistence(timeout: uiWait))
    attach(app, large ? "AX3 · New project" : "New project")
    try audit(app, atLargeText: large, overSheet: true)
    type("Kitchen refresh", into: name)
    type(app, "projectEditor.budget", "8000")
    tap(app, "projectEditor.icon.rent")
    attach(app, large ? "AX3 · New project · Filled" : "New project · Filled")
    tap(app, "projectEditor.save", opening: "project.hero")
  }

  @MainActor
  func testCreateAssignSeeAndComplete() throws {
    let app = launchProjects()
    try makeKitchen(app)

    let hero = el(app, "project.hero")
    XCTAssertTrue(hero.label.hasPrefix("Kitchen refresh, AED 8,000.00 left of 8,000."), hero.label)
    XCTAssertTrue(app.navigationBars["Kitchen refresh"].exists)
    attach(app, "Project · Kitchen refresh · Empty")
    try audit(app)

    tap(app, "project.addTransactions", opening: "projectAdd.merchant")
    XCTAssertTrue(el(app, "projectAdd.narrowFirst").waitForExistence(timeout: uiWait))
    XCTAssertFalse(first(app, prefix: "projectAdd.txn.").exists)
    XCTAssertTrue(el(app, "projectAdd.category").exists)
    attach(app, "Add transactions · Narrow first")
    type(app, "projectAdd.merchant", "Carrefour\n")
    let row = first(app, prefix: "projectAdd.txn.")
    XCTAssertTrue(row.waitForExistence(timeout: uiWait))
    let id = String(row.identifier.dropFirst("projectAdd.txn.".count))
    dragUntilHittable(app, row)
    row.tap()
    attach(app, "Add transactions · One chosen")
    try audit(app)
    let add = el(app, "projectAdd.add")
    XCTAssertTrue(reveal(app, add))
    XCTAssertEqual(add.label, "Add 1 to Kitchen refresh")
    add.tap()

    let assigned = el(app, "project.txn.\(id)")
    XCTAssertTrue(assigned.waitForExistence(timeout: uiWait))
    XCTAssertFalse(el(app, "project.hero").label.hasPrefix("Kitchen refresh, AED 8,000.00"))
    XCTAssertTrue(reveal(app, assigned))
    attach(app, "Project · Kitchen refresh · One transaction")
    try audit(app)

    let complete = el(app, "project.markComplete")
    XCTAssertTrue(reveal(app, complete))
    complete.tap()
    XCTAssertTrue(el(app, "project.markComplete").waitForLabel("Reopen"))
    attach(app, "Project · Kitchen refresh · Completed")
    let completedHero = el(app, "project.hero")
    XCTAssertTrue(completedHero.label.hasSuffix("Completed."), completedHero.label)
    _ = reveal(app, completedHero)
    attach(app, "Project · Kitchen refresh · Completed hero")

    back(app)
    let done = first(app, prefix: "projects.project.p-")
    XCTAssertTrue(done.waitForExistence(timeout: uiWait))
    XCTAssertTrue(done.label.contains("Kitchen refresh"), done.label)
    XCTAssertTrue(app.staticTexts["Completed"].exists)
    XCTAssertTrue(reveal(app, done))
    attach(app, "Projects · Active and Completed")
    try audit(app)
  }

  @MainActor
  func testATransactionJoinsAndLeavesAProjectFromItsSheet() throws {
    let app = launch(screen: "activity.txn", motion: "off")
    let row = el(app, "txn.project")
    XCTAssertTrue(row.waitForExistence(timeout: 15))
    XCTAssertEqual(row.label, "Project, None")
    XCTAssertTrue(reveal(app, row))
    row.tap()
    tap(app, "txnProject.japan")
    XCTAssertTrue(el(app, "txn.project").waitForExistence(timeout: uiWait))
    XCTAssertEqual(el(app, "txn.project").label, "Project, Japan trip")
    attach(app, "Transaction · Project Japan trip")
    try audit(app, overSheet: true)
    tap(app, "txn.project", opening: "txnProject.none")
    XCTAssertEqual(el(app, "txnProject.none").frame.minX, el(app, "txnProject.japan").frame.minX)
    attach(app, "Transaction · Project picker")
    try audit(app, overSheet: true)
    tap(app, "txnProject.none")
    XCTAssertTrue(el(app, "txn.project").waitForExistence(timeout: uiWait))
    XCTAssertEqual(el(app, "txn.project").label, "Project, None")
  }

  @MainActor
  private func activityWithTalabatInJapan(arguments: [String] = [], searching: Bool = false) -> XCUIApplication {
    let app = launch(scenario: "maya", motion: "off", arguments: arguments)
    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: 15))
    app.tabBars.firstMatch.buttons["Activity"].tap()
    XCTAssertTrue(el(app, "activity.count").waitForExistence(timeout: uiWait))
    if searching {
      let search = app.searchFields["Search transactions"]
      XCTAssertTrue(search.waitForExistence(timeout: uiWait))
      type("Talabat\n", into: search)
      XCTAssertTrue(el(app, "txn.talabat").waitForExistence(timeout: uiWait))
      XCTAssertTrue(dragUntilHittable(app, el(app, "txn.talabat")))
    } else {
      for id in ["activity.startReview", "bill.dewa", "txn.talabat"] {
        XCTAssertTrue(reveal(app, el(app, id)), "could not reach \(id)")
      }
    }
    let talabat = el(app, "txn.talabat")
    XCTAssertFalse(talabat.label.contains("project"), talabat.label)
    talabat.tap()
    let project = el(app, "txn.project")
    XCTAssertTrue(project.waitForExistence(timeout: uiWait))
    XCTAssertTrue(reveal(app, project))
    project.tap()
    tap(app, "txnProject.japan")
    XCTAssertTrue(el(app, "txn.project").waitForLabel("Project, Japan trip"))
    tap(app, "txn.close")
    return app
  }

  @MainActor
  func testActivityRowsShowTheirProject() throws {
    let app = activityWithTalabatInJapan()
    let talabat = el(app, "txn.talabat")
    XCTAssertTrue(talabat.waitForExistence(timeout: uiWait))
    XCTAssertTrue(reveal(app, talabat))
    XCTAssertTrue(talabat.label.contains("Japan trip project"), talabat.label)
    attach(app, "Activity · Project chip")
    try audit(app)

    let search = app.searchFields["Search transactions"]
    for _ in 0..<10 where !(search.exists && search.isHittable) { app.swipeDown() }
    XCTAssertTrue(search.waitForExistence(timeout: uiWait))
    type("Emirates\n", into: search)
    let emirates = el(app, "txn.emirates")
    XCTAssertTrue(emirates.waitForExistence(timeout: uiWait))
    XCTAssertTrue(emirates.label.hasSuffix("Japan trip project") || emirates.label.contains("Japan trip project, "),
                  emirates.label)
    attach(app, "Activity · Search · Project chip")
  }

  @MainActor
  func testActivityProjectChipAtLargeText() throws {
    let large = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"]
    let app = activityWithTalabatInJapan(arguments: large, searching: true)
    let talabat = el(app, "txn.talabat")
    XCTAssertTrue(talabat.waitForExistence(timeout: uiWait))
    XCTAssertTrue(dragUntilHittable(app, talabat))
    XCTAssertTrue(scroll(app, toShow: talabat))
    XCTAssertTrue(talabat.label.contains("Japan trip project"), talabat.label)
    attach(app, "AX3 · Activity · Project chip")
    try audit(app, atLargeText: true)
  }

  @MainActor
  func testProjectsAtLargeText() throws {
    let large = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"]
    let app = launchProjects(arguments: large)
    try makeKitchen(app, large: true)
    attach(app, "AX3 · Project · Kitchen refresh")
    try audit(app, atLargeText: true)
    for id in ["project.countInPlan", "project.addTransactions", "project.markComplete"] {
      XCTAssertTrue(reveal(app, el(app, id)), "could not reach \(id)")
      try audit(app, atLargeText: true)
    }
    tap(app, "project.addTransactions", opening: "projectAdd.merchant")
    attach(app, "AX3 · Add transactions")
    try audit(app, atLargeText: true)
    back(app)
    back(app)
    XCTAssertTrue(el(app, "projects.new").waitForExistence(timeout: uiWait))
    attach(app, "AX3 · Projects")
    try audit(app, atLargeText: true)
    XCTAssertTrue(reveal(app, el(app, "projects.project.japan")))
    try audit(app, atLargeText: true)
  }

  @MainActor
  func testRemoveFromEditThenStartFromATrip() throws {
    let app = launchProjects()
    XCTAssertFalse(app.navigationBars.buttons["Back"].exists)
    attach(app, "Projects tab · Japan trip")
    try audit(app)
    tap(app, "projects.project.japan", opening: "project.hero")
    tap(app, "plan.more")
    XCTAssertTrue(app.buttons["Edit project"].waitForExistence(timeout: uiWait))
    app.buttons["Edit project"].tap()
    let remove = el(app, "projectEditor.remove")
    XCTAssertTrue(remove.waitForExistence(timeout: uiWait))
    XCTAssertTrue(reveal(app, remove))
    attach(app, "Edit project · Remove")
    remove.tap()
    let confirm = app.buttons["project.removeConfirm"].firstMatch
    XCTAssertTrue(confirm.waitForExistence(timeout: uiWait))
    XCTAssertTrue(app.staticTexts["Remove Japan trip?"].exists)
    confirm.tap()

    let trip = el(app, "projects.start.travel")
    XCTAssertTrue(trip.waitForExistence(timeout: uiWait))
    XCTAssertTrue(app.staticTexts["Set money aside for one thing"].exists)
    XCTAssertTrue(el(app, "projects.start.rent").exists)
    XCTAssertTrue(el(app, "projects.start.shopping").exists)
    XCTAssertTrue(el(app, "projects.new").exists)
    XCTAssertFalse(el(app, "projects.project.japan").exists)
    attach(app, "Projects · Empty")
    try audit(app)

    trip.tap()
    let name = el(app, "projectEditor.name")
    XCTAssertTrue(name.waitForExistence(timeout: uiWait))
    XCTAssertEqual(name.value as? String, "Trip")
    XCTAssertTrue(el(app, "projectEditor.icon.travel").isSelected)
    XCTAssertFalse(el(app, "projectEditor.remove").exists)
    attach(app, "New project · Trip")
    try audit(app, overSheet: true)
    tap(app, "projectEditor.save", opening: "project.hero")
    XCTAssertTrue(app.navigationBars["Trip"].exists)
  }

  @MainActor
  func testProfileOpensPlan() throws {
    let app = launch(scenario: "maya", motion: "off")
    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: 15))
    app.buttons["header.profile"].firstMatch.tap()
    let row = el(app, "profile.plan")
    XCTAssertTrue(row.waitForExistence(timeout: uiWait))
    XCTAssertFalse(el(app, "profile.projects").exists)
    XCTAssertTrue(row.label.contains("Plan"), row.label)
    attach(app, "Profile · Plan row")
    XCTAssertTrue(reveal(app, row))
    row.tap()
    XCTAssertTrue(el(app, "plan.readyToAssign").waitForExistence(timeout: uiWait))
    XCTAssertTrue(app.navigationBars["Plan"].exists)
    attach(app, "Profile · Plan")
    try audit(app)

    let dining = el(app, "plan.row.dining")
    XCTAssertTrue(reveal(app, dining))
    dining.tap()
    XCTAssertTrue(el(app, "category.hero").waitForExistence(timeout: uiWait))
    let change = el(app, "category.changeBudget")
    XCTAssertTrue(reveal(app, change))
    change.tap()
    XCTAssertTrue(el(app, "budget.amount").waitForExistence(timeout: uiWait))
    attach(app, "Profile · Plan · Dining budget")
    tap(app, "budget.close")
    XCTAssertTrue(el(app, "budget.amount").waitForNonExistence(timeout: uiWait))
    XCTAssertTrue(el(app, "category.hero").exists)
    back(app)
    let rta = el(app, "plan.readyToAssign")
    XCTAssertTrue(rta.waitForExistence(timeout: uiWait))
    XCTAssertTrue(scroll(app, toShow: rta))
    let assign = app.buttons["plan.assign"]
    XCTAssertTrue(reveal(app, assign))
    assign.tap()
    XCTAssertTrue(el(app, "move.to").waitForExistence(timeout: uiWait))
    tap(app, "move.close")
    XCTAssertTrue(el(app, "move.to").waitForNonExistence(timeout: uiWait))
    let card = el(app, "plan.project.japan")
    XCTAssertTrue(reveal(app, card))
    card.tap()
    XCTAssertTrue(el(app, "project.hero").waitForExistence(timeout: uiWait))
    back(app)
    back(app)
    XCTAssertTrue(el(app, "profile.plan").waitForExistence(timeout: uiWait))
  }
}
