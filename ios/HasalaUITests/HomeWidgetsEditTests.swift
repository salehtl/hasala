import XCTest

final class HomeWidgetsEditTests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  @MainActor
  private func widget(_ app: XCUIApplication, _ id: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: "widget.\(id)").firstMatch
  }

  @MainActor
  private func shown(_ app: XCUIApplication, _ id: String) -> XCUIElement {
    let e = widget(app, id)
    XCTAssertTrue(e.waitForExistence(timeout: uiWait), "widget.\(id) is missing")
    XCTAssertTrue(scroll(app, toShow: e), "could not scroll to widget.\(id)")
    return e
  }

  @MainActor
  func testGalleryStaysInsideTheSheetWidth() throws {
    for scenario in ["maya", "mayaHidden"] {
      let app = launch(scenario: scenario, screen: "home.gallery", motion: "off")
      let sheet = el(app, "gallery.sheet")
      XCTAssertTrue(sheet.waitForExistence(timeout: uiWait))
      let cell = el(app, "gallery.spentSoFar")
      XCTAssertTrue(cell.waitForExistence(timeout: uiWait))
      XCTAssertEqual(cell.frame.minX, 20, accuracy: 0.01, "\(scenario): the gallery is wider than its sheet")
      let wide = el(app, "gallery.budgetPace")
      XCTAssertEqual(wide.frame.width, sheet.frame.width - 40, accuracy: 0.01, "\(scenario): a wide widget overflows")
      app.terminate()
    }
  }

  @MainActor
  func testEditRemoveAddReorderAndRelaunch() throws {
    var app = launch(scenario: "maya", motion: "off")
    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: uiWait))

    tap(app, "home.editWidgets", opening: "home.doneWidgets")
    _ = shown(app, "budgetPace")
    attach(app, "Home · Edit mode")

    tap(app, "widget.netWorth.remove")
    XCTAssertTrue(widget(app, "netWorth").waitForNonExistence(timeout: uiWait), "Net worth is still on Home")

    let pace = shown(app, "budgetPace")
    let grip = widget(app, "nextBill").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    grip.press(forDuration: 1.2, thenDragTo: pace.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)))
    XCTAssertTrue(el(app, "home.doneWidgets").waitForExistence(timeout: 5), "Home stopped answering after the drag")
    XCTAssertLessThan(widget(app, "nextBill").frame.minY, widget(app, "budgetPace").frame.minY,
                      "Next bill did not move above Budget pace")
    let started = Date()
    XCTAssertTrue(el(app, "home.addWidget").waitForExistence(timeout: 5))
    XCTAssertLessThan(Date().timeIntervalSince(started), 5, "Home is busy after the drag")

    tap(app, "home.addWidget", opening: "gallery.sheet")
    XCTAssertEqual(el(app, "gallery.budgetPace").value as? String, "On Home")
    attach(app, "Home · Add a widget")
    tap(app, "gallery.toReview")
    XCTAssertTrue(el(app, "gallery.sheet").waitForNonExistence(timeout: uiWait))
    _ = shown(app, "toReview")

    tap(app, "home.addWidget", opening: "gallery.sheet")
    tap(app, "gallery.categoryWatch", opening: "widgetConfig.sheet")
    attach(app, "Home · Category watch configuration")
    tap(app, "widgetConfig.option.groceries")
    tap(app, "widgetConfig.save")
    XCTAssertTrue(el(app, "gallery.sheet").waitForNonExistence(timeout: uiWait))
    _ = shown(app, "categoryWatch.groceries")

    let done = el(app, "home.doneWidgets")
    XCTAssertTrue(scroll(app, toShow: done), "could not scroll back to Done")
    done.tap()
    XCTAssertTrue(el(app, "home.editWidgets").waitForExistence(timeout: uiWait))
    _ = shown(app, "nextBill")
    attach(app, "Home · After the edits")

    app.terminate()
    app = launch(scenario: "maya", motion: "off", arguments: ["-HasalaKeepHomeLayout"])
    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: uiWait))
    XCTAssertFalse(widget(app, "netWorth").exists, "Net worth came back after a relaunch")
    _ = shown(app, "toReview")
    _ = shown(app, "categoryWatch.groceries")
    let bill = shown(app, "nextBill")
    XCTAssertLessThan(bill.frame.minY, widget(app, "budgetPace").frame.minY, "the order was not kept")
    attach(app, "Home · After a relaunch")

    app.terminate()
    app = launch(scenario: "maya", motion: "off")
    XCTAssertTrue(shown(app, "netWorth").exists, "a fresh mock launch kept the last layout")
  }

  @MainActor
  func testEditModeAccessibility() throws {
    for large in [false, true] {
      let size = large ? ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"] : []
      let app = launch(scenario: nil, screen: "home.edit", motion: "off", arguments: size)
      _ = shown(app, "budgetPace")
      XCTAssertTrue(el(app, "home.doneWidgets").exists)
      XCTAssertTrue(el(app, "widget.budgetPace.remove").exists)
      XCTAssertEqual(el(app, "widget.budgetPace.remove").label, "Remove Budget pace")
      attach(app, large ? "AX3 · Home · Edit mode" : "Home · Edit mode")
      try audit(app, atLargeText: large)
      let add = el(app, "home.addWidget")
      XCTAssertTrue(reveal(app, add))
      XCTAssertEqual(add.label, "Add widget")
      try audit(app, atLargeText: large)
      add.tap()
      XCTAssertTrue(el(app, "gallery.sheet").waitForExistence(timeout: uiWait))
      attach(app, large ? "AX3 · Add a widget" : "Add a widget")
      try audit(app, atLargeText: large, overSheet: true)
      app.terminate()
    }
  }
}
