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
}
