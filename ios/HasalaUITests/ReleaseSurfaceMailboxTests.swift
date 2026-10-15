import XCTest

/// Mailboxes on the Release surface: Gmail only, after setup too.
final class ReleaseSurfaceMailboxTests: ReleaseSurfaceTestCase {
  /// Gmail skipped at setup: Home offers "Connect Gmail", which runs the Gmail step and the
  /// cards in a sheet; once the cards are confirmed, Home no longer offers it. (The Profile
  /// card's button is the reconnect test's; one launch each keeps the ios job's time down.)
  @MainActor
  func testConnectGmailAfterSkippingIt() throws {
    let app = launchRelease("gmailSkipped")
    let card = el(app, "needsYou.gmail.connect")
    XCTAssertTrue(card.waitForExistence(timeout: 10))
    attach(app, "Release · Home · Connect Gmail")
    card.buttons["Connect"].tap()
    let connect = el(app, "gmail.connect")
    XCTAssertTrue(connect.waitForExistence(timeout: 5))
    XCTAssertEqual(connect.label, "Connect Gmail")
    assertNoPlaceholders(app, "Connect Gmail")
    // Not setup: no step indicator, and Close instead of Skip.
    assertNoText(app, ["Step 2 of 4"], "Connect Gmail")
    XCTAssertEqual(el(app, "account.trailing").label, "Close")
    attach(app, "Release · Connect Gmail")
    try audit(app)
    connect.tap()
    XCTAssertTrue(el(app, "result.continue").waitForExistence(timeout: 15), "the result did not appear")
    attach(app, "Release · Connect Gmail · Result")
    tap(app, "result.continue")
    XCTAssertTrue(card.waitForNonExistence(timeout: 10), "Home still offers Connect Gmail")
  }

  /// Google wants a new sign-in: the Profile card offers "Reconnect Gmail", which is done
  /// as soon as Google and the step-up say yes.
  @MainActor
  func testReconnectGmailFromTheProfile() throws {
    let app = launchRelease("gmailReconnect")
    XCTAssertTrue(el(app, "needsYou.gmail.reconnect").waitForExistence(timeout: 10))
    app.buttons["header.profile"].firstMatch.tap()
    XCTAssertTrue(el(app, "profile.name").waitForExistence(timeout: 5))
    XCTAssertTrue(el(app, "profile.bankAlerts").label.contains("Gmail needs reconnecting"))
    tap(app, "profile.connectGmail")
    let reconnect = el(app, "gmail.connect")
    XCTAssertTrue(reconnect.waitForExistence(timeout: 5))
    XCTAssertEqual(reconnect.label, "Reconnect Gmail")
    assertNoPlaceholders(app, "Reconnect Gmail")
    attach(app, "Release · Reconnect Gmail")
    try audit(app)
    reconnect.tap()
    assertText(app, "Gmail reconnected", "Profile")
    XCTAssertTrue(el(app, "profile.connectGmail").waitForNonExistence(timeout: 5))
    XCTAssertTrue(el(app, "profile.bankAlerts").label.contains("Bank alerts are working"))
  }
}
