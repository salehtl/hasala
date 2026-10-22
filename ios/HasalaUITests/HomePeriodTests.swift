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
    XCTAssertEqual(app.tabBars.firstMatch.buttons["Projects"].isSelected, true)
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
  func testAPastMonthKeepsTheBellTheBadgeAndItsDeckOnTheWholeQueue() throws {
    let app = launch(scenario: "mayaRange", motion: "off")
    tap(app, "home.period", opening: "period.sheet")
    tap(app, "period.preset.lastMonth")
    tap(app, "period.show")
    XCTAssertTrue(app.buttons["home.period"].waitForLabel("Period, September 2026"))

    let bell = app.buttons["header.notifications"].firstMatch
    XCTAssertEqual(bell.label, "Notifications, 4 need a look")
    bell.tap()
    let row = el(app, "bell.row.review")
    XCTAssertTrue(row.waitForExistence(timeout: uiWait))
    XCTAssertTrue(row.label.contains("9 transactions to sort"), row.label)
    attach(app, "Bell · September chosen")
    el(app, "bell.close").tap()
    XCTAssertTrue(el(app, "bell.sheet").waitForNonExistence(timeout: uiWait))

    let tab = app.tabBars.firstMatch.buttons["Review"]
    XCTAssertTrue("\(tab.label) \(tab.value as? String ?? "")".contains("9"), "\(tab.label) \(String(describing: tab.value))")
    tab.tap()
    let count = el(app, "review.tab.count")
    XCTAssertTrue(count.waitForLabel("1 to sort · about a minute"), count.label)
    XCTAssertEqual(app.buttons["review.tab.period"].label, "Period, September 2026")
    XCTAssertEqual(app.buttons["review.tab.elsewhere"].label, "8 more in other months")
    XCTAssertTrue(el(app, "review.tab.row.sep-steam").exists)
    attach(app, "Review · September chosen")
    try audit(app)

    bell.tap()
    tap(app, "bell.row.review")
    let position = el(app, "review.position")
    XCTAssertTrue(position.waitForLabel("1 of 9"), position.label)
    XCTAssertEqual(app.buttons["review.period"].label, "Period, All months")
    el(app, "review.close").tap()
    XCTAssertTrue(count.waitForExistence(timeout: uiWait))
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
    XCTAssertEqual(app.buttons["review.tab.elsewhere"].label, "3 more in earlier months")
  }

  @MainActor
  func testReviewsPillIsTheAppsPeriod() throws {
    let app = launch(scenario: "mayaRange", motion: "off")
    let tabBar = app.tabBars.firstMatch
    tabBar.buttons["Review"].tap()
    let pill = app.buttons["review.tab.period"]
    XCTAssertTrue(pill.waitForExistence(timeout: uiWait))
    XCTAssertEqual(pill.label, "Period, October 2026")
    let count = el(app, "review.tab.count")
    XCTAssertTrue(count.waitForLabel("6 to sort · about a minute"), count.label)
    let elsewhere = app.buttons["review.tab.elsewhere"]
    XCTAssertEqual(elsewhere.label, "3 more in earlier months")

    tap(app, "review.tab.period", opening: "period.sheet")
    tap(app, "period.preset.lastMonth")
    tap(app, "period.show")
    XCTAssertTrue(pill.waitForLabel("Period, September 2026"))
    XCTAssertTrue(count.waitForLabel("1 to sort · about a minute"), count.label)
    XCTAssertTrue(el(app, "review.tab.row.sep-steam").exists)
    XCTAssertFalse(el(app, "review.tab.row.aug-corner-shop").exists)
    XCTAssertEqual(elsewhere.label, "8 more in other months")
    let tab = tabBar.buttons["Review"]
    XCTAssertTrue("\(tab.label) \(tab.value as? String ?? "")".contains("9"), "\(tab.label) \(String(describing: tab.value))")
    attach(app, "Review · September")
    try audit(app)

    tap(app, "review.tab.start")
    let deckPill = app.buttons["review.period"]
    XCTAssertTrue(deckPill.waitForLabel("Period, September 2026"))
    XCTAssertTrue(el(app, "review.position").waitForLabel("1 of 1"))
    attach(app, "Deck · September")
    try audit(app)
    tap(app, "review.period", opening: "period.sheet")
    tap(app, "period.month.2026-08")
    tap(app, "period.month.2026-10")
    tap(app, "period.show")
    XCTAssertTrue(deckPill.waitForLabel("Period, Aug – Oct 2026"))
    XCTAssertTrue(el(app, "review.position").waitForLabel("1 of 9"))
    el(app, "review.close").tap()
    XCTAssertTrue(pill.waitForLabel("Period, Aug – Oct 2026"))
    XCTAssertTrue(count.waitForLabel("9 to sort · about 2 minutes"), count.label)
    tabBar.buttons["Activity"].tap()
    XCTAssertTrue(app.buttons["activity.period"].waitForLabel("Period, Aug – Oct 2026"))

    tabBar.buttons["Review"].tap()
    tap(app, "review.tab.period", opening: "period.sheet")
    tap(app, "period.month.2026-07")
    tap(app, "period.show")
    XCTAssertTrue(pill.waitForLabel("Period, July 2026"))
    let empty = el(app, "review.tab.empty")
    XCTAssertTrue(empty.waitForExistence(timeout: uiWait))
    XCTAssertTrue(empty.label.contains("9 more in later months"), empty.label)
    XCTAssertTrue(count.waitForLabel("Nothing to sort in July 2026"), count.label)
    attach(app, "Review · July · empty")
    try audit(app)
    tap(app, "review.tab.elsewhere")
    XCTAssertTrue(pill.waitForLabel("Period, Jul – Oct 2026"))
    XCTAssertTrue(count.waitForLabel("9 to sort · about 2 minutes"), count.label)
    tabBar.buttons["Home"].tap()
    XCTAssertTrue(app.buttons["home.period"].waitForLabel("Period, Jul – Oct 2026"))
  }

  @MainActor
  func testReviewsPillAtLargeTextSizes() throws {
    let app = launch(
      scenario: "mayaRange", motion: "off",
      arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"])
    app.tabBars.firstMatch.buttons["Review"].tap()
    let pill = app.buttons["review.tab.period"]
    XCTAssertTrue(pill.waitForExistence(timeout: 15))
    tap(app, "review.tab.period", opening: "period.sheet")
    tap(app, "period.preset.lastMonth")
    tap(app, "period.show")
    XCTAssertTrue(pill.waitForLabel("Period, September 2026"))
    attach(app, "AX3 · Review · September")
    try audit(app, atLargeText: true)
    let start = app.buttons["review.tab.start"]
    XCTAssertTrue(reveal(app, start))
    start.tap()
    XCTAssertTrue(app.buttons["review.period"].waitForLabel("Period, September 2026"))
    attach(app, "AX3 · Deck · September")
    try audit(app, atLargeText: true)
  }
}
