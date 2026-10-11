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
    XCTAssertTrue(app.descendants(matching: .any)["widget.budgetPace"].waitForExistence(timeout: 5))
    attach(app, "Home · Widgets")
    try audit(app)
    app.swipeUp()
    attach(app, "Home · Canvas end")
    try audit(app)
    app.swipeDown()
    app.swipeDown()

    // Hide amounts: the hero reads as hidden, the toast appears, Show restores.
    app.buttons["header.hideAmounts"].firstMatch.tap()
    XCTAssertTrue(app.descendants(matching: .any)["toast"].waitForExistence(timeout: 5))
    XCTAssertEqual(hero.label, "Amount hidden")
    XCTAssertFalse(app.staticTexts["7,417.55"].exists)
    attach(app, "Home · Amounts hidden")
    // Audit the hidden state once the toast has gone by itself (5 s), not while it
    // animates away mid-audit.
    XCTAssertTrue(app.descendants(matching: .any)["toast"].waitForNonExistence(timeout: 10))
    try audit(app)
    app.buttons["header.hideAmounts"].firstMatch.tap()
    XCTAssertEqual(hero.label, "AED 7,417.55")

    // Every tab opens.
    let tabBar = app.tabBars.firstMatch
    tabBar.buttons["Plan"].tap()
    XCTAssertTrue(app.descendants(matching: .any)["plan.placeholder"].waitForExistence(timeout: 5))
    try audit(app)
    tabBar.buttons["Activity"].tap()
    XCTAssertTrue(app.descendants(matching: .any)["activity.placeholder"].waitForExistence(timeout: 5))
    try audit(app)
    tabBar.buttons["Search"].tap()
    XCTAssertTrue(app.descendants(matching: .any)["search.placeholder"].waitForExistence(timeout: 5))
    try audit(app)
    tabBar.buttons["Home"].tap()
    XCTAssertTrue(hero.waitForExistence(timeout: 5))

    // The profile sheet carries the build footer.
    app.buttons["header.profile"].firstMatch.tap()
    let footer = app.staticTexts["profile.buildFooter"]
    XCTAssertTrue(footer.waitForExistence(timeout: 5))
    XCTAssertTrue(footer.label.hasPrefix("Hasala QA · 0.1.0 ("), footer.label)
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
      XCTAssertTrue(target.waitForExistence(timeout: 5), "\(id) is missing")
      XCTAssertTrue(scroll(app, toShow: target), "could not scroll to \(id)")
      attach(app, "AX3 · \(id)")
      try audit(app, atLargeText: true)
    }

    let tabBar = app.tabBars.firstMatch
    for (tab, id) in [("Plan", "plan.placeholder"), ("Activity", "activity.placeholder"),
                      ("Search", "search.placeholder")] {
      tabBar.buttons[tab].tap()
      XCTAssertTrue(app.descendants(matching: .any)[id].waitForExistence(timeout: 5))
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

  /// Drags the page until the top of `element` sits in the upper part of the screen,
  /// below the header. Returns whether it got there.
  @MainActor
  private func scroll(_ app: XCUIApplication, toShow element: XCUIElement) -> Bool {
    let height = app.frame.height
    for _ in 0..<24 {
      let top = element.frame.minY
      if top >= 120 && top <= height * 0.5 { return true }
      let up = top > height * 0.5
      let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.7 : 0.35))
      let distance = min(0.35, abs(top - height * 0.3) / height)
      let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.7 - distance : 0.35 + distance))
      from.press(forDuration: 0.05, thenDragTo: to)
    }
    return false
  }

  /// Runs the system accessibility audit on what is on screen and reports every issue
  /// it finds there in one failure, naming the element. Not counted:
  ///
  /// - Clipping at the default size. There the audit can only predict that text "may
  ///   be clipped at larger Dynamic Type sizes" (Paper sets one-line text that the
  ///   layouts let wrap above the default size); `testAccessibilityAtLargeTextSizes`
  ///   checks clipping at `.accessibility3` itself, where it is decided. The system
  ///   search field is not ours to lay out and is not counted at any size.
  /// - Contrast. The audit samples rendered pixels and fails ink on the grey canvas
  ///   (over 14:1) under the scroll-edge blur and the glass bars, so it cannot gate;
  ///   HasalaKit's ContrastTests checks every text/surface token pair exactly instead.
  /// - "Dynamic Type partially unsupported" on the figures that stop growing at
  ///   `.accessibility3` on purpose (spec 04 §14.4; marked `hasala.cappedFigure`), and
  ///   on text inside the navigation and tab bars, which keep their size and offer
  ///   the Large Content Viewer instead, as system bars do.
  @MainActor
  private func audit(
    _ app: XCUIApplication, atLargeText: Bool = false, file: StaticString = #filePath, line: UInt = #line
  ) throws {
    let bars = [app.navigationBars.firstMatch, app.tabBars.firstMatch].filter(\.exists).map(\.frame)
    var types = XCUIAccessibilityAuditType.all.subtracting(.contrast)
    if !atLargeText { types.remove(.textClipped) }
    var issues: [String] = []
    try app.performAccessibilityAudit(for: types) { issue in
      // The system search field (UISearchBarTextField) sizes its own text.
      if issue.auditType == .textClipped, issue.element?.elementType == .searchField { return true }
      if issue.auditType == .dynamicType, let element = issue.element {
        if element.identifier == "hasala.cappedFigure" { return true }
        if bars.contains(where: { $0.intersects(element.frame) }) { return true }
      }
      let element = issue.element.map { "'\($0.label)' [\($0.identifier)] \($0.elementType.rawValue) \($0.frame)" }
      issues.append("\(issue.compactDescription): \(element ?? "no element") — \(issue.detailedDescription)")
      return true
    }
    if !issues.isEmpty {
      XCTFail("accessibility audit:\n" + issues.joined(separator: "\n"), file: file, line: line)
    }
  }

  @MainActor
  private func attach(_ app: XCUIApplication, _ name: String) {
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = name
    shot.lifetime = .keepAlways
    add(shot)
  }
}
