import XCTest

/// Mailboxes on the in-memory mock: connecting one in setup, through to the first scan.
final class MailboxUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  /// Setup's email step connects Gmail (the mock's sign-in always succeeds) and the first
  /// scan starts.
  @MainActor
  func testSetupConnectsGmailToTheFirstScan() throws {
    let app = launch(scenario: "setupBank")
    tap(app, "bank.continue", timeout: 15)
    XCTAssertTrue(el(app, "gmail.connect").waitForExistence(timeout: 10))
    attach(app, "Connect Gmail")
    try audit(app)
    tap(app, "gmail.connect")
    XCTAssertTrue(el(app, "scan.progress").waitForExistence(timeout: 10), "the first scan did not start")
    attach(app, "First scan")
  }

  /// Debug offers Outlook too: Profile › Bank alerts › Add a mailbox › Outlook connects a
  /// second mailbox, and Bank alerts lists both.
  @MainActor
  func testAddOutlookFromBankAlerts() throws {
    let app = launch(scenario: "passkeyUser")
    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: 15))
    app.buttons["header.profile"].firstMatch.tap()
    tap(app, "profile.bankAlerts")
    XCTAssertTrue(el(app, "bankAlerts.mailbox.gmail-1").waitForExistence(timeout: 5))
    attach(app, "Bank alerts")
    try audit(app)
    tap(app, "bankAlerts.addMailbox")
    tap(app, "mail.choose.outlook")
    let connect = el(app, "mail.connect.outlook")
    XCTAssertTrue(connect.waitForExistence(timeout: 5))
    XCTAssertEqual(connect.label, "Continue with Microsoft")
    attach(app, "Connect Outlook")
    try audit(app)
    connect.tap()
    XCTAssertTrue(el(app, "bankAlerts.mailbox.outlook-1").waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["Outlook connected. Checking for alerts."].waitForExistence(timeout: 5))
    attach(app, "Bank alerts · two mailboxes")
  }
}
