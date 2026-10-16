import XCTest

/// The Gate A0 smoke test: the Debug app launches into the Maya scenario, Home shows
/// the board's hero, every tab opens, Hide amounts hides and restores figures, and
/// the profile sheet shows the build footer. Screenshots are attached to the report.
/// Every screen it reaches also passes `performAccessibilityAudit()` (spec 04 §17), here
/// at the default text size and in `testAccessibilityAtLargeTextSizes` at `.accessibility3`.
final class SmokeTests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  @MainActor
  func testLaunchHomeTabsAndHideAmounts() throws {
    let app = XCUIApplication()
    app.launchArguments = ["-HasalaScenario", "maya"]
    app.launch()

    let hero = app.descendants(matching: .any)["home.hero.left"]
    XCTAssertTrue(hero.waitForExistence(timeout: 15), "Home hero did not appear")
    XCTAssertEqual(hero.label, "AED 7,417.55")
    XCTAssertTrue(app.staticTexts["Needs you"].exists)
    XCTAssertTrue(app.staticTexts["Your widgets"].exists)
    attach(app, "Home · Default")
    try audit(app)
    app.swipeUp()
    XCTAssertTrue(app.descendants(matching: .any)["widget.budgetPace"].waitForExistence(timeout: uiWait))
    attach(app, "Home · Widgets")
    try audit(app)
    app.swipeUp()
    attach(app, "Home · Canvas end")
    try audit(app)
    app.swipeDown()
    app.swipeDown()

    // Hide amounts: the hero reads as hidden, the toast appears, Show restores.
    app.buttons["header.hideAmounts"].firstMatch.tap()
    XCTAssertTrue(app.descendants(matching: .any)["toast"].waitForExistence(timeout: uiWait))
    XCTAssertEqual(hero.label, "Amount hidden")
    XCTAssertFalse(app.staticTexts["7,417.55"].exists)
    attach(app, "Home · Amounts hidden")
    // Audit the hidden state once the toast has gone by itself (5 s), not while it
    // animates away mid-audit.
    XCTAssertTrue(app.descendants(matching: .any)["toast"].waitForNonExistence(timeout: 20))
    try audit(app)
    app.buttons["header.hideAmounts"].firstMatch.tap()
    XCTAssertEqual(hero.label, "AED 7,417.55")

    // Every tab opens.
    let tabBar = app.tabBars.firstMatch
    tabBar.buttons["Plan"].tap()
    XCTAssertTrue(app.descendants(matching: .any)["plan.readyToAssign"].waitForExistence(timeout: uiWait))
    try audit(app)
    tabBar.buttons["Activity"].tap()
    XCTAssertTrue(app.descendants(matching: .any)["activity.count"].waitForExistence(timeout: uiWait))
    try audit(app)
    tabBar.buttons["Home"].tap()
    XCTAssertTrue(hero.waitForExistence(timeout: uiWait))

    // The profile sheet carries the build footer.
    app.buttons["header.profile"].firstMatch.tap()
    let footer = app.staticTexts["profile.buildFooter"]
    XCTAssertTrue(footer.waitForExistence(timeout: uiWait))
    XCTAssertTrue(footer.label.hasPrefix("Hasala QA · 0.2.0 ("), footer.label)
    try audit(app)
    app.buttons["profile.close"].firstMatch.tap()

    // Search last: on iOS 26 the search tab collapses the bar into one button, so
    // there is no "Home" tab button to go back with.
    XCTAssertTrue(tabBar.buttons["Search"].waitForExistence(timeout: uiWait))
    tabBar.buttons["Search"].tap()
    XCTAssertTrue(app.descendants(matching: .any)["search.placeholder"].waitForExistence(timeout: uiWait))
    try audit(app)
  }

  /// Home and the tabs at `.accessibility3` (UIKit's AccessibilityXL): the layouts reflow
  /// instead of truncating, and the audit passes (spec 04 §17).
  @MainActor
  func testAccessibilityAtLargeTextSizes() throws {
    let app = XCUIApplication()
    app.launchArguments = [
      "-HasalaScenario", "maya",
      "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL",
    ]
    app.launch()

    let hero = app.descendants(matching: .any)["home.hero.left"]
    XCTAssertTrue(hero.waitForExistence(timeout: 15), "Home hero did not appear")
    XCTAssertEqual(hero.label, "AED 7,417.55")
    attach(app, "AX3 · Home")
    try audit(app, atLargeText: true)
    // Down the whole page: each Needs-you card, then each widget. The audit can move
    // the scroll position, so each stop scrolls to its own element first.
    for id in ["needsYou.review", "needsYou.bill.axa", "widget.budgetPace", "widget.nextBill",
               "widget.netWorth", "widget.project.Japan trip", "widget.goal.Emergency fund", "widget.today"] {
      let target = app.descendants(matching: .any)[id]
      XCTAssertTrue(target.waitForExistence(timeout: uiWait), "\(id) is missing")
      XCTAssertTrue(scroll(app, toShow: target), "could not scroll to \(id)")
      attach(app, "AX3 · \(id)")
      try audit(app, atLargeText: true)
    }

    let tabBar = app.tabBars.firstMatch
    for (tab, id) in [("Plan", "plan.readyToAssign"), ("Activity", "activity.count"),
                      ("Search", "search.placeholder")] {
      tabBar.buttons[tab].tap()
      XCTAssertTrue(app.descendants(matching: .any)[id].waitForExistence(timeout: uiWait))
      attach(app, "AX3 · \(tab)")
      try audit(app, atLargeText: true)
    }
  }

  @MainActor
  func testHiddenScenarioStartsHidden() throws {
    let app = XCUIApplication()
    app.launchArguments = ["-HasalaScenario", "mayaHidden"]
    app.launch()
    let hero = app.descendants(matching: .any)["home.hero.left"]
    XCTAssertTrue(hero.waitForExistence(timeout: 15))
    XCTAssertEqual(hero.label, "Amount hidden")
  }
}
