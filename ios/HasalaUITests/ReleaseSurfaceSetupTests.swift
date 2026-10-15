import XCTest

/// Setup on the Release surface: Gmail only (no chooser, no Outlook or Microsoft), nothing
/// "coming soon", no Gmail push, no on-device model and no notifications promised (the step
/// says so, and offers no Lock Screen choice the app can't change later).
final class ReleaseSurfaceSetupTests: ReleaseSurfaceTestCase {
  @MainActor
  func testSetupPromisesOnlyWhatWorks() throws {
    let app = launchRelease("setupBank", waitForHome: false)

    // Bank: "Another bank?" asks for yours; nothing is "coming soon".
    XCTAssertTrue(el(app, "bank.enbd").waitForExistence(timeout: 15))
    attach(app, "Release · Bank")
    assertNoPlaceholders(app, "Bank")
    assertNoOutlook(app, "Bank")
    assertText(app, "Not listed? Tell us yours.", "Bank")
    try audit(app)
    tap(app, "bank.continue")

    // One provider: straight to Gmail's screen, no chooser. New alerts are fetched when the
    // app opens and in the background, not pushed.
    let connect = el(app, "mail.connect.gmail")
    XCTAssertTrue(connect.waitForExistence(timeout: 10))
    assertAbsent(app, ["setup.chooseEmail", "mail.choose.outlook", "mail.connect.outlook"], "Gmail")
    attach(app, "Release · Gmail")
    assertNoPlaceholders(app, "Gmail")
    assertNoOutlook(app, "Gmail")
    assertNoText(app, ["our server is told"], "Gmail")
    assertText(app, "checks for new alerts when you open Hasala", "Gmail")
    try audit(app)
    connect.tap()

    XCTAssertTrue(el(app, "scan.progress").waitForExistence(timeout: 10))
    attach(app, "Release · First scan")
    assertNoPlaceholders(app, "First scan")
    assertNoOutlook(app, "First scan")
    assertNoText(app, ["on-device model"], "First scan")
    tap(app, "scan.setUpPlan")
    for d in "25000" { tap(app, "keypad.\(d)") }
    assertNoPlaceholders(app, "Income")
    assertNoOutlook(app, "Income")
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
    assertNoOutlook(app, "Done")
    tap(app, "done.home")
    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: 10), "Home did not open")
    assertNoPlaceholders(app, "Home")
  }

  /// The review account's email step offers the sample month, with the same honest copy.
  @MainActor
  func testTheReviewAccountsEmailStepOffersSampleData() throws {
    let app = launchRelease("reviewAccount", waitForHome: false)
    XCTAssertTrue(el(app, "bank.enbd").waitForExistence(timeout: 15))
    assertNoPlaceholders(app, "Bank")
    tap(app, "bank.continue")
    XCTAssertTrue(el(app, "mail.sample").waitForExistence(timeout: 10))
    attach(app, "Release · Gmail · review account")
    assertNoPlaceholders(app, "Gmail (review account)")
    assertNoOutlook(app, "Gmail (review account)")
    assertNoText(app, ["our server is told"], "Gmail (review account)")
    assertPresent(app, ["mail.connect.gmail"], "Gmail (review account)")
    try audit(app)
    tap(app, "mail.sample")
    XCTAssertTrue(el(app, "notifications.allow").waitForExistence(timeout: 10), "the sample didn't go on")
  }
}
