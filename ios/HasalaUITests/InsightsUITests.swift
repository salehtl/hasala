import XCTest

final class InsightsUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  @MainActor
  func testFromHomeToSeptemberAndItsDrillDown() throws {
    let app = launch(scenario: "maya")
    tap(app, "home.insights", opening: "insights.screen")
    XCTAssertTrue(el(app, "insights.status").waitForLabel("Day 10 of 31"))
    XCTAssertTrue(el(app, "insights.figure").waitForValue("AED 11,115.62"))
    XCTAssertEqual(el(app, "insights.figure").label, "Spent so far")
    XCTAssertTrue(app.tabBars.firstMatch.buttons["Home"].isSelected, "Home is not selected under Insights")
    XCTAssertTrue(el(app, "insights.share").exists)
    attach(app, "Insights · October so far")
    try audit(app)

    tap(app, "insights.period", opening: "period.show")
    tap(app, "period.month.2026-09")
    XCTAssertTrue(el(app, "period.show").waitForLabel("Show September 2026"))
    attach(app, "Insights · Period picker")
    try audit(app, overSheet: true)
    tap(app, "period.show")
    XCTAssertTrue(el(app, "insights.status").waitForLabel("Closed month"))
    XCTAssertTrue(el(app, "insights.figure").waitForValue("plus AED 6,587.40"))
    XCTAssertEqual(el(app, "insights.kept").value as? String, "26 percent of income")
    XCTAssertEqual(el(app, "insights.legend.wants").label, "Wants, AED 5,832.10, down 17 percent from August")
    attach(app, "Insights · September 2026")
    try audit(app)

    tap(app, "insights.legend.wants", opening: "drill.sheet")
    XCTAssertTrue(el(app, "drill.total").waitForValue("AED 5,832.10"))
    attach(app, "Insights · Drill-down · Wants")
    try audit(app, overSheet: true)
    tap(app, "drill.category.dining", opening: "drill.line")
    XCTAssertTrue(el(app, "drill.total").waitForValue("AED 1,486.20"))
    attach(app, "Insights · Drill-down · Dining")
    back(app)
    tap(app, "drill.close")
    XCTAssertTrue(el(app, "insights.screen").waitForExistence(timeout: uiWait))

    tap(app, "insights.row.category.rent", opening: "drill.sheet")
    XCTAssertTrue(el(app, "drill.total").waitForValue("AED 7,500.00"))
    tap(app, "drill.close")

    let chart = el(app, "insights.flow.chart")
    XCTAssertTrue(scroll(app, toShow: chart))
    XCTAssertTrue(chart.label.hasPrefix("Money in vs out"))
    XCTAssertTrue((chart.value as? String)?.hasPrefix("Out averaged AED 18,774.13 a month") == true)
    attach(app, "Insights · Money in vs out")
    tap(app, "insights.flow.toggle", opening: "insights.flow.table")
    attach(app, "Insights · Reports")
    try audit(app)
  }

  @MainActor
  func testFirstDaysShowNothingToCompare() throws {
    let app = launch(scenario: nil, screen: "home.insights.firstDays")
    XCTAssertTrue(el(app, "insights.status").waitForLabel("Day 3 of 31"))
    XCTAssertTrue(el(app, "insights.figure").waitForValue("AED 486.75"))
    XCTAssertEqual(el(app, "insights.kept").value as? String, "No income yet")
    XCTAssertFalse(el(app, "insights.legend.savings").exists)
    XCTAssertEqual(el(app, "insights.legend.needs").label, "Needs, AED 412.50")
    attach(app, "Insights · Not much yet")
    let empty = el(app, "insights.changes.empty")
    XCTAssertTrue(scroll(app, toShow: empty))
    XCTAssertTrue(empty.label.hasPrefix("Nothing to compare yet"))
    XCTAssertTrue(el(app, "insights.flow.empty").exists)
    attach(app, "Insights · Not much yet · lower")
    try audit(app)
  }

  @MainActor
  func testLargeTextReflowsRowsAndTiles() throws {
    let app = launch(scenario: "maya", arguments: ["-UIPreferredContentSizeCategoryName",
                                                   "UICTContentSizeCategoryAccessibilityL"])
    tap(app, "home.insights", opening: "insights.screen")
    XCTAssertTrue(el(app, "insights.figure").waitForValue("AED 11,115.62"))
    attach(app, "Insights · Large text")
    try audit(app, atLargeText: true)
    let tile = el(app, "insights.report.netWorth")
    XCTAssertTrue(scroll(app, toShow: tile))
    let other = el(app, "insights.report.inVsSpent")
    XCTAssertTrue(other.exists)
    XCTAssertGreaterThan(other.frame.minY, tile.frame.maxY - 1, "report tiles are not one column")
    attach(app, "Insights · Large text · Reports")
  }
}
