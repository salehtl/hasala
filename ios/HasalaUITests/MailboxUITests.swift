import XCTest

/// Mailboxes on the in-memory mock (Debug: Gmail and Outlook): connecting in setup through
/// to Home with the import running, Add a mailbox from Bank alerts, the two Outlook errors, Sign in again
/// from the hero and from the mailbox, Disconnect behind its alert, and the large-text audit.
final class MailboxUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  /// The large-text size the audits use (AX3).
  static let largeText = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"]

  /// Setup's bank alerts step connects Gmail (the mock's sign-in always succeeds), Home
  /// opens, and the first scan reads behind it.
  @MainActor
  func testSetupConnectsGmailToTheFirstScan() throws {
    let app = launch(scenario: "setupBank")
    let connect = try connectScreen(app, .gmail)
    attach(app, "Connect Gmail")
    try audit(app)
    connect.tap()
    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: 10), "Home did not open")
    XCTAssertTrue(el(app, "home.finish.plan").waitForExistence(timeout: uiWait), "Home has no Finish setting up")
    attach(app, "Home after the connect")
  }

  /// Outlook in setup: the bank step with Outlook (with the work account line); then Use
  /// Outlook › Choose your email › Outlook, which connects it, and Home.
  @MainActor
  func testSetupConnectsOutlookToTheFirstScan() throws {
    var app = launch(scenario: nil, screen: "mail.connectOutlook")
    let connect = el(app, "mail.connect.outlook")
    XCTAssertTrue(connect.waitForExistence(timeout: 30))
    XCTAssertEqual(connect.label, "Continue with Microsoft")
    XCTAssertTrue(el(app, "mail.provider").label.contains("Work or school account?"))
    XCTAssertFalse(el(app, "mail.googleBriefing").exists)
    attach(app, "Setup · Outlook, read-only")
    try audit(app)

    app = launch(scenario: "setupBank")
    tap(app, "mail.change", timeout: 15)
    let outlook = el(app, "mail.choose.outlook")
    XCTAssertTrue(outlook.waitForExistence(timeout: 10), "setup did not offer Choose your email")
    attach(app, "Setup · Choose your email")
    try audit(app, overSheet: true)
    outlook.tap()
    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: 15), "the pick did not connect Outlook")
    attach(app, "Home · Outlook connected")
  }

  /// A signed-in account with no mailbox: Home's Finish setting up leads with "Connect your
  /// email", which opens Bank alerts, where Add a mailbox offers Gmail and Outlook.
  @MainActor
  func testHomeOffersToConnectAnAccountWithNoMailbox() throws {
    let app = launch(scenario: "noMailbox")
    let row = el(app, "home.finish.connectEmail")
    XCTAssertTrue(row.waitForExistence(timeout: 15), "Home offers no way to connect an email")
    attach(app, "Home · Connect your email")
    try audit(app)
    row.tap()
    tap(app, "bankAlerts.addMailbox")
    XCTAssertTrue(el(app, "mail.choose.gmail").waitForExistence(timeout: uiWait))
    XCTAssertTrue(el(app, "mail.choose.outlook").exists)
  }

  /// Bank alerts with no mailbox offers Add a mailbox; where the account can't connect one
  /// it says why instead of showing nothing.
  @MainActor
  func testBankAlertsWithNoMailboxOffersAConnectOrSaysWhyNot() throws {
    var app = launch(scenario: nil, screen: "bankAlerts.none")
    XCTAssertTrue(el(app, "bankAlerts.addMailbox").waitForExistence(timeout: 15), "no Add a mailbox without a mailbox")
    XCTAssertFalse(el(app, "bankAlerts.connectRefused").exists)
    app.terminate()
    app = launch(scenario: nil, screen: "bankAlerts.refused")
    XCTAssertTrue(el(app, "bankAlerts.connectRefused").waitForExistence(timeout: 15), "a refused connect says nothing")
    XCTAssertFalse(el(app, "bankAlerts.addMailbox").exists)
    attach(app, "Bank alerts · connect refused")
    try audit(app)
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

  @MainActor
  func testGmailWithNoMailbox() throws {
    var app = launch(scenario: nil, screen: "mail.add.errorNoMailboxGmail")
    XCTAssertTrue(app.staticTexts["Gmail isn't connected."].waitForExistence(timeout: 15))
    XCTAssertTrue(says(app, "This Google account has no Gmail. Sign in with the account your bank alerts go to."))
    let other = el(app, "mail.error.retry")
    XCTAssertEqual(other.label, "Use another Google account")
    XCTAssertEqual(el(app, "mail.error.chooseDifferent").label, "Alerts go somewhere else? Choose a different email")
    attach(app, "Google account has no Gmail")
    try audit(app)
    other.tap()
    assertMailboxAdded(app, "gmail-1")

    app = launch(scenario: nil, screen: "mail.add.errorNoMailboxGmail", arguments: Self.largeText)
    XCTAssertTrue(el(app, "mail.error.retry").waitForExistence(timeout: 15))
    attach(app, "Google account has no Gmail · AX3")
    try audit(app, atLargeText: true)
  }

  @MainActor
  func testSignInAgainFromTheHeroWithNoMailbox() throws {
    let app = launch(scenario: nil, screen: "bankAlerts.signInNoMailbox")
    let button = el(app, "bankAlerts.signInAgain")
    XCTAssertTrue(button.waitForExistence(timeout: 15))
    button.tap()
    XCTAssertTrue(app.staticTexts["Outlook isn't connected."].waitForExistence(timeout: 10))
    XCTAssertTrue(says(app, "This Microsoft account has no Outlook mailbox."))
    let other = el(app, "mail.error.retry")
    XCTAssertEqual(other.label, "Use another Microsoft account")
    attach(app, "Sign in again · Microsoft account has no mailbox")
    try audit(app)
    other.tap()
    XCTAssertTrue(app.staticTexts["Outlook connected again. Catching up from the last check."]
      .waitForExistence(timeout: 10))
    let status = el(app, "bankAlerts.status")
    XCTAssertTrue(status.waitForExistence(timeout: uiWait))
    XCTAssertTrue(status.waitForLabel(containing: "Working"), "the hero still asks for a sign-in")
  }

  @MainActor
  func testSignInAgainWithAnotherAddressAsksAndKeeps() throws {
    var app = launch(scenario: nil, screen: "bankAlerts.signInOtherAddress")
    let button = el(app, "bankAlerts.signInAgain")
    XCTAssertTrue(button.waitForExistence(timeout: 15))
    button.tap()
    let alert = app.alerts["You signed in as maya.other@example.com."]
    XCTAssertTrue(alert.waitForExistence(timeout: 10), "the switch was not asked first")
    XCTAssertTrue(alert.descendants(matching: .any)
      .matching(NSPredicate(format: "label BEGINSWITH %@", "Hasala reads maya.k@example.com. Switch to maya.other@example.com?"))
      .firstMatch.exists)
    XCTAssertTrue(alert.descendants(matching: .any)
      .matching(NSPredicate(format: "label CONTAINS %@", "maya.k@example.com brought in 12 transactions.")).firstMatch.exists)
    XCTAssertTrue(alert.buttons["Switch, remove them"].firstMatch.exists)
    attach(app, "Sign in again · another address")
    alert.buttons["Try again"].firstMatch.tap()
    XCTAssertTrue(alert.waitForNonExistence(timeout: uiWait))
    XCTAssertTrue(el(app, "bankAlerts.status").label.contains("Sign in again"), "Try again changed the mailbox")
    XCTAssertTrue(button.exists)
    button.tap()
    XCTAssertTrue(alert.waitForExistence(timeout: 10))
    alert.buttons["Switch, keep the 12 transactions"].firstMatch.tap()
    XCTAssertTrue(app.staticTexts["Now reading maya.other@example.com."].waitForExistence(timeout: 10))
    XCTAssertFalse(app.staticTexts["Outlook connected again. Catching up from the last check."].exists)
    XCTAssertTrue(el(app, "bankAlerts.status").waitForLabel(containing: "Working"), "the hero still asks for a sign-in")
    try audit(app)

    app = launch(scenario: nil, screen: "bankAlerts.signInOtherAddress", arguments: Self.largeText)
    XCTAssertTrue(el(app, "bankAlerts.signInAgain").waitForExistence(timeout: 15))
    try audit(app, atLargeText: true)
    el(app, "bankAlerts.signInAgain").tap()
    let large = app.alerts["You signed in as maya.other@example.com."]
    XCTAssertTrue(large.waitForExistence(timeout: 10))
    attach(app, "Sign in again · another address · AX3")
    large.buttons["Switch, keep the 12 transactions"].firstMatch.tap()
    XCTAssertTrue(el(app, "bankAlerts.status").waitForLabel(containing: "Working"), "the hero still asks for a sign-in")
    try audit(app, atLargeText: true)
  }

  @MainActor
  func testSignInAgainWithAnotherAddressCanRemoveTheOldTransactions() throws {
    var app = launch(scenario: nil, screen: "mail.detailSignInOtherAddress")
    let signIn = el(app, "mailbox.signInAgain")
    XCTAssertTrue(signIn.waitForExistence(timeout: 15))
    try audit(app)
    signIn.tap()
    let alert = app.alerts["You signed in as maya.other@example.com."]
    XCTAssertTrue(alert.waitForExistence(timeout: 10), "the switch was not asked first")
    XCTAssertTrue(alert.buttons["Switch, keep the 12 transactions"].firstMatch.exists)
    attach(app, "Mailbox · another address")
    alert.buttons["Switch, remove them"].firstMatch.tap()
    XCTAssertTrue(app.staticTexts["Now reading maya.other@example.com. 12 transactions removed."]
      .waitForExistence(timeout: 10))
    XCTAssertTrue(el(app, "mailbox.card").waitForExistence(timeout: 10), "the page did not turn connected")
    attach(app, "Mailbox · another address · removed")
    try audit(app)

    app = launch(scenario: nil, screen: "mail.detailSignInOtherAddress", arguments: Self.largeText)
    XCTAssertTrue(el(app, "mailbox.signInAgain").waitForExistence(timeout: 15))
    try audit(app, atLargeText: true)
    el(app, "mailbox.signInAgain").tap()
    let large = app.alerts["You signed in as maya.other@example.com."]
    XCTAssertTrue(large.waitForExistence(timeout: 10))
    large.buttons["Switch, remove them"].firstMatch.tap()
    XCTAssertTrue(el(app, "mailbox.card").waitForExistence(timeout: 10), "the page did not turn connected")
    try audit(app, atLargeText: true)
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

  /// The provider's button on setup's bank step. It names the company.
  @MainActor
  private func connectScreen(_ app: XCUIApplication, _ provider: Provider) throws -> XCUIElement {
    let button = el(app, "mail.connect.\(provider.rawValue)")
    XCTAssertTrue(button.waitForExistence(timeout: 15), "the bank step has no sign-in")
    XCTAssertEqual(button.label, provider == .gmail ? "Continue with Google" : "Continue with Microsoft")
    return button
  }

  enum Provider: String { case gmail, outlook }
}
