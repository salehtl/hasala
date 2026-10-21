import XCTest

/// Setup on the in-memory mocks (Paper row 10, P2.9 row 1 and X4): the bank alerts step with
/// the mailbox and its sign-in and how to turn on email alerts, then Home's Finish setting
/// up: the monthly plan (income on the keypad with the payday strip, the starting plan with
/// its handles) and notifications. Every screen is audited for accessibility, and
/// screenshots are attached to the report.
final class SetupUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  static let largeText = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"]

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

    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: 10), "Home did not open")
    XCTAssertTrue(el(app, "home.finish.plan").waitForExistence(timeout: uiWait))
    XCTAssertTrue(el(app, "home.finish.notifications").exists)
    XCTAssertFalse(app.staticTexts["You're set, Maya."].exists, "setup still ends on Done")
    attach(app, "Home · Finish setting up")
    try audit(app)
  }

  @MainActor
  func testFinishSettingUpWhileTheAlertsAreRead() throws {
    let app = launch(scenario: nil, screen: "home.finishSetup")
    XCTAssertTrue(el(app, "home.finish").waitForExistence(timeout: 30))
    XCTAssertTrue(app.staticTexts["Finish setting up"].exists)
    XCTAssertTrue(app.staticTexts["0 of 2"].exists)
    let note = el(app, "home.finish.notifications")
    XCTAssertFalse(note.isEnabled, "notifications were offered before the alerts were read")
    XCTAssertTrue(note.label.contains("Offered once your alerts are read."))
    XCTAssertTrue(el(app, "home.importPill").exists)
    let hero = el(app, "home.hero.left")
    XCTAssertTrue((hero.value as? String)?.contains("spent so far · still reading your alerts") == true,
                  "the hero reads \(hero.value ?? "nothing")")
    XCTAssertFalse(el(app, "home.tile.needs").exists, "the hero shows tiles without a plan")
    attach(app, "Home · Finish setting up, reading")
    try audit(app)

    tap(app, "home.finish.plan")
    XCTAssertTrue(el(app, "keypad.2").waitForExistence(timeout: uiWait))
    XCTAssertFalse(app.keyboards.firstMatch.exists, "the system keyboard opened for money")
    XCTAssertFalse(el(app, "income.continue").isEnabled, "Continue was on at 0")
    typeOnKeypad(app, "25000")
    XCTAssertTrue(incomeFigure(app).contains("25,000"), "the figure reads \(incomeFigure(app))")
    attach(app, "Monthly plan · Income")
    try audit(app, overSheet: true)
    tap(app, "income.continue")

    XCTAssertTrue(el(app, "plan.split.handle.0").waitForExistence(timeout: uiWait))
    let needs = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'AED 12,500'"))
    XCTAssertGreaterThan(needs.count, 0, "the needs amount is missing")
    attach(app, "Monthly plan · Starting plan")
    try audit(app, overSheet: true)
    tap(app, "plan.use")
    XCTAssertTrue(el(app, "home.finish.plan").waitForNonExistence(timeout: uiWait), "the plan item stayed")
    XCTAssertTrue(app.staticTexts["1 of 2"].waitForExistence(timeout: uiWait))
  }

  @MainActor
  func testNotificationsAreAskedFromHomeAfterTheImport() throws {
    let app = launch(scenario: "finishSetup")
    let note = el(app, "home.finish.notifications")
    XCTAssertTrue(note.waitForExistence(timeout: 30))
    XCTAssertTrue(note.isEnabled)
    note.tap()
    XCTAssertTrue(el(app, "notifications.allow").waitForExistence(timeout: uiWait))
    attach(app, "Notifications from Home")
    try audit(app, overSheet: true)
    tap(app, "notifications.notNow")
    XCTAssertTrue(note.waitForNonExistence(timeout: uiWait), "the notifications item stayed")
    XCTAssertTrue(el(app, "home.finish.plan").exists)
  }

  @MainActor
  func testSetupAtLargeTextSizes() throws {
    let app = launch(scenario: "setupBank", arguments: Self.largeText)
    XCTAssertTrue(el(app, "bank.enbd").waitForExistence(timeout: 15))
    attach(app, "Bank · AX3")
    try audit(app, atLargeText: true)
    tap(app, "mail.connect.gmail")
    XCTAssertTrue(el(app, "home.finish.plan").waitForExistence(timeout: uiWait))
    attach(app, "Home · Finish setting up · AX3")
    try audit(app, atLargeText: true)
    tap(app, "home.finish.plan")
    XCTAssertTrue(el(app, "keypad.2").waitForExistence(timeout: uiWait))
    typeOnKeypad(app, "25000")
    attach(app, "Income · AX3")
    try audit(app, atLargeText: true, overSheet: true)
    tap(app, "income.continue")
    XCTAssertTrue(el(app, "plan.split.handle.0").waitForExistence(timeout: uiWait))
    attach(app, "Starting plan · AX3")
    try audit(app, atLargeText: true, overSheet: true)
  }

  @MainActor
  func testSetupWithReduceMotion() throws {
    let app = launch(scenario: "setupBank", motion: "reduce")
    tap(app, "mail.connect.gmail", timeout: 15)
    tap(app, "home.finish.plan")
    typeOnKeypad(app, "18000")
    XCTAssertTrue(incomeFigure(app).contains("18,000"))
    tap(app, "income.continue")
    tap(app, "plan.use")
    XCTAssertTrue(el(app, "home.finish.plan").waitForNonExistence(timeout: uiWait))
    attach(app, "Home · plan set · Reduce Motion")
  }

  @MainActor
  func testAMissingGmailGrantSaysWhatToTick() throws {
    let app = launch(scenario: nil, screen: "mail.permissionMissing")
    let line = "Hasala needs \u{201C}View your email messages and settings\u{201D} ticked. Try again and tick it."
    XCTAssertTrue(app.staticTexts[line].waitForExistence(timeout: 30), "the missing grant has no line of its own")
    attach(app, "Bank alerts · Gmail access not ticked")
    try audit(app)
    tap(app, "mail.connect.gmail")
    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: 10), "trying again did not connect")
  }
}
