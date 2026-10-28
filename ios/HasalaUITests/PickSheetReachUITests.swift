import XCTest

final class PickSheetReachUITests: XCTestCase {
  static let largeText = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"]
  static let needs = ["rent", "utilities", "groceries", "transport", "healthcare", "insurance"]

  override func setUp() {
    continueAfterFailure = false
  }

  @MainActor
  func openLuluNeed(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: 30), file: file, line: line)
    app.tabBars.firstMatch.buttons["Review"].tap()
    let row = el(app, "review.tab.row.lulu")
    XCTAssertTrue(row.waitForExistence(timeout: uiWait), file: file, line: line)
    XCTAssertTrue(reveal(app, row), file: file, line: line)
    row.tap()
    XCTAssertTrue(el(app, "review.merchant").waitForLabel(containing: "Lulu Hypermarket"), file: file, line: line)
    tap(app, "review.pill.need", opening: "pick.close", file: file, line: line)
    XCTAssertTrue(app.staticTexts["Need · which one?"].exists, file: file, line: line)
    waitForStill(app)
  }

  @MainActor
  func testTwelveProjectsKeepTheCategoriesLowAndTheSuggestionInPlace() throws {
    let app = launch(scenario: "mayaProjects")
    openLuluNeed(app)
    let close = el(app, "pick.close")
    let projects = el(app, "pick.projects")
    let rule = el(app, "pick.alwaysUse")
    XCTAssertTrue(projects.exists)
    XCTAssertLessThanOrEqual(projects.frame.height, 56, "the project row wrapped")
    XCTAssertLessThan(projects.frame.maxY, rule.frame.minY)

    let rows = Self.needs.map { el(app, "pick.\($0)") }
    for (id, row) in zip(Self.needs, rows) {
      XCTAssertTrue(row.isHittable, id)
      XCTAssertGreaterThanOrEqual(row.frame.height, 44, id)
    }
    for (above, below) in zip(rows, rows.dropFirst()) {
      XCTAssertLessThan(above.frame.minY, below.frame.minY)
    }
    XCTAssertGreaterThan(rows[0].frame.minY, rule.frame.maxY)
    XCTAssertLessThan(rows[0].frame.minY - close.frame.maxY, 240, "the categories sit too far down the sheet")
    XCTAssertEqual(rows[2].label, "Groceries, suggested")
    let add = el(app, "pick.newCategory")
    XCTAssertTrue(add.isHittable)
    XCTAssertGreaterThan(add.frame.minY, rows[5].frame.maxY)
    XCTAssertLessThanOrEqual(add.frame.maxY, app.frame.maxY)

    let chips = ["none", "japan", "kitchen", "wedding", "car", "diving", "eid", "hatta", "sofa", "laptop", "dentist",
                 "garden", "birthday"].map { el(app, "pick.project.\($0)") }
    for (left, right) in zip(chips, chips.dropFirst()) {
      XCTAssertEqual(left.frame.midY, right.frame.midY, accuracy: 1)
      XCTAssertLessThan(left.frame.minX, right.frame.minX)
    }
    XCTAssertTrue(chips[0].isHittable)
    XCTAssertFalse(chips[12].isHittable)
    let eid = chips[6]
    XCTAssertEqual(eid.label, "Eid gifts, suggested")
    attach(app, "Review · Pick a need · 12 projects")
    try audit(app, overSheet: true)

    for _ in 0..<4 where !eid.isHittable {
      projects.swipeLeft()
      waitForStill(app)
    }
    XCTAssertTrue(eid.isHittable)
    eid.tap()
    XCTAssertTrue(eid.isSelected)
    XCTAssertFalse(chips[0].isSelected)
    XCTAssertTrue(rows[2].isHittable)
    attach(app, "Review · Pick a need · 12 projects · Eid chosen")
    rows[2].tap()
    XCTAssertTrue(close.waitForNonExistence(timeout: uiWait))
    XCTAssertTrue(app.staticTexts["Sorted into Groceries"].waitForExistence(timeout: uiWait))
    XCTAssertTrue(el(app, "review.position").waitForLabel("2 of 6"))
  }

  @MainActor
  func testTheSheetReadsAtTheLargestTextSizesWithManyProjects() throws {
    let app = launch(scenario: "mayaProjects", arguments: Self.largeText)
    openLuluNeed(app)
    let projects = el(app, "pick.projects")
    XCTAssertTrue(projects.exists)
    XCTAssertLessThan(projects.frame.height, 140, "the project row wrapped")
    let groceries = el(app, "pick.groceries")
    XCTAssertEqual(groceries.label, "Groceries, suggested")
    attach(app, "Review · Pick a need · 12 projects · accessibility3")
    try audit(app, atLargeText: true, overSheet: true)
    tap(app, "pick.insurance")
    XCTAssertTrue(el(app, "pick.close").waitForNonExistence(timeout: uiWait))
    XCTAssertTrue(el(app, "review.position").waitForLabel("2 of 6"))
  }
}
