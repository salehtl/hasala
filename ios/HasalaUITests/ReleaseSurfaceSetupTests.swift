import XCTest

/// Setup on the Release surface: Gmail and Outlook (personal Microsoft accounts only, one
/// mailbox), then Home's Finish setting up, with nothing "coming soon" and no notifications
/// promised (the sheet says so, and offers no Lock Screen choice the app can't change later).
final class ReleaseSurfaceSetupTests: ReleaseSurfaceTestCase {
  @MainActor
  func testSetupPromisesOnlyWhatWorks() throws {
    let app = launchRelease("setupBank", waitForHome: false)

    // Bank alerts and Gmail on one screen: "Bank not listed?" asks for yours and points to
    // Skip; nothing is "coming soon"; what Google will show is said before it shows.
    XCTAssertTrue(el(app, "bank.enbd").waitForExistence(timeout: 15))
    let connect = el(app, "mail.connect.gmail")
    XCTAssertTrue(connect.waitForExistence(timeout: 10))
    attach(app, "Release · Bank alerts and Gmail")
    assertNoPlaceholders(app, "Bank")
    assertPersonalAccountsOnly(app, "Bank")
    assertText(app, "Meanwhile, Skip lets you add spending by hand.", "Bank")
    assertText(app, "View your email messages and settings", "Bank")
    assertPresent(app, ["mail.googleBriefing", "mail.change", "bank.howTo"], "Bank")
    assertAbsent(app, ["setup.chooseEmail", "mail.choose.other"], "Bank")
    assertNoText(app, ["our server is told"], "Bank")
    try audit(app)

    // "Use Outlook": Choose your email, which offers one mailbox, not a second.
    tap(app, "mail.change")
    XCTAssertTrue(el(app, "setup.chooseEmail").waitForExistence(timeout: 10), "Use Outlook did not open Choose your email")
    assertPresent(app, ["mail.choose.gmail", "mail.choose.outlook"], "Choose your email")
    assertText(app, "Outlook.com, Hotmail or Live", "Choose your email")
    assertText(app, "You can change it later in Profile › Bank alerts.", "Choose your email")
    assertNoText(app, ["add another mailbox"], "Choose your email")
    assertNoPlaceholders(app, "Choose your email")
    assertPersonalAccountsOnly(app, "Choose your email")
    attach(app, "Release · Choose your email")
    try audit(app, overSheet: true)
    tap(app, "mail.choose.gmail")

    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: 10), "Home did not open")
    XCTAssertTrue(el(app, "home.finish.plan").waitForExistence(timeout: uiWait), "Release has no Finish setting up")
    attach(app, "Release · Home · Finish setting up")
    assertNoPlaceholders(app, "Home")
    assertPersonalAccountsOnly(app, "Home")
    assertAbsent(app, ["done.home", "result.continue"], "Home")
    try audit(app)

    tap(app, "home.finish.plan")
    for d in "25000" { tap(app, "keypad.\(d)") }
    assertNoPlaceholders(app, "Income")
    assertPersonalAccountsOnly(app, "Income")
    tap(app, "income.continue")
    XCTAssertTrue(el(app, "plan.use").waitForExistence(timeout: 10))
    assertNoPlaceholders(app, "Starting plan")
    tap(app, "plan.use")
    XCTAssertTrue(el(app, "home.finish.plan").waitForNonExistence(timeout: uiWait))

    // Notifications, once the alerts are read: the sheet says the beta sends none yet, and
    // offers no Lock Screen choice (Profile has no Notifications row to change it later).
    let note = el(app, "home.finish.notifications")
    XCTAssertTrue(note.waitForExistence(timeout: uiWait))
    let deadline = Date().addingTimeInterval(30)
    while !note.isEnabled, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.25)) }
    XCTAssertTrue(note.isEnabled, "notifications weren't offered after the import")
    note.tap()
    XCTAssertTrue(el(app, "notifications.allow").waitForExistence(timeout: 10))
    attach(app, "Release · Notifications")
    assertNoPlaceholders(app, "Notifications")
    assertText(app, "This beta doesn't send them yet.", "Notifications")
    assertAbsent(app, ["notifications.details"], "Notifications")
    assertPresent(app, ["notifications.lockScreen", "notifications.notNow"], "Notifications")
    try audit(app, overSheet: true)
    tap(app, "notifications.notNow")
    XCTAssertTrue(el(app, "home.finish").waitForNonExistence(timeout: uiWait), "Finish setting up stayed")
    assertNoPlaceholders(app, "Home")
  }

  @MainActor
  func testNoBankAlertsYetOnHome() throws {
    let app = launchRelease("noAlerts")
    let item = el(app, "home.finish.bankAlerts")
    XCTAssertTrue(item.waitForExistence(timeout: uiWait), "Release does not say no bank alerts were found")
    assertNoPlaceholders(app, "Home")
    try audit(app)
    item.tap()
    XCTAssertTrue(el(app, "noAlerts.checkAgain").waitForExistence(timeout: uiWait))
    assertPresent(app, ["noAlerts.howTo.enbd", "noAlerts.howTo.dib", "noAlerts.howTo.adib", "noAlerts.close"],
                  "No bank alerts yet")
    assertNoPlaceholders(app, "No bank alerts yet")
    assertPersonalAccountsOnly(app, "No bank alerts yet")
    attach(app, "Release · No bank alerts yet")
    try audit(app, overSheet: true)
    tap(app, "noAlerts.close")
    XCTAssertTrue(item.waitForExistence(timeout: uiWait))
  }

  /// The review account's email step offers the sample month, with the same honest copy.
  @MainActor
  func testTheReviewAccountsEmailStepOffersSampleData() throws {
    let app = launchRelease("reviewAccount", waitForHome: false)
    XCTAssertTrue(el(app, "bank.enbd").waitForExistence(timeout: 15))
    assertNoPlaceholders(app, "Bank")
    XCTAssertTrue(el(app, "mail.sample").waitForExistence(timeout: 10))
    assertText(app, "look around with sample data meanwhile", "Bank (review account)")
    attach(app, "Release · Gmail · review account")
    assertNoPlaceholders(app, "Gmail (review account)")
    assertPersonalAccountsOnly(app, "Gmail (review account)")
    assertNoText(app, ["our server is told"], "Gmail (review account)")
    assertPresent(app, ["mail.connect.gmail"], "Gmail (review account)")
    try audit(app)
    tap(app, "mail.sample")
    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: 10), "the sample didn't go on")
  }

  /// Outlook in setup: the step says only personal Microsoft accounts work; Use Outlook ›
  /// Choose your email › Outlook connects it, and Home opens.
  @MainActor
  func testSetupConnectsOutlook() throws {
    var app = launchRelease("setupEmail", waitForHome: false, screen: "mail.connectOutlook")
    let connect = el(app, "mail.connect.outlook")
    XCTAssertTrue(connect.waitForExistence(timeout: 30))
    XCTAssertEqual(connect.label, "Continue with Microsoft")
    XCTAssertTrue(el(app, "mail.provider").label.contains("Outlook: personal Microsoft accounts only."))
    assertAbsent(app, ["mail.googleBriefing"], "Outlook")
    assertNoPlaceholders(app, "Outlook")
    assertPersonalAccountsOnly(app, "Outlook")
    assertNoText(app, ["our server is told"], "Outlook")
    attach(app, "Release · Outlook")
    try audit(app)

    app = launchRelease("setupBank", waitForHome: false)
    tap(app, "mail.change", timeout: 15)
    let outlook = el(app, "mail.choose.outlook")
    XCTAssertTrue(outlook.waitForExistence(timeout: 10), "setup did not offer Choose your email")
    outlook.tap()
    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: 15), "the pick did not connect Outlook")
    assertPersonalAccountsOnly(app, "Home")
  }

  @MainActor
  func testBankTextsStayOffOnTheReleaseSurface() throws {
    let setup = launchRelease("setupTexts", waitForHome: false)
    XCTAssertTrue(el(setup, "bank.enbd").waitForExistence(timeout: 15), "the bank step is missing")
    assertAbsent(setup, ["source.texts", "source.email"], "Bank")
    assertText(setup, "Alerts must come by email, not only SMS.", "Bank")
    setup.terminate()

    let review = launchRelease("textsWorking", waitForHome: false, screen: "review.texts")
    XCTAssertTrue(el(review, "review.tab.count").waitForExistence(timeout: 15), "Review did not open")
    assertAbsent(review, ["review.tab.pasteText"], "Review")
    review.terminate()

    let alerts = launchRelease("textsWorking", waitForHome: false, screen: "bankAlerts.texts")
    XCTAssertTrue(el(alerts, "bankAlerts.status").waitForExistence(timeout: 15), "Bank alerts did not open")
    assertAbsent(alerts, ["bankAlerts.texts.automation", "bankAlerts.useTexts", "bankAlerts.texts.useEmail"], "Bank alerts")
  }
}
