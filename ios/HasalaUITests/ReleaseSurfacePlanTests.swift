import XCTest

/// Plan on the Release surface: Assign only, no Auto-assign or New project; a budget row opens
/// its month with Change budget (also in More) and Move money in and no "Add a rule"; the
/// budget sheet has no "Match September"; the project states "Count in monthly plan" and
/// offers nothing it can't do.
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
    XCTAssertTrue(el(app, "category.hero").waitForExistence(timeout: 5))

    // Its budget sheet, from More, over the top of Dining as Paper draws it: no "Match
    // September" (no last month's figure in a Release build).
    tap(app, "plan.more")
    let changeBudget = app.buttons.matching(
      NSPredicate(format: "label == 'Change budget' AND identifier != 'category.changeBudget'")).firstMatch
    XCTAssertTrue(changeBudget.waitForExistence(timeout: 5))
    changeBudget.tap()
    XCTAssertTrue(el(app, "budget.amount").waitForExistence(timeout: 5))
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
    app.tabBars.firstMatch.buttons["Plan"].tap()
    tap(app, "plan.assign")
    XCTAssertTrue(el(app, "move.to").waitForExistence(timeout: 5))
    assertNoPlaceholders(app, "Plan › Assign")
    assertNoOutlook(app, "Plan › Assign")
    assertPresent(app, ["move.from.rta", "move.amount", "move.save"], "Plan › Assign")
    try audit(app)
  }
}
