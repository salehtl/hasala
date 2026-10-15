import XCTest

/// Setup on the in-memory mocks (Paper row 10): bank, Gmail, the first scan, income, the
/// starting plan, the result, notifications and done. Every screen is audited for
/// accessibility, and screenshots are attached to the report.
final class SetupUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  @MainActor
  func testSetupThroughToHome() throws {
    let app = launch(scenario: "setupBank")

    // Setup (row 10).
    XCTAssertTrue(el(app, "bank.enbd").waitForExistence(timeout: 15))
    attach(app, "Bank")
    try audit(app)
    tap(app, "bank.continue")
    attach(app, "Gmail")
    try audit(app)
    tap(app, "gmail.connect")
    XCTAssertTrue(el(app, "scan.progress").waitForExistence(timeout: 10))
    attach(app, "First scan")
    tap(app, "scan.setUpPlan")
    type(app, "income.field", "25000")
    attach(app, "Income")
    tap(app, "income.continue")
    XCTAssertTrue(app.staticTexts["12,500"].waitForExistence(timeout: 5))
    attach(app, "Starting plan")
    try audit(app)
    tap(app, "plan.use")

    // No cards step: the result follows the plan, and it fills in when the import is done.
    XCTAssertTrue(el(app, "result.continue").waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["268 transactions, sorted."].waitForExistence(timeout: 20))
    attach(app, "Sorted")
    try audit(app)
    tap(app, "result.continue")
    attach(app, "Notifications")
    try audit(app)
    tap(app, "notifications.notNow")
    XCTAssertTrue(app.staticTexts["You're set, Maya."].waitForExistence(timeout: 10))
    attach(app, "Done")
    try audit(app)
    tap(app, "done.home")

    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: 10), "Home did not open")
  }
}
