import XCTest

final class SyncHaltUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  @MainActor
  func testACursorPastTheServerShowsTheHaltWallAndTryAgainGetsThrough() throws {
    let app = launch(release: true, arguments: ["-HasalaSyncHalt", "tampered.chainBreak"])
    XCTAssertTrue(el(app, "wall.syncHalted").waitForExistence(timeout: uiWait), "no halt wall")
    XCTAssertTrue(app.staticTexts["Hasala stopped syncing"].exists)
    XCTAssertTrue(
      app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] 'is kept'")).firstMatch.exists,
      "the wall does not say the data stays")
    XCTAssertTrue(el(app, "wall.syncHalted.code").label.contains("tampered.chainBreak"))
    XCTAssertTrue(el(app, "wall.tryAgain").exists)
    XCTAssertTrue(el(app, "wall.support").exists)
    XCTAssertTrue(el(app, "wall.support.web").exists)
    XCTAssertFalse(el(app, "wall.erase").exists, "the halt wall offers to remove data")
    XCTAssertTrue(
      el(app, "wall.syncHalted").frame.contains(app.windows.firstMatch.frame), "the wall does not cover the screen")
    try audit(app)
    attach(app, "Sync halt · tampered")

    el(app, "wall.tryAgain").tap()
    XCTAssertTrue(el(app, "wall.syncHalted").waitForNonExistence(timeout: uiWait), "the wall stayed after a run got through")
    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: uiWait))
  }

  @MainActor
  func testARestoredServerSaysSo() throws {
    let app = launch(release: true, arguments: ["-HasalaSyncHalt", "serverRestored"])
    XCTAssertTrue(el(app, "wall.syncHalted").waitForExistence(timeout: uiWait), "no halt wall")
    XCTAssertTrue(
      app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] 'restored from an earlier copy'"))
        .firstMatch.exists)
    XCTAssertTrue(el(app, "wall.syncHalted.code").label.contains("serverRestored"))
    XCTAssertFalse(el(app, "wall.erase").exists)
  }
}
