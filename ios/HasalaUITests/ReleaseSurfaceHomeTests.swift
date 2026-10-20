import XCTest

/// Home on the Release surface: no control without a screen behind it, and every control
/// that remains goes somewhere. The bell is there (its "Needs a look" comes from the ledger,
/// plan B7.6 decision 12); "Earlier" and "Notification settings" are not (no history, no
/// in-app setting behind them yet).
final class ReleaseSurfaceHomeTests: ReleaseSurfaceTestCase {
  @MainActor
  func testHomeShowsOnlyWhatWorks() throws {
    let app = launchRelease()

    // The hero, its Insights link and the bell; no Needs-you rail. "Edit" and "Add widget"
    // arrange Home in every build.
    attach(app, "Release · Home")
    assertNoPlaceholders(app, "Home")
    assertPersonalAccountsOnly(app, "Home")
    XCTAssertTrue(el(app, "home.hero.left").waitForLabel("AED 11,115.62"))
    assertAbsent(app, ["home.seeMonth", "home.sampleData", "Needs you"], "Home")
    assertNoButtons(app, ["See all", "See month"], "Home")
    assertPresent(app, ["home.insights", "home.editWidgets", "home.addWidget"], "Home")
    XCTAssertEqual(
      app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'needsYou.'")).count, 0,
      "Home still draws Needs-you cards")
    try audit(app)
    tap(app, "home.period", opening: "period.sheet")
    assertNoPlaceholders(app, "Period")
    tap(app, "period.close")
    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: uiWait))

    // The bell counts what needs a look and opens it.
    let bell = app.buttons["header.notifications"].firstMatch
    XCTAssertTrue(bell.exists, "Home has no bell")
    XCTAssertEqual(bell.label, "Notifications, 4 need a look")
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
    // A row opens its screen: du's new price opens du, with Accept new amount.
    tap(app, "bell.row.price.du")
    XCTAssertTrue(el(app, "bills.detail.accept").waitForExistence(timeout: uiWait))
    assertNoPlaceholders(app, "du")
    back(app)
    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: uiWait))

    // Widgets without a detail screen are not buttons; the others go somewhere.
    for id in ["widget.netWorth", "widget.goal.emergency"] {
      XCTAssertTrue(el(app, id).exists, "\(id) is missing")
      XCTAssertFalse(app.buttons[id].exists, "\(id) is a button with nowhere to go")
    }
    let japan = app.buttons["widget.project.japan"]
    XCTAssertTrue(reveal(app, japan))
    attach(app, "Release · Home project widget")
    japan.tap()
    XCTAssertTrue(el(app, "project.hero").waitForExistence(timeout: uiWait))
    assertNoPlaceholders(app, "Project")
    back(app)
    app.tabBars.firstMatch.buttons["Home"].tap()
    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: uiWait))
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

  @MainActor
  func testNotCountedOpensTheProject() throws {
    let app = launchRelease()
    XCTAssertFalse(el(app, "home.hero.notCounted").exists)
    tap(app, "home.period", opening: "period.sheet")
    tap(app, "period.preset.lastMonth")
    tap(app, "period.show")
    let line = app.buttons["home.hero.notCounted"]
    XCTAssertTrue(line.waitForExistence(timeout: uiWait), "the not-counted line is not a button")
    XCTAssertEqual(line.label, "Not counted: AED 4,860.00 on Japan trip")
    attach(app, "Release · Home · Not counted")
    assertNoPlaceholders(app, "Home · September")
    XCTAssertTrue(reveal(app, line))
    line.tap()
    XCTAssertTrue(el(app, "project.hero").waitForExistence(timeout: uiWait))
    assertNoPlaceholders(app, "Project")
  }

  @MainActor
  func testTheWidgetGalleryOffersWhatWorks() throws {
    let app = launchRelease()
    tap(app, "home.addWidget", opening: "gallery.sheet")
    assertNoPlaceholders(app, "Add a widget")
    for kind in ["spentSoFar", "budgetPace", "categoryWatch", "nextBill", "netWorth", "comingUp", "project", "goal",
                 "toReview", "today"] {
      XCTAssertTrue(el(app, "gallery.\(kind)").exists, "gallery.\(kind) is missing")
    }
    attach(app, "Release · Add a widget")
    try audit(app, overSheet: true)
    tap(app, "gallery.comingUp")
    XCTAssertTrue(el(app, "gallery.sheet").waitForNonExistence(timeout: uiWait))
    let coming = app.buttons["widget.comingUp"]
    XCTAssertTrue(reveal(app, coming))
    coming.tap()
    XCTAssertTrue(el(app, "bills.next14").waitForExistence(timeout: uiWait))
  }

  @MainActor
  func testTheBellIsOnEveryTab() throws {
    let app = launchRelease()
    let tabBar = app.tabBars.firstMatch
    let bell = app.buttons["header.notifications"].firstMatch
    for (tab, id) in [("Plan", "plan.readyToAssign"), ("Review", "review.tab.count"), ("Activity", "activity.count")] {
      tabBar.buttons[tab].tap()
      XCTAssertTrue(el(app, id).waitForExistence(timeout: uiWait))
      XCTAssertTrue(bell.isHittable, "\(tab) has no bell")
      XCTAssertEqual(bell.label, "Notifications, 4 need a look")
      attach(app, "Release · Bell · \(tab)")
    }
    XCTAssertTrue(app.buttons["header.search"].firstMatch.isHittable, "Activity has no search")
    XCTAssertTrue(tabBar.buttons["Add a transaction"].exists, "Activity has no add button")
    bell.tap()
    XCTAssertTrue(el(app, "bell.sheet").waitForExistence(timeout: uiWait))
    assertAbsent(app, ["Earlier", "bell.settings"], "Notifications from Activity")
    try audit(app)
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
    XCTAssertEqual(bell.label, "Notifications, 5 need a look")
    bell.tap()
    tap(app, "bell.row.mail.connect")
    XCTAssertTrue(el(app, "bankAlerts.hero").waitForExistence(timeout: 10), "Bank alerts did not open")
    assertPersonalAccountsOnly(app, "Bank alerts from the bell")
    assertNoPlaceholders(app, "Bank alerts from the bell")
  }
}
