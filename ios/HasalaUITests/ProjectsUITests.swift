import XCTest

final class ProjectsUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  @MainActor
  private func launchPlan(arguments: [String] = []) -> XCUIApplication {
    let app = launch(scenario: "maya", motion: "off", arguments: arguments)
    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: 15))
    app.tabBars.firstMatch.buttons["Plan"].tap()
    XCTAssertTrue(el(app, "plan.readyToAssign").waitForExistence(timeout: uiWait))
    return app
  }

  @MainActor
  private func first(_ app: XCUIApplication, prefix: String) -> XCUIElement {
    app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix)).firstMatch
  }

  @MainActor
  private func makeKitchen(_ app: XCUIApplication, large: Bool = false) throws {
    let new = el(app, "plan.newProject")
    XCTAssertTrue(reveal(app, new))
    attach(app, large ? "AX3 · Plan · Projects section" : "Plan · Projects section")
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
    let app = launchPlan()
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
    let all = el(app, "plan.allProjects")
    XCTAssertTrue(reveal(app, all))
    XCTAssertEqual(app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH 'plan.project.' AND label BEGINSWITH 'Kitchen'")).count, 0)
    all.tap()
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
  func testProjectsAtLargeText() throws {
    let large = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"]
    let app = launchPlan(arguments: large)
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
    let all = el(app, "plan.allProjects")
    XCTAssertTrue(reveal(app, all))
    all.tap()
    XCTAssertTrue(el(app, "projects.new").waitForExistence(timeout: uiWait))
    attach(app, "AX3 · Projects")
    try audit(app, atLargeText: true)
    XCTAssertTrue(reveal(app, el(app, "projects.project.japan")))
    try audit(app, atLargeText: true)
  }
}
