import XCTest

/// Setup on the in-memory mocks (Paper row 10 and P2.9 row 1): bank, "Choose your email",
/// the read-only connect, the first scan, income on the keypad with the payday strip, the
/// starting plan with its handles, the result, notifications and done. Every screen is
/// audited for accessibility, and screenshots are attached to the report.
final class SetupUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  @MainActor
  func testSetupThroughToHome() throws {
    let app = launch(scenario: "setupBank")

    XCTAssertTrue(el(app, "bank.enbd").waitForExistence(timeout: 15))
    attach(app, "Bank")
    try audit(app)
    tap(app, "bank.continue")

    // Debug reads Gmail and Outlook: "Choose your email" over the bank step.
    XCTAssertTrue(el(app, "setup.chooseEmail").waitForExistence(timeout: 5))
    attach(app, "Choose your email")
    try audit(app, overSheet: true)
    tap(app, "mail.choose.gmail")
    let connect = el(app, "mail.connect.gmail")
    XCTAssertTrue(connect.waitForExistence(timeout: 5))
    XCTAssertEqual(connect.label, "Continue with Google")
    attach(app, "Connect Gmail")
    try audit(app)
    connect.tap()

    XCTAssertTrue(el(app, "scan.progress").waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["Gmail is connected. Reading your alerts now."].exists)
    attach(app, "First scan")
    try audit(app)
    tap(app, "scan.setUpPlan")

    // Income on the app's keypad: no system keyboard, Continue off at 0.
    XCTAssertTrue(el(app, "keypad.2").waitForExistence(timeout: 5))
    XCTAssertFalse(app.keyboards.firstMatch.exists, "the system keyboard opened for money")
    XCTAssertFalse(el(app, "income.continue").isEnabled, "Continue was on at 0")
    typeOnKeypad(app, "25000")
    XCTAssertTrue(incomeFigure(app).contains("25,000"), "the figure reads \(incomeFigure(app))")
    attach(app, "Income")
    try audit(app)
    tap(app, "income.continue")

    XCTAssertTrue(el(app, "plan.split.handle.0").waitForExistence(timeout: 5))
    let needs = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'AED 12,500'"))
    XCTAssertGreaterThan(needs.count, 0, "the needs amount is missing")
    attach(app, "Starting plan")
    try audit(app)
    tap(app, "plan.use")

    // No cards step: the result follows the plan, and it fills in when the import is done.
    XCTAssertTrue(el(app, "result.continue").waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["268 transactions, sorted."].waitForExistence(timeout: 20))
    attach(app, "Sorted")
    try audit(app)
    tap(app, "result.continue")
    XCTAssertTrue(el(app, "notifications.allow").waitForExistence(timeout: 5))
    attach(app, "Notifications")
    try audit(app)
    tap(app, "notifications.notNow")
    XCTAssertTrue(app.staticTexts["You're set, Maya."].waitForExistence(timeout: 10))
    attach(app, "Done")
    try audit(app)
    tap(app, "done.home")

    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: 10), "Home did not open")
  }

  /// The owner's requirement: setup remembers everything for the life of the process.
  /// Connect, Back to the bank, Continue: the email step is connected, with no second
  /// sign-in. 25,000 on the keypad, the payday and the split survive Back and Forward.
  @MainActor
  func testSetupRemembersEverythingThroughBackAndForward() throws {
    let app = launch(scenario: "setupBank")
    tap(app, "bank.continue")
    tap(app, "mail.choose.gmail")
    tap(app, "mail.connect.gmail")
    XCTAssertTrue(el(app, "scan.progress").waitForExistence(timeout: 10), "the first scan did not start")

    // Back to the email step, then to the bank.
    back(app)
    XCTAssertTrue(el(app, "mail.continue").waitForExistence(timeout: 5), "the email step forgot the connect")
    back(app)
    XCTAssertTrue(el(app, "bank.continue").waitForExistence(timeout: 5))

    // Continue again: no chooser (the provider is remembered), and the step shows connected.
    tap(app, "bank.continue")
    XCTAssertTrue(el(app, "mail.continue").waitForExistence(timeout: 5), "Continue offered a sign-in again")
    XCTAssertFalse(el(app, "setup.chooseEmail").exists, "the chooser opened again")
    XCTAssertFalse(el(app, "mail.connect.gmail").exists, "the step offered Google's sign-in again")
    let connected = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] 'connected'"))
    XCTAssertGreaterThan(connected.count, 0, "nothing says the mailbox is connected")
    attach(app, "Connect Gmail · connected again")
    try audit(app)
    tap(app, "mail.continue")
    XCTAssertTrue(el(app, "scan.progress").waitForExistence(timeout: 5))
    tap(app, "scan.setUpPlan")

    // 25,000 and the 25th.
    typeOnKeypad(app, "25000")
    tap(app, "income.payday.25")
    XCTAssertTrue(el(app, "income.payday.25").waitForLabel("Payday, 25th"), "the 25th wasn't chosen")
    tap(app, "income.continue")

    // Needs to 55%.
    let handle = el(app, "plan.split.handle.0")
    XCTAssertTrue(handle.waitForExistence(timeout: 5))
    nudge(handle, steps: 1)
    XCTAssertTrue(handle.waitForValue("55%"), "the needs handle reads \(handle.value ?? "nothing")")

    // Back to income: the figure, the payday; forward: the split.
    back(app)
    XCTAssertTrue(el(app, "keypad.1").waitForExistence(timeout: 5))
    XCTAssertTrue(incomeFigure(app).contains("25,000"), "the salary was lost: \(incomeFigure(app))")
    XCTAssertEqual(el(app, "income.payday.25").label, "Payday, 25th", "the payday was lost")
    attach(app, "Income · after Back")
    tap(app, "income.continue")
    XCTAssertEqual(el(app, "plan.split.handle.0").value as? String, "55%", "the split was lost")
    XCTAssertEqual(el(app, "plan.split.handle.1").value as? String, "25%", "the split was lost")

    // All the way back to the scan and forward again: still the same.
    back(app)
    back(app)
    XCTAssertTrue(el(app, "scan.setUpPlan").waitForExistence(timeout: 5))
    tap(app, "scan.setUpPlan")
    XCTAssertTrue(incomeFigure(app).contains("25,000"), "the salary was lost: \(incomeFigure(app))")
    XCTAssertEqual(el(app, "income.payday.25").label, "Payday, 25th")
    tap(app, "income.continue")
    XCTAssertEqual(el(app, "plan.split.handle.0").value as? String, "55%")
    attach(app, "Starting plan · after Back and Forward")
  }

  /// Bank, income and plan at a large accessibility text size: everything reflows, nothing
  /// is cut.
  @MainActor
  func testSetupAtLargeTextSizes() throws {
    let app = launch(scenario: "setupBank",
                     arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"])
    XCTAssertTrue(el(app, "bank.enbd").waitForExistence(timeout: 15))
    attach(app, "Bank · AX3")
    try audit(app, atLargeText: true)
    tap(app, "bank.continue")
    tap(app, "mail.choose.gmail")
    tap(app, "mail.connect.gmail")
    tap(app, "scan.setUpPlan")
    XCTAssertTrue(el(app, "keypad.2").waitForExistence(timeout: 5))
    typeOnKeypad(app, "25000")
    attach(app, "Income · AX3")
    try audit(app, atLargeText: true)
    tap(app, "income.continue")
    XCTAssertTrue(el(app, "plan.split.handle.0").waitForExistence(timeout: 5))
    attach(app, "Starting plan · AX3")
    try audit(app, atLargeText: true)
  }

  /// With Reduce Motion: the same steps work, the scan pill and the badges only fade.
  @MainActor
  func testSetupWithReduceMotion() throws {
    let app = launch(scenario: "setupBank", motion: "reduce")
    tap(app, "bank.continue", timeout: 15)
    tap(app, "mail.choose.gmail")
    tap(app, "mail.connect.gmail")
    tap(app, "scan.setUpPlan")
    typeOnKeypad(app, "18000")
    XCTAssertTrue(incomeFigure(app).contains("18,000"))
    tap(app, "income.continue")
    tap(app, "plan.use")
    XCTAssertTrue(app.staticTexts["268 transactions, sorted."].waitForExistence(timeout: 20))
    attach(app, "Sorted · Reduce Motion")
    tap(app, "result.continue")
    tap(app, "notifications.notNow")
    XCTAssertTrue(el(app, "done.home").waitForExistence(timeout: 10))
    attach(app, "Done · Reduce Motion")
  }
}
