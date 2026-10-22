import XCTest

/// Plan on the Release surface: Assign and New project, no Auto-assign; a budget row opens
/// its month with Change budget (also in More) and Move money in and no "Add a rule"; the
/// budget sheet has no "Match September"; the project's switch, Add transactions and Mark
/// complete all work.
final class ReleaseSurfacePlanTests: ReleaseSurfaceTestCase {
  @MainActor
  func testPlanShowsOnlyWhatWorks() throws {
    let app = launchRelease()
    openPlan(app)
    XCTAssertTrue(el(app, "plan.readyToAssign").waitForExistence(timeout: uiWait))
    attach(app, "Release · Plan")
    assertNoPlaceholders(app, "Plan")
    assertPersonalAccountsOnly(app, "Plan")
    assertNoButtons(app, ["Auto-assign"], "Plan")
    XCTAssertTrue(app.buttons["plan.assign"].exists)
    try audit(app)

    // Dining's month.
    let row = app.buttons["plan.row.dining"]
    XCTAssertTrue(reveal(app, row))
    row.tap()
    XCTAssertTrue(el(app, "category.hero").waitForExistence(timeout: uiWait))

    // Its budget sheet, from More, over the top of Dining as Paper draws it: no "Match
    // September" (no last month's figure in a Release build).
    tap(app, "plan.more")
    let changeBudget = app.buttons.matching(
      NSPredicate(format: "label == 'Change budget' AND identifier != 'category.changeBudget'")).firstMatch
    XCTAssertTrue(changeBudget.waitForExistence(timeout: uiWait))
    changeBudget.tap()
    XCTAssertTrue(el(app, "budget.amount").waitForExistence(timeout: uiWait))
    waitUntilStill(el(app, "budget.close"))
    assertNoPlaceholders(app, "Plan › Dining budget")
    XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Match'")).count, 0)
    try audit(app)
    tap(app, "budget.close")

    // Down to its actions: Change budget and Move money in, the rules, no "Add a rule".
    XCTAssertTrue(reveal(app, app.buttons["category.moveMoney"]))
    XCTAssertTrue(app.buttons["category.changeBudget"].exists)
    assertNoPlaceholders(app, "Plan › Dining")
    assertAbsent(app, ["plan.addRule"], "Plan › Dining")
    assertNoButtons(app, ["Add a rule"], "Plan › Dining")
    assertPresent(app, ["plan.rule.r-talabat"], "Plan › Dining")
    back(app)

    let project = app.buttons["plan.project.japan"]
    XCTAssertTrue(reveal(app, project))
    assertPresent(app, ["plan.newProject", "plan.allProjects"], "Plan")
    project.tap()
    let setting = el(app, "project.countInPlan")
    XCTAssertTrue(setting.waitForExistence(timeout: uiWait))
    XCTAssertEqual(setting.value as? String, "0")
    assertNoPlaceholders(app, "Plan › Japan trip")
    XCTAssertTrue(reveal(app, el(app, "project.markComplete")))
    assertPresent(app, ["project.addTransactions", "project.markComplete"], "Plan › Japan trip")
    try audit(app)
    tap(app, "plan.more")
    XCTAssertTrue(app.buttons["Edit project"].waitForExistence(timeout: uiWait))
    XCTAssertTrue(app.buttons["Remove project"].exists)
    assertNoPlaceholders(app, "Plan › Japan trip › More")
    app.buttons["Edit project"].tap()
    XCTAssertTrue(el(app, "projectEditor.name").waitForExistence(timeout: uiWait))
    assertNoPlaceholders(app, "Plan › Japan trip › Edit project")
    XCTAssertTrue(reveal(app, el(app, "projectEditor.remove")))
    back(app)
    XCTAssertTrue(el(app, "project.addTransactions").waitForExistence(timeout: uiWait))
    tap(app, "project.addTransactions", opening: "projectAdd.merchant")
    assertNoPlaceholders(app, "Plan › Japan trip › Add transactions")
    try audit(app)
    back(app)
    back(app)
    let all = el(app, "plan.allProjects")
    XCTAssertTrue(reveal(app, all))
    all.tap()
    XCTAssertTrue(el(app, "projects.new").waitForExistence(timeout: uiWait))
    assertNoPlaceholders(app, "Plan › Projects")
    try audit(app)
    tap(app, "projects.new", opening: "projectEditor.name")
    assertNoPlaceholders(app, "Plan › New project")
    try audit(app, overSheet: true)
  }

  @MainActor
  func testProjectsTabShowsOnlyWhatWorks() throws {
    let app = launchRelease()
    app.tabBars.firstMatch.buttons["Projects"].tap()
    XCTAssertTrue(el(app, "projects.new").waitForExistence(timeout: uiWait))
    attach(app, "Release · Projects")
    assertNoPlaceholders(app, "Projects")
    assertPersonalAccountsOnly(app, "Projects")
    XCTAssertTrue(app.buttons["header.profile"].exists)
    XCTAssertFalse(app.navigationBars.buttons["Back"].exists)
    try audit(app)
    tap(app, "projects.project.japan", opening: "project.hero")
    assertNoPlaceholders(app, "Projects › Japan trip")
    tap(app, "plan.more")
    XCTAssertTrue(app.buttons["Edit project"].waitForExistence(timeout: uiWait))
    app.buttons["Edit project"].tap()
    XCTAssertTrue(el(app, "projectEditor.name").waitForExistence(timeout: uiWait))
    XCTAssertTrue(reveal(app, el(app, "projectEditor.remove")))
    assertNoPlaceholders(app, "Projects › Japan trip › Edit project")
    try audit(app, overSheet: true)
    tap(app, "projectEditor.close")
    XCTAssertTrue(el(app, "project.hero").waitForExistence(timeout: uiWait))
  }

  /// Waits until `element` stops moving (a sheet settling into its detent), at most 5 s.
  @MainActor
  private func waitUntilStill(_ element: XCUIElement) {
    var last = element.frame
    for _ in 0..<20 {
      Thread.sleep(forTimeInterval: 0.25)
      let now = element.frame
      if now == last { return }
      last = now
    }
  }

  /// Assign opens Move money, whose sources and preview show and whose words promise only
  /// what it does.
  @MainActor
  func testAssignAndMoveMoney() throws {
    let app = launchRelease()
    openPlan(app)
    tap(app, "plan.assign")
    XCTAssertTrue(el(app, "move.to").waitForExistence(timeout: uiWait))
    assertNoPlaceholders(app, "Plan › Assign")
    assertPersonalAccountsOnly(app, "Plan › Assign")
    assertPresent(app, ["move.from.rta", "move.amount", "move.save"], "Plan › Assign")
    try audit(app)
  }
}
