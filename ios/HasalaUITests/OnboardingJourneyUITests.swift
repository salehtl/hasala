import XCTest

/// Onboarding as one new person walks it, on the in-memory mocks (plan Stage I task 3):
/// the stories, joining with a passkey, the 12 words (shown, then "I've written them
/// down", with no word check after them, plan B5), and setup from the bank to Home, with
/// Gmail, or with Outlook through "Use Outlook", then Home's Finish setting up. The other two tests are the owner's
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

  /// Stories › join with the passkey › the words › every bank and Gmail on one screen ›
  /// Continue with Google › Home, the import reading behind it › Finish setting up: the
  /// monthly plan (25,000 on the keypad, the 50/30/20 plan), then a note when money moves.
  @MainActor
  func testNewUserToHome() throws {
    let app = launch(scenario: "newUser")
    joinWithPasskey(app)

    XCTAssertTrue(el(app, "bank.enbd").isSelected)
    XCTAssertTrue(el(app, "bank.dib").isSelected)
    XCTAssertTrue(el(app, "bank.adib").isSelected)
    let connect = el(app, "mail.connect.gmail")
    XCTAssertTrue(connect.waitForExistence(timeout: uiWait))
    XCTAssertEqual(connect.label, "Continue with Google")
    XCTAssertTrue(el(app, "mail.googleBriefing").exists, "Google's screens aren't explained")
    attach(app, "Setup · Bank alerts and Gmail")
    connect.tap()

    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: 10), "Home did not open after the connect")
    XCTAssertTrue(el(app, "home.finish").waitForExistence(timeout: uiWait), "Home has no Finish setting up")
    let words = el(app, "home.finish.phrase")
    XCTAssertTrue(words.waitForExistence(timeout: uiWait), "Home doesn't ask for the 12 words")
    XCTAssertLessThan(words.frame.minY, el(app, "home.finish.plan").frame.minY, "the 12 words aren't first")
    attach(app, "Home · Finish setting up")
    words.tap()
    XCTAssertTrue(app.staticTexts["Show your 12 words"].waitForExistence(timeout: uiWait), "Face ID wasn't asked first")
    tap(app, "confirm.submit")
    XCTAssertTrue(el(app, "phrase.reveal").waitForExistence(timeout: 10))
    XCTAssertFalse(app.staticTexts["scissors"].exists, "the words weren't hidden until tapped")
    tap(app, "phrase.reveal")
    XCTAssertTrue(app.staticTexts["scissors"].waitForExistence(timeout: uiWait))
    attach(app, "Home · the 12 words")
    tap(app, "phrase.done")
    XCTAssertTrue(words.waitForNonExistence(timeout: uiWait), "the 12 words stayed after they were shown")
    tap(app, "home.finish.plan")

    XCTAssertTrue(el(app, "keypad.2").waitForExistence(timeout: uiWait))
    XCTAssertFalse(app.keyboards.firstMatch.exists, "the system keyboard opened for money")
    typeOnKeypad(app, "25000")
    XCTAssertTrue(incomeFigure(app).contains("25,000"), "the figure reads \(incomeFigure(app))")
    attach(app, "Monthly plan · Income")
    tap(app, "income.continue")

    let needs = el(app, "plan.split.handle.0")
    XCTAssertTrue(needs.waitForExistence(timeout: uiWait))
    XCTAssertEqual(needs.value as? String, "50%")
    XCTAssertTrue(says(app, "AED 12,500"), "the needs amount is missing")
    attach(app, "Monthly plan · Starting plan")
    tap(app, "plan.use")

    XCTAssertTrue(el(app, "home.finish.plan").waitForNonExistence(timeout: uiWait), "the plan item stayed")
    let note = el(app, "home.finish.notifications")
    XCTAssertTrue(note.waitForExistence(timeout: uiWait))
    XCTAssertTrue(enabled(note, timeout: 30), "notifications weren't offered after the import")
    note.tap()
    tap(app, "notifications.allow")
    XCTAssertTrue(el(app, "home.finish").waitForNonExistence(timeout: uiWait), "Finish setting up stayed")
    attach(app, "Home · set up")
  }

  /// The same setup with Outlook through "Use Outlook", through to Home; Bank alerts reads
  /// the Outlook mailbox.
  @MainActor
  func testOutlookPath() throws {
    let app = launch(scenario: "newUser")
    joinWithPasskey(app)
    tap(app, "mail.change")

    let outlook = el(app, "mail.choose.outlook")
    XCTAssertTrue(outlook.waitForExistence(timeout: uiWait), "Choose your email did not open")
    outlook.tap()

    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: 10), "Home did not open after the connect")
    app.buttons["header.profile"].firstMatch.tap()
    tap(app, "profile.bankAlerts")
    XCTAssertTrue(says(app, "maya.k@example.com"), "Bank alerts doesn't show the Outlook mailbox")
    attach(app, "Bank alerts · Outlook")
  }

  // MARK: - Requirement 4: setup remembers everything

  /// One bank, then Gmail: Home opens, and the account reads one mailbox and that one bank.
  /// In the monthly plan, 25,000, the 25th and a moved split handle survive Back and
  /// Forward, and closing the sheet and opening it again; the plan sent is the one chosen.
  @MainActor
  func testSetupRemembersEverything() throws {
    let app = launch(scenario: "setupBank")

    XCTAssertTrue(el(app, "bank.dib").waitForExistence(timeout: 15))
    tap(app, "bank.dib")
    tap(app, "bank.adib")
    assertBanksAsLeft(app)
    tap(app, "mail.connect.gmail")
    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: 10), "Home did not open")

    tap(app, "home.finish.plan")
    XCTAssertTrue(el(app, "keypad.2").waitForExistence(timeout: uiWait))
    typeOnKeypad(app, "25000")
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
    XCTAssertTrue(el(app, "plan.split.handle.0").waitForValue("55%"), "the split was lost")
    XCTAssertEqual(el(app, "plan.split.handle.1").value as? String, "25%", "the split was lost")
    attach(app, "Starting plan · after Back and Forward")

    back(app)
    tap(app, "plan.setup.close")
    XCTAssertTrue(el(app, "home.finish.plan").waitForExistence(timeout: uiWait), "the plan item left unsaved")
    tap(app, "home.finish.plan")
    XCTAssertTrue(el(app, "keypad.1").waitForExistence(timeout: uiWait))
    XCTAssertTrue(incomeFigure(app).contains("25,000"), "the salary was lost: \(incomeFigure(app))")
    XCTAssertEqual(el(app, "income.payday.25").label, "Payday, 25th", "the payday was lost")
    tap(app, "income.continue")
    XCTAssertTrue(el(app, "plan.split.handle.0").waitForValue("55%"), "the split was lost")
    tap(app, "plan.use")
    XCTAssertTrue(el(app, "home.finish.plan").waitForNonExistence(timeout: uiWait), "the plan item stayed")

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
  /// Get started, the invite, About you, the email code, the passkey (the default method,
  /// with PRF), then setup: the words wait for Home.
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

    XCTAssertTrue(el(app, "bank.enbd").waitForExistence(timeout: 10), "setup did not follow", file: file, line: line)
    XCTAssertFalse(el(app, "phrase.start").exists, "the words came before setup", file: file, line: line)
  }

  /// The banks as `testSetupRemembersEverything` leaves them: Emirates NBD only.
  @MainActor
  private func assertBanksAsLeft(_ app: XCUIApplication, line: UInt = #line) {
    XCTAssertTrue(el(app, "bank.enbd").isSelected, "Emirates NBD was dropped", line: line)
    XCTAssertFalse(el(app, "bank.dib").isSelected, "DIB came back", line: line)
    XCTAssertFalse(el(app, "bank.adib").isSelected, "ADIB came back", line: line)
  }

  @MainActor
  private func enabled(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if element.exists, element.isEnabled { return true }
      RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    }
    return element.isEnabled
  }

  /// Some element's label is `text` or contains it (combined rows read as one).
  @MainActor
  private func says(_ app: XCUIApplication, _ text: String) -> Bool {
    app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
      .waitForExistence(timeout: uiWait)
  }
}
