import XCTest

final class AddTransactionUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  @MainActor
  func testAddingATransactionShowsItsRowInActivity() throws {
    let app = launch(scenario: "maya")
    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: 15))
    app.tabBars.firstMatch.buttons["Activity"].tap()
    let count = el(app, "activity.count")
    XCTAssertTrue(count.waitForExistence(timeout: uiWait))
    XCTAssertEqual(count.label, "26 transactions this month")

    app.tabBars.firstMatch.buttons["Add a transaction"].tap()
    XCTAssertTrue(el(app, "add.amount").waitForExistence(timeout: uiWait))
    XCTAssertFalse(el(app, "add.save").isEnabled)
    attach(app, "Add transaction · Empty")
    try audit(app)
    typeOnKeypad(app, "32")
    tap(app, "keypad.decimal")
    typeOnKeypad(app, "75")
    XCTAssertEqual(el(app, "add.save").label, "Add AED 32.75")
    XCTAssertFalse(el(app, "add.save").isEnabled)

    type(app, "add.merchant", "Corner Bakery")
    app.toolbars.buttons["Done"].firstMatch.tap()
    XCTAssertTrue(el(app, "keypad.1").waitForExistence(timeout: uiWait))
    tap(app, "add.category", opening: "addCategory.dining")
    tap(app, "addCategory.dining")
    XCTAssertTrue(el(app, "add.save").waitForExistence(timeout: uiWait))
    XCTAssertTrue(el(app, "add.save").isEnabled)
    attach(app, "Add transaction · Filled")
    try audit(app)

    tap(app, "add.save")
    XCTAssertTrue(el(app, "add.amount").waitForNonExistence(timeout: uiWait))
    let row = el(app, "txn.manual-1")
    XCTAssertTrue(row.waitForExistence(timeout: uiWait), "the new row is not in Activity")
    XCTAssertTrue(row.label.contains("Corner Bakery"), row.label)
    XCTAssertTrue(count.waitForLabel("27 transactions this month"), count.label)
    attach(app, "Activity · Added")
    XCTAssertTrue(reveal(app, row))
    row.tap()
    XCTAssertTrue(el(app, "txn.merchant").waitForExistence(timeout: uiWait))
    XCTAssertTrue(el(app, "txn.merchant").label.contains("Corner Bakery"), el(app, "txn.merchant").label)
  }

  @MainActor
  func testTheAddButtonOpensAddATransactionOnEveryTab() throws {
    let app = launch(scenario: "maya")
    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: 15))
    let tabBar = app.tabBars.firstMatch
    let add = tabBar.buttons["Add a transaction"]
    for (tab, id) in [("Home", "home.hero.left"), ("Projects", "projects.new"), ("Review", "review.tab.count"),
                      ("Activity", "activity.count")] {
      tabBar.buttons[tab].tap()
      XCTAssertTrue(el(app, id).waitForExistence(timeout: uiWait))
      XCTAssertTrue(add.isHittable, "\(tab) has no add button")
      XCTAssertFalse(add.isSelected)
      add.tap()
      XCTAssertTrue(el(app, "add.amount").waitForExistence(timeout: uiWait), "the add button on \(tab) opened nothing")
      tap(app, "add.close")
      XCTAssertTrue(el(app, "add.amount").waitForNonExistence(timeout: uiWait))
      XCTAssertTrue(el(app, id).waitForExistence(timeout: uiWait), "closing Add a transaction left \(tab)")
      XCTAssertTrue(tabBar.buttons[tab].isSelected, "the add button left \(tab)")
      XCTAssertFalse(add.isSelected)
    }
  }
}
