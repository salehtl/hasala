import XCTest

/// Mailboxes on the in-memory mock (Debug: Gmail and Outlook): connecting in setup through
/// to the first scan, Add a mailbox from Bank alerts, the two Outlook errors, Sign in again
/// from the hero and from the mailbox, Disconnect behind its alert, and the large-text audit.
final class MailboxUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  /// The large-text size the audits use (AX3).
  static let largeText = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"]

  /// Setup's email step connects Gmail (the mock's sign-in always succeeds) and the first
  /// scan starts. With setup's chooser (P2) Continue offers Gmail and Outlook first.
  @MainActor
  func testSetupConnectsGmailToTheFirstScan() throws {
    let app = launch(scenario: "setupBank")
    tap(app, "bank.continue", timeout: 15)
    let connect = try connectScreen(app, .gmail)
    attach(app, "Connect Gmail")
    try audit(app)
    connect.tap()
    XCTAssertTrue(el(app, "scan.progress").waitForExistence(timeout: 10), "the first scan did not start")
    attach(app, "First scan")
  }

  /// Outlook in setup: Choose your email › Outlook › its read-only screen (with the work
  /// account line) › Continue with Microsoft › the first scan, through the chooser that
  /// setup (P2) presents over the bank step.
  @MainActor
  func testSetupConnectsOutlookToTheFirstScan() throws {
    let app = launch(scenario: "setupBank")
    tap(app, "bank.continue", timeout: 15)
    let outlook = el(app, "mail.choose.outlook")
    XCTAssertTrue(outlook.waitForExistence(timeout: 10), "setup did not offer Choose your email")
    attach(app, "Setup · Choose your email")
    try audit(app, overSheet: true)
    outlook.tap()
    let connect = el(app, "mail.connect.outlook")
    XCTAssertTrue(connect.waitForExistence(timeout: uiWait))
    XCTAssertEqual(connect.label, "Continue with Microsoft")
    XCTAssertTrue(el(app, "mail.notYours").label.contains("Work or school account?"))
    attach(app, "Setup · Outlook, read-only")
    try audit(app)
    connect.tap()
    XCTAssertTrue(el(app, "scan.progress").waitForExistence(timeout: 10), "the first scan did not start")
    attach(app, "Setup · Outlook connected · First scan")
  }

  /// Profile › Bank alerts › Add a mailbox › Outlook connects a second mailbox: back on Bank
  /// alerts, it is listed and checking for alerts.
  @MainActor
  func testAddOutlookFromBankAlerts() throws {
    let app = launch(scenario: "passkeyUser")
    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: 15))
    app.buttons["header.profile"].firstMatch.tap()
    tap(app, "profile.bankAlerts")
    XCTAssertTrue(el(app, "bankAlerts.mailbox.gmail-1").waitForExistence(timeout: uiWait))
    XCTAssertTrue(el(app, "bankAlerts.status").label.contains("Working"))
    attach(app, "Bank alerts · one Gmail")
    try audit(app)
    tap(app, "bankAlerts.addMailbox")
    let outlook = el(app, "mail.choose.outlook")
    XCTAssertTrue(outlook.waitForExistence(timeout: uiWait))
    XCTAssertTrue(el(app, "mail.choose.gmail").label.contains("maya@example.com is connected. Add another Google account."))
    attach(app, "Add a mailbox")
    try audit(app)
    outlook.tap()
    let connect = el(app, "mail.connect.outlook")
    XCTAssertTrue(connect.waitForExistence(timeout: uiWait))
    XCTAssertEqual(connect.label, "Continue with Microsoft")
    XCTAssertFalse(app.staticTexts["Step 2 of 4"].exists, "the profile's connect screen shows setup's step")
    attach(app, "Connect Outlook")
    try audit(app)
    connect.tap()
    assertMailboxAdded(app, "outlook-1")
    attach(app, "Bank alerts · two mailboxes")
  }

  /// A work account its admin hasn't approved, then a Microsoft sign-in that didn't finish:
  /// each has its screen; trying again runs the sign-in again, and "Choose a different
  /// email" goes back to the providers, where Gmail connects a second Google account.
  @MainActor
  func testOutlookErrors() throws {
    var app = launch(scenario: nil, screen: "mail.add.errorAdmin")
    XCTAssertTrue(app.staticTexts["Your organisation needs to approve Hasala."].waitForExistence(timeout: 15))
    XCTAssertTrue(says(app, "Ask your IT admin"))
    XCTAssertEqual(el(app, "mail.error.chooseDifferent").label, "Choose a different email")
    XCTAssertTrue(el(app, "mail.error.retry").label.contains("Try Microsoft again"))
    attach(app, "Work or school account needs an admin")
    try audit(app)
    tap(app, "mail.error.chooseDifferent")
    XCTAssertTrue(el(app, "mail.choose.outlook").waitForExistence(timeout: uiWait), "the providers did not come back")

    app = launch(scenario: nil, screen: "mail.add.errorCancelled")
    XCTAssertTrue(app.staticTexts["Outlook isn't connected."].waitForExistence(timeout: 15))
    XCTAssertTrue(says(app, "Permissions not accepted"))
    XCTAssertEqual(el(app, "mail.error.retry").label, "Continue with Microsoft")
    attach(app, "Microsoft sign-in didn't finish")
    try audit(app)
    // The scenario's Microsoft sign-in never finishes: trying again lands here again.
    tap(app, "mail.error.retry")
    XCTAssertTrue(app.staticTexts["Outlook isn't connected."].waitForExistence(timeout: 10))
    tap(app, "mail.error.chooseDifferent")
    tap(app, "mail.choose.gmail", timeout: uiWait)
    tap(app, "mail.connect.gmail", timeout: uiWait)
    assertMailboxAdded(app, "gmail-2")
  }

  @MainActor
  func testOutlookWithNoMailbox() throws {
    var app = launch(scenario: nil, screen: "mail.add.errorNoMailbox")
    XCTAssertTrue(app.staticTexts["Outlook isn't connected."].waitForExistence(timeout: 15))
    XCTAssertTrue(says(app, "This Microsoft account has no Outlook mailbox."))
    XCTAssertTrue(says(app, "such as you@outlook.com or you@hotmail.com"))
    let other = el(app, "mail.error.retry")
    XCTAssertEqual(other.label, "Use another Microsoft account")
    XCTAssertEqual(el(app, "mail.error.chooseDifferent").label, "Alerts go somewhere else? Choose a different email")
    attach(app, "Microsoft account has no mailbox")
    try audit(app)
    other.tap()
    assertMailboxAdded(app, "outlook-1")

    app = launch(scenario: nil, screen: "mail.add.errorNoMailbox", arguments: Self.largeText)
    XCTAssertTrue(el(app, "mail.error.retry").waitForExistence(timeout: 15))
    attach(app, "Microsoft account has no mailbox · AX3")
    try audit(app, atLargeText: true)
    tap(app, "mail.error.chooseDifferent")
    XCTAssertTrue(el(app, "mail.choose.outlook").waitForExistence(timeout: uiWait), "the providers did not come back")
  }

  /// Microsoft ended access to Outlook: Bank alerts' hero says so and carries "Continue
  /// with Microsoft"; signed in again, the hero says it works.
  @MainActor
  func testSignInAgainFromTheHero() throws {
    let app = launch(scenario: "outlookSignIn", screen: "bankAlerts")
    let status = el(app, "bankAlerts.status")
    XCTAssertTrue(status.waitForExistence(timeout: 15))
    XCTAssertTrue(status.label.contains("Sign in again"))
    let button = el(app, "bankAlerts.signInAgain")
    XCTAssertEqual(button.label, "Continue with Microsoft")
    attach(app, "Bank alerts · Outlook needs sign-in")
    try audit(app)
    button.tap()
    XCTAssertTrue(app.staticTexts["Outlook connected again. Catching up from the last check."]
      .waitForExistence(timeout: 10))
    XCTAssertTrue(status.waitForLabel(containing: "Working"), "the hero still asks for a sign-in")
    XCTAssertFalse(el(app, "bankAlerts.signInAgain").exists)
  }

  /// While Outlook needs a sign-in, Add a mailbox says so on its Outlook row rather than
  /// "is connected", and the row leads where it says: Outlook's sign-in again, then back on
  /// Bank alerts with Outlook working.
  @MainActor
  func testAddAMailboxWhileOutlookNeedsASignIn() throws {
    let app = launch(scenario: "outlookSignIn", screen: "bankAlerts")
    tap(app, "bankAlerts.addMailbox", timeout: 15)
    let outlook = el(app, "mail.choose.outlook")
    XCTAssertTrue(outlook.waitForExistence(timeout: uiWait))
    XCTAssertTrue(outlook.label.contains("maya.k@example.com needs a new sign-in. Sign in to Outlook again."),
                  outlook.label)
    XCTAssertFalse(outlook.label.contains("is connected"))
    XCTAssertTrue(el(app, "mail.choose.gmail").label.contains("maya@example.com is connected."))
    attach(app, "Add a mailbox · Outlook needs sign-in")
    try audit(app)
    outlook.tap()
    XCTAssertTrue(app.staticTexts["Sign in to Outlook again."].waitForExistence(timeout: uiWait))
    tap(app, "mail.connect.outlook")
    XCTAssertTrue(app.staticTexts["Outlook connected again. Catching up from the last check."]
      .waitForExistence(timeout: 10))
    XCTAssertTrue(el(app, "bankAlerts.status").waitForLabel(containing: "Working"), "the hero still asks for a sign-in")
    XCTAssertTrue(el(app, "bankAlerts.mailbox.outlook-1").waitForLabel(containing: "Checked just now"))
  }

  /// The Outlook mailbox: signed in again from its page, which turns into the working
  /// layout; then disconnected behind the system alert, back on Bank alerts with a grey row.
  @MainActor
  func testMailboxSignInAgainAndDisconnect() throws {
    let app = launch(scenario: "outlookSignIn", screen: "bankAlerts")
    tap(app, "bankAlerts.mailbox.outlook-1")
    let signIn = el(app, "mailbox.signInAgain")
    XCTAssertTrue(signIn.waitForExistence(timeout: uiWait))
    XCTAssertTrue(app.staticTexts["Microsoft ended Hasala's access"].exists)
    attach(app, "Mailbox · needs sign-in")
    try audit(app)
    signIn.tap()
    XCTAssertTrue(el(app, "mailbox.card").waitForExistence(timeout: 10), "the page did not turn connected")
    XCTAssertFalse(el(app, "mailbox.signInAgain").exists)
    attach(app, "Mailbox · connected again")
    tap(app, "mailbox.disconnect")
    let alert = app.alerts["Disconnect maya.k@example.com?"]
    XCTAssertTrue(alert.waitForExistence(timeout: uiWait))
    XCTAssertTrue(alert.descendants(matching: .any)
      .matching(NSPredicate(format: "label CONTAINS %@", "account.live.com/consent/Manage")).firstMatch.exists)
    attach(app, "Mailbox · Disconnect")
    XCTAssertTrue(alert.buttons["Keep the 12 transactions from this inbox"].firstMatch.exists)
    XCTAssertTrue(alert.buttons["Remove them"].firstMatch.exists)
    alert.buttons["Keep the 12 transactions from this inbox"].firstMatch.tap()
    let row = el(app, "bankAlerts.mailbox.outlook-1")
    XCTAssertTrue(row.waitForExistence(timeout: 10), "Bank alerts did not come back")
    XCTAssertTrue(row.waitForLabel(containing: "Off since 10 Oct"))
    XCTAssertTrue(app.staticTexts["Outlook disconnected. Past transactions stay."].waitForExistence(timeout: uiWait))
    attach(app, "Bank alerts · disconnected row")
  }

  @MainActor
  func testDisconnectAsksToKeepOrRemoveTheTransactions() throws {
    let app = launch(scenario: "passkeyUser")
    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: 15))
    app.buttons["header.profile"].firstMatch.tap()
    tap(app, "profile.bankAlerts")
    tap(app, "bankAlerts.mailbox.gmail-1")
    XCTAssertTrue(el(app, "mailbox.card").waitForExistence(timeout: uiWait))
    tap(app, "mailbox.disconnect")
    let alert = app.alerts["Disconnect maya@example.com?"]
    XCTAssertTrue(alert.waitForExistence(timeout: uiWait))
    XCTAssertTrue(alert.descendants(matching: .any)
      .matching(NSPredicate(format: "label CONTAINS %@", "It brought in 42 transactions.")).firstMatch.exists)
    XCTAssertTrue(alert.descendants(matching: .any)
      .matching(NSPredicate(format: "label CONTAINS %@", "Removing also takes the 3 you changed.")).firstMatch.exists)
    XCTAssertTrue(alert.buttons["Keep the 42 transactions from this inbox"].firstMatch.exists)
    XCTAssertTrue(alert.buttons["Cancel"].firstMatch.exists)
    attach(app, "Mailbox · Disconnect · keep or remove")
    alert.buttons["Remove them"].firstMatch.tap()
    XCTAssertTrue(app.staticTexts["Gmail disconnected. 42 transactions removed."].waitForExistence(timeout: 10))
    XCTAssertTrue(el(app, "bankAlerts.mailbox.gmail-1").waitForLabel(containing: "Off since 10 Oct"))
    attach(app, "Bank alerts · removed")
  }

  /// Bank alerts and both mailbox layouts at AX3: nothing clipped, every control reachable.
  @MainActor
  func testBankAlertsAndMailboxAtLargeText() throws {
    var app = launch(scenario: nil, screen: "bankAlerts", arguments: Self.largeText)
    XCTAssertTrue(el(app, "bankAlerts.hero").waitForExistence(timeout: 15))
    try audit(app, atLargeText: true)
    for id in ["bankAlerts.addMailbox", "bankAlerts.bank.dib", "bankAlerts.howItReads"] {
      XCTAssertTrue(scroll(app, toShow: el(app, id)), "\(id) never came into view")
      try audit(app, atLargeText: true)
    }
    // Disconnect ends each page, so it can't reach the upper half: drag until it can be
    // tapped above the bottom edge.
    app = launch(scenario: nil, screen: "mail.detail", arguments: Self.largeText)
    XCTAssertTrue(el(app, "mailbox.card").waitForExistence(timeout: 15))
    try audit(app, atLargeText: true)
    XCTAssertTrue(reveal(app, el(app, "mailbox.disconnect")), "Disconnect never came into view")
    try audit(app, atLargeText: true)
    app = launch(scenario: nil, screen: "mail.detailSignIn", arguments: Self.largeText)
    XCTAssertTrue(el(app, "mailbox.signInAgain").waitForExistence(timeout: 15))
    try audit(app, atLargeText: true)
    XCTAssertTrue(reveal(app, el(app, "mailbox.disconnect")), "Disconnect never came into view")
    try audit(app, atLargeText: true)
  }

  /// The docks of the read-only screen and the two errors, at the default size and AX3:
  /// "Not your email? Choose a different one." grows with the text as one sentence, and a
  /// provider's pill takes the two lines it needs (setup's dock draws the same parts). The
  /// row leads to the providers.
  @MainActor
  func testDocksGrowWithTheText() throws {
    var app = launch(scenario: nil, screen: "mail.profile.gmail")
    let notYours = el(app, "mail.notYours")
    XCTAssertTrue(notYours.waitForExistence(timeout: 15))
    XCTAssertEqual(notYours.label, "Not your email? Choose a different one.")
    try audit(app)
    notYours.tap()
    XCTAssertTrue(el(app, "mail.choose.gmail").waitForExistence(timeout: uiWait), "the providers did not open")

    app = launch(scenario: nil, screen: "mail.profile.gmail", arguments: Self.largeText)
    XCTAssertTrue(el(app, "mail.notYours").waitForExistence(timeout: 15))
    attach(app, "Connect Gmail · AX3")
    try audit(app, atLargeText: true)

    app = launch(scenario: nil, screen: "mail.add.errorCancelled", arguments: Self.largeText)
    XCTAssertTrue(el(app, "mail.error.chooseDifferent").waitForExistence(timeout: 15))
    XCTAssertEqual(el(app, "mail.error.chooseDifferent").label, "Wrong account? Choose a different email")
    attach(app, "Microsoft sign-in didn't finish · AX3")
    try audit(app, atLargeText: true)

    app = launch(scenario: nil, screen: "mail.add.errorAdmin", arguments: Self.largeText)
    XCTAssertTrue(el(app, "mail.error.retry").waitForExistence(timeout: 15))
    attach(app, "Work or school account needs an admin · AX3")
    try audit(app, atLargeText: true)
  }

  /// Some element on screen says `text`.
  @MainActor
  private func says(_ app: XCUIApplication, _ text: String) -> Bool {
    app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
      .waitForExistence(timeout: uiWait)
  }

  /// The provider's read-only screen after the bank step: through setup's chooser when the
  /// build offers more than one provider, else straight on. Its button names the company.
  @MainActor
  private func connectScreen(_ app: XCUIApplication, _ provider: Provider) throws -> XCUIElement {
    let chooser = el(app, "mail.choose.\(provider.rawValue)")
    let button = el(app, "mail.connect.\(provider.rawValue)")
    for _ in 0..<30 {
      if chooser.exists { chooser.tap(); break }
      if button.exists { break }
      Thread.sleep(forTimeInterval: 0.5)
    }
    XCTAssertTrue(button.waitForExistence(timeout: 10), "the read-only screen did not open")
    XCTAssertEqual(button.label, provider == .gmail ? "Continue with Google" : "Continue with Microsoft")
    return button
  }

  enum Provider: String { case gmail, outlook }
}
