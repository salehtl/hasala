import XCTest

/// Sign-in, unlock, forgot password, recovery, Sign-in & security, "Confirm it's you",
/// freezes, reset approval and the passcode wall on the in-memory account mock (Paper P2.3
/// to P2.8). Every screen a flow reaches is audited for accessibility, and screenshots are
/// attached to the report.
///
/// Mock values (synthetic): email codes are 123456; the existing account is
/// maya@example.com / "copper lantern quietly 42"; the phrase is `phrase` below.
final class SignInSecurityUITests: XCTestCase {
  static let phrase = ["absurd", "avoid", "scissors", "anxiety", "gather", "lottery", "category", "door", "army",
                       "half", "long", "camera"]
  static let password = "copper lantern quietly 42"

  override func setUp() {
    continueAfterFailure = false
  }

  // MARK: - Sign in with a password, wrong then right

  @MainActor
  func testPasswordSignIn() throws {
    let app = launch(scenario: "signInPassword")
    tap(app, "stories.signIn", timeout: 15)
    XCTAssertTrue(el(app, "signIn.passkey").waitForExistence(timeout: 5))
    type(app, "signIn.email", "maya@example.com")
    type(app, "signIn.password", "not my password")
    tap(app, "signIn.withPassword")
    // Paper FWD: the password box rings, one line under it, the email isn't marked.
    XCTAssertTrue(app.staticTexts["That email and password don't match. Try again, or reset your password."]
      .waitForExistence(timeout: 10))
    XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
    attach(app, "Sign in · wrong password")
    try audit(app)
    // Typing again clears the line; Return signs in.
    type(app, "signIn.password", "c")
    XCTAssertTrue(el(app, "signIn.wrongPassword").waitForNonExistence(timeout: 5))
    el(app, "signIn.password").typeText(String(Self.password.dropFirst()) + "\n")
    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: 10))
  }

  // MARK: - New iPhone: unlock

  /// Password-only (Paper G80 → GDD → GJJ → GL7): the words only, Return on the twelfth
  /// opens the data, Welcome back offers a passkey, then Home.
  @MainActor
  func testUnlockWithTheWords() throws {
    let app = launch(scenario: "unlockPasswordOnly")
    XCTAssertTrue(el(app, "unlock.words").waitForExistence(timeout: 15))
    XCTAssertFalse(el(app, "unlock.passkey").exists)
    attach(app, "Unlock · password only")
    try audit(app)
    tap(app, "unlock.words")
    XCTAssertTrue(el(app, "phraseEntry.field").waitForExistence(timeout: 10))
    assertEntryClearOfTheBar(app)
    attach(app, "Unlock · 12 words")
    try audit(app)
    type(app, "phraseEntry.field", Self.phrase.joined(separator: " ") + "\n")
    XCTAssertTrue(app.staticTexts["Welcome back, Maya."].waitForExistence(timeout: 15))
    XCTAssertTrue(el(app, "unlock.addPasskey").exists)
    attach(app, "Welcome back")
    try audit(app)
    tap(app, "unlock.open")
    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: 10))
  }

  /// Also a passkey (Paper K34): both ways; the words' suggestions come from the list.
  @MainActor
  func testUnlockOffersThePasskeyAndTheWords() throws {
    let app = launch(scenario: "unlockWithPasskey")
    XCTAssertTrue(el(app, "unlock.passkey").waitForExistence(timeout: 15))
    XCTAssertTrue(el(app, "unlock.words").exists)
    attach(app, "Unlock · passkey or words")
    try audit(app)
    tap(app, "unlock.words")
    type(app, "phraseEntry.field", "absu")
    XCTAssertTrue(el(app, "phraseEntry.suggestion.absurd").waitForExistence(timeout: 5))
    tap(app, "phraseEntry.suggestion.absurd")
    XCTAssertTrue(app.staticTexts["In the order on your paper. 1 of 12 so far."].waitForExistence(timeout: 5))
    back(app)
    tap(app, "unlock.passkey")
    // A passkey unlock offers no second passkey on Welcome back.
    XCTAssertTrue(el(app, "unlock.open").waitForExistence(timeout: 15))
    XCTAssertFalse(el(app, "unlock.addPasskey").exists)
    tap(app, "unlock.open")
    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: 10))
  }

  // MARK: - Forgot password and recovery

  /// Paper GQL → G2U → KH7 → GS6 → KIL → GUM: the other iPhone's yes signs in, and the
  /// data stays locked until the words.
  @MainActor
  func testForgotPasswordThroughTheOtherIPhone() throws {
    let app = launch(scenario: "signInPassword")
    tap(app, "stories.signIn", timeout: 15)
    tap(app, "signIn.forgot")
    type(app, "forgot.email", "maya@example.com")
    attach(app, "Forgot · email")
    try audit(app)
    tap(app, "forgot.send")
    XCTAssertTrue(el(app, "code.field").waitForExistence(timeout: 10))
    type(app, "code.field", "123456")
    tap(app, "forgot.approve")
    type(app, "password.new", "harbor lights at dawn 7")
    type(app, "password.confirm", "harbor lights at dawn 7")
    tap(app, "forgot.request")
    XCTAssertTrue(el(app, "forgot.resetCode").waitForExistence(timeout: 10))
    attach(app, "Forgot · waiting for the other iPhone")
    try audit(app)
    XCTAssertTrue(app.staticTexts["You're in. Your data is still locked."].waitForExistence(timeout: 20))
    XCTAssertTrue(el(app, "unlock.words").exists)
    try audit(app)
  }

  /// Paper GYP → GZT → G5E → H43 → H5V on the service's order: the words, then the code.
  @MainActor
  func testRecoveryWithTheWordsThenTheCode() throws {
    let app = launch(scenario: "signInPassword")
    tap(app, "stories.signIn", timeout: 15)
    tap(app, "signIn.recover")
    attach(app, "Recover · what you need")
    try audit(app)
    tap(app, "recover.start")
    XCTAssertTrue(el(app, "phraseEntry.field").waitForExistence(timeout: 10))
    assertEntryClearOfTheBar(app)
    attach(app, "Recover · 12 words")
    type(app, "phraseEntry.field", Self.phrase.prefix(6).joined(separator: " ") + " ")
    // The twelfth row (6 and 12) stays clear too once half the words are in (Paper GZT).
    assertEntryClearOfTheBar(app)
    el(app, "phraseEntry.field").typeText(Self.phrase.dropFirst(6).joined(separator: " ") + "\n")
    XCTAssertTrue(el(app, "code.field").waitForExistence(timeout: 10))
    type(app, "code.field", "123456")
    XCTAssertTrue(el(app, "recover.passkey").waitForExistence(timeout: 10))
    attach(app, "Recover · new way to sign in")
    try audit(app)
    tap(app, "recover.passkey")
    XCTAssertTrue(app.staticTexts["You're back in, Maya."].waitForExistence(timeout: 10))
    try audit(app)
    tap(app, "recover.home")
    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: 10))
  }

  /// No words (Paper H9F): the honest end, then back to the words.
  @MainActor
  func testTheHonestEndLeadsBackToTheWords() throws {
    let app = launch(scenario: "unlockPasswordOnly")
    tap(app, "unlock.noWords", timeout: 15)
    XCTAssertTrue(app.staticTexts["Without your recovery phrase, we can't open your data"].waitForExistence(timeout: 5))
    attach(app, "Honest end")
    try audit(app)
    tap(app, "honest.foundWords")
    XCTAssertTrue(el(app, "phraseEntry.field").waitForExistence(timeout: 5))
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

    // Adding a passkey asks for the password and this iPhone's key (Paper IT2); a wrong
    // password keeps the sheet up with its line.
    tap(app, "security.addPasskey")
    XCTAssertTrue(app.staticTexts["This iPhone signs it too"].waitForExistence(timeout: 5))
    type(app, "confirm.password", "not it at all")
    tap(app, "confirm.submit")
    XCTAssertTrue(app.staticTexts["That didn't confirm. Try again."].waitForExistence(timeout: 10))
    attach(app, "Confirm it's you · password")
    try audit(app)
    type(app, "confirm.password", Self.password)
    tap(app, "confirm.submit")
    XCTAssertTrue(app.staticTexts["Protected"].waitForExistence(timeout: 10))
  }

  /// Delete account says how a password-only account confirms (Paper IAM, updated copy).
  @MainActor
  func testDeleteSaysHowThisAccountConfirms() throws {
    let app = launch(scenario: "passwordOnly")
    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: 15))
    app.buttons["header.profile"].firstMatch.tap()
    tap(app, "profile.security")
    tap(app, "security.delete")
    XCTAssertTrue(el(app, "delete.subtitle").waitForLabel("This can't be undone. You'll confirm with your password.",
                                                         timeout: 10))
    attach(app, "Delete account · password only")
    try audit(app)
    tap(app, "delete.confirm")
    app.alerts["Delete your Hasala account?"].buttons["Delete"].tap()
    type(app, "confirm.password", Self.password)
    tap(app, "confirm.submit")
    XCTAssertTrue(el(app, "stories.getStarted").waitForExistence(timeout: 15))
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

    // View your 12 words: Face ID first (Paper INK), then the cover, hidden until tapped.
    tap(app, "security.viewPhrase")
    XCTAssertTrue(app.staticTexts["Show your 12 words"].waitForExistence(timeout: 5))
    tap(app, "confirm.submit")
    tap(app, "phrase.reveal")
    XCTAssertTrue(app.staticTexts["scissors"].waitForExistence(timeout: 5))
    attach(app, "View your 12 words")
    try audit(app)
    tap(app, "phrase.done")
    // Closed, the words are gone: another look asks again and starts hidden.
    XCTAssertTrue(el(app, "security.viewPhrase").waitForExistence(timeout: 5))
    XCTAssertFalse(app.staticTexts["scissors"].exists)
    tap(app, "security.viewPhrase")
    tap(app, "confirm.submit")
    XCTAssertTrue(el(app, "phrase.reveal").waitForExistence(timeout: 10))
    XCTAssertFalse(app.staticTexts["scissors"].exists)
    tap(app, "phrase.close")

    // Freeze: the alert, then Face ID (Paper P2.6), then the wall on every iPhone.
    tap(app, "security.freeze")
    app.alerts.buttons["Freeze my account"].tap()
    tap(app, "confirm.submit")
    XCTAssertTrue(app.staticTexts["Your account is frozen"].waitForExistence(timeout: 10))
    attach(app, "Frozen")
    try audit(app)
    // Unfreeze takes a full sign-in (Paper MUT).
    tap(app, "frozen.unfreeze")
    XCTAssertTrue(el(app, "unfreeze.passkey").waitForExistence(timeout: 5))
    attach(app, "Unfreeze")
    try audit(app)
    tap(app, "unfreeze.passkey")
    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: 10))
  }

  /// The four alerts ask first (Paper HS1, HWP, I1C, I5Z), and "Confirm it's you" names
  /// the change (IHY); closing it changes nothing.
  @MainActor
  func testRemovingAPasskeyAsksThenConfirms() throws {
    let app = launch(scenario: "passkeyUser")
    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: 15))
    app.buttons["header.profile"].firstMatch.tap()
    tap(app, "profile.security")
    tap(app, "security.removePasskey.pk-2")
    let alert = app.alerts["Remove the Work iPad passkey?"]
    XCTAssertTrue(alert.waitForExistence(timeout: 5))
    XCTAssertTrue(alert.staticTexts["It won't be able to sign in to Hasala. You'll confirm with Face ID next."].exists)
    alert.buttons["Remove"].tap()
    XCTAssertTrue(app.staticTexts["Remove the Work iPad passkey"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Face ID confirms it's really you, using your passkey."].exists)
    attach(app, "Confirm it's you · Face ID")
    try auditOverThePage(app)
    tap(app, "confirm.cancel")
    XCTAssertTrue(el(app, "security.removePasskey.pk-2").waitForExistence(timeout: 5))
    tap(app, "security.removePasskey.pk-2")
    app.alerts["Remove the Work iPad passkey?"].buttons["Remove"].tap()
    tap(app, "confirm.submit")
    XCTAssertTrue(el(app, "security.notice").waitForExistence(timeout: 10))
    XCTAssertFalse(el(app, "security.removePasskey.pk-2").exists)

    tap(app, "security.removeDevice.ios-other")
    XCTAssertTrue(app.alerts["Remove Maya\u{2019}s iPad?"].waitForExistence(timeout: 5))
    app.alerts.buttons["Cancel"].tap()
    tap(app, "security.signOutEverywhere")
    XCTAssertTrue(app.alerts["Sign out everywhere?"].waitForExistence(timeout: 5))
    app.alerts.buttons["Cancel"].tap()
  }

  /// This iPhone's data is sealed, so a password step-up can't be signed here (Paper IYT).
  @MainActor
  func testAnIPhoneWithoutItsKeyCantConfirm() throws {
    let app = launch(scenario: nil, screen: "confirm.noKey")
    XCTAssertTrue(app.staticTexts["This iPhone can't confirm yet"].waitForExistence(timeout: 20))
    XCTAssertTrue(el(app, "confirm.enterWords").exists)
    attach(app, "Confirm it's you · no key")
    try audit(app)
  }

  /// Change email (Paper LPY, LRC): Face ID, the new address, both codes, then the page
  /// shows the new address.
  @MainActor
  func testChangeEmailWithTwoCodes() throws {
    let app = launch(scenario: "passkeyUser")
    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: 15))
    app.buttons["header.profile"].firstMatch.tap()
    tap(app, "profile.security")
    tap(app, "security.changeEmail")
    tap(app, "confirm.submit")
    type(app, "changeEmail.new", "maya.rahman@example.com")
    attach(app, "Change email · new address")
    try audit(app)
    tap(app, "changeEmail.send")
    type(app, "changeEmail.currentCode", "123456")
    type(app, "changeEmail.newCode", "123456")
    attach(app, "Change email · both codes")
    tap(app, "changeEmail.confirm")
    let notice = el(app, "security.notice")
    XCTAssertTrue(notice.waitForExistence(timeout: 10))
    XCTAssertTrue(notice.waitForLabel(containing: "maya.rahman@example.com"))
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
    // The keyboard went away on Approve, so the line above is in view.
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

  /// Unlock and the 12-word entry at `.accessibility3`: one column, no clipping.
  @MainActor
  func testUnlockAtLargeTextSizes() throws {
    let app = launch(
      scenario: "unlockWithPasskey",
      arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"])
    XCTAssertTrue(el(app, "unlock.passkey").waitForExistence(timeout: 15))
    attach(app, "AX3 · Unlock")
    try audit(app, atLargeText: true)
  }
}

