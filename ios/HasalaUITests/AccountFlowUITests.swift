import XCTest

/// The account and setup flows on the in-memory account mock (spec 04 §15.3's page-14
/// and row-10 scenarios). Every screen a flow reaches is audited for accessibility, and
/// screenshots are attached to the report.
///
/// Mock values (synthetic): email codes are 123456; the existing account is
/// maya@example.com / "copper lantern quietly 42"; the phrase is `phrase` below.
final class AccountFlowUITests: XCTestCase {
  static let phrase = ["absurd", "avoid", "scissors", "anxiety", "gather", "lottery", "category", "door", "army",
                       "half", "long", "camera"]
  static let invite = "ABCDEFGHIJKLMNOPQRSTUVWX"

  override func setUp() {
    continueAfterFailure = false
  }

  @MainActor
  private func launch(_ scenario: String) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-HasalaScenario", scenario]
    app.launch()
    return app
  }

  @MainActor
  private func el(_ app: XCUIApplication, _ id: String) -> XCUIElement {
    app.descendants(matching: .any)[id].firstMatch
  }

  @MainActor
  private func tap(_ app: XCUIApplication, _ id: String, timeout: TimeInterval = 10) {
    let e = el(app, id)
    XCTAssertTrue(e.waitForExistence(timeout: timeout), "\(id) is missing")
    dragUntilHittable(app, e)
    e.tap()
  }

  /// Replaces a text field's whole contents: the cursor goes to the end (a tap can land
  /// mid-text), then one delete per character.
  @MainActor
  private func replaceText(_ app: XCUIApplication, _ id: String, _ text: String) {
    let e = el(app, id)
    XCTAssertTrue(e.waitForExistence(timeout: 10), "\(id) is missing")
    e.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
    let current = (e.value as? String) ?? ""
    e.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 2))
    XCTAssertEqual((e.value as? String).map { $0 == (e.placeholderValue ?? "") || $0.isEmpty }, true,
                   "\(id) was not cleared")
    e.typeText(text)
  }

  @MainActor
  private func type(_ app: XCUIApplication, _ id: String, _ text: String) {
    let e = el(app, id)
    XCTAssertTrue(e.waitForExistence(timeout: 10), "\(id) is missing")
    e.tap()
    e.typeText(text)
  }

  // MARK: - Signup with a passkey, then setup to Home

  @MainActor
  func testSignupWithPasskeyThroughSetupToHome() throws {
    let app = launch("newUser")
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

    // A wrong code first: "That code didn't work. 4 tries left."
    type(app, "code.field", "000000")
    XCTAssertTrue(app.staticTexts["That code didn't work. 4 tries left."].waitForExistence(timeout: 5))
    attach(app, "Verify email · wrong code")
    el(app, "code.field").typeText("123456")

    XCTAssertTrue(el(app, "method.passkey").waitForExistence(timeout: 10))
    attach(app, "How do you want to sign in")
    try audit(app)
    tap(app, "method.continue")

    tap(app, "phrase.start")
    tap(app, "phrase.reveal")
    XCTAssertTrue(app.staticTexts["scissors"].waitForExistence(timeout: 5))
    attach(app, "Recovery phrase · revealed")
    tap(app, "phrase.written")

    // A wrong word is marked and taken back by tapping it.
    tap(app, "chip.avoid")
    XCTAssertTrue(app.staticTexts["That isn't word 3. Check your paper, then tap the word to take it back."]
      .waitForExistence(timeout: 5))
    attach(app, "Check 4 words · wrong word")
    tap(app, "phrase.slot.0")
    for w in ["scissors", "category", "army", "camera"] { tap(app, "chip.\(w)") }
    attach(app, "Check 4 words · done")
    try audit(app)
    tap(app, "phrase.confirm")

    XCTAssertTrue(el(app, "ready.continue").waitForExistence(timeout: 10))
    attach(app, "Account ready")
    try audit(app)
    tap(app, "ready.continue")

    // Setup (row 10).
    XCTAssertTrue(el(app, "bank.enbd").waitForExistence(timeout: 10))
    attach(app, "Bank")
    try audit(app)
    tap(app, "bank.continue")
    attach(app, "Gmail")
    try audit(app)
    tap(app, "gmail.connect")
    XCTAssertTrue(el(app, "scan.progress").waitForExistence(timeout: 10))
    attach(app, "First scan")
    tap(app, "scan.setUpPlan")
    type(app, "income.field", "25000")
    attach(app, "Income")
    tap(app, "income.continue")
    XCTAssertTrue(app.staticTexts["12,500"].waitForExistence(timeout: 5))
    attach(app, "Starting plan")
    try audit(app)
    tap(app, "plan.use")

    let cards = el(app, "cards.continue")
    XCTAssertTrue(cards.waitForExistence(timeout: 10))
    let enabled = NSPredicate(format: "isEnabled == true")
    expectation(for: enabled, evaluatedWith: cards)
    waitForExpectations(timeout: 20)
    attach(app, "Your cards")
    try audit(app)
    cards.tap()
    XCTAssertTrue(app.staticTexts["264 transactions, sorted."].waitForExistence(timeout: 10))
    attach(app, "Sorted")
    tap(app, "result.continue")
    attach(app, "Notifications")
    try audit(app)
    tap(app, "notifications.notNow")
    XCTAssertTrue(app.staticTexts["You're set, Maya."].waitForExistence(timeout: 10))
    attach(app, "Done")
    try audit(app)
    tap(app, "done.home")

    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: 10), "Home did not open")
  }

  // MARK: - Signup with a password

  @MainActor
  func testSignupWithPasswordChecksTheRules() throws {
    let app = launch("newUser")
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
    let app = launch("newUser")
    tap(app, "stories.getStarted", timeout: 15)
    tap(app, "welcome.join")
    type(app, "invite.field", "ZZZZ" + String(Self.invite.dropFirst(4)))
    tap(app, "invite.continue")
    type(app, "about.name", "Maya")
    type(app, "about.email", "maya@example.com")
    tap(app, "about.continue")
    XCTAssertTrue(app.staticTexts["We couldn't find that invite. Check the code, or ask for a new one."]
      .waitForExistence(timeout: 10))
    attach(app, "Invite · not found")
    try audit(app)
  }

  // MARK: - Sign in with a password, wrong then right

  @MainActor
  func testPasswordSignIn() throws {
    let app = launch("signInPassword")
    tap(app, "stories.signIn", timeout: 15)
    type(app, "signIn.email", "maya@example.com")
    type(app, "signIn.password", "not my password")
    tap(app, "signIn.withPassword")
    XCTAssertTrue(app.staticTexts["That email and password don't match."].waitForExistence(timeout: 10))
    app.keyboards.buttons["return"].firstMatch.tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
    attach(app, "Sign in · wrong password")
    try audit(app)
    type(app, "signIn.password", "copper lantern quietly 42")
    tap(app, "signIn.withPassword")
    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: 10))
  }

  // MARK: - New iPhone: unlock with the 12 words

  @MainActor
  func testUnlockWithTheWords() throws {
    let app = launch("unlockPasswordOnly")
    XCTAssertTrue(el(app, "phraseEntry.field").waitForExistence(timeout: 15))
    attach(app, "Unlock · 12 words")
    try audit(app)
    type(app, "phraseEntry.field", Self.phrase.joined(separator: " "))
    tap(app, "unlock.submit")
    tap(app, "unlock.open")
    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: 10))
  }

  // MARK: - Sign-in & security

  @MainActor
  func testSecurityForAPasswordOnlyAccount() throws {
    let app = launch("passwordOnly")
    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: 15))
    app.buttons["header.profile"].firstMatch.tap()
    tap(app, "profile.security")
    XCTAssertTrue(app.staticTexts["Password only"].waitForExistence(timeout: 10))
    // Password-only accounts never see "View your 12 words" (S-41).
    XCTAssertFalse(el(app, "security.viewPhrase").exists)
    attach(app, "Sign-in & security · password only")
    try audit(app)

    // Adding a passkey asks for the password first.
    tap(app, "security.addPasskey")
    type(app, "confirm.password", "copper lantern quietly 42")
    attach(app, "Confirm it's you · password")
    tap(app, "confirm.submit")
    XCTAssertTrue(app.staticTexts["Protected"].waitForExistence(timeout: 10))
  }

  @MainActor
  func testSecurityForAPasskeyAccountAndFreeze() throws {
    let app = launch("passkeyUser")
    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: 15))
    app.buttons["header.profile"].firstMatch.tap()
    tap(app, "profile.security")
    XCTAssertTrue(app.staticTexts["Protected"].waitForExistence(timeout: 10))
    attach(app, "Sign-in & security · passkey")
    try audit(app)
    tap(app, "security.viewPhrase")
    tap(app, "phrase.reveal")
    XCTAssertTrue(app.staticTexts["scissors"].waitForExistence(timeout: 5))
    tap(app, "phrase.done")

    tap(app, "security.freeze")
    app.alerts.buttons["Freeze my account"].tap()
    XCTAssertTrue(app.staticTexts["Your account is frozen"].waitForExistence(timeout: 10))
    attach(app, "Frozen")
    try audit(app)
    tap(app, "frozen.unfreeze")
    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: 10))
  }

  @MainActor
  func testOperatorFreezeHasNoUnfreeze() throws {
    let app = launch("frozenOperator")
    XCTAssertTrue(app.staticTexts["We froze your account to protect it. Talk to us to unfreeze it."]
      .waitForExistence(timeout: 15))
    XCTAssertFalse(el(app, "frozen.unfreeze").exists)
    try audit(app)
    tap(app, "frozen.leave")
    // The banner keeps the operator's freeze: no Unfreeze there either.
    XCTAssertTrue(el(app, "frozenBanner.details").waitForExistence(timeout: 10))
    XCTAssertFalse(el(app, "frozenBanner.unfreeze").exists)
    tap(app, "frozenBanner.details")
    XCTAssertTrue(app.staticTexts["We froze your account to protect it. Talk to us to unfreeze it."]
      .waitForExistence(timeout: 10))
    XCTAssertFalse(el(app, "frozen.unfreeze").exists)
  }

  @MainActor
  func testApprovingAPasswordReset() throws {
    let app = launch("resetApproval")
    XCTAssertTrue(app.staticTexts["Is this you on a new iPhone?"].waitForExistence(timeout: 15))
    attach(app, "Approve a password reset")
    try audit(app)
    type(app, "approval.code", "ABCD EFGH IJKL MNOP")
    tap(app, "approval.approve")
    XCTAssertTrue(app.staticTexts["That code doesn't match a request. Nothing was approved."].waitForExistence(timeout: 10))
    // The keyboard went away on Approve, so the banner above is in view.
    XCTAssertFalse(app.keyboards.firstMatch.exists)
    replaceText(app, "approval.code", "WMO6 C7ID 7TYM 2M5S")
    tap(app, "approval.approve")
    XCTAssertTrue(app.staticTexts["Approved"].waitForExistence(timeout: 10))
    tap(app, "approval.done")
    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: 10))
  }

  @MainActor
  func testNotMeOpensLockdownAfterTheApprovalSheet() throws {
    let app = launch("resetApproval")
    XCTAssertTrue(app.staticTexts["Is this you on a new iPhone?"].waitForExistence(timeout: 15))
    tap(app, "approval.notMe")
    XCTAssertTrue(app.staticTexts["Let's lock it down"].waitForExistence(timeout: 10))
    attach(app, "Let's lock it down")
    try audit(app)
    tap(app, "lockdown.close")
    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: 10))
  }

  /// C1 killed before its bootstrap, then relaunched (spec 04 §6.2 "C1 interrupted"):
  /// a new phrase, the four-word check, then setup at the bank.
  @MainActor
  func testRelaunchAfterAnInterruptedSignupMakesNewWords() throws {
    let app = launch("relaunchInterrupted")
    XCTAssertTrue(app.staticTexts["This is a new recovery phrase. Throw away any words you wrote down before."]
      .waitForExistence(timeout: 15))
    attach(app, "Interrupted setup · new phrase")
    try audit(app)
    tap(app, "resume.start")
    tap(app, "phrase.reveal")
    XCTAssertTrue(app.staticTexts["scissors"].waitForExistence(timeout: 5))
    tap(app, "phrase.written")
    for w in ["scissors", "category", "army", "camera"] { tap(app, "chip.\(w)") }
    tap(app, "phrase.confirm")
    XCTAssertTrue(el(app, "ready.continue").waitForExistence(timeout: 10))
    tap(app, "ready.continue")
    XCTAssertTrue(el(app, "bank.enbd").waitForExistence(timeout: 10))
  }

  /// A new-iPhone sign-in killed before unlock, then relaunched: unlock, not setup.
  @MainActor
  func testRelaunchAfterASignInGoesToUnlock() throws {
    let app = launch("relaunchSignedIn")
    XCTAssertTrue(el(app, "unlock.passkey").waitForExistence(timeout: 15))
    XCTAssertFalse(app.staticTexts["This is a new recovery phrase. Throw away any words you wrote down before."].exists)
  }

  @MainActor
  func testNoPasscodeStopsOnboarding() throws {
    let app = launch("noPasscode")
    XCTAssertTrue(app.staticTexts["Set a passcode first"].waitForExistence(timeout: 15))
    XCTAssertFalse(el(app, "stories.getStarted").exists)
    try audit(app)
  }

  /// The signed-out screens and Sign-in & security at `.accessibility3` reflow instead of
  /// clipping (spec 04 §17).
  @MainActor
  func testAccountScreensAtLargeTextSizes() throws {
    let app = XCUIApplication()
    app.launchArguments = [
      "-HasalaScenario", "newUser", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL",
    ]
    app.launch()
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

    let signedIn = XCUIApplication()
    signedIn.launchArguments = [
      "-HasalaScenario", "passwordOnly", "-UIPreferredContentSizeCategoryName",
      "UICTContentSizeCategoryAccessibilityXL",
    ]
    signedIn.launch()
    XCTAssertTrue(el(signedIn, "home.hero.left").waitForExistence(timeout: 15))
    signedIn.buttons["header.profile"].firstMatch.tap()
    tap(signedIn, "profile.security")
    XCTAssertTrue(signedIn.staticTexts["Password only"].waitForExistence(timeout: 10))
    attach(signedIn, "AX3 · Sign-in & security")
    try audit(signedIn, atLargeText: true)
  }

  // Helpers (audit, attach) are the shared ones in UITestSupport.swift.
}
