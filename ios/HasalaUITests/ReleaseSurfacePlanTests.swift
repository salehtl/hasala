import XCTest

/// Plan on the Release surface: Assign only, no Auto-assign; a budget row opens its month.
final class ReleaseSurfacePlanTests: ReleaseSurfaceTestCase {
  @MainActor
  func testPlanShowsOnlyWhatWorks() throws {
    let app = launchRelease()
    app.tabBars.firstMatch.buttons["Plan"].tap()
    XCTAssertTrue(el(app, "plan.readyToAssign").waitForExistence(timeout: 5))
    attach(app, "Release · Plan")
    assertNoPlaceholders(app, "Plan")
    assertNoOutlook(app, "Plan")
    assertNoButtons(app, ["Auto-assign"], "Plan")
    XCTAssertTrue(app.buttons["plan.assign"].exists)
    try audit(app)
    let row = app.buttons["plan.row.dining"]
    XCTAssertTrue(reveal(app, row))
    row.tap()
    XCTAssertTrue(el(app, "category.changeBudget").waitForExistence(timeout: 5))
    assertNoPlaceholders(app, "Plan › Dining")
    back(app)
  }
}
