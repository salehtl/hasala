import XCTest

/// Mailboxes on the Release surface: Gmail and Outlook (personal Microsoft accounts), one
/// mailbox (as the live lane reads), a switch of provider only after "Change your email?",
/// and no copy that promises a work or school account. Each test goes Home › Profile › Bank
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

  /// No mailbox: Bank alerts says so, and Add a mailbox offers Gmail and Outlook, one
  /// mailbox (no "also", no second one promised). Gmail's read-only screen says how new
  /// alerts are really caught. Connecting lands back on Bank alerts with the mailbox, and
  /// no second one is offered.
  @MainActor
  func testAddAMailboxOffersGmailAndOutlook() throws {
    let app = bankAlerts("noMailbox")
    XCTAssertTrue(el(app, "bankAlerts.status").label.contains("Not connected"))
    assertNoPlaceholders(app, "Bank alerts")
    assertPersonalAccountsOnly(app, "Bank alerts")
    // Debug's parts with no screen behind them yet.
    assertAbsent(app, ["bankAlerts.addBank", "bankAlerts.unreadable"], "Bank alerts")
    assertNoText(app, ["when new mail arrives"], "Bank alerts")
    attach(app, "Release · Bank alerts · no mailbox")
    try audit(app)
    tap(app, "bankAlerts.addMailbox")
    XCTAssertTrue(el(app, "mail.choose").waitForExistence(timeout: uiWait), "Add a mailbox did not open")
    assertPresent(app, ["mail.choose.gmail", "mail.choose.outlook"], "Add a mailbox")
    assertText(app, "Pick where your bank sends its alerts.", "Add a mailbox")
    assertText(app, "different from the email you sign in to Hasala with", "Add a mailbox")
    assertText(app, "You can disconnect it at any time.", "Add a mailbox")
    assertNoText(app, ["also sends", "on its own"], "Add a mailbox")
    assertNoPlaceholders(app, "Add a mailbox")
    assertPersonalAccountsOnly(app, "Add a mailbox")
    attach(app, "Release · Add a mailbox")
    try audit(app)
    tap(app, "mail.choose.gmail")
    let connect = el(app, "mail.connect.gmail")
    XCTAssertTrue(connect.waitForExistence(timeout: uiWait))
    XCTAssertEqual(connect.label, "Continue with Google")
    assertText(app, "checks for new alerts when you open Hasala", "Connect your email")
    assertNoText(app, ["Step 2 of 4", "our server is told"], "Connect your email")
    assertNoPlaceholders(app, "Connect your email")
    assertPersonalAccountsOnly(app, "Connect your email")
    attach(app, "Release · Connect your email")
    try audit(app)
    connect.tap()
    assertMailboxAdded(app, "gmail-1")
    // Live reads one mailbox: no "Add a mailbox" beside it.
    assertAbsent(app, ["bankAlerts.addMailbox"], "Bank alerts")
    assertPersonalAccountsOnly(app, "Bank alerts")
    attach(app, "Release · Bank alerts · Gmail connected")
  }

  /// Setup's bank step was skipped (manual entry), so the account reads no bank: Add a
  /// mailbox asks for the banks first (the lane reads only their senders), then Gmail's
  /// screen names the banks picked, never an empty list.
  @MainActor
  func testConnectWithNoBankAsksForTheBanksFirst() throws {
    let app = bankAlerts("noBanks")
    tap(app, "bankAlerts.addMailbox")
    tap(app, "mail.choose.gmail")
    XCTAssertTrue(el(app, "bank.enbd").waitForExistence(timeout: uiWait), "the banks were not asked for")
    XCTAssertFalse(el(app, "mail.connect.gmail").exists, "Gmail's sign-in came before the banks")
    attach(app, "Release · Connect your email · Banks")
    assertNoPlaceholders(app, "Banks")
    assertPersonalAccountsOnly(app, "Banks")
    assertNoText(app, ["Step 1 of 4"], "Banks")
    try audit(app)
    tap(app, "bank.dib")
    XCTAssertEqual(el(app, "bank.continue").label, "Continue with 1 bank")
    tap(app, "bank.continue")
    let connect = el(app, "mail.connect.gmail")
    XCTAssertTrue(connect.waitForExistence(timeout: uiWait))
    assertText(app, "Alerts from Emirates NBD, and nothing else", "Connect your email")
    assertNoText(app, ["Alerts from ,"], "Connect your email")
    attach(app, "Release · Connect your email · After the banks")
    connect.tap()
    assertMailboxAdded(app, "gmail-1")
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
    assertPersonalAccountsOnly(app, "Bank alerts")
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
    XCTAssertTrue(el(app, "mailbox.card").waitForExistence(timeout: uiWait))
    assertNoPlaceholders(app, "Mailbox")
    assertPersonalAccountsOnly(app, "Mailbox")
    attach(app, "Release · Mailbox")
    try audit(app)
    tap(app, "mailbox.disconnect")
    let alert = app.alerts["Disconnect maya@example.com?"]
    XCTAssertTrue(alert.waitForExistence(timeout: uiWait))
    XCTAssertTrue(alert.descendants(matching: .any)
      .matching(NSPredicate(format: "label CONTAINS %@", "myaccount.google.com/permissions")).firstMatch.exists)
    assertPersonalAccountsOnly(app, "Disconnect")
    alert.buttons["Keep the 42 transactions from this inbox"].firstMatch.tap()
    assertText(app, "Gmail disconnected. Past transactions stay.", "Bank alerts")
    XCTAssertTrue(el(app, "bankAlerts.addMailbox").waitForExistence(timeout: uiWait), "no way to connect again")
    assertPersonalAccountsOnly(app, "Bank alerts")
  }

  /// Profile › Settings › Mailboxes reaches the same Disconnect: the row names the
  /// mailbox, opens Bank alerts, and the Gmail mailbox's Disconnect says that Google's
  /// access ends; disconnected, the row says so.
  @MainActor
  func testSettingsMailboxesRowReachesDisconnect() throws {
    let app = launchRelease("passkeyUser")
    app.buttons["header.profile"].firstMatch.tap()
    let row = el(app, "profile.mailboxes")
    XCTAssertTrue(row.waitForExistence(timeout: 10), "Settings has no Mailboxes row")
    XCTAssertTrue(reveal(app, row))
    XCTAssertEqual(row.value as? String, "Gmail")
    row.tap()
    XCTAssertTrue(el(app, "bankAlerts.hero").waitForExistence(timeout: 15), "Mailboxes did not open Bank alerts")
    tap(app, "bankAlerts.mailbox.gmail-1")
    XCTAssertTrue(el(app, "mailbox.card").waitForExistence(timeout: uiWait))
    tap(app, "mailbox.disconnect")
    let alert = app.alerts["Disconnect maya@example.com?"]
    XCTAssertTrue(alert.waitForExistence(timeout: uiWait))
    XCTAssertTrue(alert.descendants(matching: .any)
      .matching(NSPredicate(format: "label CONTAINS %@", "ends its access at Google")).firstMatch.exists)
    attach(app, "Release · Disconnect from Settings")
    alert.buttons["Keep the 42 transactions from this inbox"].firstMatch.tap()
    assertText(app, "Gmail disconnected. Past transactions stay.", "Bank alerts")
    back(app)
    XCTAssertTrue(reveal(app, row))
    XCTAssertTrue(row.waitForValue("Not connected"), "the row says \(String(describing: row.value))")
  }

  /// Setup's email step was skipped: Add a mailbox › Outlook says only personal Microsoft
  /// accounts work, and connects the one mailbox.
  @MainActor
  func testConnectOutlookAfterSkipping() throws {
    let app = bankAlerts("gmailSkipped")
    tap(app, "bankAlerts.addMailbox")
    tap(app, "mail.choose.outlook")
    let connect = el(app, "mail.connect.outlook")
    XCTAssertTrue(connect.waitForExistence(timeout: uiWait))
    XCTAssertEqual(connect.label, "Continue with Microsoft")
    assertText(app, "Outlook: personal Microsoft accounts only.", "Outlook")
    assertNoText(app, ["our server is told"], "Outlook")
    assertPersonalAccountsOnly(app, "Outlook")
    assertNoPlaceholders(app, "Outlook")
    attach(app, "Release · Connect Outlook")
    try audit(app)
    connect.tap()
    assertMailboxAdded(app, "outlook-1")
    assertAbsent(app, ["bankAlerts.addMailbox"], "Bank alerts")
  }

  /// Reading Gmail, Bank alerts offers "Use another email": Outlook's sign-in asks first
  /// ("Change your email?", main's "This replaces your Gmail connection."). Cancel keeps
  /// Gmail; "Use Outlook, keep the 42 transactions" leaves one mailbox, Outlook's.
  @MainActor
  func testSwitchFromGmailToOutlook() throws {
    let app = bankAlerts("gmailLinked")
    XCTAssertTrue(el(app, "bankAlerts.mailbox.gmail-1").waitForExistence(timeout: uiWait))
    assertAbsent(app, ["bankAlerts.addMailbox"], "Bank alerts")
    tap(app, "bankAlerts.changeMailbox")
    XCTAssertTrue(el(app, "mail.choose").waitForExistence(timeout: uiWait), "Use another email did not open")
    assertText(app, "Hasala reads one mailbox at a time.", "Use another email")
    assertText(app, "maya@example.com is connected.", "Use another email")
    assertNoText(app, ["Add another Google account"], "Use another email")
    assertPersonalAccountsOnly(app, "Use another email")
    attach(app, "Release · Use another email")
    try audit(app)
    tap(app, "mail.choose.outlook")
    let connect = el(app, "mail.connect.outlook")
    XCTAssertTrue(connect.waitForExistence(timeout: uiWait))
    try audit(app)
    connect.tap()
    let alert = app.alerts["Change your email?"]
    XCTAssertTrue(alert.waitForExistence(timeout: uiWait), "the switch was not confirmed first")
    XCTAssertTrue(alert.descendants(matching: .any)
      .matching(NSPredicate(format: "label BEGINSWITH %@", "This replaces your Gmail connection.")).firstMatch.exists)
    attach(app, "Release · Change your email?")
    alert.buttons["Cancel"].firstMatch.tap()
    XCTAssertTrue(alert.waitForNonExistence(timeout: uiWait))
    XCTAssertTrue(connect.exists, "Cancel left the Outlook screen")
    connect.tap()
    XCTAssertTrue(alert.waitForExistence(timeout: uiWait))
    XCTAssertTrue(alert.buttons["Use Outlook, remove them"].firstMatch.exists)
    alert.buttons["Use Outlook, keep the 42 transactions"].firstMatch.tap()
    assertMailboxAdded(app, "outlook-1")
    XCTAssertFalse(el(app, "bankAlerts.mailbox.gmail-1").exists, "Gmail is still read beside Outlook")
    assertPersonalAccountsOnly(app, "Bank alerts")
    try audit(app)
  }

  /// Microsoft ended Hasala's access to Outlook, the one mailbox: the Profile card and
  /// Bank alerts say "Sign in again", and the hero's Microsoft button reads it again.
  @MainActor
  func testReconnectOutlook() throws {
    let app = launchRelease("outlookReconnect")
    app.buttons["header.profile"].firstMatch.tap()
    let card = app.buttons["profile.bankAlerts"]
    XCTAssertTrue(card.waitForExistence(timeout: uiWait))
    XCTAssertTrue(card.label.contains("Sign in again"), "the Profile card says \(card.label)")
    card.tap()
    let status = el(app, "bankAlerts.status")
    XCTAssertTrue(status.waitForExistence(timeout: uiWait))
    XCTAssertTrue(status.label.contains("Microsoft ended access to maya.k@example.com on"), status.label)
    let button = el(app, "bankAlerts.signInAgain")
    XCTAssertEqual(button.label, "Continue with Microsoft")
    assertPersonalAccountsOnly(app, "Bank alerts")
    attach(app, "Release · Bank alerts · Outlook sign in again")
    try audit(app)
    button.tap()
    assertText(app, "Outlook connected again. Catching up from the last check.", "Bank alerts")
    XCTAssertTrue(status.waitForLabel(containing: "Working"), "the hero still asks for a sign-in")
    try audit(app)
  }
}
