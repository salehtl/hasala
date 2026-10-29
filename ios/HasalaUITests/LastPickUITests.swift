import XCTest

final class LastPickUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  @MainActor
  func openDeck(_ app: XCUIApplication, at id: String, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: 30), file: file, line: line)
    app.tabBars.firstMatch.buttons["Review"].tap()
    XCTAssertTrue(el(app, "review.tab.start").waitForExistence(timeout: uiWait), file: file, line: line)
    let row = el(app, "review.tab.row.\(id)")
    XCTAssertTrue(row.waitForExistence(timeout: uiWait), "no row for \(id)", file: file, line: line)
    XCTAssertTrue(scroll(app, toShow: row), "could not reach \(id)", file: file, line: line)
    row.tap()
    XCTAssertTrue(el(app, "review.position").waitForLabel("1 of 30"), "the deck did not open at \(id)", file: file, line: line)
  }

  @MainActor
  func testSortingAMerchantMakesItsNextPaymentSuggestYourLastPickAndUseFilesIt() throws {
    let app = launch(scenario: "mayaBacklog")
    openDeck(app, at: "bl-alnoor-t-2")
    let merchant = el(app, "review.merchant")
    XCTAssertTrue(merchant.label.hasPrefix("Al Noor Trading"), merchant.label)
    XCTAssertFalse(el(app, "review.use").exists)

    tap(app, "review.pill.need", opening: "pick.close")
    el(app, "pick.groceries").tap()
    XCTAssertTrue(el(app, "pick.close").waitForNonExistence(timeout: uiWait))
    XCTAssertTrue(app.staticTexts["Sorted into Groceries"].waitForExistence(timeout: uiWait))
    XCTAssertTrue(el(app, "review.position").waitForLabel("2 of 30"))
    XCTAssertTrue(merchant.waitForLabel(containing: "Al Noor Trading"), merchant.label)
    XCTAssertTrue(merchant.label.contains("Looks like Groceries. Your last pick."), merchant.label)
    let by = el(app, "review.suggestedBy")
    XCTAssertTrue(by.waitForExistence(timeout: uiWait))
    XCTAssertEqual(by.label, "Looks like Groceries, Your last pick")
    let use = el(app, "review.use")
    XCTAssertEqual(use.label, "Use Groceries")
    attach(app, "Review · Deck · your last pick")
    try audit(app)

    tap(app, "review.pill.need", opening: "pick.close")
    let suggested = el(app, "pick.groceries")
    XCTAssertEqual(suggested.label, "Groceries, suggested")
    XCTAssertGreaterThan(suggested.frame.minY, el(app, "pick.utilities").frame.minY)
    XCTAssertGreaterThan(el(app, "pick.utilities").frame.minY, el(app, "pick.rent").frame.minY)
    tap(app, "pick.close")
    XCTAssertTrue(el(app, "pick.close").waitForNonExistence(timeout: uiWait))
    XCTAssertTrue(el(app, "toast").waitForNonExistence(timeout: 12))

    use.tap()
    XCTAssertTrue(app.staticTexts["Sorted into Groceries"].waitForExistence(timeout: uiWait))
    XCTAssertTrue(el(app, "review.position").waitForLabel("3 of 30"))
    XCTAssertFalse(merchant.label.hasPrefix("Al Noor Trading"), merchant.label)

    tap(app, "review.close")
    XCTAssertTrue(el(app, "review.tab.count").waitForLabel("28 to sort · about 5 minutes"))
    XCTAssertFalse(el(app, "review.tab.row.bl-alnoor-t-3").exists)
    XCTAssertFalse(el(app, "review.tab.row.bl-alnoor-t-2").exists)
  }
}