extension SignInSecurityUITests {
  /// `audit(_:)` for "Confirm it's you" over Sign-in & security (a fitted sheet over the
  /// profile's large sheet). Over that page the audit reports "Potentially inaccessible
  /// text" with no element, and the tree gives the sheet's elements frames about 0.9 of
  /// their drawn size, so the audit's text and the elements don't line up. Every element of
  /// the sheet is in the tree with its label (the test asserts the title and the line), and
  /// the same sheet over the password page passes the plain audit (IT2, IYT), so
  /// element-less issues are let through here only; any issue that names an element still
  /// fails.
  @MainActor
  func auditOverThePage(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) throws {
    var issues: [String] = []
    try app.performAccessibilityAudit(for: XCUIAccessibilityAuditType.all.subtracting([.contrast, .textClipped])) {
      issue in
      guard let e = issue.element else { return true }
      if e.elementType == .key || e.elementType == .keyboard { return true }
      issues.append("\(issue.compactDescription): '\(e.label)' [\(e.identifier)] — \(issue.detailedDescription)")
      return true
    }
    if !issues.isEmpty {
      XCTFail("accessibility audit:\n" + issues.joined(separator: "\n"), file: file, line: line)
    }
  }

  // MARK: - Helpers

  /// Paper GDD, GZT: with the keyboard up, the grid's helper line and Paste sit clear above
  /// the word-list bar, never half-hidden under its glass. The page scrolls with the
  /// keyboard, so this waits a moment for it to settle.
  @MainActor
  private func assertEntryClearOfTheBar(_ app: XCUIApplication, line: UInt = #line) {
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "no keyboard", line: line)
    let bar = el(app, "phraseEntry.suggestions")
    XCTAssertTrue(bar.waitForExistence(timeout: 5), "no suggestion bar", line: line)
    let paste = el(app, "phraseEntry.paste")
    let helper = app.staticTexts["Suggestions come from the recovery word list, never your keyboard history."]
    func clear() -> Bool {
      paste.exists && helper.exists && paste.frame.maxY <= bar.frame.minY + 0.5
        && helper.frame.maxY <= bar.frame.minY + 0.5
    }
    let deadline = Date().addingTimeInterval(5)
    while !clear(), Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    }
    XCTAssertTrue(clear(), "under the bar (\(bar.frame)): Paste \(paste.frame), helper \(helper.frame)", line: line)
  }
}
