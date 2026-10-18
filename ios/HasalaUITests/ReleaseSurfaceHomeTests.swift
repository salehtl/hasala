import XCTest

/// Home on the Release surface: no control without a screen behind it, and every control
/// that remains goes somewhere. The bell is there (its "Needs a look" comes from the ledger,
/// plan B7.6 decision 12); "Earlier" and "Notification settings" are not (no history, no
/// in-app setting behind them yet).
final class ReleaseSurfaceHomeTests: ReleaseSurfaceTestCase {
  @MainActor
  func testHomeShowsOnlyWhatWorks() throws {
    let app = launchRelease()

    // The hero and the bell; no "See month", "Edit" or "Add widget", no Needs-you rail.
    attach(app, "Release · Home")
    assertNoPlaceholders(app, "Home")
    assertPersonalAccountsOnly(app, "Home")
    XCTAssertTrue(el(app, "home.hero.left").waitForLabel("AED 10,288.34"))
    assertAbsent(app, ["home.seeMonth", "home.sampleData", "home.editWidgets", "Needs you"], "Home")
    assertNoButtons(app, ["See all", "Edit", "Add widget", "See month"], "Home")
    XCTAssertEqual(
      app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'needsYou.'")).count, 0,
      "Home still draws Needs-you cards")
    // The period pill names the month; it is not a control until the picker exists.
    XCTAssertTrue(el(app, "Period, October 2026").exists)
    XCTAssertFalse(app.buttons["Period, October 2026"].exists, "the period pill is a button with nowhere to go")
    try audit(app)

    // The bell counts what needs a look and opens it.
    let bell = app.buttons["header.notifications"].firstMatch
    XCTAssertTrue(bell.exists, "Home has no bell")
    XCTAssertEqual(bell.label, "Notifications, 4 new")
    bell.tap()
    XCTAssertTrue(el(app, "bell.sheet").waitForExistence(timeout: uiWait))
    assertText(app, "Needs a look", "Notifications")
    assertPresent(app, ["bell.row.review", "bell.row.bill.axa", "bell.row.found.apple-bill", "bell.row.price.du"],
                  "Notifications")
    assertAbsent(app, ["Earlier", "bell.settings", "Notification settings"], "Notifications")
    assertNoPlaceholders(app, "Notifications")
    assertPersonalAccountsOnly(app, "Notifications")
    attach(app, "Release · Notifications")
    try audit(app)
    // A row opens its screen: du's new price is in Bills.
    tap(app, "bell.row.price.du")
    XCTAssertTrue(el(app, "bills.next14").waitForExistence(timeout: uiWait))
    assertNoPlaceholders(app, "Recurring")
    assertAbsent(app, ["bills.allSchedules"], "Recurring")
    back(app)
    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: uiWait))

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
    XCTAssertTrue(el(app, "bills.next14").waitForExistence(timeout: uiWait))
    attach(app, "Release · Recurring")
    assertNoPlaceholders(app, "Recurring")
    assertAbsent(app, ["bills.allSchedules"], "Home › Recurring")
    assertNoButtons(app, ["Remind me"], "Recurring")
    try audit(app)
    back(app)
    let pace = app.buttons["widget.budgetPace"]
    XCTAssertTrue(reveal(app, pace))
    pace.tap()
    XCTAssertTrue(el(app, "plan.readyToAssign").waitForExistence(timeout: uiWait))
  }

  /// With nothing to look at the bell has no badge and the sheet says so; mail's row
  /// promises no work or school account.
  @MainActor
  func testAllClearAndTheMailRow() throws {
    // All clear: the caught-up queue, AXA paid, du accepted, the found bill dismissed.
    var app = launchRelease("mayaCaughtUp", waitForHome: false, screen: "home.allClear")
    XCTAssertTrue(el(app, "bell.allClear").waitForExistence(timeout: 15))
    assertText(app, "Nothing needs you", "Notifications · all clear")
    assertAbsent(app, ["Needs a look", "Earlier", "bell.settings"], "Notifications · all clear")
    attach(app, "Release · Notifications · all clear")
    try audit(app)
    el(app, "bell.close").tap()
    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: uiWait))
    XCTAssertEqual(app.buttons["header.notifications"].firstMatch.label, "Notifications")

    // No mailbox: the bell's last row asks to connect it and opens Bank alerts in Profile.
    app = launchRelease("gmailSkipped")
    let bell = app.buttons["header.notifications"].firstMatch
    XCTAssertEqual(bell.label, "Notifications, 5 new")
    bell.tap()
    tap(app, "bell.row.mail.connect")
    XCTAssertTrue(el(app, "bankAlerts.hero").waitForExistence(timeout: 10), "Bank alerts did not open")
    assertPersonalAccountsOnly(app, "Bank alerts from the bell")
    assertNoPlaceholders(app, "Bank alerts from the bell")
  }
}
