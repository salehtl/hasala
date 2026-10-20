import XCTest

final class SetupCloudSortUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  @MainActor
  func testTurnOnSortsTheFirstImport() throws {
    let app = launch(scenario: nil, screen: "setup.sort")
    XCTAssertTrue(el(app, "sort.turnOn").waitForExistence(timeout: 30))
    XCTAssertTrue(el(app, "sort.notNow").exists)
    XCTAssertTrue(app.staticTexts["Sort the rest with Cloudflare AI?"].exists)
    XCTAssertTrue(app.staticTexts["Only the merchant name"].exists)
    XCTAssertTrue(app.staticTexts["What's not sent"].exists)
    attach(app, "Setup · Sort the first import")
    try audit(app)
    tap(app, "sort.turnOn", opening: "notifications.allow")
    tap(app, "notifications.notNow")
    XCTAssertTrue(el(app, "done.home").waitForExistence(timeout: uiWait))
    XCTAssertTrue(app.staticTexts["Merchants Hasala doesn't know go to Cloudflare AI"].exists)
  }

  @MainActor
  func testNotNowLeavesItOff() throws {
    let app = launch(scenario: nil, screen: "setup.sort")
    tap(app, "sort.notNow", opening: "notifications.allow")
    tap(app, "notifications.notNow")
    XCTAssertTrue(el(app, "done.home").waitForExistence(timeout: uiWait))
    XCTAssertFalse(app.staticTexts["Merchants Hasala doesn't know go to Cloudflare AI"].exists)
  }

  @MainActor
  func testTheOfferAtLargeTextSizes() throws {
    let app = launch(
      scenario: nil, screen: "setup.sort",
      arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"])
    XCTAssertTrue(el(app, "sort.turnOn").waitForExistence(timeout: 30))
    attach(app, "AX3 · Sort the first import")
    try audit(app, atLargeText: true)
  }
}
