import XCTest

final class SecurityRecoveryUITests: XCTestCase {
  static let phrase = SignInSecurityUITests.phrase
  static let ax3 = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"]
  static let ax5 = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]

  override func setUp() {
    continueAfterFailure = false
  }

  @MainActor
  func testAFreezeOnlyWeCanLiftOffersAPersonAndNoUnfreeze() throws {
    let app = launch(scenario: "frozenNeedsUs")
    XCTAssertTrue(el(app, "frozen.talk").waitForExistence(timeout: 15))
    XCTAssertFalse(el(app, "frozen.unfreeze").exists)
    XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'only we can lift it'")).firstMatch.exists)
    attach(app, "Frozen · needs us")
    try audit(app)
  }

  @MainActor
  func testAPasskeyOnlyAccountUnfreezesWithFaceIDAlone() throws {
    let app = launch(scenario: "frozenPasskeyOnly")
    tap(app, "frozen.unfreeze", timeout: 15)
    XCTAssertTrue(el(app, "unfreeze.passkey").waitForExistence(timeout: uiWait))
    XCTAssertFalse(el(app, "unfreeze.password").exists)
    XCTAssertFalse(el(app, "orDivider.label").exists)
    XCTAssertFalse(app.staticTexts["Your passkey is enough on its own."].exists)
    attach(app, "Unfreeze · passkey only")
  }

  @MainActor
  func testUnfreezeStaysOnScreenAtTheLargestSizes() throws {
    for size in [Self.ax3, Self.ax5] {
      let app = launch(scenario: "frozen", arguments: size)
      let title = app.staticTexts["Your account is frozen"]
      XCTAssertTrue(title.waitForExistence(timeout: 15))
      let unfreeze = el(app, "frozen.unfreeze")
      for _ in 0..<6 where !unfreeze.isHittable { app.swipeUp() }
      XCTAssertTrue(unfreeze.isHittable, "\(size)")
      unfreeze.tap()
      let passkey = el(app, "unfreeze.passkey")
      XCTAssertTrue(passkey.waitForExistence(timeout: uiWait))
      let window = app.windows.firstMatch.frame
      XCTAssertGreaterThanOrEqual(passkey.frame.minX, window.minX - 0.5, "\(size)")
      XCTAssertLessThanOrEqual(passkey.frame.maxX, window.maxX + 0.5, "\(size)")
      let label = el(app, "orDivider.label")
      XCTAssertTrue(label.exists)
      XCTAssertGreaterThanOrEqual(label.frame.minX, window.minX - 0.5, "\(size)")
      XCTAssertLessThanOrEqual(label.frame.maxX, window.maxX + 0.5, "\(size)")
      let show = app.buttons["Show password"].firstMatch
      _ = dragUntilHittable(app, show)
      XCTAssertTrue(show.isHittable, "\(size)")
      XCTAssertLessThanOrEqual(show.frame.maxX, window.maxX + 0.5, "\(size)")
      attach(app, "Unfreeze · \(size.last ?? "")")
      app.terminate()
    }
  }

  @MainActor
  func testTheDividerLabelStaysOnOneLineAtTheDefaultSize() throws {
    let app = launch(scenario: "frozen")
    tap(app, "frozen.unfreeze", timeout: 15)
    let label = el(app, "orDivider.label")
    XCTAssertTrue(label.waitForExistence(timeout: uiWait))
    XCTAssertLessThan(label.frame.height, 24)
  }

  @MainActor
  func testUnlockShowsWithTheKeyboardUpOnceTheTwelfthWordIsIn() throws {
    let app = launch(scenario: "unlockPasswordOnly")
    tap(app, "unlock.words", timeout: 15)
    XCTAssertTrue(el(app, "phraseEntry.field").waitForExistence(timeout: uiWait))
    type(app, "phraseEntry.field", Self.phrase.joined(separator: " "))
    let submit = el(app, "unlock.submit")
    XCTAssertTrue(submit.waitForExistence(timeout: uiWait))
    XCTAssertTrue(app.keyboards.firstMatch.exists)
    XCTAssertTrue(submit.isHittable)
    attach(app, "Unlock · 12 words in, keyboard up")
    submit.tap()
    XCTAssertTrue(el(app, "phraseEntry.field").waitForNonExistence(timeout: uiWait))
  }

  @MainActor
  func testAWrongWordIsFixedInPlace() throws {
    let app = launch(scenario: "unlockPasswordOnly")
    tap(app, "unlock.words", timeout: 15)
    XCTAssertTrue(el(app, "phraseEntry.field").waitForExistence(timeout: uiWait))
    var words = Self.phrase
    words[2] = "scisors"
    type(app, "phraseEntry.field", words.prefix(5).joined(separator: " ") + " ")
    XCTAssertTrue(el(app, "phraseEntry.unknown").waitForExistence(timeout: uiWait))
    let cell = el(app, "phraseEntry.cellButton.2")
    XCTAssertEqual(cell.label, "Word 3, scisors")
    cell.tap()
    let edit = el(app, "phraseEntry.editField")
    XCTAssertTrue(edit.waitForExistence(timeout: uiWait))
    edit.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 7) + "scissors\n")
    XCTAssertTrue(el(app, "phraseEntry.unknown").waitForNonExistence(timeout: uiWait))
    XCTAssertEqual(el(app, "phraseEntry.cellButton.2").label, "Word 3, scissors")
    XCTAssertEqual(el(app, "phraseEntry.cellButton.4").label, "Word 5, gather")
    attach(app, "Unlock · word fixed in place")
  }

  @MainActor
  func testTheTwelveWordsReadDownEachColumn() throws {
    let app = launch(scenario: "passkeyUser")
    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: 15))
    app.buttons["header.profile"].firstMatch.tap()
    tap(app, "profile.security")
    tap(app, "security.viewPhrase")
    tap(app, "confirm.submit")
    tap(app, "phrase.reveal")
    let grid = el(app, "phrase.grid")
    XCTAssertTrue(grid.waitForExistence(timeout: uiWait))
    let labels = grid.descendants(matching: .any)
      .matching(NSPredicate(format: "label BEGINSWITH 'Word '")).allElementsBoundByIndex.map(\.label)
    XCTAssertEqual(labels.compactMap { Int($0.dropFirst(5).prefix { $0.isNumber }) }, Array(1...12))
  }
}
