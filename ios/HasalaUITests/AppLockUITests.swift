import XCTest

final class AppLockUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  @MainActor
  private func leaveAndComeBack(_ app: XCUIApplication) {
    XCUIDevice.shared.press(.home)
    XCTAssertTrue(app.wait(for: .runningBackground, timeout: uiWait))
    app.activate()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: uiWait))
  }

  @MainActor
  func testTheLockCoversTheAppUntilItUnlocks() throws {
    let app = launch(arguments: ["-HasalaAppLock", "cancel,pass,cancel,pass", "-HasalaAppLockGrace", "0"])
    XCTAssertTrue(el(app, "lock.unlock").waitForExistence(timeout: uiWait))
    XCTAssertFalse(el(app, "home.hero.left").exists, "Home shows under the lock")
    attach(app, "App lock · Locked")
    try audit(app)

    tap(app, "lock.unlock")
    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: uiWait))
    XCTAssertFalse(el(app, "lock.unlock").exists)

    app.buttons["header.profile"].firstMatch.tap()
    XCTAssertTrue(el(app, "profile.name").waitForExistence(timeout: uiWait))

    leaveAndComeBack(app)
    XCTAssertTrue(el(app, "lock.unlock").waitForExistence(timeout: uiWait))
    XCTAssertFalse(el(app, "profile.name").exists, "the profile sheet shows over the lock")
    tap(app, "lock.unlock")
    XCTAssertTrue(el(app, "profile.name").waitForExistence(timeout: uiWait))
  }

  @MainActor
  func testTurningTheLockOffInProfile() {
    let app = launch(arguments: ["-HasalaAppLock", "pass", "-HasalaAppLockGrace", "0"])
    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: uiWait))
    app.buttons["header.profile"].firstMatch.tap()
    XCTAssertTrue(el(app, "profile.name").waitForExistence(timeout: uiWait))

    let toggle = app.switches["profile.faceID"].firstMatch
    XCTAssertTrue(toggle.waitForExistence(timeout: uiWait))
    dragUntilHittable(app, toggle)
    XCTAssertEqual(toggle.value as? String, "1")
    toggle.tap()
    let off = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '0'"), object: toggle)
    XCTAssertEqual(XCTWaiter.wait(for: [off], timeout: uiWait), .completed, "the lock did not turn off")

    leaveAndComeBack(app)
    XCTAssertTrue(el(app, "profile.name").waitForExistence(timeout: uiWait))
    XCTAssertFalse(el(app, "lock.unlock").exists, "the lock came back after it was turned off")
  }
}
