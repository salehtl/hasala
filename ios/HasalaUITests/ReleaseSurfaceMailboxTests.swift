import XCTest

/// Mailboxes on the Release surface: Gmail only, one mailbox (as the live lane reads), and
/// no copy that names another provider (plan B4.6). Each test goes Home › Profile › Bank
/// alerts through the Profile card, as a person does.
final class ReleaseSurfaceMailboxTests: ReleaseSurfaceTestCase {
  /// Bank alerts with an account's scenario, its hero on screen: through the Profile card,
  /// a button in Release too.
  @MainActor
  private func bankAlerts(_ scenario: String) -> XCUIApplication {
    let app = launchRelease(scenario)
    app.buttons["header.profile"].firstMatch.tap()
    let card = app.buttons["profile.bankAlerts"]
    XCTAssertTrue(card.waitForExistence(timeout: 10), "the Profile card is not a button")
    card.tap()
    XCTAssertTrue(el(app, "bankAlerts.hero").waitForExistence(timeout: 15), "Bank alerts did not open")
    return app
  }

  /// No mailbox: Bank alerts says so, and Add a mailbox goes straight to Gmail's read-only
  /// screen (no chooser: Gmail is the only provider), which asks which email the person
  /// uses instead of offering another and says how new alerts are really caught.
  /// Connecting lands back on Bank alerts with the mailbox, and no second one is offered.
  @MainActor
  func testAddAMailboxGoesStraightToGmail() throws {
    let app = bankAlerts("noMailbox")
    XCTAssertTrue(el(app, "bankAlerts.status").label.contains("Not connected"))
    assertNoPlaceholders(app, "Bank alerts")
    assertNoOutlook(app, "Bank alerts")
    // Debug's parts with no screen behind them yet.
    assertAbsent(app, ["bankAlerts.addBank", "bankAlerts.unreadable"], "Bank alerts")
    assertNoText(app, ["when new mail arrives"], "Bank alerts")
    attach(app, "Release · Bank alerts · no mailbox")
    try audit(app)
    tap(app, "bankAlerts.addMailbox")
    let connect = el(app, "mail.connect.gmail")
    XCTAssertTrue(connect.waitForExistence(timeout: 5))
    XCTAssertEqual(connect.label, "Continue with Google")
    assertAbsent(app, ["mail.choose.gmail", "mail.notYours"], "Connect your email")
    assertPresent(app, ["mail.choose.other"], "Connect your email")
    XCTAssertEqual(el(app, "mail.choose.other").label, "Use a different email? Tell us which.")
    assertText(app, "checks for new alerts when you open Hasala", "Connect your email")
    assertNoText(app, ["Step 2 of 4", "our server is told"], "Connect your email")
    assertNoPlaceholders(app, "Connect your email")
    assertNoOutlook(app, "Connect your email")
    attach(app, "Release · Connect your email")
    try audit(app)
    connect.tap()
    XCTAssertTrue(el(app, "bankAlerts.mailbox.gmail-1").waitForExistence(timeout: 10), "Bank alerts did not come back")
    assertText(app, "Gmail connected. Checking for alerts.", "Bank alerts")
    // Live reads one mailbox: no "Add a mailbox" beside it.
    assertAbsent(app, ["bankAlerts.addMailbox"], "Bank alerts")
    assertNoOutlook(app, "Bank alerts")
    attach(app, "Release · Bank alerts · Gmail connected")
  }

  /// Setup's bank step was skipped (manual entry), so the account reads no bank: Add a
  /// mailbox asks for the banks first (the lane reads only their senders), then Gmail's
  /// screen names the banks picked, never an empty list.
  @MainActor
  func testConnectWithNoBankAsksForTheBanksFirst() throws {
    let app = bankAlerts("noBanks")
    tap(app, "bankAlerts.addMailbox")
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

  /// Google ended Hasala's access: the hero says "Sign in again" with "Continue with
  /// Google"; signed in again, it says it works.
  @MainActor
  func testSignInAgainFromTheHero() throws {
    let app = bankAlerts("gmailReconnect")
    XCTAssertTrue(el(app, "bankAlerts.status").label.contains("Sign in again"))
    let button = el(app, "bankAlerts.signInAgain")
    XCTAssertEqual(button.label, "Continue with Google")
    assertNoPlaceholders(app, "Bank alerts")
    assertNoOutlook(app, "Bank alerts")
    attach(app, "Release · Bank alerts · Sign in again")
    try audit(app)
    button.tap()
    assertText(app, "Gmail connected again. Catching up from the last check.", "Bank alerts")
    XCTAssertTrue(el(app, "bankAlerts.status").waitForLabel(containing: "Working"), "the hero still asks for a sign-in")
    assertNoPlaceholders(app, "Bank alerts")
  }

  /// The Gmail mailbox: its page names Google's settings, and Disconnect's alert Google's
  /// permissions page; disconnected, Bank alerts offers to add one again.
  @MainActor
  func testMailboxPageAndDisconnect() throws {
    let app = bankAlerts("passkeyUser")
    tap(app, "bankAlerts.mailbox.gmail-1")
    XCTAssertTrue(el(app, "mailbox.card").waitForExistence(timeout: 5))
    assertNoPlaceholders(app, "Mailbox")
    assertNoOutlook(app, "Mailbox")
    attach(app, "Release · Mailbox")
    try audit(app)
    tap(app, "mailbox.disconnect")
    let alert = app.alerts["Disconnect maya@example.com?"]
    XCTAssertTrue(alert.waitForExistence(timeout: 5))
    XCTAssertTrue(alert.descendants(matching: .any)
      .matching(NSPredicate(format: "label CONTAINS %@", "myaccount.google.com/permissions")).firstMatch.exists)
    assertNoOutlook(app, "Disconnect")
    alert.buttons["Disconnect"].tap()
    assertText(app, "Gmail disconnected. Past transactions stay.", "Bank alerts")
    XCTAssertTrue(el(app, "bankAlerts.addMailbox").waitForExistence(timeout: 5), "no way to connect again")
    assertNoOutlook(app, "Bank alerts")
  }
}
