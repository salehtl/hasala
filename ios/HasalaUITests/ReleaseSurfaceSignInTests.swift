import XCTest

/// Sign-in, unlock and Sign-in & security on the Release surface: the beta's account
/// actions only (`AccountCapabilities.beta`), support in place of the rest, and alerts
/// that say only what the beta does.
final class ReleaseSurfaceSignInTests: ReleaseSurfaceTestCase {
  /// Sign in offers the passkey, the password and recovery with the 12 words; "Forgot
  /// password?" becomes a support email link, and a wrong password doesn't point to a
  /// reset it can't do.
  @MainActor
  func testSignInOffersRecoveryAndSupportInsteadOfAReset() throws {
    let app = launchRelease("signInPassword", waitForHome: false)
    let signIn = el(app, "stories.signIn")
    XCTAssertTrue(signIn.waitForExistence(timeout: 15))
    signIn.tap()
    XCTAssertTrue(el(app, "signIn.passkey").waitForExistence(timeout: uiWait))
    attach(app, "Release · Sign in")
    assertNoPlaceholders(app, "Sign in")
    assertPersonalAccountsOnly(app, "Sign in")
    assertAbsent(app, ["signIn.forgot"], "Sign in")
    assertPresent(app, ["signIn.email", "signIn.password", "signIn.withPassword", "signIn.recover", "signIn.support",
                        "signIn.support.web"], "Sign in")
    try audit(app)

    type(app, "signIn.email", "maya@example.com")
    type(app, "signIn.password", "not my password")
    tap(app, "signIn.withPassword")
    XCTAssertTrue(app.staticTexts["That email and password don't match. Try again."].waitForExistence(timeout: 10))
    assertNoText(app, ["reset your password"], "Sign in · wrong password")
  }

