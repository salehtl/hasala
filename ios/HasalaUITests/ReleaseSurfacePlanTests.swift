import XCTest

/// Plan on the Release surface: Assign only, no Auto-assign or New project; a budget row opens
/// its month with Change budget and Move money in and no "Add a rule"; the budget sheet has no
/// "Match September"; the project states "Count in monthly plan" and offers nothing it can't do.
final class ReleaseSurfacePlanTests: ReleaseSurfaceTestCase {
  @MainActor
  func testPlanShowsOnlyWhatWorks() throws {
    let app = launchRelease()
    app.tabBars.firstMatch.buttons["Plan"].tap()
    XCTAssertTrue(el(app, "plan.readyToAssign").waitForExistence(timeout: 5))
    attach(app, "Release · Plan")
    assertNoPlaceholders(app, "Plan")
    assertNoOutlook(app, "Plan")
    assertNoButtons(app, ["Auto-assign", "New project"], "Plan")
    XCTAssertTrue(app.buttons["plan.assign"].exists)
    try audit(app)

    // Dining's month.
    let row = app.buttons["plan.row.dining"]
    XCTAssertTrue(reveal(app, row))
    row.tap()
    XCTAssertTrue(el(app, "category.changeBudget").waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["category.changeBudget"].exists)
    XCTAssertTrue(reveal(app, app.buttons["category.moveMoney"]))
    assertNoPlaceholders(app, "Plan › Dining")
    assertAbsent(app, ["plan.addRule"], "Plan › Dining")
    assertNoButtons(app, ["Add a rule"], "Plan › Dining")
    assertPresent(app, ["plan.rule.r-talabat"], "Plan › Dining")

    // Its budget sheet: no "Match September" (no last month's figure in a Release build).
    app.buttons["category.changeBudget"].tap()
    XCTAssertTrue(el(app, "budget.amount").waitForExistence(timeout: 5))
    assertNoPlaceholders(app, "Plan › Dining budget")
    XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Match'")).count, 0)
    try audit(app)
    tap(app, "budget.close")
    back(app)

    // The project: a status, not a switch, and no actions that don't exist yet.
    let project = app.buttons["plan.project.japan"]
    XCTAssertTrue(reveal(app, project))
    project.tap()
    let setting = el(app, "project.countInPlan")
    XCTAssertTrue(setting.waitForExistence(timeout: 5))
    XCTAssertEqual(setting.value as? String, "Off")
    XCTAssertEqual(app.switches.count, 0)
    assertNoPlaceholders(app, "Plan › Japan trip")
    assertNoButtons(app, ["Add transactions", "Mark complete"], "Plan › Japan trip")
    assertAbsent(app, ["project.addTransactions", "project.markComplete"], "Plan › Japan trip")
    try audit(app)
  }

  /// Assign opens Move money, whose sources and preview show and whose words promise only
  /// what it does.
  @MainActor
  func testAssignAndMoveMoney() throws {
    let app = launchRelease()
    app.tabBars.firstMatch.buttons["Plan"].tap()
    tap(app, "plan.assign")
    XCTAssertTrue(el(app, "move.to").waitForExistence(timeout: 5))
    assertNoPlaceholders(app, "Plan › Assign")
    assertNoOutlook(app, "Plan › Assign")
    assertPresent(app, ["move.from.rta", "move.amount", "move.save"], "Plan › Assign")
    try audit(app)
  }
}
