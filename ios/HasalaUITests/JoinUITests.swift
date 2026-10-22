import XCTest

/// Joining on the in-memory account mock (Paper P2.1 and P2.2): the stories, the invite,
/// About you, the email code, the sign-in method and the 12 words. Every screen a flow
/// reaches is audited for accessibility, and screenshots are attached to the report.
///
/// Mock values (synthetic): email codes are 123456; the existing account is
/// maya@example.com / "copper lantern quietly 42"; the phrase is `phrase` below.
final class JoinUITests: XCTestCase {
  static let invite = "ABCDEFGHIJKLMNOPQRSTUVWX"

  override func setUp() {
    continueAfterFailure = false
  }

  // MARK: - The stories

  /// The four stories as one pager (Paper row 10): a swipe moves on, story 4 is the last
  /// ("Page 4 of 4", it doesn't loop), and "Get started" opens the invite code.
  @MainActor
  func testStoriesSwipeToTheLastThenGetStarted() throws {
    let app = launch(scenario: "newUser")
    let progress = el(app, "stories.progress")
    XCTAssertTrue(progress.waitForExistence(timeout: 15))
    for _ in 0..<3 {
      el(app, "stories.pager").swipeLeft()
    }
    XCTAssertTrue(progress.waitForLabel("Page 4 of 4", timeout: 10), "the pager did not reach story 4")
    // Every story's copy is laid out side by side; story 4's is the one on screen.
    XCTAssertTrue(el(app, "Sort a week in a minute.").isHittable)
    attach(app, "Stories · 4 of 4")
    try audit(app)
    // A swipe past the last story stays there.
    el(app, "stories.pager").swipeLeft()
    XCTAssertTrue(progress.waitForLabel("Page 4 of 4", timeout: uiWait))
    tap(app, "stories.getStarted")
    XCTAssertTrue(el(app, "invite.field").waitForExistence(timeout: 10))
    // Back returns to the story the person left.
    back(app)
    XCTAssertTrue(progress.waitForLabel("Page 4 of 4", timeout: 10))
  }

  /// "Who can see what" over story 3 (the screen launch opens it as the link does): the
  /// stories wait under it longer than a story lasts, it closes back to story 3, and the
  /// link opens it again.
  @MainActor
  func testWhoCanSeeWhatFromStoryThree() throws {
    let app = launch(scenario: nil, screen: "welcome.whoSees")
    XCTAssertTrue(el(app, "Your iPhone holds the key. Here's everyone else.").waitForExistence(timeout: 15))
    XCTAssertTrue(el(app, "Google or Microsoft").exists, "Debug can connect Outlook, so Microsoft is named")
    attach(app, "Who can see what")
    try audit(app)
    sleep(7)
    tap(app, "whoSees.close")
    let progress = el(app, "stories.progress")
    XCTAssertTrue(progress.waitForLabel("Page 3 of 4", timeout: 10), "the stories moved on under the sheet")
    tap(app, "stories.whoSees")
    XCTAssertTrue(el(app, "whoSees.close").waitForExistence(timeout: 10))
    tap(app, "whoSees.close")
  }

  // MARK: - An invite link on the pasteboard

  static let inviteLink = "https://hasala.app/i/\(invite)#" + String(repeating: "k", count: 43)

