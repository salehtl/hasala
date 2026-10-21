import XCTest

/// Onboarding as one new person walks it, on the in-memory mocks (plan Stage I task 3):
/// the stories, joining with a passkey, the 12 words (shown, then "I've written them
/// down", with no word check after them, plan B5), and setup from the bank to Home, with
/// Gmail or with Outlook from "Choose your email". The other two tests are the owner's
/// requirement 4: whatever is typed or chosen in onboarding stays for the life of the
/// process, through Back and Forward (plan B3).
///
/// The area classes (`JoinUITests`, `SetupUITests`, `MailboxUITests`) audit each screen
/// these tests pass through; these walk the screens end to end, across the hand-offs
/// between join and setup, and attach a screenshot where the journey turns.
///
/// Mock values (synthetic): the invite is `JoinUITests.invite`; email codes are 123456;
/// Gmail reads maya@example.com and Outlook maya.k@example.com.
final class OnboardingJourneyUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  // MARK: - New user to Home

  /// Stories › join with the passkey › the words › setup: every bank, Choose your email ›
  /// Gmail › the first scan › 25,000 on the keypad › the 50/30/20 plan › the result ›
  /// notifications › You're set › Home.
  @MainActor
  func testNewUserToHome() throws {
    let app = launch(scenario: "newUser")
    joinWithPasskey(app)

    // Setup · 1 of 4: both banks start picked.
    XCTAssertTrue(el(app, "bank.enbd").isSelected)
    XCTAssertTrue(el(app, "bank.dib").isSelected)
    XCTAssertTrue(el(app, "bank.adib").isSelected)
    XCTAssertEqual(el(app, "bank.continue").label, "Continue with 3 banks")
    attach(app, "Setup · Bank")
    tap(app, "bank.continue")

    // Debug reads Gmail and Outlook: Choose your email over the bank step (decision 5).
    XCTAssertTrue(el(app, "setup.chooseEmail").waitForExistence(timeout: uiWait), "Choose your email did not open")
    attach(app, "Setup · Choose your email")
    tap(app, "mail.choose.gmail")
    let connect = el(app, "mail.connect.gmail")
    XCTAssertTrue(connect.waitForExistence(timeout: uiWait))
    XCTAssertEqual(connect.label, "Continue with Google")
    connect.tap()

    XCTAssertTrue(app.staticTexts["Gmail is connected. Reading your alerts now."].waitForExistence(timeout: 10))
    XCTAssertTrue(el(app, "scan.progress").exists)
    XCTAssertTrue(says(app, "maya@example.com"), "the first scan doesn't show the mailbox")
    attach(app, "Setup · First scan")
    tap(app, "scan.setUpPlan")

    // Income on the app's keypad, never the system keyboard.
    XCTAssertTrue(el(app, "keypad.2").waitForExistence(timeout: uiWait))
    XCTAssertFalse(app.keyboards.firstMatch.exists, "the system keyboard opened for money")
    typeOnKeypad(app, "25000")
    XCTAssertTrue(incomeFigure(app).contains("25,000"), "the figure reads \(incomeFigure(app))")
    attach(app, "Setup · Income")
    tap(app, "income.continue")

    // The starting plan: 50/30/20 of 25,000.
    let needs = el(app, "plan.split.handle.0")
    XCTAssertTrue(needs.waitForExistence(timeout: uiWait))
    XCTAssertEqual(needs.value as? String, "50%")
    XCTAssertTrue(says(app, "AED 12,500"), "the needs amount is missing")
    attach(app, "Setup · Starting plan")
    tap(app, "plan.use")

    XCTAssertTrue(app.staticTexts["268 transactions, sorted."].waitForExistence(timeout: 20))
    attach(app, "Setup · Sorted")
    tap(app, "result.continue")

    // The mock grants notifications without the system's alert.
    tap(app, "notifications.allow")
    XCTAssertTrue(app.staticTexts["You're set, Maya."].waitForExistence(timeout: 10))
    XCTAssertTrue(says(app, "starting at 50/30/20"), "Done doesn't say which plan")
    attach(app, "Setup · You're set")
    tap(app, "done.home")

    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: 10), "Home did not open")
    attach(app, "Home")
  }

  /// The same setup with Outlook from Choose your email, through to the first scan; Back
  /// from the scan, and Back to the bank and Continue again, find Outlook connected, never
  /// Google's sign-in.
  @MainActor
  func testOutlookPath() throws {
    let app = launch(scenario: "newUser")
    joinWithPasskey(app)
    tap(app, "bank.continue")

    let outlook = el(app, "mail.choose.outlook")
    XCTAssertTrue(outlook.waitForExistence(timeout: uiWait), "Choose your email did not open")
    outlook.tap()
    let connect = el(app, "mail.connect.outlook")
    XCTAssertTrue(connect.waitForExistence(timeout: uiWait))
    XCTAssertEqual(connect.label, "Continue with Microsoft")
    attach(app, "Setup · Outlook, read-only")
    connect.tap()

    XCTAssertTrue(app.staticTexts["Outlook is connected. Reading your alerts now."].waitForExistence(timeout: 10))
    XCTAssertTrue(el(app, "scan.progress").exists)
    XCTAssertTrue(says(app, "maya.k@example.com"), "the first scan doesn't show the Outlook mailbox")
    attach(app, "Setup · Outlook connected · First scan")

    // The provider is remembered: Outlook's screen, connected, with no chooser.
    back(app)
    XCTAssertTrue(app.staticTexts["Outlook is connected."].waitForExistence(timeout: uiWait))
    back(app)
    tap(app, "bank.continue")
    XCTAssertTrue(app.staticTexts["Outlook is connected."].waitForExistence(timeout: uiWait), "Outlook was forgotten")
    XCTAssertFalse(el(app, "setup.chooseEmail").exists, "the chooser opened again")
    XCTAssertFalse(el(app, "mail.connect.outlook").exists, "the step offered Microsoft's sign-in again")
    XCTAssertFalse(el(app, "mail.connect.gmail").exists, "the step offered Google's sign-in")
    tap(app, "mail.continue")
    XCTAssertTrue(el(app, "scan.setUpPlan").waitForExistence(timeout: uiWait))
  }

  // MARK: - Requirement 4: setup remembers everything

  /// Connect Gmail; Back to the bank step; Continue: the provider screen is connected, with
  /// Continue and no second sign-in. 25,000 on the keypad survives Back twice and Forward
  /// twice; the payday and a moved split handle survive Back and Forward; the banks are as
  /// they were left. On to Home, the plan is the one chosen and the account reads one
  /// mailbox: Google's sign-in ran once.
  @MainActor
  func testSetupRemembersEverything() throws {
    let app = launch(scenario: "setupBank")

    // One bank, not the two the step starts with, so "unchanged" means something.
    XCTAssertTrue(el(app, "bank.dib").waitForExistence(timeout: 15))
    tap(app, "bank.dib")
    tap(app, "bank.adib")
    assertBanksAsLeft(app)
    tap(app, "bank.continue")
    tap(app, "mail.choose.gmail")
    tap(app, "mail.connect.gmail")
    XCTAssertTrue(el(app, "scan.progress").waitForExistence(timeout: 10), "the first scan did not start")

    // Back to the bank step: through the email step, connected.
    back(app)
    XCTAssertTrue(el(app, "mail.continue").waitForExistence(timeout: uiWait), "the email step forgot the connect")
    back(app)
    XCTAssertTrue(el(app, "bank.continue").waitForExistence(timeout: uiWait))
    assertBanksAsLeft(app)

    // Continue: no chooser (the provider is remembered), no sign-in, the mailbox connected.
    tap(app, "bank.continue")
    XCTAssertTrue(el(app, "mail.continue").waitForExistence(timeout: uiWait), "Continue offered a sign-in again")
    XCTAssertTrue(app.staticTexts["Gmail is connected."].exists)
    XCTAssertTrue(el(app, "mail.connected").exists, "the connected mailbox isn't shown")
    XCTAssertFalse(el(app, "setup.chooseEmail").exists, "the chooser opened again")
    XCTAssertFalse(el(app, "mail.connect.gmail").exists, "the step offered Google's sign-in again")
    attach(app, "Connect Gmail · connected, after Back")
    tap(app, "mail.continue")
    tap(app, "scan.setUpPlan")

    // 25,000; Back twice (the scan, the email step) and Forward twice.
    XCTAssertTrue(el(app, "keypad.2").waitForExistence(timeout: uiWait))
    typeOnKeypad(app, "25000")
    XCTAssertTrue(incomeFigure(app).contains("25,000"), "the figure reads \(incomeFigure(app))")
    back(app)
    XCTAssertTrue(el(app, "scan.setUpPlan").waitForExistence(timeout: uiWait))
    back(app)
    XCTAssertTrue(el(app, "mail.continue").waitForExistence(timeout: uiWait))
    tap(app, "mail.continue")
    tap(app, "scan.setUpPlan")
    XCTAssertTrue(incomeFigure(app).contains("25,000"), "the salary was lost: \(incomeFigure(app))")
    XCTAssertTrue(el(app, "income.continue").isEnabled)
    attach(app, "Income · after Back twice and Forward twice")

    // The 25th, and needs to 55%; Back and Forward.
    tap(app, "income.payday.25")
    XCTAssertTrue(el(app, "income.payday.25").waitForLabel("Payday, 25th"), "the 25th wasn't chosen")
    tap(app, "income.continue")
    let handle = el(app, "plan.split.handle.0")
    XCTAssertTrue(handle.waitForExistence(timeout: uiWait))
    nudge(handle, steps: 1)
    XCTAssertTrue(handle.waitForValue("55%"), "the needs handle reads \(handle.value ?? "nothing")")
    back(app)
    XCTAssertTrue(el(app, "keypad.1").waitForExistence(timeout: uiWait))
    XCTAssertTrue(incomeFigure(app).contains("25,000"), "the salary was lost: \(incomeFigure(app))")
    XCTAssertEqual(el(app, "income.payday.25").label, "Payday, 25th", "the payday was lost")
    tap(app, "income.continue")
    XCTAssertTrue(el(app, "plan.split.handle.0").waitForExistence(timeout: uiWait))
    XCTAssertEqual(el(app, "plan.split.handle.0").value as? String, "55%", "the split was lost")
    XCTAssertEqual(el(app, "plan.split.handle.1").value as? String, "25%", "the split was lost")
    attach(app, "Starting plan · after Back and Forward")

    // All the way back to the bank step (income, the scan, the email step, the bank): the
    // banks as they were left.
    for screen in ["keypad.1", "scan.setUpPlan", "mail.continue", "bank.continue"] {
      back(app)
      XCTAssertTrue(el(app, screen).waitForExistence(timeout: uiWait), "Back did not reach \(screen)")
    }
    assertBanksAsLeft(app)
    attach(app, "Bank · after Back")

    // Forward to the end: every step shows what it held.
    tap(app, "bank.continue")
    tap(app, "mail.continue")
    tap(app, "scan.setUpPlan")
    XCTAssertTrue(incomeFigure(app).contains("25,000"), "the salary was lost: \(incomeFigure(app))")
    XCTAssertEqual(el(app, "income.payday.25").label, "Payday, 25th", "the payday was lost")
    tap(app, "income.continue")
    XCTAssertTrue(el(app, "plan.split.handle.0").waitForValue("55%"), "the split was lost")
    tap(app, "plan.use")
    tap(app, "result.continue", timeout: 20)
    tap(app, "notifications.notNow")
    XCTAssertTrue(app.staticTexts["You're set, Maya."].waitForExistence(timeout: 10))
    XCTAssertTrue(says(app, "starting at 55/25/20"), "Done doesn't show the split that was chosen")
    tap(app, "done.home")

    // Profile › Bank alerts: the one Gmail setup connected (a second sign-in would have
    // added a second Google account: the mock gives it its own address), reading the one
    // bank that was left picked.
    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: 10), "Home did not open")
    app.buttons["header.profile"].firstMatch.tap()
    tap(app, "profile.bankAlerts")
    XCTAssertTrue(el(app, "bankAlerts.mailbox.gmail-1").waitForExistence(timeout: uiWait))
    XCTAssertFalse(el(app, "bankAlerts.mailbox.gmail-2").exists, "Google's sign-in ran twice")
    XCTAssertTrue(el(app, "bankAlerts.bank.enbd").exists, "the account doesn't read Emirates NBD")
    XCTAssertFalse(el(app, "bankAlerts.bank.dib").exists, "the account reads DIB, which was left out")
    XCTAssertFalse(el(app, "bankAlerts.bank.adib").exists, "the account reads ADIB, which was left out")
    attach(app, "Bank alerts · one mailbox, one bank")
  }

  // MARK: - Requirement 4: join remembers what was typed

  /// The invite, the name and the email; Back to the stories; Forward: each field still holds
  /// what was typed, and Continue is on.
  @MainActor
  func testJoinRemembersTypedFields() throws {
    let app = launch(scenario: "newUser")
    tap(app, "stories.getStarted", timeout: 15)
    type(app, "invite.field", JoinUITests.invite)
    tap(app, "invite.continue")
    type(app, "about.name", "Maya Rahman")
    type(app, "about.email", "maya@example.com")
    attach(app, "About you · typed")

    // Back to the invite, then to the stories.
    back(app)
    XCTAssertTrue(el(app, "invite.field").waitForExistence(timeout: 10))
    XCTAssertEqual(el(app, "invite.field").value as? String, Self.groupedInvite)
    back(app)
    XCTAssertTrue(el(app, "stories.getStarted").waitForExistence(timeout: 10))
    attach(app, "Stories · after Back")

    // Forward: the invite, the name and the email as they were typed.
    tap(app, "stories.getStarted")
    XCTAssertTrue(el(app, "invite.field").waitForExistence(timeout: 10))
    XCTAssertEqual(el(app, "invite.field").value as? String, Self.groupedInvite, "the invite was lost")
    XCTAssertTrue(el(app, "invite.continue").isEnabled)
    tap(app, "invite.continue")
    XCTAssertTrue(el(app, "about.name").waitForExistence(timeout: 10))
    XCTAssertEqual(el(app, "about.name").value as? String, "Maya Rahman", "the name was lost")
    XCTAssertEqual(el(app, "about.email").value as? String, "maya@example.com", "the email was lost")
    XCTAssertTrue(el(app, "about.continue").isEnabled)
    attach(app, "About you · after Back and Forward")

    // And it carries on from there: the code is asked for the address that was kept.
    tap(app, "about.continue")
    XCTAssertTrue(el(app, "code.field").waitForExistence(timeout: 10))
  }

  // MARK: - Support

  /// The invite as the field groups it.
  static let groupedInvite = "ABCD-EFGH-IJKL-MNOP-QRST-UVWX"

  /// A new person from the stories to setup's bank step: the four stories swiped through,
  /// Get started, the invite, About you, the email code, the passkey (the default method),
  /// the words shown, "I've written them down" (it waits for the reveal, and no word check
  /// follows), then "Your account is ready".
  @MainActor
  private func joinWithPasskey(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
    let progress = el(app, "stories.progress")
    XCTAssertTrue(progress.waitForExistence(timeout: 15), file: file, line: line)
    for _ in 0..<3 { el(app, "stories.pager").swipeLeft() }
    XCTAssertTrue(progress.waitForLabel("Page 4 of 4", timeout: 10), "the pager did not reach story 4",
                  file: file, line: line)
    attach(app, "Stories · 4 of 4")
    tap(app, "stories.getStarted", file: file, line: line)
    type(app, "invite.field", JoinUITests.invite, file: file, line: line)
    tap(app, "invite.continue", file: file, line: line)
    type(app, "about.name", "Maya Rahman", file: file, line: line)
    type(app, "about.email", "maya@example.com", file: file, line: line)
    tap(app, "about.continue", file: file, line: line)
    type(app, "code.field", "123456", file: file, line: line)

    let passkey = el(app, "method.passkey")
    XCTAssertTrue(passkey.waitForExistence(timeout: 10), file: file, line: line)
    XCTAssertTrue(passkey.isSelected, "the passkey isn't the default", file: file, line: line)
    tap(app, "method.continue", file: file, line: line)

    tap(app, "phrase.start", file: file, line: line)
    let written = el(app, "phrase.written")
    XCTAssertTrue(written.waitForExistence(timeout: 10), file: file, line: line)
    XCTAssertFalse(written.isEnabled, "the words could be skipped unseen", file: file, line: line)
    tap(app, "phrase.reveal", file: file, line: line)
    XCTAssertTrue(el(app, "phrase.hide").waitForExistence(timeout: uiWait), file: file, line: line)
    attach(app, "Recovery phrase · revealed")
    tap(app, "phrase.written", file: file, line: line)

    XCTAssertTrue(el(app, "ready.continue").waitForExistence(timeout: 10), "the words led to a check",
                  file: file, line: line)
    attach(app, "Account ready")
    tap(app, "ready.continue", file: file, line: line)
    XCTAssertTrue(el(app, "bank.enbd").waitForExistence(timeout: 10), "setup did not follow", file: file, line: line)
  }

  /// The banks as `testSetupRemembersEverything` leaves them: Emirates NBD only.
  @MainActor
  private func assertBanksAsLeft(_ app: XCUIApplication, line: UInt = #line) {
    XCTAssertTrue(el(app, "bank.enbd").isSelected, "Emirates NBD was dropped", line: line)
    XCTAssertFalse(el(app, "bank.dib").isSelected, "DIB came back", line: line)
    XCTAssertFalse(el(app, "bank.adib").isSelected, "ADIB came back", line: line)
    XCTAssertEqual(el(app, "bank.continue").label, "Continue with 1 bank", line: line)
  }

  /// Some element's label is `text` or contains it (combined rows read as one).
  @MainActor
  private func says(_ app: XCUIApplication, _ text: String) -> Bool {
    app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
      .waitForExistence(timeout: uiWait)
  }
}