  /// A lost passkey: Recover your account with the 12 words and the emailed code, to a
  /// new passkey (a new password isn't in the beta), then "You're back in" says only what
  /// happened, and Home opens.
  @MainActor
  func testRecoveryToANewPasskey() throws {
    let app = launchRelease("signInPassword", waitForHome: false)
    let signIn = el(app, "stories.signIn")
    XCTAssertTrue(signIn.waitForExistence(timeout: 15))
    signIn.tap()
    tap(app, "signIn.recover")
    XCTAssertTrue(el(app, "recover.start").waitForExistence(timeout: uiWait))
    attach(app, "Release · Recover your account")
    assertNoPlaceholders(app, "Recover your account")
    try audit(app)
    tap(app, "recover.start")
    type(app, "phraseEntry.field", Self.phrase.joined(separator: " ") + "\n")
    XCTAssertTrue(el(app, "code.field").waitForExistence(timeout: 10))
    assertNoPlaceholders(app, "Recover · code")
    type(app, "code.field", "123456")
    XCTAssertTrue(el(app, "recover.passkey").waitForExistence(timeout: 10))
    attach(app, "Release · Set a new way to sign in")
    assertNoPlaceholders(app, "Set a new way to sign in")
    assertAbsent(app, ["recover.choosePassword", "recover.password"], "Set a new way to sign in")
    XCTAssertTrue(app.staticTexts["Your old passkeys and password stop working, and other devices are signed out."].exists)
    try audit(app)
    tap(app, "recover.passkey")
    XCTAssertTrue(app.staticTexts["You're back in, Maya."].waitForExistence(timeout: 10))
    attach(app, "Release · You're back in")
    assertNoPlaceholders(app, "You're back in")
    XCTAssertTrue(app.staticTexts["Old passkeys, password"].exists)
    try audit(app)
    tap(app, "recover.home")
    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: 15))
  }

  static let phrase = ["absurd", "avoid", "scissors", "anxiety", "gather", "lottery", "category", "door", "army",
                       "half", "long", "camera"]

  /// Unlocking on a new iPhone: the words only (no passkey without its capability), and
  /// the honest end points to a person, not a start-fresh the beta can't do. A
  /// password-only account's other device can't show the words, so the page doesn't say it
  /// can.
  @MainActor
  func testUnlockAndTheHonestEndPromiseOnlyWhatWorks() throws {
    let app = launchRelease("unlockPasswordOnly", waitForHome: false)
    XCTAssertTrue(el(app, "unlock.words").waitForExistence(timeout: 15))
    assertAbsent(app, ["unlock.passkey"], "Unlock")
    assertNoPlaceholders(app, "Unlock")
    tap(app, "unlock.noWords")
    XCTAssertTrue(el(app, "honest.foundWords").waitForExistence(timeout: uiWait))
    attach(app, "Release · Honest end")
    assertNoPlaceholders(app, "Honest end")
    assertAbsent(app, ["honest.startFresh"], "Honest end")
    assertNoText(app, ["Starting fresh", "add a passkey", "can show your words"], "Honest end")
    assertText(app, "can't be shown again", "Honest end")
    assertPresent(app, ["honest.talk"], "Honest end")
    try audit(app)
  }

  /// Sign-in & security: the beta's actions, support for the rest, and the two alerts it
  /// shows say what signing out really does (this iPhone's data stays, S-26).
  @MainActor
  func testSecurityOffersOnlyTheBetasActions() throws {
    let app = launchRelease()
    app.buttons["header.profile"].firstMatch.tap()
    let security = el(app, "profile.security")
    XCTAssertTrue(security.waitForExistence(timeout: uiWait))
    XCTAssertTrue(reveal(app, security))
    security.tap()
    XCTAssertTrue(el(app, "security.hero").waitForExistence(timeout: 10))
    attach(app, "Release · Sign-in & security")
    assertNoPlaceholders(app, "Sign-in & security")
    assertPersonalAccountsOnly(app, "Sign-in & security")
    assertAbsent(app, ["security.changeEmail", "security.removePasskey.pk-1",
                       "security.removePasskey.pk-2", "security.removeDevice.ios-other", "security.newWords",
                       "security.freeze", "security.lockdown", "security.setPassword", "security.changePassword",
                       "security.removePassword"],
                 "Sign-in & security")
    assertPresent(app, ["security.addPasskey", "security.viewPhrase", "security.signOut", "security.signOutEverywhere", "security.delete",
                        "security.support", "security.support.web"], "Sign-in & security")
    try audit(app)

    tap(app, "security.signOut")
    let signOut = app.alerts["Sign out of this iPhone?"]
    XCTAssertTrue(signOut.waitForExistence(timeout: uiWait))
    XCTAssertTrue(signOut.staticTexts[
      "To come back, sign in with your passkey or your password. Hasala's data stays on this iPhone, locked to your account."
    ].exists)
    attach(app, "Release · Sign out of this iPhone?")
    signOut.buttons["Cancel"].tap()

    tap(app, "security.signOutEverywhere")
    let everywhere = app.alerts["Sign out everywhere?"]
    XCTAssertTrue(everywhere.waitForExistence(timeout: uiWait))
    XCTAssertTrue(everywhere.staticTexts[
      "Every device signs out, this one too. Your data stays on each, and your sealed backup stays, ready for your next sign-in."
    ].exists)
    assertNoText(app, ["erase"], "Sign out everywhere?")
    everywhere.buttons["Cancel"].tap()
    XCTAssertTrue(el(app, "security.hero").waitForExistence(timeout: uiWait))
  }

  /// View your 12 words: "Confirm it's you" with Face ID, then the cover, nothing a
  /// placeholder; Done closes it.
  @MainActor
  func testViewingTheWordsConfirmsFirst() throws {
    let app = launchRelease()
    app.buttons["header.profile"].firstMatch.tap()
    let security = el(app, "profile.security")
    XCTAssertTrue(security.waitForExistence(timeout: uiWait))
    XCTAssertTrue(reveal(app, security))
    security.tap()
    tap(app, "security.viewPhrase")
    XCTAssertTrue(app.staticTexts["Show your 12 words"].waitForExistence(timeout: uiWait))
    assertNoPlaceholders(app, "Confirm it's you")
    tap(app, "confirm.submit")
    XCTAssertTrue(el(app, "phrase.reveal").waitForExistence(timeout: 10))
    attach(app, "Release · View your 12 words")
    assertNoPlaceholders(app, "View your 12 words")
    try audit(app)
    tap(app, "phrase.done")
    XCTAssertTrue(el(app, "security.hero").waitForExistence(timeout: uiWait))
  }

  @MainActor
  func testAHolderFreezeOffersUnfreezeOnEverySurface() throws {
    let app = launchRelease("frozen", waitForHome: false)
    XCTAssertTrue(el(app, "frozen.unfreeze").waitForExistence(timeout: 15))
    tap(app, "frozen.leave")
    XCTAssertTrue(el(app, "frozenBanner.unfreeze").waitForExistence(timeout: 10))
    app.buttons["header.profile"].firstMatch.tap()
    let security = el(app, "profile.security")
    XCTAssertTrue(security.waitForExistence(timeout: uiWait))
    XCTAssertTrue(reveal(app, security))
    security.tap()
    XCTAssertTrue(el(app, "security.hero").waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["Your account is frozen. Confirm it's you to unfreeze it."].exists)
    attach(app, "Release · Sign-in & security · frozen")
    assertPresent(app, ["security.unfreeze"], "Sign-in & security · frozen")
    assertAbsent(app, ["security.frozenTalk", "security.freeze"], "Sign-in & security · frozen")
    try audit(app)
  }
}
