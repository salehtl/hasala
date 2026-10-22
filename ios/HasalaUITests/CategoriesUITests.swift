import XCTest

final class CategoriesUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  @MainActor
  private func openCategories() -> XCUIApplication {
    let app = launch(scenario: nil, screen: "profile.rules")
    XCTAssertTrue(el(app, "rule.r-carrefour").waitForExistence(timeout: 15))
    app.buttons["Categories"].firstMatch.tap()
    XCTAssertTrue(el(app, "categories.capLine").waitForExistence(timeout: uiWait))
    return app
  }

  @MainActor
  func testAddRenameAndArchiveACategory() throws {
    let app = openCategories()
    XCTAssertEqual(el(app, "categories.capLine").label, "1 of 20 custom categories")
    XCTAssertTrue(el(app, "category.emergency-fund").label.contains("Counts as Savings"))
    attach(app, "Categories")
    try audit(app)

    tap(app, "categories.add", opening: "categoryEditor.name")
    type(app, "categoryEditor.name", "Coffee")
    tap(app, "categoryEditor.parent")
    let dining = app.buttons["Dining"].firstMatch
    XCTAssertTrue(dining.waitForExistence(timeout: uiWait))
    dining.tap()
    XCTAssertTrue(el(app, "categoryEditor.parentNote").waitForLabel("Its spending counts in Wants."))
    tap(app, "categoryEditor.icon.dining")
    attach(app, "New category")
    tap(app, "categoryEditor.save")
    XCTAssertTrue(app.staticTexts["Coffee added"].waitForExistence(timeout: uiWait))
    XCTAssertTrue(el(app, "categories.capLine").waitForLabel("2 of 20 custom categories"))
    let row = el(app, "category.c_mock1")
    XCTAssertTrue(row.waitForExistence(timeout: uiWait))
    XCTAssertTrue(row.label.contains("Counts as Dining"), row.label)

    tap(app, "category.c_mock1", opening: "categoryEditor.name")
    let name = el(app, "categoryEditor.name")
    XCTAssertTrue(name.waitForExistence(timeout: uiWait))
    name.tap()
    XCTAssertTrue(name.waitForKeyboardFocus())
    name.typeText(" shops")
    XCTAssertEqual(name.value as? String, "Coffee shops")
    tap(app, "categoryEditor.save")
    XCTAssertTrue(app.staticTexts["Category saved"].waitForExistence(timeout: uiWait))
    XCTAssertTrue(el(app, "category.c_mock1").waitForLabel(containing: "Coffee shops"))

    tap(app, "category.c_mock1", opening: "categoryEditor.archive")
    tap(app, "categoryEditor.archive")
    let confirm = app.buttons["Archive"].firstMatch
    XCTAssertTrue(confirm.waitForExistence(timeout: uiWait))
    XCTAssertTrue(app.buttons["Archive and move to\u{2026}"].exists)
    attach(app, "Archive Coffee shops")
    confirm.tap()
    XCTAssertTrue(app.staticTexts["Coffee shops archived"].waitForExistence(timeout: uiWait))
    XCTAssertTrue(el(app, "categories.capLine").waitForLabel("1 of 20 custom categories"))
    tap(app, "categories.archived")
    XCTAssertTrue(el(app, "category.c_mock1").waitForValue("Restore"))
    attach(app, "Archived")
    tap(app, "category.c_mock1")
    XCTAssertTrue(app.staticTexts["Coffee shops restored"].waitForExistence(timeout: uiWait))
    XCTAssertTrue(el(app, "categories.capLine").waitForLabel("2 of 20 custom categories"))
  }

  @MainActor
  func testAGoalKeepsItsCategoryAndBuiltInsHide() throws {
    let app = openCategories()
    tap(app, "category.emergency-fund", opening: "categoryEditor.archive")
    tap(app, "categoryEditor.archive")
    XCTAssertTrue(el(app, "categoryEditor.refusal").waitForLabel("A goal uses this category. Finish or change the goal first."))
    back(app)

    tap(app, "category.dining", opening: "categoryEditor.hide")
    XCTAssertFalse(el(app, "categoryEditor.parent").exists, "a built-in has no Counts as")
    attach(app, "Edit Dining")
    try audit(app)
    let toggle = app.switches["categoryEditor.hide"].firstMatch
    XCTAssertTrue(toggle.waitForExistence(timeout: uiWait))
    toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
    let hide = app.buttons["Hide"].firstMatch
    XCTAssertTrue(hide.waitForExistence(timeout: uiWait))
    hide.tap()
    XCTAssertTrue(app.staticTexts["Dining hidden"].waitForExistence(timeout: uiWait))
    back(app)
    XCTAssertTrue(el(app, "category.dining").waitForValue("Hidden"))
  }
}
