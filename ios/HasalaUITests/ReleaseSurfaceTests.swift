import XCTest

/// What a Release build shows (App Review Guideline 2.1): signup, setup, every tab and the
/// profile, with no placeholder text ("later build", "coming soon") and no control whose
/// screen isn't built, only the account actions the beta carries out
/// (`AccountCapabilities.beta`), and no copy that promises what the beta doesn't do
/// (recovery by emailed code, Gmail push, the on-device model, notifications).
///
/// The app runs the Maya mock with `-HasalaReleaseSurface`, which gives a Debug build the
/// Release surface and the mock the beta's capabilities. A Release build ignores the
/// argument and always shows that surface: `ios/scripts/test-release-surface.sh` runs these
/// tests on a Release-configuration build that links the mock.
final class ReleaseSurfaceTests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  @MainActor
  private func launch(_ scenario: String = "maya", waitForHome: Bool = true) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-HasalaScenario", scenario, "-HasalaReleaseSurface"]
    app.launch()
    if waitForHome {
      XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: 15), "Home did not appear")
    }
    return app
  }

  @MainActor
  private func el(_ app: XCUIApplication, _ id: String) -> XCUIElement {
    app.descendants(matching: .any)[id].firstMatch
  }

  /// No element on screen reads like a placeholder.
  @MainActor
  private func assertNoPlaceholders(_ app: XCUIApplication, _ screen: String, line: UInt = #line) {
    let predicate = NSPredicate(
      format: "label CONTAINS[c] 'later build' OR label CONTAINS[c] 'coming soon' OR label CONTAINS[c] 'coming in a'"
        + " OR label CONTAINS[c] 'in this build' OR label CONTAINS[c] 'in this beta' OR label CONTAINS[c] 'arrives with'"
        + " OR label CONTAINS[c] 'arrives in' OR label CONTAINS[c] 'arrive in'")
    let hits = app.descendants(matching: .any).matching(predicate).allElementsBoundByIndex.map(\.label)
    XCTAssertTrue(hits.isEmpty, "\(screen) shows placeholder text: \(hits)", line: line)
  }

  /// None of `ids` (identifiers or labels) is on screen as anything.
  @MainActor
  private func assertAbsent(_ app: XCUIApplication, _ ids: [String], _ screen: String, line: UInt = #line) {
    for id in ids {
      XCTAssertFalse(app.descendants(matching: .any)[id].exists, "\(screen) offers \(id)", line: line)
    }
  }

  /// None of `labels` is a button on screen.
  @MainActor
  private func assertNoButtons(_ app: XCUIApplication, _ labels: [String], _ screen: String, line: UInt = #line) {
    for label in labels {
      XCTAssertFalse(app.buttons[label].exists, "\(screen) has a \(label) button", line: line)
    }
  }

  @MainActor
  private func assertPresent(_ app: XCUIApplication, _ ids: [String], _ screen: String, line: UInt = #line) {
    for id in ids {
      XCTAssertTrue(el(app, id).waitForExistence(timeout: 5), "\(screen) is missing \(id)", line: line)
    }
  }

  // `reveal(_:_:)` (drag until an element is tappable) is CoreScreensTests' XCTestCase helper.

  @MainActor
  private func tap(_ app: XCUIApplication, _ id: String, timeout: TimeInterval = 10, line: UInt = #line) {
    let e = el(app, id)
    XCTAssertTrue(e.waitForExistence(timeout: timeout), "\(id) is missing", line: line)
    dragUntilHittable(app, e)
    e.tap()
  }

  @MainActor
  private func type(_ app: XCUIApplication, _ id: String, _ text: String, line: UInt = #line) {
    let e = el(app, id)
    XCTAssertTrue(e.waitForExistence(timeout: 10), "\(id) is missing", line: line)
    e.tap()
    e.typeText(text)
  }

  /// No text on screen contains any of `phrases`.
  @MainActor
  private func assertNoText(_ app: XCUIApplication, _ phrases: [String], _ screen: String, line: UInt = #line) {
    for phrase in phrases {
      let hits = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", phrase))
      XCTAssertEqual(hits.count, 0, "\(screen) says '\(phrase)'", line: line)
    }
  }

  /// Some text on screen contains `phrase`.
  @MainActor
  private func assertText(_ app: XCUIApplication, _ phrase: String, _ screen: String, line: UInt = #line) {
    let hit = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", phrase)).firstMatch
    XCTAssertTrue(hit.waitForExistence(timeout: 5), "\(screen) does not say '\(phrase)'", line: line)
  }

  @MainActor
  private func back(_ app: XCUIApplication) {
    app.navigationBars.buttons.firstMatch.tap()
  }

  // MARK: - Signup and setup

  /// Path B, as a reviewer meets it: join with a password, the 12 words, then every setup
  /// step to Home. Nothing reads like a placeholder, and nothing promises what the beta
  /// doesn't do: no recovery by emailed code, no Gmail push, no on-device model, and no
  /// notifications (the step says so, and offers no Lock Screen choice the app can't
  /// change later).
  @MainActor
  func testSignupAndSetupPromiseOnlyWhatWorks() throws {
    let app = launch("newUser", waitForHome: false)
    tap(app, "stories.getStarted", timeout: 15)
    tap(app, "welcome.join")
    assertNoPlaceholders(app, "Invite code")
    type(app, "invite.field", "ABCDEFGHIJKLMNOPQRSTUVWX")
    tap(app, "invite.continue")
    type(app, "about.name", "Maya Rahman")
    type(app, "about.email", "maya@example.com")
    assertNoPlaceholders(app, "About you")
    tap(app, "about.continue")
    type(app, "code.field", "123456")
    XCTAssertTrue(el(app, "method.password").waitForExistence(timeout: 10))
    attach(app, "Release · How do you want to sign in")
    assertNoPlaceholders(app, "Sign-in method")
    tap(app, "method.password")
    tap(app, "method.continue")
    type(app, "password.new", "copper lantern quietly 42")
    type(app, "password.confirm", "copper lantern quietly 42")
    assertNoPlaceholders(app, "Password")
    tap(app, "password.create")

    // The words: no promise of getting back in with an emailed code (C4 is not in the beta).
    XCTAssertTrue(el(app, "phrase.start").waitForExistence(timeout: 10))
    attach(app, "Release · 12 words")
    assertNoPlaceholders(app, "12 words")
    assertNoText(app, ["code we email"], "12 words")
    assertText(app, "They unlock your data on a new iPhone once you sign in there.", "12 words")
    try audit(app)
    tap(app, "phrase.start")
    tap(app, "phrase.reveal")
    tap(app, "phrase.written")
    for w in ["scissors", "category", "army", "camera"] { tap(app, "chip.\(w)") }
    tap(app, "phrase.confirm")
    tap(app, "ready.continue")

    // Bank: "Another bank?" asks for yours; nothing is "coming soon".
    XCTAssertTrue(el(app, "bank.enbd").waitForExistence(timeout: 10))
    attach(app, "Release · Bank")
    assertNoPlaceholders(app, "Bank")
    assertText(app, "Not listed? Tell us yours.", "Bank")
    try audit(app)
    tap(app, "bank.continue")

    // Gmail: new alerts are fetched when the app opens and in the background, not pushed.
    XCTAssertTrue(el(app, "gmail.connect").waitForExistence(timeout: 10))
    attach(app, "Release · Gmail")
    assertNoPlaceholders(app, "Gmail")
    assertNoText(app, ["our server is told"], "Gmail")
    assertText(app, "checks for new alerts when you open Hasala", "Gmail")
    try audit(app)
    tap(app, "gmail.connect")

    XCTAssertTrue(el(app, "scan.progress").waitForExistence(timeout: 10))
    assertNoPlaceholders(app, "First scan")
    assertNoText(app, ["on-device model"], "First scan")
    tap(app, "scan.setUpPlan")
    type(app, "income.field", "25000")
    assertNoPlaceholders(app, "Income")
    tap(app, "income.continue")
    XCTAssertTrue(el(app, "plan.use").waitForExistence(timeout: 10))
    assertNoPlaceholders(app, "Starting plan")
    tap(app, "plan.use")

    // How they were sorted: no on-device model row, since the beta doesn't use it.
    XCTAssertTrue(el(app, "result.continue").waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["268 transactions, sorted."].waitForExistence(timeout: 20))
    attach(app, "Release · Sorted")
    assertNoPlaceholders(app, "Sorted")
    assertNoText(app, ["on-device model"], "Sorted")
    tap(app, "result.continue")

    // Notifications: the step says the beta sends none yet, and offers no Lock Screen
    // choice (Profile has no Notifications row to change it later).
    XCTAssertTrue(el(app, "notifications.allow").waitForExistence(timeout: 10))
    attach(app, "Release · Notifications")
    assertNoPlaceholders(app, "Notifications")
    assertText(app, "This beta doesn't send them yet.", "Notifications")
    assertAbsent(app, ["notifications.details"], "Notifications")
    assertPresent(app, ["notifications.lockScreen", "notifications.notNow"], "Notifications")
    try audit(app)
    tap(app, "notifications.notNow")

    XCTAssertTrue(el(app, "done.home").waitForExistence(timeout: 10))
    attach(app, "Release · Done")
    assertNoPlaceholders(app, "Done")
    tap(app, "done.home")
    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: 10), "Home did not open")
    assertNoPlaceholders(app, "Home")
  }

  /// The review account's Gmail step offers the sample month, with the same honest copy.
  @MainActor
  func testTheReviewAccountsGmailStepOffersSampleData() throws {
    let app = launch("reviewAccount", waitForHome: false)
    XCTAssertTrue(el(app, "bank.enbd").waitForExistence(timeout: 15))
    assertNoPlaceholders(app, "Bank")
    tap(app, "bank.continue")
    XCTAssertTrue(el(app, "gmail.sample").waitForExistence(timeout: 10))
    attach(app, "Release · Gmail · review account")
    assertNoPlaceholders(app, "Gmail (review account)")
    assertNoText(app, ["our server is told"], "Gmail (review account)")
    assertPresent(app, ["gmail.connect"], "Gmail (review account)")
    try audit(app)
  }

  // MARK: - Tabs

  /// Home, Plan, Activity, Bills and a transaction: nothing unfinished, and every control
  /// that remains goes somewhere.
  @MainActor
  func testEveryTabShowsOnlyWhatWorks() throws {
    let app = launch()

    // Home: no bell, no "See month", "See all", "Edit" or "Add widget"; no Search tab.
    attach(app, "Release · Home")
    assertNoPlaceholders(app, "Home")
    assertAbsent(app, ["header.notifications", "home.seeMonth", "home.sampleData"], "Home")
    assertNoButtons(app, ["See all", "Edit", "Add widget", "See month"], "Home")
    let tabBar = app.tabBars.firstMatch
    XCTAssertEqual(tabBar.buttons.count, 3, "tabs: \(tabBar.buttons.allElementsBoundByIndex.map(\.label))")
    XCTAssertFalse(tabBar.buttons["Search"].exists)
    // Needs you counts the cards it draws (no "See all" list to show the rest).
    let drawn = Set(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'needsYou.'"))
      .allElementsBoundByIndex.map(\.identifier)).count
    XCTAssertGreaterThan(drawn, 0)
    XCTAssertTrue(app.descendants(matching: .any)["\(drawn) items"].exists,
                  "the Needs you badge is not \(drawn), the cards drawn")
    try audit(app)

    // Widgets without a detail screen are not buttons; the others go somewhere.
    for id in ["widget.netWorth", "widget.project.Japan trip", "widget.goal.Emergency fund"] {
      XCTAssertTrue(el(app, id).exists, "\(id) is missing")
      XCTAssertFalse(app.buttons[id].exists, "\(id) is a button with nowhere to go")
    }
    let nextBill = app.buttons["widget.nextBill"]
    XCTAssertTrue(reveal(app, nextBill))
    attach(app, "Release · Home widgets")
    assertNoPlaceholders(app, "Home widgets")
    nextBill.tap()
    XCTAssertTrue(el(app, "bills.next14").waitForExistence(timeout: 5))
    attach(app, "Release · Bills")
    assertNoPlaceholders(app, "Bills")
    assertNoButtons(app, ["Remind me"], "Bills")
    try audit(app)
    back(app)
    let pace = app.buttons["widget.budgetPace"]
    XCTAssertTrue(reveal(app, pace))
    pace.tap()
    XCTAssertTrue(el(app, "plan.readyToAssign").waitForExistence(timeout: 5))

    // Plan: Assign only, no Auto-assign; a budget row opens its month.
    attach(app, "Release · Plan")
    assertNoPlaceholders(app, "Plan")
    assertNoButtons(app, ["Auto-assign"], "Plan")
    XCTAssertTrue(app.buttons["plan.assign"].exists)
    try audit(app)
    let row = app.buttons["plan.row.dining"]
    XCTAssertTrue(reveal(app, row))
    row.tap()
    XCTAssertTrue(el(app, "category.changeBudget").waitForExistence(timeout: 5))
    assertNoPlaceholders(app, "Plan › Dining")
    back(app)

    // Activity: no "+"; a row opens its sheet.
    tabBar.buttons["Activity"].tap()
    XCTAssertTrue(el(app, "activity.count").waitForExistence(timeout: 5))
    attach(app, "Release · Activity")
    assertNoPlaceholders(app, "Activity")
    assertAbsent(app, ["header.add"], "Activity")
    try audit(app)
    let carrefour = el(app, "txn.carrefour")
    XCTAssertTrue(reveal(app, carrefour))
    carrefour.tap()
    XCTAssertTrue(el(app, "txn.merchant").waitForExistence(timeout: 5))
    attach(app, "Release · Transaction")
    assertNoPlaceholders(app, "Transaction")
    // A row read from email shows where it came from, not the sample note.
    XCTAssertTrue(el(app, "txn.rawMerchant").exists)
    assertAbsent(app, ["txn.sample"], "Transaction")
    el(app, "txn.close").tap()

    // Review: every control sorts, skips or closes.
    tabBar.buttons["Home"].tap()
    el(app, "needsYou.review").buttons["Start"].tap()
    XCTAssertTrue(el(app, "review.position").waitForExistence(timeout: 5))
    attach(app, "Release · Review")
    assertNoPlaceholders(app, "Review")
    el(app, "review.close").tap()
  }

  // MARK: - Profile

  /// The profile and every page it opens in the app: only rows that work, the beta's
  /// account actions, and support in place of the rest.
  @MainActor
  func testProfileShowsOnlyWhatWorks() throws {
    let app = launch()
    app.buttons["header.profile"].firstMatch.tap()
    XCTAssertTrue(el(app, "profile.name").waitForExistence(timeout: 5))
    attach(app, "Release · Profile")
    assertNoPlaceholders(app, "Profile")
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

    // Sign-in & security: the beta's actions, support for the rest.
    let security = el(app, "profile.security")
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
    let app = launch()
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
    let app = launch()
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

  // MARK: - Gmail after setup

  /// Gmail skipped at setup: Home offers "Connect Gmail", which runs the Gmail step and the
  /// cards in a sheet; once the cards are confirmed, Home no longer offers it. (The Profile
  /// card's button is the reconnect test's; one launch each keeps the ios job's time down.)
  @MainActor
  func testConnectGmailAfterSkippingIt() throws {
    let app = launch("gmailSkipped")
    let card = el(app, "needsYou.gmail.connect")
    XCTAssertTrue(card.waitForExistence(timeout: 10))
    attach(app, "Release · Home · Connect Gmail")
    card.buttons["Connect"].tap()
    let connect = el(app, "gmail.connect")
    XCTAssertTrue(connect.waitForExistence(timeout: 5))
    XCTAssertEqual(connect.label, "Connect Gmail")
    assertNoPlaceholders(app, "Connect Gmail")
    // Not setup: no step indicator, and Close instead of Skip.
    assertNoText(app, ["Step 2 of 4"], "Connect Gmail")
    XCTAssertEqual(el(app, "account.trailing").label, "Close")
    attach(app, "Release · Connect Gmail")
    try audit(app)
    connect.tap()
    XCTAssertTrue(el(app, "result.continue").waitForExistence(timeout: 15), "the result did not appear")
    attach(app, "Release · Connect Gmail · Result")
    tap(app, "result.continue")
    XCTAssertTrue(card.waitForNonExistence(timeout: 10), "Home still offers Connect Gmail")
  }

  /// Google wants a new sign-in: the Profile card offers "Reconnect Gmail", which is done
  /// as soon as Google and the step-up say yes.
  @MainActor
  func testReconnectGmailFromTheProfile() throws {
    let app = launch("gmailReconnect")
    XCTAssertTrue(el(app, "needsYou.gmail.reconnect").waitForExistence(timeout: 10))
    app.buttons["header.profile"].firstMatch.tap()
    XCTAssertTrue(el(app, "profile.name").waitForExistence(timeout: 5))
    XCTAssertTrue(el(app, "profile.bankAlerts").label.contains("Gmail needs reconnecting"))
    tap(app, "profile.connectGmail")
    let reconnect = el(app, "gmail.connect")
    XCTAssertTrue(reconnect.waitForExistence(timeout: 5))
    XCTAssertEqual(reconnect.label, "Reconnect Gmail")
    assertNoPlaceholders(app, "Reconnect Gmail")
    attach(app, "Release · Reconnect Gmail")
    try audit(app)
    reconnect.tap()
    assertText(app, "Gmail reconnected", "Profile")
    XCTAssertTrue(el(app, "profile.connectGmail").waitForNonExistence(timeout: 5))
    XCTAssertTrue(el(app, "profile.bankAlerts").label.contains("Bank alerts are working"))
  }

  // MARK: - Sample data and sign-in

  /// The App Review demo account: Home says "Sample data", and a sample row's sheet says
  /// there's no email behind it.
  @MainActor
  func testTheReviewAccountShowsSampleData() throws {
    let app = launch("mayaSample")
    XCTAssertTrue(el(app, "home.sampleData").waitForExistence(timeout: 5))
    attach(app, "Release · Home · Sample data")
    try audit(app)
    app.tabBars.firstMatch.buttons["Activity"].tap()
    let carrefour = el(app, "txn.carrefour")
    XCTAssertTrue(carrefour.waitForExistence(timeout: 5))
    XCTAssertTrue(reveal(app, carrefour))
    carrefour.tap()
    let note = el(app, "txn.sample")
    XCTAssertTrue(note.waitForExistence(timeout: 5))
    XCTAssertEqual(note.label, "This is sample data. There's no email behind it.")
    assertAbsent(app, ["txn.rawMerchant"], "Sample transaction")
    attach(app, "Release · Transaction · Sample data")
    try audit(app)
  }

  /// Sign in offers the passkey and the password; "Forgot password?" and recovery become
  /// a support email link.
  @MainActor
  func testSignInOffersSupportInsteadOfRecovery() throws {
    let app = launch("signInPassword", waitForHome: false)
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
}
