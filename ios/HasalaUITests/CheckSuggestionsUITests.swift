import XCTest

final class CheckSuggestionsUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  @MainActor
  func testUntickOneUseTheRestAndUndo() throws {
    let app = launch(scenario: "mayaSuggestions")
    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: uiWait))
    app.tabBars.firstMatch.buttons["Review"].tap()
    let entry = el(app, "review.tab.checkSuggestions")
    XCTAssertTrue(entry.waitForExistence(timeout: uiWait))
    XCTAssertTrue(entry.label.contains("Check 7 suggestions"), entry.label)
    tap(app, "review.tab.checkSuggestions", opening: "suggestions.use")

    XCTAssertTrue(app.staticTexts["Check suggestions"].waitForExistence(timeout: uiWait))
    XCTAssertTrue(el(app, "suggestions.lead").label.hasPrefix("Cloudflare's AI suggested these."))
    XCTAssertTrue(el(app, "suggestions.group.dining").label.contains("Dining · 3 payments · 2 merchants"))
    let row = el(app, "suggestions.row.sug-tim-8")
    XCTAssertTrue(row.label.contains("Tim Hortons, Thu 8 Oct, Suggested by Cloudflare AI"), row.label)
    XCTAssertTrue(row.isSelected)
    let use = el(app, "suggestions.use")
    XCTAssertEqual(use.label, "Use 7 suggestions")
    attach(app, "Check suggestions")
    try audit(app, overSheet: true)

    row.tap()
    XCTAssertTrue(use.waitForLabel("Use 6 suggestions"), use.label)
    XCTAssertFalse(row.isSelected)
    use.tap()

    let undo = el(app, "toast").buttons["Undo"]
    XCTAssertTrue(undo.waitForExistence(timeout: uiWait))
    XCTAssertTrue(app.staticTexts["Used 6 suggestions"].exists)
    undo.tap()
    XCTAssertTrue(use.waitForNonExistence(timeout: uiWait))
    XCTAssertTrue(entry.waitForLabel(containing: "Check 7 suggestions"), entry.label)
    XCTAssertEqual(el(app, "review.tab.count").label, "10 to sort · about 2 minutes")
  }

  @MainActor
  func testTheSheetReflowsAtTheLargestSizes() throws {
    let app = launch(
      scenario: nil, screen: "review.suggestions",
      arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"])
    XCTAssertTrue(el(app, "suggestions.use").waitForExistence(timeout: uiWait))
    XCTAssertTrue(el(app, "suggestions.row.sug-shake-9").exists)
    attach(app, "Check suggestions · accessibility3")
    try audit(app, atLargeText: true, overSheet: true)
  }
}
