import XCTest

final class OneCardDeckUITests: XCTestCase {
  static let largeText = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"]
  static let qasrLine = "Groceries for all 6 Qasr Corner Store payments"

  override func setUp() {
    continueAfterFailure = false
  }

  @MainActor
  func openReview(_ app: XCUIApplication) {
    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: 30))
    app.tabBars.firstMatch.buttons["Review"].tap()
    XCTAssertTrue(el(app, "review.tab.start").waitForExistence(timeout: uiWait))
  }

  @MainActor
  func openDeck(_ app: XCUIApplication, at id: String, file: StaticString = #filePath, line: UInt = #line) {
    let row = el(app, "review.tab.row.\(id)")
    XCTAssertTrue(row.waitForExistence(timeout: uiWait), "no row for \(id)", file: file, line: line)
    XCTAssertTrue(scroll(app, toShow: row), "could not reach \(id)", file: file, line: line)
    row.tap()
    XCTAssertTrue(el(app, "review.position").waitForLabel("1 of 30"), "the deck did not open at \(id)", file: file, line: line)
  }

  @MainActor
  func alwaysUseGroceries(_ app: XCUIApplication) {
    tap(app, "review.pill.need", opening: "pick.close")
    tap(app, "pick.alwaysUse")
    tap(app, "pick.groceries")
    XCTAssertTrue(el(app, "pick.close").waitForNonExistence(timeout: uiWait))
  }

  @MainActor
  func groupRows(_ app: XCUIApplication) -> XCUIElementQuery {
    app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'review.tab.group.'"))
  }

  @MainActor
  func testTheTabAndTheDeckShowOneCardPerPayment() throws {
    let app = launch(scenario: "mayaBacklog")
    openReview(app)
    XCTAssertEqual(el(app, "review.tab.count").label, "30 to sort · about 5 minutes")
    XCTAssertTrue(app.staticTexts["Need, want or save. One card at a time."].exists)
    XCTAssertTrue(el(app, "review.tab.row.bl-ts-01").waitForExistence(timeout: uiWait))
    XCTAssertTrue(el(app, "review.tab.row.bl-ts-02").exists, "each Tailscale payment has its own row")
    XCTAssertTrue(el(app, "review.tab.row.bl-ts-unverified").exists)
    XCTAssertEqual(groupRows(app).count, 0)
    attach(app, "Review · Tab · one row per payment")
    try audit(app)

    tap(app, "review.tab.start")
    XCTAssertTrue(el(app, "review.position").waitForLabel("1 of 30"))
    XCTAssertFalse(el(app, "review.sortEach").exists)
    XCTAssertFalse(el(app, "review.strip.notThis").exists)
    XCTAssertFalse(el(app, "review.result").exists)
    attach(app, "Review · Deck · one card per payment")
    try audit(app)
  }

  @MainActor
  func testASwipeAndATapSortACard() throws {
    let app = launch(scenario: "mayaBacklog")
    openReview(app)
    openDeck(app, at: "bl-saffron")
    let merchant = el(app, "review.merchant")
    XCTAssertTrue(merchant.label.hasPrefix("Saffron Lane Tailor"), merchant.label)
    el(app, "review.card").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
      .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.45)))
    XCTAssertTrue(el(app, "pick.close").waitForExistence(timeout: uiWait))
    XCTAssertTrue(app.staticTexts["Need · which one?"].exists)
    XCTAssertFalse(el(app, "pick.commit").exists)
    XCTAssertFalse(el(app, "pick.history").exists)
    attach(app, "Review · Pick a need · one payment")
    try audit(app, overSheet: true)
    el(app, "pick.groceries").tap()
    XCTAssertTrue(app.staticTexts["Sorted into Groceries"].waitForExistence(timeout: uiWait))
    XCTAssertTrue(el(app, "review.position").waitForLabel("2 of 30"))
    XCTAssertFalse(merchant.label.hasPrefix("Saffron Lane Tailor"), merchant.label)
  }

  @MainActor
  func testUseSortsASuggestedCardInOneTap() throws {
    let app = launch(scenario: "mayaBacklog")
    openReview(app)
    openDeck(app, at: "bl-bright-10")
    let use = el(app, "review.use")
    XCTAssertTrue(use.waitForExistence(timeout: uiWait))
    XCTAssertEqual(use.label, "Use Shopping")
    use.tap()
    XCTAssertTrue(app.staticTexts["Sorted into Shopping"].waitForExistence(timeout: uiWait))
    XCTAssertTrue(el(app, "review.position").waitForLabel("2 of 30"))
    XCTAssertFalse(el(app, "review.merchant").label.hasPrefix("Brightwell Academy"), el(app, "review.merchant").label)
  }

  @MainActor
  func testAlwaysUseOnOneCardFilesTheMerchantsOtherCardsAndUndoBringsThemBack() throws {
    let app = launch(scenario: "mayaBacklog")
    openReview(app)
    openDeck(app, at: "bl-qasr-4")
    alwaysUseGroceries(app)
    let toast = el(app, "toast")
    XCTAssertTrue(toast.waitForExistence(timeout: uiWait))
    XCTAssertTrue(app.staticTexts[Self.qasrLine].exists, toast.debugDescription)
    XCTAssertTrue(el(app, "review.position").waitForLabel("2 of 30"))
    attach(app, "Review · Deck · undo line after Always use")
    toast.buttons["Undo"].tap()
    XCTAssertTrue(el(app, "review.position").waitForLabel("1 of 30"))
    XCTAssertTrue(el(app, "review.merchant").waitForLabel(containing: "Qasr Corner Store"))
    try audit(app)

    tap(app, "review.close")
    let count = el(app, "review.tab.count")
    XCTAssertTrue(count.waitForLabel("30 to sort · about 5 minutes"), count.label)
    XCTAssertTrue(el(app, "review.tab.row.bl-qasr-5").exists && el(app, "review.tab.row.bl-qasr-6").exists)

    openDeck(app, at: "bl-qasr-4")
    alwaysUseGroceries(app)
    XCTAssertTrue(app.staticTexts[Self.qasrLine].waitForExistence(timeout: uiWait))
    tap(app, "review.close")
    XCTAssertTrue(count.waitForLabel("27 to sort · about 5 minutes"), count.label)
    for id in ["bl-qasr-4", "bl-qasr-5", "bl-qasr-6"] {
      XCTAssertFalse(el(app, "review.tab.row.\(id)").exists, id)
    }
  }

  @MainActor
  func testSortedForYouListsTheBatchAndUndoAllPutsItBack() throws {
    let app = launch(scenario: "mayaBacklog")
    openReview(app)
    openDeck(app, at: "bl-qasr-4")
    alwaysUseGroceries(app)
    XCTAssertTrue(app.staticTexts[Self.qasrLine].waitForExistence(timeout: uiWait))
    tap(app, "review.close")

    app.tabBars.firstMatch.buttons["Home"].tap()
    let look = el(app, "home.sortedForYou")
    XCTAssertTrue(look.waitForExistence(timeout: uiWait))
    XCTAssertEqual(look.label, "5 payments sorted for you this week. Look.")
    XCTAssertTrue(scroll(app, toShow: look))
    look.tap()
    let undoAll = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'sortedForYou.undoAll.'")).firstMatch
    XCTAssertTrue(undoAll.waitForExistence(timeout: uiWait))
    XCTAssertEqual(undoAll.label, "Undo all 5")
    let stopRule = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'sortedForYou.stopRule.'")).firstMatch
    XCTAssertTrue(stopRule.exists)
    attach(app, "Home · Sorted for you")
    try audit(app)
    undoAll.tap()
    XCTAssertTrue(el(app, "sortedForYou.empty").waitForExistence(timeout: uiWait))
  }

  @MainActor
  func testTheUndoLineAndSortedForYouReadAtTheLargestTextSizes() throws {
    let app = launch(scenario: "mayaBacklog", arguments: Self.largeText)
    openReview(app)
    attach(app, "Review · Tab · accessibility3")
    try audit(app, atLargeText: true)
    openDeck(app, at: "bl-qasr-4")
    alwaysUseGroceries(app)
    XCTAssertTrue(el(app, "toast").waitForExistence(timeout: uiWait))
    attach(app, "Review · Deck · undo line · accessibility3")
    try audit(app, atLargeText: true)
    tap(app, "review.close")
    XCTAssertTrue(el(app, "review.tab.count").waitForExistence(timeout: uiWait))

    app.tabBars.firstMatch.buttons["Home"].tap()
    let look = el(app, "home.sortedForYou")
    XCTAssertTrue(look.waitForExistence(timeout: uiWait))
    XCTAssertTrue(scroll(app, toShow: look))
    attach(app, "Home · sorted for you row · accessibility3")
    try audit(app, atLargeText: true)
    look.tap()
    let undoAll = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'sortedForYou.undoAll.'")).firstMatch
    XCTAssertTrue(undoAll.waitForExistence(timeout: uiWait))
    attach(app, "Home · Sorted for you · accessibility3")
    try audit(app, atLargeText: true)
  }
}
