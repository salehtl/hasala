import XCTest

/// Home on the Release surface: no control without a screen behind it, and every control
/// that remains goes somewhere.
final class ReleaseSurfaceHomeTests: ReleaseSurfaceTestCase {
  @MainActor
  func testHomeShowsOnlyWhatWorks() throws {
    let app = launchRelease()

    // No bell, no "See month", "See all", "Edit" or "Add widget".
    attach(app, "Release · Home")
    assertNoPlaceholders(app, "Home")
    assertNoOutlook(app, "Home")
    assertAbsent(app, ["header.notifications", "home.seeMonth", "home.sampleData"], "Home")
    assertNoButtons(app, ["See all", "Edit", "Add widget", "See month"], "Home")
    // Needs you counts the cards it draws (no "See all" list to show the rest).
    let drawn = Set(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'needsYou.'"))
      .allElementsBoundByIndex.map(\.identifier)).count
    XCTAssertGreaterThan(drawn, 0)
    XCTAssertTrue(app.descendants(matching: .any)["\(drawn) items"].exists,
                  "the Needs you badge is not \(drawn), the cards drawn")
    try audit(app)

    // Widgets without a detail screen are not buttons; the others go somewhere.
    for id in ["widget.netWorth", "widget.project.Japan trip", "widget.goal.Emergency fund"] {
      XCTAssertTrue(el(app, id).exists, "\(id) is missing")
      XCTAssertFalse(app.buttons[id].exists, "\(id) is a button with nowhere to go")
    }
    let nextBill = app.buttons["widget.nextBill"]
    XCTAssertTrue(reveal(app, nextBill))
    attach(app, "Release · Home widgets")
    assertNoPlaceholders(app, "Home widgets")
    nextBill.tap()
    XCTAssertTrue(el(app, "bills.next14").waitForExistence(timeout: 5))
    attach(app, "Release · Bills")
    assertNoPlaceholders(app, "Bills")
    assertNoButtons(app, ["Remind me"], "Bills")
    try audit(app)
    back(app)
    let pace = app.buttons["widget.budgetPace"]
    XCTAssertTrue(reveal(app, pace))
    pace.tap()
    XCTAssertTrue(el(app, "plan.readyToAssign").waitForExistence(timeout: 5))
  }
}
