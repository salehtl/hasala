import XCTest

/// The profile on the Maya mock: Bills, rules, notifications and Hide amounts.
final class ProfileUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  /// The Maya mock, once Home has appeared.
  @MainActor
  private func launchHome(_ scenario: String = "maya", arguments: [String] = []) -> XCUIApplication {
    let app = launch(scenario: scenario, arguments: arguments)
    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: 15))
    return app
  }

  /// Profile: the sheet, Bills (track a found bill), rules, notifications, Hide amounts.
  @MainActor
  func testProfileBillsAndSettings() throws {
    let app = launchHome()
    app.buttons["header.profile"].firstMatch.tap()
    XCTAssertTrue(el(app, "profile.name").waitForExistence(timeout: 5))
    XCTAssertTrue(el(app, "profile.bankAlerts").label.contains("Bank alerts are working"))
    attach(app, "Profile")
    try audit(app)

    el(app, "profile.bills").tap()
    let next14 = el(app, "bills.next14")
    XCTAssertTrue(next14.waitForExistence(timeout: 5))
    XCTAssertEqual(next14.label, "AED 1,039.15")
    attach(app, "Bills")
    try audit(app)
    let track = el(app, "bills.track.apple-bill")
    XCTAssertTrue(reveal(app, track))
    track.tap()
    XCTAssertTrue(app.staticTexts["Tracking Apple.com/bill"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["10 tracked"].waitForExistence(timeout: 5))
    app.navigationBars.buttons.firstMatch.tap()

    el(app, "profile.rules").tap()
    XCTAssertTrue(el(app, "rule.r-carrefour").waitForExistence(timeout: 5))
    attach(app, "Categories and rules")
    try audit(app)
    app.navigationBars.buttons.firstMatch.tap()

    let notifications = el(app, "profile.notifications")
    XCTAssertTrue(reveal(app, notifications))
    notifications.tap()
    el(app, "notifications.everything").tap()
    app.navigationBars.buttons.firstMatch.tap()
    XCTAssertTrue(el(app, "profile.notifications").waitForLabel(containing: "Everything"))
    el(app, "profile.close").tap()

    // Hide amounts reaches Activity and the transaction sheet.
    app.buttons["header.hideAmounts"].firstMatch.tap()
    app.tabBars.firstMatch.buttons["Activity"].tap()
    let talabat = el(app, "txn.talabat")
    XCTAssertTrue(talabat.waitForExistence(timeout: 5))
    talabat.tap()
    XCTAssertTrue(el(app, "txn.amount").waitForLabel("Amount hidden"))
    attach(app, "Transaction · Amounts hidden")
  }

  /// Profile at `.accessibility3` (spec 04 §17).
  @MainActor
  func testProfileAtLargeTextSizes() throws {
    let app = launchHome(arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"])

    // Profile and Bills.
    app.buttons["header.profile"].firstMatch.tap()
    XCTAssertTrue(el(app, "profile.name").waitForExistence(timeout: 5))
    try audit(app, atLargeText: true)
    for id in ["profile.rules", "profile.faceID", "profile.signOut"] {
      XCTAssertTrue(reveal(app, el(app, id)), "could not reach \(id)")
      attach(app, "AX3 · Profile · \(id)")
      try audit(app, atLargeText: true)
    }
  }
}
