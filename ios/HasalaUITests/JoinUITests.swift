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
    el(app, "code.field").typeText("123456")

    XCTAssertTrue(el(app, "method.passkey").waitForExistence(timeout: 10))
    attach(app, "How do you want to sign in")
    try audit(app)
    tap(app, "method.continue")

    tap(app, "phrase.start")
    // "I've written them down" waits until the words were shown (Paper F6Q).
    XCTAssertTrue(el(app, "phrase.reveal").waitForExistence(timeout: 10))
    XCTAssertFalse(el(app, "phrase.written").isEnabled)
    tap(app, "phrase.reveal")
    XCTAssertTrue(app.staticTexts["scissors"].waitForExistence(timeout: 5))
    attach(app, "Recovery phrase · revealed")
    try audit(app)
    // "I've written them down" publishes the account: there is no word check.
    tap(app, "phrase.written")

    XCTAssertTrue(el(app, "ready.continue").waitForExistence(timeout: 10))
    attach(app, "Account ready")
    try audit(app)
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

    type(app, "password.new", "password2026!")
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
    tap(app, "stories.getStarted")
    XCTAssertTrue(el(app, "welcome.join").waitForExistence(timeout: 10))
    attach(app, "AX3 · Welcome")
    try audit(app, atLargeText: true)
    tap(app, "welcome.join")
    XCTAssertTrue(el(app, "invite.field").waitForExistence(timeout: 10))
    attach(app, "AX3 · Invite")
    try audit(app, atLargeText: true)
  }
}