  @MainActor
  func testACopiedInviteLinkNeedsNoCode() throws {
    let app = launch(scenario: "newUser", pasteboard: Self.inviteLink)
    XCTAssertTrue(el(app, "stories.inviteFound").waitForExistence(timeout: 15))
    XCTAssertTrue(el(app, "stories.getStarted").exists)
    attach(app, "Stories · invite link found")
    try audit(app)
    tap(app, "stories.useInvite")
    XCTAssertTrue(el(app, "inviteReady.card").waitForExistence(timeout: uiWait))
    attach(app, "Invite ready · pasted")
    tap(app, "inviteReady.create")
    type(app, "about.name", "Maya Rahman")
    type(app, "about.email", "maya@example.com")
    tap(app, "about.continue")
    XCTAssertTrue(el(app, "method.passkey").waitForExistence(timeout: uiWait), "the link's key did not prove the address")
    tap(app, "method.continue")
    tap(app, "phrase.start")
    tap(app, "phrase.reveal")
    XCTAssertTrue(el(app, "phrase.hide").waitForExistence(timeout: uiWait))
    tap(app, "phrase.written")
    XCTAssertTrue(el(app, "ready.continue").waitForExistence(timeout: 10))
    attach(app, "Account ready · from a pasted link")
  }

  @MainActor
  func testACopiedLinkThatIsNoInviteOpensTheCodeField() throws {
    let app = launch(scenario: "newUser", pasteboard: "https://example.com/hello")
    tap(app, "stories.useInvite")
    XCTAssertTrue(el(app, "invite.field").waitForExistence(timeout: uiWait))
    XCTAssertEqual(UIPasteboard.general.string, "https://example.com/hello")
  }

  @MainActor
  func testACopiedLinkStillLetsYouTypeACodeAtLargeText() throws {
    let app = launch(
      scenario: "newUser", arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"],
      pasteboard: "https://example.com/hello")
    XCTAssertTrue(el(app, "stories.inviteFound").waitForExistence(timeout: 15))
    attach(app, "AX3 · Stories · link copied")
    try audit(app, atLargeText: true)
    tap(app, "stories.getStarted")
    XCTAssertTrue(el(app, "invite.field").waitForExistence(timeout: uiWait))
    XCTAssertEqual(UIPasteboard.general.string, "https://example.com/hello")
  }

  @MainActor
  func testPasteFillsTheInviteCodeWithoutAPrompt() throws {
    let app = launch(scenario: "newUser", pasteboard: "abcd efgh-ijkl mnop qrst uvwx")
    XCTAssertTrue(el(app, "stories.getStarted").waitForExistence(timeout: 15))
    XCTAssertFalse(el(app, "stories.inviteFound").exists)
    tap(app, "stories.getStarted")
    tap(app, "invite.paste")
    XCTAssertTrue(el(app, "invite.field").waitForValue("ABCD-EFGH-IJKL-MNOP-QRST-UVWX", timeout: uiWait))
    XCTAssertTrue(el(app, "invite.continue").isEnabled)
    attach(app, "Invite code · pasted")
    try audit(app)
  }

  // MARK: - Back and Forward keep what was typed

  /// Name, email, the method and the password stay through the system back, all the way
  /// to About you and forward again (plan B3, owner requirement 4); the confirmed address
  /// needs no second code.
  @MainActor
  func testBackAndForwardKeepNameEmailAndPassword() throws {
    let app = launch(scenario: "newUser")
    tap(app, "stories.getStarted", timeout: 15)
    type(app, "invite.field", Self.invite)
    tap(app, "invite.continue")
    type(app, "about.name", "Maya Rahman")
    type(app, "about.email", "maya@example.com")
    tap(app, "about.continue")
    type(app, "code.field", "123456")
    tap(app, "method.password")
    tap(app, "method.continue")
    type(app, "password.new", "copper lantern quietly 42")
    type(app, "password.confirm", "copper lantern quietly 42")
    XCTAssertTrue(el(app, "password.create").isEnabled)

    // Back to the method, the code, then About you.
    back(app)
    XCTAssertTrue(el(app, "method.password").waitForExistence(timeout: 10))
    XCTAssertTrue(el(app, "method.password").isSelected)
    back(app)
    XCTAssertTrue(el(app, "code.field").waitForExistence(timeout: 10))
    back(app)
    XCTAssertTrue(el(app, "about.name").waitForExistence(timeout: 10))
    XCTAssertEqual(el(app, "about.name").value as? String, "Maya Rahman")
    XCTAssertEqual(el(app, "about.email").value as? String, "maya@example.com")
    XCTAssertTrue(el(app, "about.confirmed").exists, "the confirmed address lost its chip")
    attach(app, "About you · after Back")
    try audit(app)

    // Forward: no second code, the method and the password as they were.
    tap(app, "about.continue")
    XCTAssertTrue(el(app, "method.password").waitForExistence(timeout: 10))
    XCTAssertTrue(el(app, "method.password").isSelected)
    tap(app, "method.continue")
    XCTAssertTrue(el(app, "password.create").waitForExistence(timeout: 10))
    XCTAssertTrue(el(app, "password.create").isEnabled, "the password was not kept")
    tap(app, "password.create")
    XCTAssertTrue(el(app, "phrase.start").waitForExistence(timeout: 10))
  }

