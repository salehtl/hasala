import XCTest

final class ReleaseSurfaceInsightsTests: ReleaseSurfaceTestCase {
  @MainActor
  func testInsightsShowsOnlyWhatWorks() throws {
    let app = launchRelease()
    tap(app, "home.insights", opening: "insights.screen")
    XCTAssertTrue(el(app, "insights.figure").waitForValue("AED 11,115.62"))
    assertNoPlaceholders(app, "Insights")
    attach(app, "Release · Insights")
    try audit(app)

    let netWorth = el(app, "insights.report.netWorth")
    XCTAssertTrue(reveal(app, netWorth), "Insights has no net worth tile")
    assertAbsent(app, ["insights.report.inVsSpent", "insights.report.ageOfMoney", "insights.report.yearOnYear"],
                 "Insights")
    assertNoPlaceholders(app, "Insights")
    attach(app, "Release · Insights · Reports")
    netWorth.tap()
    XCTAssertTrue(el(app, "accounts.netWorth").waitForExistence(timeout: uiWait), "Net worth opens nothing")
  }
}
