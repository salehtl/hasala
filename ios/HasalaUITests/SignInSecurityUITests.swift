import XCTest

/// Sign-in, unlock, Sign-in & security, freezes, reset approval and the passcode wall on
/// the in-memory account mock (Paper P2.3 to P2.8). Every screen a flow reaches is audited
/// for accessibility, and screenshots are attached to the report.
///
/// Mock values (synthetic): email codes are 123456; the existing account is
/// maya@example.com / "copper lantern quietly 42"; the phrase is `phrase` below.
final class SignInSecurityUITests: XCTestCase {
  static let phrase = ["absurd", "avoid", "scissors", "anxiety", "gather", "lottery", "category", "door", "army",
                       "half", "long", "camera"]

  override func setUp() {
    continueAfterFailure = false
  }

  // MARK: - Sign in with a password, wrong then right

  @MainActor
  func testPasswordSignIn() throws {
    let app = launch(scenario: "signInPassword")
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
    let app = launch(scenario: "unlockPasswordOnly")
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
    let app = launch(scenario: "passwordOnly")
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
    let app = launch(scenario: "passkeyUser")
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
    let app = launch(scenario: "frozenOperator")
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
    let app = launch(scenario: "resetApproval")
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
    let app = launch(scenario: "resetApproval")
    XCTAssertTrue(app.staticTexts["Is this you on a new iPhone?"].waitForExistence(timeout: 15))
    tap(app, "approval.notMe")
    XCTAssertTrue(app.staticTexts["Let's lock it down"].waitForExistence(timeout: 10))
    attach(app, "Let's lock it down")
    try audit(app)
    tap(app, "lockdown.close")
    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: 10))
  }

  /// A new-iPhone sign-in killed before unlock, then relaunched: unlock, not setup.
  @MainActor
  func testRelaunchAfterASignInGoesToUnlock() throws {
    let app = launch(scenario: "relaunchSignedIn")
    XCTAssertTrue(el(app, "unlock.passkey").waitForExistence(timeout: 15))
    XCTAssertFalse(app.staticTexts["This is a new recovery phrase. Throw away any words you wrote down before."].exists)
  }

  @MainActor
  func testNoPasscodeStopsOnboarding() throws {
    let app = launch(scenario: "noPasscode")
    XCTAssertTrue(app.staticTexts["Set a passcode first"].waitForExistence(timeout: 15))
    XCTAssertFalse(el(app, "stories.getStarted").exists)
    try audit(app)
  }

  /// Sign-in & security at `.accessibility3` reflows instead of clipping (spec 04 §17).
  @MainActor
  func testSecurityAtLargeTextSizes() throws {
    let app = launch(
      scenario: "passwordOnly",
      arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"])
    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: 15))
    app.buttons["header.profile"].firstMatch.tap()
    tap(app, "profile.security")
    XCTAssertTrue(app.staticTexts["Password only"].waitForExistence(timeout: 10))
    attach(app, "AX3 · Sign-in & security")
    try audit(app, atLargeText: true)
  }
}
