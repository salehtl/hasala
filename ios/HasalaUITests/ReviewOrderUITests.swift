import XCTest

final class ReviewOrderUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  @MainActor
  func openReview(_ app: XCUIApplication) -> XCUIElement {
    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: 30))
    app.tabBars.firstMatch.buttons["Review"].tap()
    let sort = el(app, "review.sort")
    XCTAssertTrue(sort.waitForExistence(timeout: uiWait))
    return sort
  }

  @MainActor
  func above(_ app: XCUIApplication, _ first: String, _ second: String) -> Bool {
    el(app, "review.tab.row.\(first)").frame.minY < el(app, "review.tab.row.\(second)").frame.minY
  }

  @MainActor
  func choose(_ app: XCUIApplication, _ sort: XCUIElement, _ title: String) {
    XCTAssertTrue(scroll(app, toShow: sort))
    sort.tap()
    let item = app.buttons[title]
    XCTAssertTrue(item.waitForExistence(timeout: uiWait), "the menu has no \(title)")
    item.tap()
    XCTAssertTrue(sort.waitForLabel("Order, \(title)"), sort.label)
  }

  @MainActor
  func startsAt(_ app: XCUIApplication, _ merchant: String) {
    tap(app, "review.tab.start")
    let shown = el(app, "review.merchant")
    XCTAssertTrue(shown.waitForLabel(containing: merchant), shown.debugDescription)
    XCTAssertEqual(el(app, "review.position").label, "1 of 6")
    tap(app, "review.close")
    XCTAssertTrue(el(app, "review.tab.count").waitForExistence(timeout: uiWait))
  }

  @MainActor
  func testTheListAndTheDeckFollowTheChosenOrder() throws {
    let app = launch(motion: "off", reviewOrder: nil)
    let sort = openReview(app)
    XCTAssertEqual(sort.label, "Order, Newest first")
    XCTAssertTrue(above(app, "steam", "atm"))
    attach(app, "Review · Tab · Newest first")
    try audit(app)
    startsAt(app, "Steam")

    choose(app, sort, "Oldest first")
    XCTAssertTrue(above(app, "atm", "steam"))
    attach(app, "Review · Tab · Oldest first")
    try audit(app)
    startsAt(app, "ADCB ATM withdrawal")

    choose(app, sort, "Newest first")
    XCTAssertTrue(above(app, "steam", "atm"))
  }

  @MainActor
  func testTheOrderControlWorksOnTheReleaseSurface() throws {
    let app = launch(release: true, motion: "off", reviewOrder: nil)
    let sort = openReview(app)
    XCTAssertEqual(sort.label, "Order, Newest first")
    choose(app, sort, "Oldest first")
    XCTAssertTrue(above(app, "atm", "steam"))
  }

  @MainActor
  func testTheOrderControlReadsAtTheLargestTextSizes() throws {
    let app = launch(
      reviewOrder: nil, arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"])
    let sort = openReview(app)
    XCTAssertTrue(scroll(app, toShow: sort))
    attach(app, "AX3 · Review · order")
    try audit(app, atLargeText: true)
  }
}
