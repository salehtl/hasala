import XCTest

/// The profile on the Release surface: only rows that work, the beta's account actions,
/// and support in place of the rest.
final class ReleaseSurfaceProfileTests: ReleaseSurfaceTestCase {
  /// The profile and every page it opens in the app (Sign-in & security is
  /// `ReleaseSurfaceSignInTests`', Bank alerts `ReleaseSurfaceMailboxTests`').
  @MainActor
  func testProfileShowsOnlyWhatWorks() throws {
    let app = launchRelease()
    app.buttons["header.profile"].firstMatch.tap()
    XCTAssertTrue(el(app, "profile.name").waitForExistence(timeout: 5))
    attach(app, "Release · Profile")
    assertNoPlaceholders(app, "Profile")
    assertNoOutlook(app, "Profile")
    assertAbsent(app, ["profile.notifications", "profile.faceID", "profile.connectGmail"], "Profile")
    assertPresent(app, ["profile.accounts", "profile.bills", "profile.rules", "profile.projects", "profile.security",
                        "profile.export", "profile.privacy", "profile.help", "profile.signOut", "profile.delete",
                        "profile.buildFooter"], "Profile")
    try audit(app)

    // The bank alerts card is a button that opens Bank alerts.
    XCTAssertTrue(app.buttons["profile.bankAlerts"].exists, "the bank alerts card is not a button")
    tap(app, "profile.bankAlerts")
    XCTAssertTrue(el(app, "bankAlerts.hero").waitForExistence(timeout: 5), "Bank alerts did not open")
    assertNoPlaceholders(app, "Profile › Bank alerts")
    assertNoOutlook(app, "Profile › Bank alerts")
    back(app)

    tap(app, "profile.accounts")
    XCTAssertTrue(el(app, "accounts.netWorth").waitForExistence(timeout: 5))
    attach(app, "Release · Accounts")
    assertNoPlaceholders(app, "Profile › Accounts")
    assertAbsent(app, ["accounts.add", "Add an account"], "Profile › Accounts")
    back(app)

    tap(app, "profile.bills")
    XCTAssertTrue(el(app, "bills.next14").waitForExistence(timeout: 5))
    attach(app, "Release · Bills")
    assertNoPlaceholders(app, "Profile › Bills")
    assertAbsent(app, ["bills.remind.axa", "Add a bill", "All schedules · 9"], "Profile › Bills")
    assertNoButtons(app, ["Remind me"], "Profile › Bills")
    tap(app, "bill.axa")
    XCTAssertTrue(el(app, "bills.detail.axa").waitForExistence(timeout: 5))
    attach(app, "Release · AXA Insurance")
    assertNoPlaceholders(app, "Profile › Bills › AXA Insurance")
    assertAbsent(app, ["bills.detail.remind"], "Profile › Bills › AXA Insurance")
    assertPresent(app, ["bills.detail.paid", "bills.detail.stop"], "Profile › Bills › AXA Insurance")
    back(app)
    back(app)

    tap(app, "profile.rules")
    XCTAssertTrue(el(app, "rule.r-carrefour").waitForExistence(timeout: 5))
    assertNoPlaceholders(app, "Profile › Categories and rules")
    assertAbsent(app, ["rules.segment", "rules.add", "rules.seeAll"], "Profile › Categories and rules")
    try audit(app)
    back(app)

    tap(app, "profile.help")
    XCTAssertTrue(el(app, "help.email").waitForExistence(timeout: 5))
    attach(app, "Release · Get help")
    assertNoPlaceholders(app, "Get help")
    try audit(app)
    back(app)

    let footer = el(app, "profile.buildFooter")
    XCTAssertTrue(reveal(app, footer))
    XCTAssertTrue(footer.label.hasPrefix("Hasala QA · 0.2.0 ("), footer.label)
    XCTAssertTrue(footer.label.hasSuffix("never sold"), footer.label)

    tap(app, "profile.delete")
    XCTAssertTrue(el(app, "delete.confirm").waitForExistence(timeout: 5))
    attach(app, "Release · Delete your account")
    assertNoPlaceholders(app, "Delete your account")
    back(app)
    el(app, "profile.close").tap()
  }

  /// With no mailbox the card says so, and it is still the way to Bank alerts, where
  /// connecting starts (the card itself offers no second button).
  @MainActor
  func testNoMailboxCardOpensBankAlerts() throws {
    let app = launchRelease("noMailbox")
    app.buttons["header.profile"].firstMatch.tap()
    XCTAssertTrue(el(app, "profile.name").waitForExistence(timeout: 5))
    XCTAssertTrue(el(app, "profile.bankAlerts").label.contains("Your email isn't connected"))
    attach(app, "Release · Profile · No mailbox")
    assertNoPlaceholders(app, "Profile")
    assertNoOutlook(app, "Profile")
    assertAbsent(app, ["profile.connectGmail"], "Profile")
    tap(app, "profile.bankAlerts")
    XCTAssertTrue(el(app, "bankAlerts.hero").waitForExistence(timeout: 5), "Bank alerts did not open")
    assertNoOutlook(app, "Profile › Bank alerts")
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
    // Sign-in & security's words for the same action (P4); Paper's "erased" isn't said.
    XCTAssertTrue(alert.staticTexts[
      "To come back, sign in with your passkey or your password. Hasala's data stays on this iPhone, locked to your account."
    ].exists)
    alert.buttons["Sign out"].tap()
    XCTAssertTrue(el(app, "stories.getStarted").waitForExistence(timeout: 15), "Welcome did not appear")
  }
}
