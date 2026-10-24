import XCTest

final class PickSheetNewCategoryUITests: XCTestCase {
  static let largeText = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"]

  override func setUp() {
    continueAfterFailure = false
  }

  @MainActor
  func openDeck(_ app: XCUIApplication, at id: String, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: 30), file: file, line: line)
    app.tabBars.firstMatch.buttons["Review"].tap()
    openRow(app, at: id, file: file, line: line)
  }

  @MainActor
  func openRow(_ app: XCUIApplication, at id: String, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(el(app, "review.tab.start").waitForExistence(timeout: uiWait), file: file, line: line)
    let row = el(app, "review.tab.row.\(id)")
    XCTAssertTrue(row.waitForExistence(timeout: uiWait), "no row for \(id)", file: file, line: line)
    XCTAssertTrue(scroll(app, toShow: row), "could not reach \(id)", file: file, line: line)
    row.tap()
    XCTAssertTrue(el(app, "review.position").waitForLabel("1 of 30"), "the deck did not open at \(id)", file: file, line: line)
  }

  @MainActor
  func swipeToNeed(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
    el(app, "review.card").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
      .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.45)))
    XCTAssertTrue(el(app, "pick.close").waitForExistence(timeout: uiWait), file: file, line: line)
    XCTAssertTrue(app.staticTexts["Need · which one?"].exists, file: file, line: line)
  }

  @MainActor
  func openCategories(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
    tap(app, "review.close", file: file, line: line)
    XCTAssertTrue(el(app, "review.tab.count").waitForExistence(timeout: uiWait), file: file, line: line)
    app.buttons["header.profile"].firstMatch.tap()
    tap(app, "profile.rules", opening: "rules.segment", file: file, line: line)
    app.buttons["Categories"].firstMatch.tap()
    XCTAssertTrue(el(app, "categories.capLine").waitForExistence(timeout: uiWait), file: file, line: line)
  }

  @MainActor
  func toTheEnd(_ app: XCUIApplication, up: Bool = true) {
    for _ in 0..<2 {
      app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.6 : 0.3))
        .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.3 : 0.6)),
               withVelocity: .default, thenHoldForDuration: 0.3)
    }
    waitForStill(app)
  }

  @MainActor
  func categoryRow(_ app: XCUIApplication, named name: String) -> XCUIElement {
    app.descendants(matching: .any)
      .matching(NSPredicate(format: "identifier BEGINSWITH 'category.' AND label CONTAINS %@", name)).firstMatch
  }

  @MainActor
  func testASwipeAddsACategoryAndSortsTheCardIntoIt() throws {
    let app = launch(scenario: "mayaBacklog")
    openDeck(app, at: "bl-alnoor-t-2")
    let merchant = el(app, "review.merchant")
    XCTAssertTrue(merchant.label.hasPrefix("Al Noor Trading"), merchant.label)
    swipeToNeed(app)
    attach(app, "Review · Pick a need · New category row")
    tap(app, "pick.newCategory", opening: "pick.newCategory.name")
    XCTAssertEqual(el(app, "pick.newCategory.title").label, "Need · new category")
    XCTAssertFalse(el(app, "pick.close").exists)
    let name = el(app, "pick.newCategory.name")
    XCTAssertTrue(name.waitForKeyboardFocus(), "the name field has the keyboard")
    XCTAssertTrue(el(app, "pick.newCategory.icon.tag").isSelected)

    name.typeText("Coffee")
    XCTAssertTrue(el(app, "pick.newCategory.icon.dining").isSelected, "the icon follows the name")
    name.typeText(" beans")
    XCTAssertTrue(el(app, "pick.newCategory.icon.dining").isSelected)
    attach(app, "Review · New category · form")
    tap(app, "pick.newCategory.save")
    XCTAssertTrue(el(app, "pick.newCategory.name").waitForNonExistence(timeout: uiWait))
    XCTAssertTrue(app.staticTexts["Sorted into Coffee beans"].waitForExistence(timeout: uiWait))
    XCTAssertTrue(el(app, "review.position").waitForLabel("2 of 30"))
    XCTAssertTrue(merchant.waitForLabel(containing: "Al Noor Trading"), merchant.label)
    XCTAssertTrue(merchant.label.contains("Looks like Coffee beans. Your last pick."), merchant.label)
    attach(app, "Review · Deck · sorted into the new category")

    openCategories(app)
    XCTAssertTrue(el(app, "categories.capLine").waitForLabel("2 of 20 custom categories"))
    let row = categoryRow(app, named: "Coffee beans")
    XCTAssertTrue(row.waitForExistence(timeout: uiWait))
    XCTAssertTrue(row.label.contains("Counts as Needs"), row.label)
  }

  @MainActor
  func deckFrames(_ app: XCUIApplication) -> [String: CGRect] {
    var frames: [String: CGRect] = [:]
    for id in ["review.close", "review.position", "review.more", "review.period"] {
      let e = el(app, id)
      XCTAssertTrue(e.waitForExistence(timeout: uiWait), "\(id) is missing")
      frames[id] = e.frame
    }
    return frames
  }

  @MainActor
  func testTheDeckStaysPutWhenTheNameFieldHasTheKeyboard() throws {
    let app = launch(scenario: "mayaBacklog")
    openDeck(app, at: "bl-alnoor-t-2")
    waitForStill(app)
    let atRest = deckFrames(app)
    swipeToNeed(app)
    tap(app, "pick.newCategory", opening: "pick.newCategory.name")
    let name = el(app, "pick.newCategory.name")
    XCTAssertTrue(name.waitForKeyboardFocus())
    name.typeText("Coffee\n")
    XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: uiWait))
    waitForStill(app)
    XCTAssertEqual(deckFrames(app), atRest, "the deck moved under the sheet")

    name.tap()
    XCTAssertTrue(name.waitForKeyboardFocus())
    let keyboard = app.keyboards.firstMatch
    XCTAssertTrue(keyboard.waitForExistence(timeout: uiWait))
    waitForStill(app)
    attach(app, "Review · New category · keyboard over the deck")
    XCTAssertEqual(deckFrames(app), atRest, "the deck moved with the keyboard")
    XCTAssertTrue(name.isHittable)
    XCTAssertLessThanOrEqual(name.frame.maxY, keyboard.frame.minY, "the name field is under the keyboard")
  }

  @MainActor
  func testAClashingNameShowsWhyAndWritesNothing() throws {
    let app = launch(scenario: "mayaBacklog")
    openDeck(app, at: "bl-alnoor-t-2")
    swipeToNeed(app)
    tap(app, "pick.newCategory", opening: "pick.newCategory.name")
    let name = el(app, "pick.newCategory.name")
    XCTAssertTrue(name.waitForKeyboardFocus())
    name.typeText("groceries")
    tap(app, "pick.newCategory.save")
    let refusal = el(app, "pick.newCategory.refusal")
    XCTAssertTrue(refusal.waitForLabel("You already have a category named Groceries."), refusal.label)
    XCTAssertTrue(name.exists)
    XCTAssertFalse(el(app, "toast").exists)
    attach(app, "Review · New category · name taken")

    tap(app, "pick.newCategory.back", opening: "pick.groceries")
    XCTAssertTrue(el(app, "pick.newCategory").exists)
    XCTAssertFalse(name.exists)
    tap(app, "pick.close")
    XCTAssertTrue(el(app, "pick.close").waitForNonExistence(timeout: uiWait))
    XCTAssertTrue(el(app, "review.position").waitForLabel("1 of 30"))
    XCTAssertTrue(el(app, "review.merchant").label.hasPrefix("Al Noor Trading"))
    XCTAssertFalse(el(app, "toast").exists)

    openCategories(app)
    XCTAssertTrue(el(app, "categories.capLine").waitForLabel("1 of 20 custom categories"))
    XCTAssertFalse(categoryRow(app, named: "groceries").exists)
  }

  @MainActor
  func testTransferAndMoneyInHaveNoNewCategoryRow() throws {
    let app = launch(scenario: "mayaBacklog")
    openDeck(app, at: "bl-alnoor-t-2")
    tap(app, "review.pill.transfer", opening: "pick.close")
    XCTAssertTrue(app.staticTexts["Transfer · which one?"].exists)
    XCTAssertFalse(el(app, "pick.newCategory").exists)
    tap(app, "pick.close")
    XCTAssertTrue(el(app, "pick.close").waitForNonExistence(timeout: uiWait))

    tap(app, "review.close")
    openRow(app, at: "bl-ts-refund")
    tap(app, "review.pill.need", opening: "pick.close")
    XCTAssertTrue(app.staticTexts["Need · which one?"].exists)
    XCTAssertFalse(el(app, "pick.newCategory").exists)
  }

  @MainActor
  func testTheFormPassesTheAccessibilityAudit() throws {
    let app = launch(scenario: "mayaBacklog")
    openDeck(app, at: "bl-alnoor-t-2")
    swipeToNeed(app)
    try audit(app, overSheet: true)
    tap(app, "pick.newCategory", opening: "pick.newCategory.name")
    type(app, "pick.newCategory.name", "Groceries\n")
    XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: uiWait))
    tap(app, "pick.newCategory.save")
    XCTAssertTrue(el(app, "pick.newCategory.refusal").waitForExistence(timeout: uiWait))
    attach(app, "Review · New category · form")
    try audit(app, overSheet: true)
  }

  @MainActor
  func testTheFormReadsAtTheLargestTextSizes() throws {
    let app = launch(scenario: "mayaBacklog", arguments: Self.largeText)
    openDeck(app, at: "bl-alnoor-t-2")
    tap(app, "review.pill.need", opening: "pick.close")
    let row = el(app, "pick.newCategory")
    XCTAssertTrue(row.waitForExistence(timeout: uiWait))
    toTheEnd(app)
    XCTAssertTrue(row.isHittable)
    XCTAssertGreaterThanOrEqual(row.frame.height, 44)
    attach(app, "Review · Pick a need · New category row · accessibility3")
    try audit(app, atLargeText: true, overSheet: true)
    row.tap()
    XCTAssertTrue(el(app, "pick.newCategory.name").waitForExistence(timeout: uiWait))
    type(app, "pick.newCategory.name", "Coffee beans\n")
    XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: uiWait))
    for id in ["pick.newCategory.back", "pick.newCategory.save"] {
      let e = el(app, id)
      XCTAssertTrue(e.isHittable, id)
      XCTAssertGreaterThanOrEqual(e.frame.width, 44, id)
      XCTAssertGreaterThanOrEqual(e.frame.height, 44, id)
    }
    XCTAssertEqual(el(app, "pick.newCategory.title").label, "Need · new category")
    attach(app, "Review · New category · form · accessibility3")
    try audit(app, atLargeText: true, overSheet: true)
    let icon = el(app, "pick.newCategory.icon.flag")
    toTheEnd(app)
    XCTAssertTrue(icon.isHittable)
    XCTAssertGreaterThanOrEqual(icon.frame.height, 44)
    attach(app, "Review · New category · icons · accessibility3")
    try audit(app, atLargeText: true, overSheet: true)
    XCTAssertTrue(el(app, "pick.newCategory.icon.dining").isSelected)
    toTheEnd(app, up: false)
    tap(app, "pick.newCategory.save")
    XCTAssertTrue(app.staticTexts["Sorted into Coffee beans"].waitForExistence(timeout: uiWait))
    XCTAssertTrue(el(app, "review.position").waitForLabel("2 of 30"))
  }

  @MainActor
  func testTheRefusalReadsAtTheLargestTextSizes() throws {
    let app = launch(scenario: "mayaBacklog", arguments: Self.largeText)
    openDeck(app, at: "bl-alnoor-t-2")
    tap(app, "review.pill.need", opening: "pick.close")
    let row = el(app, "pick.newCategory")
    XCTAssertTrue(row.waitForExistence(timeout: uiWait))
    toTheEnd(app)
    row.tap()
    XCTAssertTrue(el(app, "pick.newCategory.name").waitForExistence(timeout: uiWait))
    type(app, "pick.newCategory.name", "Groceries\n")
    XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: uiWait))
    tap(app, "pick.newCategory.save")
    let refusal = el(app, "pick.newCategory.refusal")
    XCTAssertTrue(refusal.waitForLabel("You already have a category named Groceries."), refusal.label)
    XCTAssertFalse(el(app, "toast").exists)
    let name = el(app, "pick.newCategory.name")
    let firstIcon = el(app, "pick.newCategory.icon.tag")
    XCTAssertGreaterThanOrEqual(refusal.frame.minY, name.frame.maxY)
    XCTAssertLessThanOrEqual(refusal.frame.maxY, firstIcon.frame.minY)
    XCTAssertGreaterThan(refusal.frame.height, name.frame.height)
    XCTAssertTrue(app.windows.firstMatch.frame.contains(refusal.frame))
    attach(app, "Review · New category · name taken · accessibility3")
    try audit(app, overSheet: true)
    try app.performAccessibilityAudit(for: .textClipped) { issue in
      issue.element?.identifier == "pick.newCategory.refusal"
    }
  }
}
