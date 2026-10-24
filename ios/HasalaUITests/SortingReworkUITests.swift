import XCTest

final class SortingReworkUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  @MainActor
  func testAnActivityRowSaysWhichRuleSortedIt() throws {
    let app = launch(scenario: "mayaBacklog")
    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: 30))
    app.tabBars.firstMatch.buttons["Activity"].tap()
    let ruled = app.buttons.matching(NSPredicate(format: "label CONTAINS ', sorted by your rule'")).firstMatch
    XCTAssertTrue(ruled.waitForExistence(timeout: uiWait), "no Activity row says it was sorted by your rule")
    XCTAssertFalse(ruled.label.contains("Your rule"), ruled.label)
    XCTAssertTrue(ruled.label.contains(" · "), ruled.label)
    attach(app, "Activity · sorted by your rule")
    try audit(app)
  }
}
