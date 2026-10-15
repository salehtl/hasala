import XCTest

/// Sign-in and Sign-in & security on the Release surface: the beta's account actions
/// only, and support in place of the rest.
final class ReleaseSurfaceSignInTests: ReleaseSurfaceTestCase {
  /// Sign in offers the passkey and the password; "Forgot password?" and recovery become
  /// a support email link.
  @MainActor
  func testSignInOffersSupportInsteadOfRecovery() throws {
    let app = launchRelease("signInPassword", waitForHome: false)
    let signIn = el(app, "stories.signIn")
    XCTAssertTrue(signIn.waitForExistence(timeout: 15))
    signIn.tap()
    XCTAssertTrue(el(app, "signIn.passkey").waitForExistence(timeout: 5))
    attach(app, "Release · Sign in")
    assertNoPlaceholders(app, "Sign in")
    assertAbsent(app, ["signIn.forgot", "signIn.recover"], "Sign in")
    assertPresent(app, ["signIn.email", "signIn.password", "signIn.withPassword", "signIn.support", "signIn.support.web"],
                  "Sign in")
    try audit(app)
  }

  /// Sign-in & security: the beta's actions, support for the rest.
  @MainActor
  func testSecurityOffersOnlyTheBetasActions() throws {
    let app = launchRelease()
    app.buttons["header.profile"].firstMatch.tap()
    let security = el(app, "profile.security")
    XCTAssertTrue(security.waitForExistence(timeout: 5))
    XCTAssertTrue(reveal(app, security))
    security.tap()
    XCTAssertTrue(el(app, "security.hero").waitForExistence(timeout: 10))
    attach(app, "Release · Sign-in & security")
    assertNoPlaceholders(app, "Sign-in & security")
    assertAbsent(app, ["security.changeEmail", "security.addPasskey", "security.removePasskey.pk-1",
                       "security.removeDevice.ios-other", "security.newWords", "security.freeze",
                       "security.lockdown", "security.setPassword", "security.changePassword"],
                 "Sign-in & security")
    assertPresent(app, ["security.viewPhrase", "security.signOut", "security.signOutEverywhere", "security.delete",
                        "security.support", "security.support.web"], "Sign-in & security")
    try audit(app)
  }
}
