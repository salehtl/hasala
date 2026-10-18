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
}
