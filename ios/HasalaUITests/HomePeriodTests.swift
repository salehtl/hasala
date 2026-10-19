import XCTest

final class HomePeriodTests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  @MainActor
  func testThePillPicksAMonthOrARangeAndScopesHome() throws {
    let app = launch(scenario: "maya", motion: "off")
    let hero = el(app, "home.hero.left")
    XCTAssertTrue(hero.waitForLabel("AED 11,115.62"), hero.label)
    XCTAssertFalse(el(app, "home.backToThisMonth").exists)

    tap(app, "home.period", opening: "period.sheet")
    XCTAssertTrue(app.buttons["period.preset.thisMonth"].isSelected)
    XCTAssertEqual(el(app, "period.hint").label, "Tap a month, or two for a range.")
    XCTAssertFalse(app.buttons["period.month.2026-11"].isEnabled)
    XCTAssertFalse(app.buttons["period.nextYear"].isEnabled)
    attach(app, "Home · Period picker")
    try audit(app, overSheet: true)

    tap(app, "period.month.2026-08")
    tap(app, "period.month.2026-10")
    XCTAssertTrue(app.buttons["period.preset.last3Months"].isSelected)
    XCTAssertEqual(el(app, "period.hint").label, "Aug to Oct. Tap a month to start again.")
    XCTAssertEqual(app.buttons["period.show"].label, "Show Aug – Oct 2026")
    attach(app, "Home · Period picker · Range")
    tap(app, "period.show")

    XCTAssertTrue(hero.waitForLabel("AED 48,811.32"), hero.label)
    XCTAssertEqual(app.buttons["home.period"].label, "Period, Aug – Oct 2026")
    XCTAssertTrue(el(app, "home.hero.months").exists)
    XCTAssertTrue(el(app, "home.aboutNow.nextBill").exists)
    XCTAssertFalse(el(app, "widget.budgetPace").exists)
    attach(app, "Home · Last 3 months")
    try audit(app)

    tap(app, "home.period", opening: "period.sheet")
    tap(app, "period.preset.lastMonth")
    tap(app, "period.show")
    XCTAssertTrue(hero.waitForLabel("AED 18,412.60"), hero.label)
    XCTAssertTrue(app.staticTexts["September"].exists)
    XCTAssertTrue(el(app, "widget.budgetPace").exists)
    attach(app, "Home · September")
    try audit(app)

    tap(app, "home.backToThisMonth")
    XCTAssertTrue(hero.waitForLabel("AED 11,115.62"), hero.label)
    XCTAssertTrue(app.staticTexts["Your widgets"].exists)
  }

  @MainActor
  func testNotCountedNamesTheProjectAndOpensIt() throws {
    let app = launch(scenario: "maya", motion: "off")
    XCTAssertTrue(el(app, "home.hero.left").waitForLabel("AED 11,115.62"))
    XCTAssertFalse(el(app, "home.hero.notCounted").exists)
    tap(app, "home.period", opening: "period.sheet")
    tap(app, "period.preset.lastMonth")
    tap(app, "period.show")
    let line = app.buttons["home.hero.notCounted"]
    XCTAssertTrue(line.waitForExistence(timeout: uiWait))
    XCTAssertEqual(line.label, "Not counted: AED 4,860.00 on Japan trip")
    attach(app, "Home · September · Not counted")
    try audit(app)
    line.tap()
    XCTAssertTrue(el(app, "project.hero").waitForExistence(timeout: uiWait))
    XCTAssertEqual(app.tabBars.firstMatch.buttons["Plan"].isSelected, true)
  }

  @MainActor
  func testNotCountedAtLargeTextSizes() throws {
    let app = launch(
      scenario: "maya", motion: "off",
      arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"])
    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: 15))
    tap(app, "home.period", opening: "period.sheet")
    tap(app, "period.preset.lastMonth")
    tap(app, "period.show")
    let line = app.buttons["home.hero.notCounted"]
    XCTAssertTrue(line.waitForExistence(timeout: uiWait))
    XCTAssertTrue(reveal(app, line))
    XCTAssertEqual(line.label, "Not counted: AED 4,860.00 on Japan trip")
    attach(app, "AX3 · Home · Not counted")
    try audit(app, atLargeText: true)
    line.tap()
    XCTAssertTrue(el(app, "project.hero").waitForExistence(timeout: uiWait))
  }

  @MainActor
  func testHomesRangeScopesActivityAndReview() throws {
    let app = launch(scenario: "mayaRange", motion: "off")
    tap(app, "home.period", opening: "period.sheet")
    tap(app, "period.month.2026-08")
    tap(app, "period.month.2026-10")
    tap(app, "period.show")
    XCTAssertTrue(app.buttons["home.period"].waitForLabel("Period, Aug – Oct 2026"))

    let tabBar = app.tabBars.firstMatch
    tabBar.buttons["Activity"].tap()
    let pill = app.buttons["activity.period"]
    XCTAssertTrue(pill.waitForExistence(timeout: uiWait))
    XCTAssertEqual(pill.label, "Period, Aug – Oct 2026")
    XCTAssertTrue(el(app, "activity.backToThisMonth").exists)
    XCTAssertTrue(app.buttons["activity.chip.toReview"].label.contains("9"), app.buttons["activity.chip.toReview"].label)
    attach(app, "Activity · Aug – Oct")
    try audit(app)
    let august = el(app, "txn.h-bounce-8")
    for _ in 0..<40 where !august.exists {
      app.swipeUp(velocity: .fast)
    }
    XCTAssertTrue(august.waitForExistence(timeout: uiWait))
    XCTAssertTrue(el(app, "txn.h-rent-9").exists || el(app, "txn.h-salary-8").exists)

    tabBar.buttons["Review"].tap()
    let count = el(app, "review.tab.count")
    XCTAssertTrue(count.waitForLabel("9 to sort · about 2 minutes"), count.label)
    XCTAssertTrue(el(app, "review.tab.row.aug-corner-shop").waitForExistence(timeout: uiWait))
    XCTAssertTrue(el(app, "review.tab.row.sep-steam").exists)
    XCTAssertTrue(el(app, "review.tab.row.aug-talabat-copy").exists)
    attach(app, "Review · Aug – Oct")

    tabBar.buttons["Activity"].tap()
    app.swipeDown(velocity: .fast)
    for _ in 0..<40 where !el(app, "activity.backToThisMonth").isHittable {
      app.swipeDown(velocity: .fast)
    }
    tap(app, "activity.backToThisMonth")
    XCTAssertTrue(pill.waitForLabel("Period, October 2026"))
    XCTAssertTrue(el(app, "activity.count").waitForLabel("26 transactions this month"))
    tabBar.buttons["Home"].tap()
    XCTAssertTrue(app.buttons["home.period"].waitForLabel("Period, October 2026"))
    tabBar.buttons["Review"].tap()
    XCTAssertTrue(el(app, "review.tab.count").waitForLabel("6 to sort · about a minute"))
  }
}