  // MARK: - The stories wait under a pushed screen

  /// Story 2 has just begun when "Get started" opens the invite code: under it the stories
  /// don't move on, and Back finds the same story.
  @MainActor
  func testStoriesWaitUnderAPushedScreen() throws {
    let app = launch(scenario: "newUser")
    let progress = el(app, "stories.progress")
    XCTAssertTrue(progress.waitForExistence(timeout: 15))
    XCTAssertTrue(progress.waitForLabel("Page 2 of 4", timeout: 15))
    let shown = progress.label
    tap(app, "stories.getStarted")
    XCTAssertTrue(el(app, "invite.field").waitForExistence(timeout: uiWait))
    sleep(8)
    back(app)
    XCTAssertTrue(progress.waitForExistence(timeout: uiWait))
    XCTAssertEqual(progress.label, shown, "the stories moved on under the invite code")
  }

  // MARK: - The keyboard

  /// With the keyboard up, the dock keeps its button over the keyboard and its links step
  /// aside, so they never cover a field (invite, about you, the password).
  @MainActor
  func testDockLinksStepAsideForTheKeyboard() throws {
    try dockLinksStepAside(arguments: [])
  }

  @MainActor
  func testDockLinksStepAsideForTheKeyboardAtLargeText() throws {
    try dockLinksStepAside(arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXXXL"])
  }

  @MainActor
  private func dockLinksStepAside(arguments: [String]) throws {
    let app = launch(scenario: "newUser", screen: "join.invite", arguments: arguments)
    tap(app, "invite.field")
    assertClearOfKeyboard(app, shown: ["invite.field"], button: "invite.continue", hidden: ["invite.waitlist"],
                          "Keyboard · Invite")

    let about = launch(scenario: "newUser", screen: "join.aboutTyped", arguments: arguments)
    tap(about, "about.name")
    assertClearOfKeyboard(about, shown: ["about.name", "about.email"], button: "about.continue",
                          hidden: ["about.signIn"], "Keyboard · About you")

    let password = launch(scenario: "newUser", screen: "join.method", arguments: arguments)
    tap(password, "method.password")
    tap(password, "method.continue")
    tap(password, "password.new")
    assertClearOfKeyboard(password, shown: ["password.new", "password.confirm"], button: "password.create",
                          hidden: ["password.useFaceID"], "Keyboard · Password")
  }

  // MARK: - Reduce Motion

  /// With Reduce Motion the stories cross-fade (a tap on the drawing moves on, no slide),
  /// and the join flow runs to "Your account is ready" as usual.
  @MainActor
  func testJoinWithReduceMotion() throws {
    let app = launch(scenario: "newUser", motion: "reduce", arguments: [Self.noPRF])
    let progress = el(app, "stories.progress")
    XCTAssertTrue(progress.waitForExistence(timeout: 15))
    el(app, "stories.pager").coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.3)).tap()
    XCTAssertTrue(progress.waitForLabel("Page 2 of 4", timeout: 10), "a tap did not move on")
    XCTAssertTrue(el(app, "Your bank emails do the typing.").isHittable)
    attach(app, "Reduce Motion · Story 2")
    try audit(app)
    tap(app, "stories.getStarted")
    type(app, "invite.field", Self.invite)
    tap(app, "invite.continue")
    type(app, "about.name", "Maya Rahman")
    type(app, "about.email", "maya@example.com")
    tap(app, "about.continue")
    type(app, "code.field", "123456")
    tap(app, "method.continue")
    tap(app, "phrase.start")
    tap(app, "phrase.reveal")
    XCTAssertTrue(el(app, "phrase.hide").waitForExistence(timeout: uiWait))
    tap(app, "phrase.written")
    XCTAssertTrue(el(app, "ready.continue").waitForExistence(timeout: 10))
    attach(app, "Reduce Motion · Account ready")
    try audit(app)
  }

  @MainActor
  func testSignupWithAPasskeyThatDoesNotSyncShowsTheWords() throws {
    let app = launch(scenario: "newUser", arguments: [Self.notSynced])
    XCTAssertTrue(el(app, "stories.getStarted").waitForExistence(timeout: 15))
    tap(app, "stories.getStarted")
    tap(app, "welcome.join")
    type(app, "invite.field", Self.invite)
    tap(app, "invite.continue")
    type(app, "about.name", "Maya Rahman")
    type(app, "about.email", "maya@example.com")
    tap(app, "about.continue")
    type(app, "code.field", "123456")
    tap(app, "method.continue")
    XCTAssertTrue(el(app, "phrase.start").waitForExistence(timeout: 10))
    attach(app, "Passkey not synced · why it matters")
    try audit(app)
  }

  // MARK: - Signup with a passkey, up to setup

  @MainActor
  func testSignupWithPasskeyWithoutPRFShowsTheWords() throws {
    let app = launch(scenario: "newUser", arguments: [Self.noPRF])
    XCTAssertTrue(el(app, "stories.getStarted").waitForExistence(timeout: 15))
    attach(app, "Stories")
    try audit(app)
    tap(app, "stories.getStarted")

    type(app, "invite.field", Self.invite.lowercased())
    XCTAssertEqual(el(app, "invite.field").value as? String, "ABCD-EFGH-IJKL-MNOP-QRST-UVWX")
    attach(app, "Invite code")
    try audit(app)
    tap(app, "invite.continue")

    type(app, "about.name", "Maya Rahman")
    type(app, "about.email", "maya@example.com")
    attach(app, "About you")
    try audit(app)
    tap(app, "about.continue")

    // A wrong code first: "That code isn't right. … 4 tries left."
    type(app, "code.field", "000000")
    XCTAssertTrue(
      app.staticTexts["That code isn't right. Check the newest email from us, or get a new code. 4 tries left."]
        .waitForExistence(timeout: uiWait))
    attach(app, "Verify email · wrong code")
    try audit(app)
    el(app, "code.field").typeText("123456")

    XCTAssertTrue(el(app, "method.passkey").waitForExistence(timeout: 10))
    attach(app, "How do you want to sign in")
    try audit(app)
    tap(app, "method.continue")

    XCTAssertTrue(el(app, "phrase.start").waitForExistence(timeout: 10))
    attach(app, "Recovery phrase · why it matters")
    try audit(app)
    tap(app, "phrase.start")
    // "I've written them down" waits until the words were shown (Paper F6Q).
    XCTAssertTrue(el(app, "phrase.reveal").waitForExistence(timeout: 10))
    XCTAssertFalse(el(app, "phrase.written").isEnabled)
    attach(app, "Recovery phrase · hidden")
    try audit(app)
    tap(app, "phrase.reveal")
    XCTAssertTrue(app.staticTexts["scissors"].waitForExistence(timeout: uiWait))
    attach(app, "Recovery phrase · revealed")
    try audit(app)
    // "I've written them down" publishes the account: there is no word check.
    tap(app, "phrase.written")

    XCTAssertTrue(el(app, "ready.continue").waitForExistence(timeout: 10))
    XCTAssertTrue(has(app, "Face ID passkey, In iCloud Keychain"))
    attach(app, "Account ready")
    try audit(app)
    // "What Hasala reads, and what it doesn't" opens "Who can see what".
    tap(app, "ready.whoSees")
    XCTAssertTrue(el(app, "whoSees.close").waitForExistence(timeout: 10))
    tap(app, "whoSees.close")
    tap(app, "ready.continue")
    XCTAssertTrue(el(app, "bank.enbd").waitForExistence(timeout: 10), "setup did not follow")
  }

  /// A passkey with PRF can show the words again after Face ID, so signup makes the account
  /// without them and setup follows; Home asks for them first.
  @MainActor
  func testSignupWithPRFPasskeyLeavesTheWordsForHome() throws {
    let app = launch(scenario: "newUser")
    tap(app, "stories.getStarted", timeout: 15)
    tap(app, "welcome.join")
    type(app, "invite.field", Self.invite)
    tap(app, "invite.continue")
    type(app, "about.name", "Maya Rahman")
    type(app, "about.email", "maya@example.com")
    tap(app, "about.continue")
    type(app, "code.field", "123456")
    XCTAssertTrue(el(app, "method.passkey").waitForExistence(timeout: 10))
    tap(app, "method.continue")
    XCTAssertTrue(el(app, "bank.enbd").waitForExistence(timeout: 10), "setup did not follow the passkey")
    XCTAssertFalse(el(app, "phrase.start").exists)
    XCTAssertFalse(el(app, "ready.continue").exists)
    attach(app, "Setup · after the passkey")
    tap(app, "mail.connect.gmail")
    XCTAssertTrue(el(app, "home.finish.phrase").waitForExistence(timeout: 15), "Home doesn't ask for the 12 words")
    try audit(app)
  }

  // MARK: - Signup with a password

  @MainActor
  func testSignupWithPasswordChecksTheRules() throws {
    let app = launch(scenario: "newUser")
    tap(app, "stories.getStarted", timeout: 15)
    type(app, "invite.field", Self.invite)
    tap(app, "invite.continue")
    type(app, "about.name", "Maya Rahman")
    type(app, "about.email", "maya@example.com")
    tap(app, "about.continue")
    type(app, "code.field", "123456")
    tap(app, "method.password")
    tap(app, "method.continue")

    type(app, "password.new", "lantern4")
    XCTAssertTrue(app.staticTexts["Too short. 8 of 12 characters."].waitForExistence(timeout: uiWait))
    XCTAssertFalse(el(app, "password.create").isEnabled)
    replaceText(app, "password.new", "password2026!")
    XCTAssertTrue(app.staticTexts["That password is too common. Try a longer phrase or let iPhone suggest one."]
      .waitForExistence(timeout: uiWait))
    attach(app, "Password · too common")
    XCTAssertFalse(el(app, "password.create").isEnabled)
    let field = el(app, "password.new")
    type(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 13), into: field)
    field.typeText("copper lantern quietly 42")
    type(app, "password.confirm", "copper lantern quietly 42")
    XCTAssertTrue(app.staticTexts["Passwords match."].waitForExistence(timeout: uiWait))
    attach(app, "Password · strong, confirmed")
    try audit(app)
    tap(app, "password.create")
    XCTAssertTrue(el(app, "phrase.start").waitForExistence(timeout: 10))
  }

  // MARK: - Invite not found

  @MainActor
  func testUnknownInviteSaysSo() throws {
    let app = launch(scenario: "newUser")
    tap(app, "stories.getStarted", timeout: 15)
    type(app, "invite.field", "ZZZZ" + String(Self.invite.dropFirst(4)))
    tap(app, "invite.continue")
    type(app, "about.name", "Maya")
    type(app, "about.email", "maya@example.com")
    tap(app, "about.continue")
    XCTAssertTrue(app.staticTexts["We couldn't find that invite. Check each character against your email."]
      .waitForExistence(timeout: 10))
    attach(app, "Invite · not found")
    try audit(app)
  }

  /// C1 killed before its bootstrap, then relaunched (spec 04 §6.2 "C1 interrupted"):
  /// a new phrase, shown, then setup at the bank.
  @MainActor
  func testRelaunchAfterAnInterruptedSignupMakesNewWords() throws {
    let app = launch(scenario: "relaunchInterrupted")
    XCTAssertTrue(app.staticTexts["This is a new recovery phrase. Throw away any words you wrote down before."]
      .waitForExistence(timeout: 15))
    attach(app, "Interrupted setup · new phrase")
    try audit(app)
    tap(app, "resume.start")
    tap(app, "phrase.reveal")
    XCTAssertTrue(app.staticTexts["scissors"].waitForExistence(timeout: uiWait))
    tap(app, "phrase.written")
    XCTAssertTrue(el(app, "ready.continue").waitForExistence(timeout: 10))
    tap(app, "ready.continue")
    XCTAssertTrue(el(app, "bank.enbd").waitForExistence(timeout: 10))
  }

  /// The signed-out screens at `.accessibility3` reflow instead of clipping (spec 04 §17).
  @MainActor
  func testJoinScreensAtLargeTextSizes() throws {
    let app = launch(
      scenario: "newUser",
      arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL", Self.noPRF])
    XCTAssertTrue(el(app, "stories.getStarted").waitForExistence(timeout: 15))
    attach(app, "AX3 · Stories")
    try audit(app, atLargeText: true)
    // The copy fills the screen at this size, so the stories wait for the person: still the
    // first after longer than a story plays.
    sleep(7)
    XCTAssertEqual(el(app, "stories.progress").label, "Page 1 of 4", "the stories moved on mid-read")
    tap(app, "stories.getStarted")
    XCTAssertTrue(el(app, "invite.field").waitForExistence(timeout: uiWait))
    attach(app, "AX3 · Invite")
    try audit(app, atLargeText: true)
    type(app, "invite.field", Self.invite)
    tap(app, "invite.continue")
    type(app, "about.name", "Maya Rahman")
    type(app, "about.email", "maya@example.com")
    attach(app, "AX3 · About you")
    try audit(app, atLargeText: true)
    tap(app, "about.continue", opening: "code.field")
    attach(app, "AX3 · Check your email")
    try audit(app, atLargeText: true)
    type(app, "code.field", "123456")
    XCTAssertTrue(el(app, "method.passkey").waitForExistence(timeout: uiWait))
    attach(app, "AX3 · How to sign in")
    try audit(app, atLargeText: true)
    tap(app, "method.continue")
    XCTAssertTrue(el(app, "phrase.start").waitForExistence(timeout: uiWait))
    attach(app, "AX3 · Why it matters")
    try audit(app, atLargeText: true)
    tap(app, "phrase.start")
    tap(app, "phrase.reveal")
    XCTAssertTrue(el(app, "phrase.hide").waitForExistence(timeout: uiWait))
    attach(app, "AX3 · Write these down")
    try audit(app, atLargeText: true)
    tap(app, "phrase.written")
    XCTAssertTrue(el(app, "ready.continue").waitForExistence(timeout: uiWait))
    attach(app, "AX3 · Account ready")
    try audit(app, atLargeText: true)
  }

  static let noPRF = "-HasalaPasskeyNoPRF"
  static let notSynced = "-HasalaPasskeyNotSynced"

  /// Some element's label is `label` or contains it (combined rows read as one).
  @MainActor
  func has(_ app: XCUIApplication, _ label: String) -> Bool {
    app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", label)).firstMatch
      .waitForExistence(timeout: uiWait)
  }
}
