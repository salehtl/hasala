import XCTest

final class TabRoundTripTests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  @MainActor
  func testActivityProfileProjectsAndBackHomeWhileImporting() throws {
    let app = launch(scenario: nil, screen: "home.importing")
    XCTAssertTrue(el(app, "home.importPill").waitForExistence(timeout: uiWait))
    for _ in 0..<3 {
      app.tabBars.firstMatch.buttons["Activity"].tap()
      XCTAssertTrue(el(app, "activity.count").waitForExistence(timeout: uiWait))
      app.buttons["header.profile"].firstMatch.tap()
      XCTAssertTrue(el(app, "profile.bills").waitForExistence(timeout: uiWait))
      if el(app, "profile.close").exists { el(app, "profile.close").tap() }
      app.tabBars.firstMatch.buttons["Projects"].tap()
      XCTAssertTrue(el(app, "projects.new").waitForExistence(timeout: uiWait))
      for _ in 0..<4 { app.swipeUp() }
      app.tabBars.firstMatch.buttons["Home"].tap()
      XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: uiWait))
      XCTAssertTrue(el(app, "home.importPill").exists)
      XCTAssertEqual(app.state, .runningForeground, "the app is no longer running")
    }
    attach(app, "Home · back from Activity, Profile and Projects")
  }
}
