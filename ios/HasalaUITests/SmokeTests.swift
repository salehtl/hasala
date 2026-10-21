import XCTest

/// The Gate A0 smoke test: the Debug app launches into the Maya scenario, Home shows the
/// board's hero (spent on needs and wants), the bell opens what needs a look, every tab opens,
/// Hide amounts hides and restores figures, and the profile sheet shows the build footer.
/// Screenshots are attached to the report. Every screen it reaches also passes
/// `performAccessibilityAudit()` (spec 04 §17), here at the default text size and in
/// `testAccessibilityAtLargeTextSizes` at `.accessibility3`.
final class SmokeTests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  @MainActor
  func testLaunchHomeTabsAndHideAmounts() throws {
    let app = launch(scenario: "maya")

    let hero = el(app, "home.hero.left")
    XCTAssertTrue(hero.waitForExistence(timeout: 15), "Home hero did not appear")
    XCTAssertTrue(hero.waitForLabel("AED 11,115.62"), hero.label)
    XCTAssertTrue(app.staticTexts["Your widgets"].exists)
    // Home has no Needs-you rail any more (decided 14 Oct): the bell counts what needs a look.
    XCTAssertFalse(app.staticTexts["Needs you"].exists)
    XCTAssertEqual(app.buttons["header.notifications"].firstMatch.label, "Notifications, 4 need a look")
    attach(app, "Home · Default")
    try audit(app)
    app.swipeUp()
    XCTAssertTrue(el(app, "widget.budgetPace").waitForExistence(timeout: uiWait))
    attach(app, "Home · Widgets")
    try audit(app)
    app.swipeUp()
    attach(app, "Home · Canvas end")
    try audit(app)
    app.swipeDown()
    app.swipeDown()

    // The bell: "Needs a look" with its four rows, then "Earlier" (Debug's feed).
    app.buttons["header.notifications"].firstMatch.tap()
    XCTAssertTrue(el(app, "bell.sheet").waitForExistence(timeout: uiWait))
    XCTAssertTrue(app.staticTexts["Needs a look"].exists)
    for id in ["review", "bill.axa", "found.apple-bill", "price.du"] {
      XCTAssertTrue(el(app, "bell.row.\(id)").exists, "bell.row.\(id) is missing")
    }
    XCTAssertTrue(app.staticTexts["Earlier"].exists)
    attach(app, "Home · Notifications")
    try audit(app)
    el(app, "bell.close").tap()
    XCTAssertTrue(el(app, "bell.sheet").waitForNonExistence(timeout: uiWait))

    // Hide amounts: the hero reads as hidden, the toast appears and goes by itself.
    app.buttons["header.hideAmounts"].firstMatch.tap()
    XCTAssertTrue(el(app, "toast").waitForExistence(timeout: uiWait))
    XCTAssertEqual(hero.label, "Amount hidden")
    XCTAssertFalse(app.staticTexts["11,115.62"].exists)
    attach(app, "Home · Amounts hidden")
    // Audit the hidden state once the toast has gone by itself, not while it animates away
    // mid-audit.
    XCTAssertTrue(el(app, "toast").waitForNonExistence(timeout: 20))
    try audit(app)
    app.buttons["header.hideAmounts"].firstMatch.tap()
    XCTAssertTrue(hero.waitForLabel("AED 11,115.62"), hero.label)

    // Every tab opens; coming back to Home shows the hero as it was (no replay).
    let tabBar = app.tabBars.firstMatch
    tabBar.buttons["Plan"].tap()
    XCTAssertTrue(el(app, "plan.readyToAssign").waitForExistence(timeout: uiWait))
    try audit(app)
    tabBar.buttons["Review"].tap()
    XCTAssertTrue(el(app, "review.tab.count").waitForExistence(timeout: uiWait))
    try audit(app)
    tabBar.buttons["Activity"].tap()
    XCTAssertTrue(el(app, "activity.count").waitForExistence(timeout: uiWait))
    try audit(app)
    tabBar.buttons["Home"].tap()
    XCTAssertTrue(hero.waitForExistence(timeout: uiWait))
    XCTAssertEqual(hero.label, "AED 11,115.62")

    // The profile sheet carries the build footer.
    app.buttons["header.profile"].firstMatch.tap()
    let footer = app.staticTexts["profile.buildFooter"]
    XCTAssertTrue(footer.waitForExistence(timeout: uiWait))
    XCTAssertTrue(footer.label.hasPrefix("Hasala QA · 0.2.0 ("), footer.label)
    try audit(app)
    app.buttons["profile.close"].firstMatch.tap()

    app.buttons["header.search"].firstMatch.tap()
    XCTAssertTrue(el(app, "search.placeholder").waitForExistence(timeout: uiWait))
    try audit(app)
    tap(app, "search.close")
    XCTAssertTrue(el(app, "search.placeholder").waitForNonExistence(timeout: uiWait))
    XCTAssertTrue(tabBar.buttons["Home"].isSelected, "Search left Home")
  }

  /// A bell row closes the sheet and opens its screen (spec 10 §4.4): the late bill inside
  /// Home, then the transactions to sort as the review deck once the sheet has gone.
  @MainActor
  func testTheBellOpensWhatNeedsALook() throws {
    let app = launch(scenario: "maya")
    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: 15))

    app.buttons["header.notifications"].firstMatch.tap()
    tap(app, "bell.row.bill.axa")
    XCTAssertTrue(el(app, "bell.sheet").waitForNonExistence(timeout: uiWait))
    // The bill is pushed inside Home: the tab root's header (and its bell) has gone.
    XCTAssertTrue(app.buttons["header.notifications"].waitForNonExistence(timeout: uiWait), "no bill pushed")
    XCTAssertEqual(app.tabBars.firstMatch.buttons["Home"].isSelected, true)
    attach(app, "Bell · AXA Insurance")
    back(app)
    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: uiWait))

    app.buttons["header.notifications"].firstMatch.tap()
    tap(app, "bell.row.review")
    XCTAssertTrue(el(app, "review.card").waitForExistence(timeout: 10), "the deck did not open")
    attach(app, "Bell · Review deck")
    el(app, "review.close").tap()
    XCTAssertTrue(el(app, "review.tab.count").waitForExistence(timeout: uiWait), "not on the Review tab")
  }

  @MainActor
  func testTappingTheMarkOpensNothing() throws {
    let app = launch(scenario: "maya")
    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: 15))
    let mark = app.images["Hasala"].firstMatch
    XCTAssertTrue(mark.waitForExistence(timeout: uiWait))
    for _ in 0..<5 { mark.tap() }
    XCTAssertFalse(el(app, "bell.sheet").exists, "the mark opened the notifications")
    XCTAssertTrue(app.buttons["header.notifications"].firstMatch.isHittable)
    XCTAssertTrue(el(app, "home.hero.left").exists, "the mark left Home")
    XCTAssertEqual(mark.frame.midX, app.frame.midX, accuracy: 2, "the mark is off centre")
  }

  @MainActor
  func testTheBellIsOnEveryTab() throws {
    let app = launch(scenario: "maya")
    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: 15))
    attach(app, "Bell · Home")
    let tabBar = app.tabBars.firstMatch
    let bell = app.buttons["header.notifications"].firstMatch
    let profile = app.buttons["header.profile"].firstMatch
    let search = app.buttons["header.search"].firstMatch
    let mark = app.images["Hasala"].firstMatch
    for (tab, id) in [("Plan", "plan.readyToAssign"), ("Review", "review.tab.count"), ("Activity", "activity.count")] {
      tabBar.buttons[tab].tap()
      XCTAssertTrue(el(app, id).waitForExistence(timeout: uiWait))
      XCTAssertTrue(bell.isHittable, "\(tab) has no bell")
      XCTAssertEqual(bell.label, "Notifications, 4 need a look")
      XCTAssertLessThan(bell.frame.maxX, profile.frame.minX, "\(tab): the bell is not before the profile")
      XCTAssertTrue(search.isHittable, "\(tab) has no search")
      XCTAssertEqual(search.frame.maxX, bell.frame.minX, accuracy: 1, "\(tab): search and the bell are not joined")
      XCTAssertGreaterThanOrEqual(search.frame.width, 44)
      XCTAssertGreaterThanOrEqual(search.frame.height, 44)
      if mark.exists {
        XCTAssertLessThanOrEqual(mark.frame.maxX, search.frame.minX, "\(tab): search overlaps the mark")
        XCTAssertEqual(mark.frame.midX, app.frame.midX, accuracy: 2, "\(tab): the mark is off centre")
      }
      attach(app, "Bell · \(tab)")
      bell.tap()
      XCTAssertTrue(el(app, "bell.sheet").waitForExistence(timeout: uiWait))
      XCTAssertTrue(el(app, "bell.row.review").exists)
      el(app, "bell.close").tap()
      XCTAssertTrue(el(app, "bell.sheet").waitForNonExistence(timeout: uiWait))
      XCTAssertTrue(tabBar.buttons[tab].isSelected, "the bell left \(tab)")
    }

    bell.tap()
    tap(app, "bell.row.bill.axa")
    XCTAssertTrue(el(app, "bills.detail.axa").waitForExistence(timeout: uiWait), "no bill pushed")
    XCTAssertEqual(tabBar.buttons["Home"].isSelected, true)
  }

  /// Home and the tabs at `.accessibility3` (UIKit's AccessibilityXL): the layouts reflow
  /// instead of truncating, and the audit passes (spec 04 §17).
  @MainActor
  func testAccessibilityAtLargeTextSizes() throws {
    let app = launch(scenario: "maya", arguments: [
      "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL",
    ])

    let hero = el(app, "home.hero.left")
    XCTAssertTrue(hero.waitForExistence(timeout: 15), "Home hero did not appear")
    XCTAssertTrue(hero.waitForLabel("AED 11,115.62"), hero.label)
    attach(app, "AX3 · Home")
    try audit(app, atLargeText: true)
    // Down the whole page: the tiles, then each widget. The audit can move the scroll
    // position, so each stop scrolls to its own element first.
    for id in ["widget.budgetPace", "widget.nextBill", "widget.netWorth", "widget.project.japan",
               "widget.goal.emergency", "widget.today"] {
      let target = el(app, id)
      XCTAssertTrue(target.waitForExistence(timeout: uiWait), "\(id) is missing")
      XCTAssertTrue(scroll(app, toShow: target), "could not scroll to \(id)")
      attach(app, "AX3 · \(id)")
      try audit(app, atLargeText: true)
    }

    // The bell's sheet at AX3: rows stack, nothing clips.
    for _ in 0..<6 where !app.buttons["header.notifications"].firstMatch.isHittable { app.swipeDown() }
    app.buttons["header.notifications"].firstMatch.tap()
    XCTAssertTrue(el(app, "bell.sheet").waitForExistence(timeout: uiWait))
    attach(app, "AX3 · Notifications")
    try audit(app, atLargeText: true)
    el(app, "bell.close").tap()
    XCTAssertTrue(el(app, "bell.sheet").waitForNonExistence(timeout: uiWait))

    let tabBar = app.tabBars.firstMatch
    app.buttons["header.search"].firstMatch.tap()
    XCTAssertTrue(el(app, "search.placeholder").waitForExistence(timeout: uiWait))
    attach(app, "AX3 · Search")
    try audit(app, atLargeText: true)
    tap(app, "search.close")
    XCTAssertTrue(el(app, "search.placeholder").waitForNonExistence(timeout: uiWait))

    for (tab, id) in [("Plan", "plan.readyToAssign"), ("Activity", "activity.count")] {
      tabBar.buttons[tab].tap()
      XCTAssertTrue(el(app, id).waitForExistence(timeout: uiWait))
      attach(app, "AX3 · \(tab)")
      if tab == "Plan" {
        // As PlanUITests.testPlanAtLargeTextSizes does: every check but clipped text, then
        // clipped text alone, letting through only the "READY TO ASSIGN" overline, which the
        // audit reads as cut off and which wraps instead
        // (`PlanUITests.testReadyToAssignWrapsAtTheLargestSize`).
        try audit(app)
        try app.performAccessibilityAudit(for: .textClipped) { issue in
          issue.element?.label.localizedCaseInsensitiveCompare("Ready to assign") == .orderedSame
        }
      } else {
        try audit(app, atLargeText: true)
      }
    }
  }

  /// The first reveal after launch keeps the owner's timing with amounts shown, so the figure
  /// rolls with the fill: the bar fills over 300 ms, the tick starts to drop as it lands, the
  /// verdict fades in after the tick and is in by 570 ms (0–300–420–570). The app stamps the
  /// frames it draws (Debug, `-HasalaRevealTiming`), in milliseconds from the frame the fill
  /// started on. A frame is 17 ms. The marks are frames drawn, so a CI runner that drops a
  /// few can stamp one mark late and the next on time: the order is what holds exactly, and
  /// each gap and bound allows a few frames (seen: the verdict 85 ms after the tick, not 120).
  @MainActor
  func testTheFirstRevealKeepsItsTimingWithAmountsShown() throws {
    let app = launch(scenario: "maya", arguments: ["-HasalaRevealTiming"])
    let timing = el(app, "home.hero.revealTiming")
    XCTAssertTrue(timing.waitForExistence(timeout: 15), "the hero did not appear")
    let finished = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS 'done'"), object: timing)
    XCTAssertEqual(XCTWaiter().wait(for: [finished], timeout: 10), .completed, "\(timing.value ?? "")")

    let value = timing.value as? String ?? ""
    XCTContext.runActivity(named: "Reveal timing: \(value)") { _ in }
    var marks: [String: Int] = [:]
    for mark in value.split(separator: ", ") {
      let words = mark.split(separator: " ")
      if words.count == 2, let ms = Int(words[1]) { marks[String(words[0])] = ms }
    }
    let filled = try XCTUnwrap(marks["filled"], value)
    let tick = try XCTUnwrap(marks["tick"], value)
    let verdict = try XCTUnwrap(marks["verdict"], value)
    let done = try XCTUnwrap(marks["done"], value)
    // The bar fills in 300 ms; the tick waits for it, and nothing holds the tick back.
    XCTAssertTrue((250...360).contains(filled), value)
    XCTAssertTrue((filled...400).contains(tick), value)
    // The verdict follows the tick's 120 ms, and the whole reveal is in by 570 ms, within
    // the owner's 600 ms.
    XCTAssertTrue((tick + 50...510).contains(verdict), value)
    XCTAssertTrue((verdict...620).contains(done), value)
    XCTAssertEqual(el(app, "home.hero.left").label, "AED 11,115.62")
  }

  /// Home's wash sits behind the scroll view (owner's TestFlight report: a pull to refresh
  /// carried it down with the content). It still scrolls away with the content, as in Paper
  /// (absolute, 420 tall), and comes back when the content returns to the top.
  @MainActor
  func testTheWashScrollsAwayWithHomeAndComesBack() throws {
    let app = launch(scenario: "maya", release: true, motion: "off")
    let hero = el(app, "home.hero.left")
    XCTAssertTrue(hero.waitForExistence(timeout: 15), "Home hero did not appear")
    XCTAssertTrue(hero.waitForLabel("AED 11,115.62"), hero.label)

    // Under the bar, at the leading edge (no content there): the wash's blue, or the canvas.
    let probe = CGPoint(x: 6, y: 150)
    let atRest = try XCTUnwrap(pixel(app.screenshot(), probe))
    XCTAssertGreaterThan(atRest[2] - atRest[0], 0.08, "no wash at rest: \(atRest)")

    app.swipeUp()
    let scrolled = try XCTUnwrap(pixel(app.screenshot(), probe))
    XCTAssertLessThan(scrolled[2] - scrolled[0], 0.04, "the wash did not scroll away: \(scrolled)")

    app.swipeDown(velocity: .fast)
    app.swipeDown(velocity: .fast)
    XCTAssertTrue(hero.waitForExistence(timeout: 5))
    let back = try XCTUnwrap(pixel(app.screenshot(), probe))
    XCTAssertLessThan(distance(atRest, back), 0.03, "the wash did not come back: \(atRest), \(back)")
  }

  /// The RGBA (0...1) of a screenshot at a point in points.
  @MainActor
  private func pixel(_ shot: XCUIScreenshot, _ point: CGPoint) -> [CGFloat]? {
    guard let image = shot.image.cgImage else { return nil }
    let scale = shot.image.scale
    var rgba = [UInt8](repeating: 0, count: 4)
    guard let ctx = CGContext(data: &rgba, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.draw(image, in: CGRect(x: -point.x * scale, y: -(CGFloat(image.height) - point.y * scale),
                               width: CGFloat(image.width), height: CGFloat(image.height)))
    return rgba.map { CGFloat($0) / 255 }
  }

  private func distance(_ a: [CGFloat], _ b: [CGFloat]) -> CGFloat {
    zip(a, b).map { abs($0 - $1) }.max() ?? 1
  }

  @MainActor
  func testAPullOnActivityEndsAtOnceAndTheListComesBackToTheTop() throws {
    let app = launch(scenario: "maya", arguments: ["-HasalaRefreshDelay", "10000"])
    app.tabBars.firstMatch.buttons["Activity"].tap()
    let pill = el(app, "activity.period")
    XCTAssertTrue(pill.waitForExistence(timeout: uiWait))
    waitForStill(app)
    let rest = top(app, pill)
    attach(app, "Refresh · Activity · 0 at rest")
    pull(app)
    let status = el(app, "sync.status")
    let sawStatus = status.waitForExistence(timeout: 2)
    let backWhileSyncing = waitUntil(2) { abs(top(app, pill) - rest) < 1 } && status.exists
    attach(app, "Refresh · Activity · 1 back at the top while updating")
    _ = status.waitForNonExistence(timeout: 15)
    waitForStill(app)
    attach(app, "Refresh · Activity · 2 after the update")
    XCTAssertTrue(sawStatus, "no Updating line")
    XCTAssertTrue(backWhileSyncing, "the content did not spring back while the sync ran")
    XCTAssertEqual(top(app, pill), rest, accuracy: 1, "the list stayed offset after the refresh")
  }

  @MainActor
  func testAPullOnEveryTabReturnsToTheTop() throws {
    let app = launch(scenario: "maya", arguments: ["-HasalaRefreshDelay", "8000", "-HasalaPullHold", "5000"])
    let tabs = [("Home", "home.period"), ("Plan", "plan.readyToAssign"), ("Review", "review.tab.count"),
                ("Activity", "activity.period")]
    for (tab, anchor) in tabs {
      app.tabBars.firstMatch.buttons[tab].tap()
      let mark = el(app, anchor)
      XCTAssertTrue(mark.waitForExistence(timeout: uiWait), tab)
      waitForStill(app)
      let rest = top(app, mark)
      pull(app)
      attach(app, "Refresh · \(tab) · updating")
      _ = el(app, "sync.status").waitForNonExistence(timeout: 15)
      waitForStill(app)
      XCTAssertEqual(top(app, mark), rest, accuracy: 1, "\(tab) stayed offset after the refresh")
    }
  }

  @MainActor
  private func top(_ app: XCUIApplication, _ mark: XCUIElement) -> CGFloat {
    let search = app.searchFields.firstMatch
    return mark.frame.minY - (search.exists ? search.frame.maxY : 0)
  }

  @MainActor
  private func pull(_ app: XCUIApplication) {
    let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
    let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
    from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.1)
  }

  @MainActor
  private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
    let deadline = Date(timeIntervalSinceNow: timeout)
    while Date() < deadline {
      if condition() { return true }
      RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
    }
    return condition()
  }

  @MainActor
  func testHiddenScenarioStartsHidden() throws {
    let app = launch(scenario: "mayaHidden")
    let hero = el(app, "home.hero.left")
    XCTAssertTrue(hero.waitForExistence(timeout: 15))
    XCTAssertEqual(hero.label, "Amount hidden")
    XCTAssertEqual(app.buttons["header.hideAmounts"].firstMatch.label, "Show amounts")
  }
}
