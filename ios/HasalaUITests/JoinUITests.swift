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
  /// ("Page 4 of 4", it doesn't loop), and "Get started" opens Welcome · Join.
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
    XCTAssertTrue(progress.waitForLabel("Page 4 of 4", timeout: 5))
    tap(app, "stories.getStarted")
    XCTAssertTrue(el(app, "welcome.join").waitForExistence(timeout: 10))
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

  // MARK: - Back and Forward keep what was typed

  /// Name, email, the method and the password stay through the system back, all the way
  /// to About you and forward again (plan B3, owner requirement 4); the confirmed address
  /// needs no second code.
  @MainActor
  func testBackAndForwardKeepNameEmailAndPassword() throws {
    let app = launch(scenario: "newUser")
    tap(app, "stories.getStarted", timeout: 15)
    tap(app, "welcome.join")
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

  // MARK: - Reduce Motion

  /// With Reduce Motion the stories cross-fade (a tap on the drawing moves on, no slide),
  /// and the join flow runs to "Your account is ready" as usual.
  @MainActor
  func testJoinWithReduceMotion() throws {
    let app = launch(scenario: "newUser", motion: "reduce")
    let progress = el(app, "stories.progress")
    XCTAssertTrue(progress.waitForExistence(timeout: 15))
    el(app, "stories.pager").coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.3)).tap()
    XCTAssertTrue(progress.waitForLabel("Page 2 of 4", timeout: 10), "a tap did not move on")
    XCTAssertTrue(el(app, "Your bank emails do the typing.").isHittable)
    attach(app, "Reduce Motion · Story 2")
    try audit(app)
    tap(app, "stories.getStarted")
    tap(app, "welcome.join")
    type(app, "invite.field", Self.invite)
    tap(app, "invite.continue")
    type(app, "about.name", "Maya Rahman")
    type(app, "about.email", "maya@example.com")
    tap(app, "about.continue")
    type(app, "code.field", "123456")
    tap(app, "method.continue")
    tap(app, "phrase.start")
    tap(app, "phrase.reveal")
    XCTAssertTrue(el(app, "phrase.hide").waitForExistence(timeout: 5))
    tap(app, "phrase.written")
    XCTAssertTrue(el(app, "ready.continue").waitForExistence(timeout: 10))
    attach(app, "Reduce Motion · Account ready")
    try audit(app)
  }

  // MARK: - Signup with a passkey, up to setup

  @MainActor
  func testSignupWithPasskeyToSetup() throws {
    let app = launch(scenario: "newUser")
    XCTAssertTrue(el(app, "stories.getStarted").waitForExistence(timeout: 15))
    attach(app, "Stories")
    try audit(app)
    tap(app, "stories.getStarted")
    attach(app, "Welcome")
    try audit(app)
    tap(app, "welcome.join")

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
        .waitForExistence(timeout: 5))
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
    XCTAssertTrue(app.staticTexts["scissors"].waitForExistence(timeout: 5))
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

  // MARK: - Signup with a password

  @MainActor
  func testSignupWithPasswordChecksTheRules() throws {
    let app = launch(scenario: "newUser")
    tap(app, "stories.getStarted", timeout: 15)
    tap(app, "welcome.join")
    type(app, "invite.field", Self.invite)
    tap(app, "invite.continue")
    type(app, "about.name", "Maya Rahman")
    type(app, "about.email", "maya@example.com")
    tap(app, "about.continue")
    type(app, "code.field", "123456")
    tap(app, "method.password")
    tap(app, "method.continue")

    type(app, "password.new", "lantern4")
    XCTAssertTrue(app.staticTexts["Too short. 8 of 12 characters."].waitForExistence(timeout: 5))
    XCTAssertFalse(el(app, "password.create").isEnabled)
    replaceText(app, "password.new", "password2026!")
    XCTAssertTrue(app.staticTexts["That password is too common. Try a longer phrase or let iPhone suggest one."]
      .waitForExistence(timeout: 5))
    attach(app, "Password · too common")
    XCTAssertFalse(el(app, "password.create").isEnabled)
    let field = el(app, "password.new")
    field.tap()
    field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 13))
    field.typeText("copper lantern quietly 42")
    type(app, "password.confirm", "copper lantern quietly 42")
    XCTAssertTrue(app.staticTexts["Passwords match."].waitForExistence(timeout: 5))
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
    tap(app, "welcome.join")
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
    XCTAssertTrue(app.staticTexts["scissors"].waitForExistence(timeout: 5))
    tap(app, "phrase.written")
    XCTAssertTrue(el(app, "ready.continue").waitForExistence(timeout: 10))
    tap(app, "ready.continue")
    XCTAssertTrue(el(app, "bank.enbd").waitForExistence(timeout: 10))
  }

  /// The signed-out screens at `.accessibility3` reflow instead of clipping (spec 04 §17).
  @MainActor
  func testJoinScreensAtLargeTextSizes() throws {
    let app = launch(
      scenario: "newUser", arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"])
    XCTAssertTrue(el(app, "stories.getStarted").waitForExistence(timeout: 15))
    attach(app, "AX3 · Stories")
    try audit(app, atLargeText: true)
    // The copy fills the screen at this size, so the stories wait for the person: still the
    // first after longer than a story plays.
    sleep(7)
    XCTAssertEqual(el(app, "stories.progress").label, "Page 1 of 4", "the stories moved on mid-read")
    tap(app, "stories.getStarted")
    XCTAssertTrue(el(app, "welcome.join").waitForExistence(timeout: 10))
    attach(app, "AX3 · Welcome")
    try audit(app, atLargeText: true)
    tap(app, "welcome.join")
    XCTAssertTrue(el(app, "invite.field").waitForExistence(timeout: 10))
    attach(app, "AX3 · Invite")
    try audit(app, atLargeText: true)
    type(app, "invite.field", Self.invite)
    tap(app, "invite.continue")
    type(app, "about.name", "Maya Rahman")
    type(app, "about.email", "maya@example.com")
    attach(app, "AX3 · About you")
    try audit(app, atLargeText: true)
    tap(app, "about.continue")
    XCTAssertTrue(el(app, "code.field").waitForExistence(timeout: 10))
    attach(app, "AX3 · Check your email")
    try audit(app, atLargeText: true)
    type(app, "code.field", "123456")
    XCTAssertTrue(el(app, "method.passkey").waitForExistence(timeout: 10))
    attach(app, "AX3 · How to sign in")
    try audit(app, atLargeText: true)
    tap(app, "method.continue")
    XCTAssertTrue(el(app, "phrase.start").waitForExistence(timeout: 10))
    attach(app, "AX3 · Why it matters")
    try audit(app, atLargeText: true)
    tap(app, "phrase.start")
    tap(app, "phrase.reveal")
    XCTAssertTrue(el(app, "phrase.hide").waitForExistence(timeout: 5))
    attach(app, "AX3 · Write these down")
    try audit(app, atLargeText: true)
    tap(app, "phrase.written")
    XCTAssertTrue(el(app, "ready.continue").waitForExistence(timeout: 10))
    attach(app, "AX3 · Account ready")
    try audit(app, atLargeText: true)
  }

  /// Some element's label is `label` or contains it (combined rows read as one).
  @MainActor
  func has(_ app: XCUIApplication, _ label: String) -> Bool {
    app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", label)).firstMatch
      .waitForExistence(timeout: 5)
  }
}
