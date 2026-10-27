import XCTest

final class ActivitySwipeUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  @MainActor
  func testSwipeArchivesUndoesAndRestores() throws {
    let app = launch()
    app.tabBars.firstMatch.buttons["Activity"].tap()
    let row = el(app, "txn.carrefour")
    XCTAssertTrue(row.waitForExistence(timeout: uiWait))
    XCTAssertTrue(reveal(app, row))

    row.swipeLeft(velocity: .fast)
    XCTAssertTrue(el(app, "toast").staticTexts["Archived"].waitForExistence(timeout: uiWait))
    XCTAssertTrue(row.waitForNonExistence(timeout: uiWait))
    attach(app, "Activity · swiped to archive")

    el(app, "toast").buttons["Undo"].tap()
    XCTAssertTrue(row.waitForExistence(timeout: uiWait))
    XCTAssertTrue(reveal(app, row))

    row.swipeLeft(velocity: .fast)
    XCTAssertTrue(row.waitForNonExistence(timeout: uiWait))
    let chip = el(app, "activity.chip.archived")
    XCTAssertTrue(chip.waitForExistence(timeout: uiWait))
    chip.tap()
    XCTAssertTrue(row.waitForExistence(timeout: uiWait))
    XCTAssertTrue(reveal(app, row))
    attach(app, "Activity · Archived")

    row.swipeLeft(velocity: .fast)
    XCTAssertTrue(el(app, "toast").staticTexts["Restored"].waitForExistence(timeout: uiWait))
    XCTAssertTrue(row.waitForNonExistence(timeout: uiWait))
  }

  @MainActor
  func testShortSwipeSpringsBackAndKeepsTheRow() throws {
    let app = launch()
    app.tabBars.firstMatch.buttons["Activity"].tap()
    let row = el(app, "txn.carrefour")
    XCTAssertTrue(row.waitForExistence(timeout: uiWait))
    XCTAssertTrue(reveal(app, row))
    let x = row.frame.minX

    let from = row.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5))
    let to = row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.1)
    waitForStill(app)
    XCTAssertTrue(row.exists)
    XCTAssertEqual(row.frame.minX, x, accuracy: 1)
    XCTAssertFalse(el(app, "toast").exists)
  }

  @MainActor
  func testHalfSwipeRevealsArchiveAndATapClosesIt() throws {
    let app = launch()
    app.tabBars.firstMatch.buttons["Activity"].tap()
    let row = el(app, "txn.carrefour")
    XCTAssertTrue(row.waitForExistence(timeout: uiWait))
    XCTAssertTrue(reveal(app, row))
    let x = row.frame.minX
    let frame = row.frame

    func halfSwipe() {
      let from = row.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
      let to = from.withOffset(CGVector(dx: -110, dy: 0))
      from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.2)
      waitForStill(app)
    }

    halfSwipe()
    XCTAssertLessThan(row.frame.minX, x - 40)
    row.tap()
    waitForStill(app)
    XCTAssertEqual(row.frame.minX, x, accuracy: 1)
    XCTAssertFalse(el(app, "txn.merchant").exists)

    halfSwipe()
    app.coordinate(withNormalizedOffset: .zero)
      .withOffset(CGVector(dx: frame.maxX - 30, dy: frame.midY)).tap()
    XCTAssertTrue(el(app, "toast").staticTexts["Archived"].waitForExistence(timeout: uiWait))
    XCTAssertTrue(row.waitForNonExistence(timeout: uiWait))
  }
}
