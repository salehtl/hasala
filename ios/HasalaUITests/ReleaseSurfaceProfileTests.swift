import XCTest

/// The profile on the Release surface: only rows that work, the beta's account actions,
/// and support in place of the rest.
final class ReleaseSurfaceProfileTests: ReleaseSurfaceTestCase {
  /// The profile and every page it opens in the app (Sign-in & security is
  /// `ReleaseSurfaceSignInTests`').
  @MainActor
  func testProfileShowsOnlyWhatWorks() throws {
    let app = launchRelease()
    app.buttons["header.profile"].firstMatch.tap()
    XCTAssertTrue(el(app, "profile.name").waitForExistence(timeout: 5))
    attach(app, "Release · Profile")
    assertNoPlaceholders(app, "Profile")
    assertNoOutlook(app, "Profile")
    // The bank alerts card states the status; it opens no page.
    XCTAssertTrue(el(app, "profile.bankAlerts").exists)
    XCTAssertFalse(app.buttons["profile.bankAlerts"].exists, "the bank alerts card is a button")
    assertAbsent(app, ["profile.notifications", "profile.faceID"], "Profile")
    assertNoButtons(app, ["Accounts", "Privacy and data"], "Profile")
    assertPresent(app, ["profile.bills", "profile.rules", "profile.security", "profile.export", "profile.privacy",
                        "profile.help", "profile.signOut", "profile.delete", "profile.buildFooter"], "Profile")
    try audit(app)

    el(app, "profile.bills").tap()
    XCTAssertTrue(el(app, "bills.next14").waitForExistence(timeout: 5))
    assertNoPlaceholders(app, "Profile › Bills")
    assertNoButtons(app, ["Remind me"], "Profile › Bills")
    back(app)

    el(app, "profile.rules").tap()
    XCTAssertTrue(el(app, "rule.r-carrefour").waitForExistence(timeout: 5))
    assertNoPlaceholders(app, "Profile › Categories and rules")
    back(app)

    let help = el(app, "profile.help")
    XCTAssertTrue(reveal(app, help))
    help.tap()
    XCTAssertTrue(el(app, "help.email").waitForExistence(timeout: 5))
    attach(app, "Release · Get help")
    assertNoPlaceholders(app, "Get help")
    try audit(app)
    back(app)

    let delete = el(app, "profile.delete")
    XCTAssertTrue(reveal(app, delete))
    delete.tap()
    XCTAssertTrue(el(app, "delete.confirm").waitForExistence(timeout: 5))
    attach(app, "Release · Delete your account")
    assertNoPlaceholders(app, "Delete your account")
    back(app)
    el(app, "profile.close").tap()
  }

  /// Profile › Delete your account deletes it (Guideline 5.1.1(v)) and lands on Welcome.
  @MainActor
  func testDeleteYourAccountFromTheProfile() throws {
    let app = launchRelease()
    app.buttons["header.profile"].firstMatch.tap()
    let delete = el(app, "profile.delete")
    XCTAssertTrue(delete.waitForExistence(timeout: 5))
    XCTAssertTrue(reveal(app, delete))
    delete.tap()
    el(app, "delete.confirm").tap()
    let alert = app.alerts["Delete your Hasala account?"]
    XCTAssertTrue(alert.waitForExistence(timeout: 5))
    alert.buttons["Delete"].tap()
    XCTAssertTrue(el(app, "stories.getStarted").waitForExistence(timeout: 15), "Welcome did not appear")
    attach(app, "Release · Deleted")
  }

  /// Sign out from the profile ends the session and lands on Welcome.
  @MainActor
  func testSignOutFromTheProfile() throws {
    let app = launchRelease()
    app.buttons["header.profile"].firstMatch.tap()
    let signOut = el(app, "profile.signOut")
    XCTAssertTrue(signOut.waitForExistence(timeout: 5))
    XCTAssertTrue(reveal(app, signOut))
    signOut.tap()
    let alert = app.alerts["Sign out of this iPhone?"]
    XCTAssertTrue(alert.waitForExistence(timeout: 5))
    alert.buttons["Sign out"].tap()
    XCTAssertTrue(el(app, "stories.getStarted").waitForExistence(timeout: 15), "Welcome did not appear")
  }
}
