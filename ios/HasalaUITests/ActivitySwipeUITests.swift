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
  func testArchivedListsEveryMonthAndProfileOpensIt() throws {
    let app = launch()
    app.tabBars.firstMatch.buttons["Activity"].tap()
    let row = el(app, "txn.carrefour")
    XCTAssertTrue(row.waitForExistence(timeout: uiWait))
    XCTAssertTrue(reveal(app, row))
    row.swipeLeft(velocity: .fast)
    XCTAssertTrue(el(app, "toast").staticTexts["Archived"].waitForExistence(timeout: uiWait))
    XCTAssertTrue(row.waitForNonExistence(timeout: uiWait))

    app.tabBars.firstMatch.buttons["Home"].tap()
    tap(app, "home.period", opening: "period.sheet")
    tap(app, "period.preset.lastMonth")
    tap(app, "period.show")
    XCTAssertTrue(app.buttons["home.period"].waitForLabel("Period, September 2026"))
    app.tabBars.firstMatch.buttons["Activity"].tap()

    let chip = app.buttons["activity.chip.archived"]
    XCTAssertTrue(chip.waitForExistence(timeout: uiWait))
    XCTAssertTrue(chip.label.contains("1"), chip.label)
    chip.tap()
    XCTAssertTrue(row.waitForExistence(timeout: uiWait))
    XCTAssertEqual(el(app, "activity.count").label, "1 archived · all time")
    XCTAssertFalse(app.buttons["activity.period"].exists)
    XCTAssertFalse(el(app, "activity.backToThisMonth").exists)
    try audit(app)
    attach(app, "Activity · Archived, all time")

    let all = app.buttons["activity.chip.all"]
    for _ in 0..<3 where all.frame.minX < 0 { app.buttons["activity.chip.archived"].swipeRight() }
    all.tap()
    XCTAssertTrue(app.buttons["activity.period"].waitForExistence(timeout: uiWait))
    XCTAssertEqual(app.buttons["activity.period"].label, "Period, September 2026")
    XCTAssertTrue(row.waitForNonExistence(timeout: uiWait))

    app.buttons["header.profile"].firstMatch.tap()
    let entry = app.buttons["profile.archived"]
    XCTAssertTrue(entry.waitForExistence(timeout: uiWait))
    XCTAssertTrue(entry.label.contains("Archived transactions"), entry.label)
    XCTAssertTrue(entry.label.contains("1 kept out of your plan"), entry.label)
    attach(app, "Profile · Archived transactions")
    tap(app, "profile.archived")
    XCTAssertTrue(el(app, "profile.name").waitForNonExistence(timeout: uiWait))
    XCTAssertTrue(app.tabBars.firstMatch.buttons["Activity"].isSelected)
    XCTAssertTrue(app.buttons["activity.chip.archived"].waitForExistence(timeout: uiWait))
    XCTAssertTrue(app.buttons["activity.chip.archived"].isSelected)
    XCTAssertTrue(row.waitForExistence(timeout: uiWait))
    XCTAssertEqual(el(app, "activity.count").label, "1 archived · all time")

    XCTAssertTrue(reveal(app, row))
    row.swipeLeft(velocity: .fast)
    XCTAssertTrue(el(app, "toast").staticTexts["Restored"].waitForExistence(timeout: uiWait))
    XCTAssertTrue(row.waitForNonExistence(timeout: uiWait))
    XCTAssertTrue(el(app, "activity.empty").waitForExistence(timeout: uiWait))
    XCTAssertEqual(el(app, "activity.count").label, "0 archived · all time")

    app.buttons["header.profile"].firstMatch.tap()
    XCTAssertTrue(el(app, "profile.name").waitForExistence(timeout: uiWait))
    XCTAssertFalse(app.buttons["profile.archived"].exists)
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
