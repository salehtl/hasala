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
    XCTAssertTrue(el(app, "profile.name").waitForExistence(timeout: uiWait))
    attach(app, "Release · Profile")
    assertNoPlaceholders(app, "Profile")
    assertPersonalAccountsOnly(app, "Profile")
    assertAbsent(app, ["profile.notifications", "profile.connectGmail", "profile.faceID"], "Profile")
    assertPresent(app, ["profile.accounts", "profile.bills", "profile.rules", "profile.plan", "profile.security",
                        "profile.currency", "profile.editName", "profile.gravatar",
                        "profile.mailboxes",
                        "profile.export", "profile.privacy", "profile.help", "profile.signOut", "profile.delete",
                        "profile.buildFooter"], "Profile")
    try audit(app)

    // The bank alerts card is a button that opens Bank alerts.
    XCTAssertTrue(app.buttons["profile.bankAlerts"].exists, "the bank alerts card is not a button")
    tap(app, "profile.bankAlerts")
    XCTAssertTrue(el(app, "bankAlerts.hero").waitForExistence(timeout: uiWait), "Bank alerts did not open")
    assertNoPlaceholders(app, "Profile › Bank alerts")
    assertPersonalAccountsOnly(app, "Profile › Bank alerts")
    back(app)

    tap(app, "profile.accounts")
    XCTAssertTrue(el(app, "accounts.netWorth").waitForExistence(timeout: uiWait))
    attach(app, "Release · Accounts")
    assertNoPlaceholders(app, "Profile › Accounts")
    assertAbsent(app, ["accounts.add", "Add an account"], "Profile › Accounts")
    back(app)

    tap(app, "profile.bills")
    XCTAssertTrue(el(app, "bills.next14").waitForExistence(timeout: uiWait))
    attach(app, "Release · Recurring")
    assertNoPlaceholders(app, "Profile › Recurring")
    // "All schedules" opens a screen that doesn't exist yet: matched by its identifier,
    // since its label ("All schedules, 9") is not the text it draws.
    assertAbsent(app, ["bills.remind.axa", "bills.allSchedules"], "Profile › Recurring")
    assertPresent(app, ["bills.add"], "Profile › Recurring")
    assertNoButtons(app, ["Remind me"], "Profile › Recurring")
    tap(app, "bill.axa")
    XCTAssertTrue(el(app, "bills.detail.axa").waitForExistence(timeout: uiWait))
    attach(app, "Release · AXA Insurance")
    assertNoPlaceholders(app, "Profile › Recurring › AXA Insurance")
    assertAbsent(app, ["bills.detail.remind"], "Profile › Recurring › AXA Insurance")
    assertPresent(app, ["bills.detail.paid", "bills.detail.end", "bills.detail.manage"],
                  "Profile › Recurring › AXA Insurance")
    back(app)
    back(app)

    tap(app, "profile.rules")
    XCTAssertTrue(el(app, "rule.r-carrefour").waitForExistence(timeout: uiWait))
    assertNoPlaceholders(app, "Profile › Categories and rules")
    assertAbsent(app, ["rules.add", "rules.seeAll"], "Profile › Categories and rules")
    assertPresent(app, ["rules.segment"], "Profile › Categories and rules")
    try audit(app)
    app.buttons["Categories"].firstMatch.tap()
    XCTAssertTrue(el(app, "categories.capLine").waitForExistence(timeout: uiWait))
    attach(app, "Release · Categories")
    assertNoPlaceholders(app, "Profile › Categories")
    assertPresent(app, ["categories.add", "category.dining"], "Profile › Categories")
    try audit(app)
    back(app)

    tap(app, "profile.currency")
    XCTAssertTrue(el(app, "rates.USD").waitForExistence(timeout: uiWait))
    attach(app, "Release · Exchange rates")
    assertNoPlaceholders(app, "Profile › Exchange rates")
    assertPresent(app, ["rates.add"], "Profile › Exchange rates")
    try audit(app)
    back(app)

    tap(app, "profile.help")
    XCTAssertTrue(el(app, "help.email").waitForExistence(timeout: uiWait))
    attach(app, "Release · Get help")
    assertNoPlaceholders(app, "Get help")
    try audit(app)
    back(app)

    let footer = el(app, "profile.buildFooter")
    XCTAssertTrue(reveal(app, footer))
    XCTAssertTrue(footer.label.hasPrefix("Hasala QA · 0.3.0 ("), footer.label)
    XCTAssertTrue(footer.label.hasSuffix("never sold"), footer.label)

    tap(app, "profile.delete")
    XCTAssertTrue(el(app, "delete.confirm").waitForExistence(timeout: uiWait))
    attach(app, "Release · Delete your account")
    assertNoPlaceholders(app, "Delete your account")
    back(app)
    el(app, "profile.close").tap()
  }

  @MainActor
  func testPlanRowOpensPlan() throws {
    let app = launchRelease()
    app.buttons["header.profile"].firstMatch.tap()
    XCTAssertTrue(el(app, "profile.name").waitForExistence(timeout: uiWait))
    assertAbsent(app, ["profile.projects"], "Profile")
    XCTAssertTrue(el(app, "profile.plan").label.contains("ready to assign"))
    tap(app, "profile.plan", opening: "plan.readyToAssign")
    attach(app, "Release · Profile › Plan")
    assertNoPlaceholders(app, "Profile › Plan")
    assertPresent(app, ["plan.readyToAssign"], "Profile › Plan")
    try audit(app)
    back(app)
    XCTAssertTrue(el(app, "profile.plan").waitForExistence(timeout: uiWait))
  }

  /// With no mailbox the card says so, and it is still the way to Bank alerts, where
  /// connecting starts (the card itself offers no second button).
  @MainActor
  func testNoMailboxCardOpensBankAlerts() throws {
    let app = launchRelease("noMailbox")
    app.buttons["header.profile"].firstMatch.tap()
    XCTAssertTrue(el(app, "profile.name").waitForExistence(timeout: uiWait))
    XCTAssertTrue(el(app, "profile.bankAlerts").label.contains("Your email isn't connected"))
    attach(app, "Release · Profile · No mailbox")
    assertNoPlaceholders(app, "Profile")
    assertPersonalAccountsOnly(app, "Profile")
    assertAbsent(app, ["profile.connectGmail"], "Profile")
    tap(app, "profile.bankAlerts")
    XCTAssertTrue(el(app, "bankAlerts.hero").waitForExistence(timeout: uiWait), "Bank alerts did not open")
    assertPersonalAccountsOnly(app, "Profile › Bank alerts")
  }

  /// Profile › Delete your account deletes it (Guideline 5.1.1(v)) and lands on Welcome.
  @MainActor
  func testDeleteYourAccountFromTheProfile() throws {
    let app = launchRelease()
    app.buttons["header.profile"].firstMatch.tap()
    let delete = el(app, "profile.delete")
    XCTAssertTrue(delete.waitForExistence(timeout: uiWait))
    XCTAssertTrue(reveal(app, delete))
    delete.tap()
    el(app, "delete.confirm").tap()
    let alert = app.alerts["Delete your Hasala account?"]
    XCTAssertTrue(alert.waitForExistence(timeout: uiWait))
    alert.buttons["Delete"].tap()
    // "Confirm it's you" (Paper P2.6, spec 09 §12) asks before the passkey's Face ID.
    let confirm = el(app, "confirm.submit")
    XCTAssertTrue(confirm.waitForExistence(timeout: 10), "Confirm it's you did not ask")
    attach(app, "Release · Confirm it's you")
    confirm.tap()
    XCTAssertTrue(el(app, "stories.getStarted").waitForExistence(timeout: 15), "Welcome did not appear")
    attach(app, "Release · Deleted")
  }

  /// Sign out from the profile ends the session and lands on Welcome.
  @MainActor
  func testSignOutFromTheProfile() throws {
    let app = launchRelease()
    app.buttons["header.profile"].firstMatch.tap()
    let signOut = el(app, "profile.signOut")
    XCTAssertTrue(signOut.waitForExistence(timeout: uiWait))
    XCTAssertTrue(reveal(app, signOut))
    signOut.tap()
    let alert = app.alerts["Sign out of this iPhone?"]
    XCTAssertTrue(alert.waitForExistence(timeout: uiWait))
    // Sign-in & security's words for the same action (P4); Paper's "erased" isn't said.
    XCTAssertTrue(alert.staticTexts[
      "To come back, sign in with your passkey or your password. Hasala's data stays on this iPhone, locked to your account."
    ].exists)
    alert.buttons["Sign out"].tap()
    XCTAssertTrue(el(app, "stories.getStarted").waitForExistence(timeout: 15), "Welcome did not appear")
  }
}
