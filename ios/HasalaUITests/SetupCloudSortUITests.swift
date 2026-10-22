import XCTest

final class SetupCloudSortUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  @MainActor
  func testReviewAsksOnceAndTurnOnSorts() throws {
    let app = launch(scenario: nil, screen: "review.cloudSort")
    let card = el(app, "review.cloudSort")
    XCTAssertTrue(card.waitForExistence(timeout: 30))
    XCTAssertTrue(app.staticTexts["Sort the rest with Cloudflare AI?"].exists)
    XCTAssertTrue(el(app, "review.tab.start").exists, "the ask hid the queue")
    attach(app, "Review · Sort the rest with Cloudflare AI?")
    try audit(app)
    tap(app, "review.cloudSort.details")
    XCTAssertTrue(app.staticTexts["Only the merchant name"].waitForExistence(timeout: uiWait))
    XCTAssertTrue(app.staticTexts["What's not sent"].exists)
    attach(app, "Review · What Cloudflare sees")
    try audit(app, overSheet: true)
    tap(app, "sort.turnOn")
    XCTAssertTrue(card.waitForNonExistence(timeout: uiWait), "the ask stayed after Turn on")
    XCTAssertTrue(el(app, "review.tab.start").exists)
  }

  @MainActor
  func testNotNowLeavesItOff() throws {
    let app = launch(scenario: nil, screen: "review.cloudSort")
    tap(app, "review.cloudSort.notNow", timeout: 30)
    XCTAssertTrue(el(app, "review.cloudSort").waitForNonExistence(timeout: uiWait))
    XCTAssertTrue(el(app, "review.tab.start").exists)
  }

  @MainActor
  func testNotAskedWhenTheBuildDoesNotOfferIt() throws {
    let app = launch(scenario: "maya")
    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: 15))
    app.tabBars.firstMatch.buttons["Review"].tap()
    XCTAssertTrue(el(app, "review.tab.start").waitForExistence(timeout: uiWait))
    XCTAssertFalse(el(app, "review.cloudSort").exists)
  }

  @MainActor
  func testTheAskAtLargeTextSizes() throws {
    let app = launch(
      scenario: nil, screen: "review.cloudSort",
      arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"])
    XCTAssertTrue(el(app, "review.cloudSort.turnOn").waitForExistence(timeout: 30))
    attach(app, "AX3 · Review · Sort the rest")
    try audit(app, atLargeText: true)
  }
}
