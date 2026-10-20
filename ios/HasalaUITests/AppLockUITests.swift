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

  @MainActor
  private func openSignInAndSecurity(_ app: XCUIApplication) -> XCUIElement {
    app.buttons["header.profile"].firstMatch.tap()
    XCTAssertTrue(el(app, "profile.name").waitForExistence(timeout: uiWait))
    tap(app, "profile.security", opening: "security.hero")
    let toggle = app.switches["security.appLock"].firstMatch
    XCTAssertTrue(toggle.waitForExistence(timeout: uiWait), "Sign-in & security has no app lock row")
    dragUntilHittable(app, toggle)
    return toggle
  }

  @MainActor
  private func waitForValue(_ toggle: XCUIElement, _ value: String, _ message: String) {
    let reached = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: toggle)
    XCTAssertEqual(XCTWaiter.wait(for: [reached], timeout: uiWait), .completed, message)
  }

  @MainActor
  func testTurningTheLockOffAndOnInSignInAndSecurity() {
    let app = launch(arguments: ["-HasalaAppLock", "cancel,pass,pass,pass,cancel", "-HasalaAppLockGrace", "0"])
    tap(app, "lock.unlock")
    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: uiWait))
    let toggle = openSignInAndSecurity(app)
    XCTAssertEqual(toggle.value as? String, "1")
    XCTAssertTrue(el(app, "security.appLock.note").exists)
    XCTAssertFalse(el(app, "security.appLock.settings").exists)

    toggle.tap()
    waitForValue(toggle, "0", "the lock did not turn off")
    toggle.tap()
    waitForValue(toggle, "1", "the lock did not turn back on")

    leaveAndComeBack(app)
    XCTAssertTrue(el(app, "lock.unlock").waitForExistence(timeout: uiWait), "the lock did not hold after turning it on")
  }

  @MainActor
  func testAFailedCheckKeepsTheLockAsItWas() {
    let app = launch(arguments: ["-HasalaAppLock", "cancel,pass,fail,pass", "-HasalaAppLockGrace", "0"])
    tap(app, "lock.unlock")
    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: uiWait))
    let toggle = openSignInAndSecurity(app)
    toggle.tap()
    XCTAssertTrue(el(app, "security.appLock.failed").waitForExistence(timeout: uiWait))
    XCTAssertEqual(toggle.value as? String, "1")
    toggle.tap()
    waitForValue(toggle, "0", "the lock did not turn off after a retry")
    XCTAssertFalse(el(app, "security.appLock.failed").exists)
  }

  @MainActor
  func testSignInAndSecurityExplainsAMissingPasscode() throws {
    let app = launch(arguments: ["-HasalaAppLock", "none"])
    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: uiWait))
    _ = openSignInAndSecurity(app)
    XCTAssertTrue(el(app, "security.appLock.note").exists)
    XCTAssertTrue(el(app, "security.appLock.settings").exists)
    attach(app, "Sign-in & security · App lock · no passcode")
    try audit(app)
  }

  @MainActor
  func testSignInAndSecurityExplainsWhenFaceIDIsNotSetUp() {
    let app = launch(arguments: ["-HasalaAppLock", "pass", "-HasalaAppLockIssue", "notEnrolled"])
    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: uiWait))
    let toggle = openSignInAndSecurity(app)
    XCTAssertTrue(toggle.isEnabled)
    XCTAssertTrue(el(app, "security.appLock.settings").exists)
    XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "isn't set up")).firstMatch.exists)
    attach(app, "Sign-in & security · App lock · Face ID not set up")
  }
}
