import XCTest

/// Setup on the in-memory mocks (Paper row 10, P2.9 row 1 and X4): the bank alerts step with
/// the mailbox and its sign-in, how to turn on email alerts, the first scan, income on the keypad with the payday strip, the
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
    let connect = el(app, "mail.connect.gmail")
    XCTAssertEqual(connect.label, "Continue with Google")
    XCTAssertTrue(app.staticTexts["Connect your bank alerts"].exists)
    XCTAssertTrue(el(app, "mail.googleBriefing").exists, "the Google card is missing")
    XCTAssertTrue(el(app, "mail.change").label.contains("Use Outlook"))
    XCTAssertFalse(el(app, "setup.chooseEmail").exists)
    attach(app, "Bank alerts and Gmail")
    try audit(app)

    tap(app, "bank.howTo")
    XCTAssertTrue(el(app, "alertsHelp.enbd").waitForExistence(timeout: uiWait), "the how-to did not open")
    XCTAssertTrue(el(app, "alertsHelp.adib").exists)
    attach(app, "How to turn on email alerts")
    try audit(app, overSheet: true)
    tap(app, "alertsHelp.done")
    XCTAssertTrue(connect.waitForExistence(timeout: uiWait))
    connect.tap()

    XCTAssertTrue(el(app, "scan.progress").waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["Gmail is connected. Reading your alerts now."].exists)
    attach(app, "First scan")
    try audit(app)
    tap(app, "scan.setUpPlan")

    // Income on the app's keypad: no system keyboard, Continue off at 0.
    XCTAssertTrue(el(app, "keypad.2").waitForExistence(timeout: uiWait))
    XCTAssertFalse(app.keyboards.firstMatch.exists, "the system keyboard opened for money")
    XCTAssertFalse(el(app, "income.continue").isEnabled, "Continue was on at 0")
    typeOnKeypad(app, "25000")
    XCTAssertTrue(incomeFigure(app).contains("25,000"), "the figure reads \(incomeFigure(app))")
    attach(app, "Income")
    try audit(app)
    tap(app, "income.continue")

    XCTAssertTrue(el(app, "plan.split.handle.0").waitForExistence(timeout: uiWait))
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
    XCTAssertTrue(el(app, "notifications.allow").waitForExistence(timeout: uiWait))
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
  /// Connect, Back to the bank step: it shows the mailbox connected, with no second sign-in.
  /// 25,000 on the keypad, the payday and the split survive Back and Forward.
  @MainActor
  func testSetupRemembersEverythingThroughBackAndForward() throws {
    let app = launch(scenario: "setupBank")
    tap(app, "mail.connect.gmail", timeout: 15)
    XCTAssertTrue(el(app, "scan.progress").waitForExistence(timeout: 10), "the first scan did not start")

    back(app)
    XCTAssertTrue(el(app, "bank.continue").waitForExistence(timeout: uiWait), "the bank step forgot the connect")
    XCTAssertFalse(el(app, "setup.chooseEmail").exists, "the chooser opened")
    XCTAssertFalse(el(app, "mail.connect.gmail").exists, "the step offered Google's sign-in again")
    XCTAssertFalse(el(app, "mail.googleBriefing").exists, "the Google card stayed after the connect")
    let connected = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] 'connected'"))
    XCTAssertGreaterThan(connected.count, 0, "nothing says the mailbox is connected")
    attach(app, "Bank alerts · connected again")
    try audit(app)
    tap(app, "bank.continue")
    XCTAssertTrue(el(app, "scan.progress").waitForExistence(timeout: uiWait))
    tap(app, "scan.setUpPlan")

    // 25,000 and the 25th.
    typeOnKeypad(app, "25000")
    tap(app, "income.payday.25")
    XCTAssertTrue(el(app, "income.payday.25").waitForLabel("Payday, 25th"), "the 25th wasn't chosen")
    tap(app, "income.continue")

    // Needs to 55%.
    let handle = el(app, "plan.split.handle.0")
    XCTAssertTrue(handle.waitForExistence(timeout: uiWait))
    nudge(handle, steps: 1)
    XCTAssertTrue(handle.waitForValue("55%"), "the needs handle reads \(handle.value ?? "nothing")")

    // Back to income: the figure, the payday; forward: the split.
    back(app)
    XCTAssertTrue(el(app, "keypad.1").waitForExistence(timeout: uiWait))
    XCTAssertTrue(incomeFigure(app).contains("25,000"), "the salary was lost: \(incomeFigure(app))")
    XCTAssertEqual(el(app, "income.payday.25").label, "Payday, 25th", "the payday was lost")
    attach(app, "Income · after Back")
    tap(app, "income.continue")
    XCTAssertEqual(el(app, "plan.split.handle.0").value as? String, "55%", "the split was lost")
    XCTAssertEqual(el(app, "plan.split.handle.1").value as? String, "25%", "the split was lost")

    // All the way back to the scan and forward again: still the same.
    back(app)
    back(app)
    XCTAssertTrue(el(app, "scan.setUpPlan").waitForExistence(timeout: uiWait))
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
    tap(app, "mail.connect.gmail")
    tap(app, "scan.setUpPlan")
    XCTAssertTrue(el(app, "keypad.2").waitForExistence(timeout: uiWait))
    typeOnKeypad(app, "25000")
    attach(app, "Income · AX3")
    try audit(app, atLargeText: true)
    tap(app, "income.continue")
    XCTAssertTrue(el(app, "plan.split.handle.0").waitForExistence(timeout: uiWait))
    attach(app, "Starting plan · AX3")
    try audit(app, atLargeText: true)
  }

  /// With Reduce Motion: the same steps work, the scan pill and the badges only fade.
  @MainActor
  func testSetupWithReduceMotion() throws {
    let app = launch(scenario: "setupBank", motion: "reduce")
    tap(app, "mail.connect.gmail", timeout: 15)
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

  @MainActor
  func testAMissingGmailGrantSaysWhatToTick() throws {
    let app = launch(scenario: nil, screen: "mail.permissionMissing")
    let line = "Hasala needs \u{201C}View your email messages and settings\u{201D} ticked. Try again and tick it."
    XCTAssertTrue(app.staticTexts[line].waitForExistence(timeout: 30), "the missing grant has no line of its own")
    attach(app, "Bank alerts · Gmail access not ticked")
    try audit(app)
    tap(app, "mail.connect.gmail")
    XCTAssertTrue(el(app, "scan.progress").waitForExistence(timeout: 10), "trying again did not connect")
  }

  @MainActor
  func testNoBankAlertsYet() throws {
    let app = launch(scenario: nil, screen: "setup.resultNoAlerts")
    XCTAssertTrue(app.staticTexts["No bank alerts yet."].waitForExistence(timeout: 30))
    XCTAssertTrue(el(app, "result.howTo.enbd").exists && el(app, "result.howTo.adib").exists)
    attach(app, "No bank alerts yet")
    try audit(app)
    tap(app, "result.howTo.dib")
    XCTAssertTrue(el(app, "alertsHelp.dib").waitForExistence(timeout: uiWait), "the how-to did not open")
    XCTAssertFalse(el(app, "alertsHelp.enbd").exists, "the how-to shows every bank")
    tap(app, "alertsHelp.done")
    XCTAssertEqual(el(app, "result.checkAgain").label, "Check for new alerts")
    tap(app, "result.checkAgain")
    XCTAssertTrue(app.staticTexts["No bank alerts yet."].waitForExistence(timeout: 10))
    tap(app, "result.continue")
    XCTAssertTrue(el(app, "notifications.allow").waitForExistence(timeout: uiWait))
  }

  @MainActor
  func testNoBankAlertsYetOffersAnotherMailbox() throws {
    let app = launch(scenario: nil, screen: "setup.resultNoAlerts")
    XCTAssertTrue(app.staticTexts["No bank alerts yet."].waitForExistence(timeout: 30))
    tap(app, "result.differentEmail")
    let outlook = el(app, "mail.choose.outlook")
    XCTAssertTrue(outlook.waitForExistence(timeout: uiWait), "Choose your email did not open")
    XCTAssertTrue(el(app, "mail.connected").exists, "the bank step is not under the chooser")
    XCTAssertFalse(app.buttons["Skip"].exists, "Skip is offered with a mailbox connected")
  }

  @MainActor
  func testNoBankAlertsYetAtLargeTextSizes() throws {
    let app = launch(scenario: nil, screen: "setup.resultNoAlerts",
                     arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"])
    XCTAssertTrue(app.staticTexts["No bank alerts yet."].waitForExistence(timeout: 30))
    attach(app, "No bank alerts yet · AX3")
    try audit(app, atLargeText: true)
  }
}
