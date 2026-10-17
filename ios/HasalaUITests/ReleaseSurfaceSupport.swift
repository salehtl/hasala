import XCTest

/// The base of every `ReleaseSurface*` class (plan B7.4): what a Release build shows (App
/// Review Guideline 2.1), checked one area per class. Nothing reads like a placeholder
/// ("later build", "coming soon"), no control leads nowhere, only the beta's account
/// actions are offered (`AccountCapabilities.beta`), no copy promises what the beta doesn't
/// do, and the mail is Gmail and Outlook (personal Microsoft accounts), one mailbox: no work
/// or school account is promised, as the live Microsoft app refuses them.
///
/// The app runs the Maya mock with `-HasalaReleaseSurface`, which gives a Debug build the
/// Release surface and the mock the beta's capabilities. A Release build ignores the
/// argument and always shows that surface: `ios/scripts/test-release-surface.sh` runs every
/// class on a Release-configuration build that links the mock.
class ReleaseSurfaceTestCase: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  /// The app on the Release surface, waiting for Home unless the scenario starts elsewhere.
  @MainActor
  func launchRelease(_ scenario: String = "maya", waitForHome: Bool = true, screen: String? = nil) -> XCUIApplication {
    let app = launch(scenario: scenario, screen: screen, release: true)
    if waitForHome {
      XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: 15), "Home did not appear")
    }
    return app
  }

  /// No element on screen reads like a placeholder.
  @MainActor
  func assertNoPlaceholders(_ app: XCUIApplication, _ screen: String, line: UInt = #line) {
    let predicate = NSPredicate(
      format: "label CONTAINS[c] 'later build' OR label CONTAINS[c] 'coming soon' OR label CONTAINS[c] 'coming in a'"
        + " OR label CONTAINS[c] 'in this build' OR label CONTAINS[c] 'in this beta' OR label CONTAINS[c] 'arrives with'"
        + " OR label CONTAINS[c] 'arrives in' OR label CONTAINS[c] 'arrive in'")
    let hits = app.descendants(matching: .any).matching(predicate).allElementsBoundByIndex.map(\.label)
    XCTAssertTrue(hits.isEmpty, "\(screen) shows placeholder text: \(hits)", line: line)
  }

  /// No label promises a work or school Microsoft account: the live Microsoft app takes
  /// personal accounts only.
  @MainActor
  func assertPersonalAccountsOnly(_ app: XCUIApplication, _ screen: String, line: UInt = #line) {
    assertNoText(app, ["work or school", "Work or school", "Microsoft 365", "Entra", "organisation"], screen, line: line)
  }

  /// None of `ids` (identifiers or labels) is on screen as anything.
  @MainActor
  func assertAbsent(_ app: XCUIApplication, _ ids: [String], _ screen: String, line: UInt = #line) {
    for id in ids {
      XCTAssertFalse(app.descendants(matching: .any)[id].exists, "\(screen) offers \(id)", line: line)
    }
  }

  /// None of `labels` is a button on screen.
  @MainActor
  func assertNoButtons(_ app: XCUIApplication, _ labels: [String], _ screen: String, line: UInt = #line) {
    for label in labels {
      XCTAssertFalse(app.buttons[label].exists, "\(screen) has a \(label) button", line: line)
    }
  }

  @MainActor
  func assertPresent(_ app: XCUIApplication, _ ids: [String], _ screen: String, line: UInt = #line) {
    for id in ids {
      XCTAssertTrue(el(app, id).waitForExistence(timeout: uiWait), "\(screen) is missing \(id)", line: line)
    }
  }

  /// No text on screen contains any of `phrases`.
  @MainActor
  func assertNoText(_ app: XCUIApplication, _ phrases: [String], _ screen: String, line: UInt = #line) {
    for phrase in phrases {
      let hits = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", phrase))
      XCTAssertEqual(hits.count, 0, "\(screen) says '\(phrase)'", line: line)
    }
  }

  /// Some text on screen contains `phrase`.
  @MainActor
  func assertText(_ app: XCUIApplication, _ phrase: String, _ screen: String, line: UInt = #line) {
    let hit = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", phrase)).firstMatch
    XCTAssertTrue(hit.waitForExistence(timeout: uiWait), "\(screen) does not say '\(phrase)'", line: line)
  }
}
