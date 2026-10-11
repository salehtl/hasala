import XCTest

/// The Gate A0 smoke test: the Debug app launches into the Maya scenario, Home shows
/// the board's hero, every tab opens, Hide amounts hides and restores figures, and
/// the profile sheet shows the build footer. Screenshots are attached to the report.
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
    app.swipeUp()
    XCTAssertTrue(app.descendants(matching: .any)["widget.budgetPace"].waitForExistence(timeout: 5))
    attach(app, "Home · Widgets")
    app.swipeUp()
    attach(app, "Home · Canvas end")
    app.swipeDown()
    app.swipeDown()

    // Hide amounts: the hero reads as hidden, the toast appears, Show restores.
    app.buttons["header.hideAmounts"].firstMatch.tap()
    XCTAssertTrue(app.descendants(matching: .any)["toast"].waitForExistence(timeout: 5))
    XCTAssertEqual(hero.label, "Amount hidden")
    XCTAssertFalse(app.staticTexts["7,417.55"].exists)
    attach(app, "Home · Amounts hidden")
    app.buttons["header.hideAmounts"].firstMatch.tap()
    XCTAssertEqual(hero.label, "AED 7,417.55")

    // Every tab opens.
    let tabBar = app.tabBars.firstMatch
    tabBar.buttons["Plan"].tap()
    XCTAssertTrue(app.descendants(matching: .any)["plan.placeholder"].waitForExistence(timeout: 5))
    tabBar.buttons["Activity"].tap()
    XCTAssertTrue(app.descendants(matching: .any)["activity.placeholder"].waitForExistence(timeout: 5))
    tabBar.buttons["Search"].tap()
    XCTAssertTrue(app.descendants(matching: .any)["search.placeholder"].waitForExistence(timeout: 5))
    tabBar.buttons["Home"].tap()
    XCTAssertTrue(hero.waitForExistence(timeout: 5))

    // The profile sheet carries the build footer.
    app.buttons["header.profile"].firstMatch.tap()
    let footer = app.staticTexts["profile.buildFooter"]
    XCTAssertTrue(footer.waitForExistence(timeout: 5))
    XCTAssertTrue(footer.label.hasPrefix("Hasala QA · 0.1.0 ("), footer.label)
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

  @MainActor
  private func attach(_ app: XCUIApplication, _ name: String) {
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = name
    shot.lifetime = .keepAlways
    add(shot)
  }
}
