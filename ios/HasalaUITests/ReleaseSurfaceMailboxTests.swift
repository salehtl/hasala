import XCTest

/// Mailboxes on the Release surface: Gmail only, after setup too.
final class ReleaseSurfaceMailboxTests: ReleaseSurfaceTestCase {
  /// Gmail skipped at setup: Home offers "Connect Gmail", which runs the Gmail step and the
  /// cards in a sheet; once the cards are confirmed, Home no longer offers it. (The Profile
  /// card's button is the reconnect test's; one launch each keeps the ios job's time down.)
  @MainActor
  func testConnectGmailAfterSkippingIt() throws {
    // Home's Gmail card went with the mailbox contract (plan B4.3); the bell's mail row and
    // Bank alerts take its place.
    try XCTSkipIf(true, "P3: replaced by ReleaseSurfaceMailboxTests")
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
    try XCTSkipIf(true, "P3: replaced by ReleaseSurfaceMailboxTests")
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

  /// No mailbox: the Profile card offers "Connect your email", which opens Gmail's screen
  /// inside the profile (no chooser: Gmail is the only provider), and connecting lands on
  /// Bank alerts with the new mailbox.
  @MainActor
  func testConnectYourEmailFromTheProfile() throws {
    let app = launchRelease("noMailbox")
    app.buttons["header.profile"].firstMatch.tap()
    XCTAssertTrue(el(app, "profile.bankAlerts").waitForExistence(timeout: 5))
    XCTAssertTrue(el(app, "profile.bankAlerts").label.contains("Your email isn't connected"))
    tap(app, "profile.connectGmail")
    let connect = el(app, "mail.connect.gmail")
    XCTAssertTrue(connect.waitForExistence(timeout: 5))
    XCTAssertEqual(connect.label, "Continue with Google")
    attach(app, "Release · Connect your email")
    assertNoPlaceholders(app, "Connect your email")
    assertNoOutlook(app, "Connect your email")
    assertNoText(app, ["Step 2 of 4", "our server is told"], "Connect your email")
    try audit(app)
    connect.tap()
    XCTAssertTrue(el(app, "bankAlerts.mailbox.gmail-1").waitForExistence(timeout: 10), "Bank alerts did not open")
    assertText(app, "Gmail connected. Checking for alerts.", "Bank alerts")
    attach(app, "Release · Bank alerts")
    assertNoPlaceholders(app, "Bank alerts")
    assertNoOutlook(app, "Bank alerts")
    // Live reads one mailbox: no "Add a mailbox" beside it.
    assertAbsent(app, ["bankAlerts.addMailbox"], "Bank alerts")
  }

  /// Setup's bank step was skipped (manual entry), so the account reads no bank: "Connect
  /// your email" asks for the banks first (the lane reads only their senders), then Gmail's
  /// screen names the banks picked, never an empty list.
  @MainActor
  func testConnectWithNoBankAsksForTheBanksFirst() throws {
    let app = launchRelease("noBanks")
    app.buttons["header.profile"].firstMatch.tap()
    XCTAssertTrue(el(app, "profile.bankAlerts").waitForExistence(timeout: 5))
    tap(app, "profile.connectGmail")
    XCTAssertTrue(el(app, "bank.enbd").waitForExistence(timeout: 5), "the banks were not asked for")
    XCTAssertFalse(el(app, "mail.connect.gmail").exists, "Gmail's sign-in came before the banks")
    attach(app, "Release · Connect your email · Banks")
    assertNoPlaceholders(app, "Banks")
    assertNoOutlook(app, "Banks")
    assertNoText(app, ["Step 1 of 4"], "Banks")
    try audit(app)
    tap(app, "bank.dib")
    XCTAssertEqual(el(app, "bank.continue").label, "Continue with 1 bank")
    tap(app, "bank.continue")
    let connect = el(app, "mail.connect.gmail")
    XCTAssertTrue(connect.waitForExistence(timeout: 5))
    assertText(app, "Alerts from Emirates NBD, and nothing else", "Connect your email")
    assertNoText(app, ["Alerts from ,"], "Connect your email")
    attach(app, "Release · Connect your email · After the banks")
    connect.tap()
    XCTAssertTrue(el(app, "bankAlerts.mailbox.gmail-1").waitForExistence(timeout: 10), "Bank alerts did not open")
    assertText(app, "Gmail connected. Checking for alerts.", "Bank alerts")
  }

  /// Google ended Hasala's access: the Profile card says so and "Sign in again" runs the
  /// same Google screen, then Bank alerts says it works again.
  @MainActor
  func testSignInAgainFromTheProfile() throws {
    let app = launchRelease("gmailReconnect")
    app.buttons["header.profile"].firstMatch.tap()
    XCTAssertTrue(el(app, "profile.bankAlerts").waitForExistence(timeout: 5))
    XCTAssertTrue(el(app, "profile.bankAlerts").label.contains("Sign in again"))
    assertNoOutlook(app, "Profile")
    tap(app, "profile.connectGmail")
    let connect = el(app, "mail.connect.gmail")
    XCTAssertTrue(connect.waitForExistence(timeout: 5))
    connect.tap()
    assertText(app, "Gmail reconnected", "Bank alerts")
    XCTAssertTrue(el(app, "bankAlerts.hero").waitForExistence(timeout: 5))
    XCTAssertTrue(el(app, "bankAlerts.hero").label.contains("Bank alerts are working")
                  || app.staticTexts["Bank alerts are working"].exists)
    assertNoPlaceholders(app, "Bank alerts")
  }
}
