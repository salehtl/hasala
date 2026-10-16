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
    XCTAssertTrue(hero.waitForLabel("AED 10,288.34"), hero.label)
    XCTAssertTrue(app.staticTexts["Your widgets"].exists)
    // Home has no Needs-you rail any more (decided 14 Oct): the bell counts what needs a look.
    XCTAssertFalse(app.staticTexts["Needs you"].exists)
    XCTAssertEqual(app.buttons["header.notifications"].firstMatch.label, "Notifications, 4 new")
    attach(app, "Home · Default")
    try audit(app)
    app.swipeUp()
    XCTAssertTrue(el(app, "widget.budgetPace").waitForExistence(timeout: 5))
    attach(app, "Home · Widgets")
    try audit(app)
    app.swipeUp()
    attach(app, "Home · Canvas end")
    try audit(app)
    app.swipeDown()
    app.swipeDown()

    // The bell: "Needs a look" with its four rows, then "Earlier" (Debug's feed).
    app.buttons["header.notifications"].firstMatch.tap()
    XCTAssertTrue(el(app, "bell.sheet").waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Needs a look"].exists)
    for id in ["review", "bill.axa", "found.apple-bill", "price.du"] {
      XCTAssertTrue(el(app, "bell.row.\(id)").exists, "bell.row.\(id) is missing")
    }
    XCTAssertTrue(app.staticTexts["Earlier"].exists)
    attach(app, "Home · Notifications")
    try audit(app)
    el(app, "bell.close").tap()
    XCTAssertTrue(el(app, "bell.sheet").waitForNonExistence(timeout: 5))

    // Hide amounts: the hero reads as hidden, the toast appears and goes by itself.
    app.buttons["header.hideAmounts"].firstMatch.tap()
    XCTAssertTrue(el(app, "toast").waitForExistence(timeout: 5))
    XCTAssertEqual(hero.label, "Amount hidden")
    XCTAssertFalse(app.staticTexts["10,288.34"].exists)
    attach(app, "Home · Amounts hidden")
    // Audit the hidden state once the toast has gone by itself, not while it animates away
    // mid-audit.
    XCTAssertTrue(el(app, "toast").waitForNonExistence(timeout: 10))
    try audit(app)
    app.buttons["header.hideAmounts"].firstMatch.tap()
    XCTAssertTrue(hero.waitForLabel("AED 10,288.34"), hero.label)

    // Every tab opens; coming back to Home shows the hero as it was (no replay).
    let tabBar = app.tabBars.firstMatch
    tabBar.buttons["Plan"].tap()
    XCTAssertTrue(el(app, "plan.readyToAssign").waitForExistence(timeout: 5))
    try audit(app)
    tabBar.buttons["Review"].tap()
    XCTAssertTrue(el(app, "review.tab.count").waitForExistence(timeout: 5))
    try audit(app)
    tabBar.buttons["Activity"].tap()
    XCTAssertTrue(el(app, "activity.count").waitForExistence(timeout: 5))
    try audit(app)
    tabBar.buttons["Home"].tap()
    XCTAssertTrue(hero.waitForExistence(timeout: 5))
    XCTAssertEqual(hero.label, "AED 10,288.34")

    // The profile sheet carries the build footer.
    app.buttons["header.profile"].firstMatch.tap()
    let footer = app.staticTexts["profile.buildFooter"]
    XCTAssertTrue(footer.waitForExistence(timeout: 5))
    XCTAssertTrue(footer.label.hasPrefix("Hasala QA · 0.2.0 ("), footer.label)
    try audit(app)
    app.buttons["profile.close"].firstMatch.tap()

    // Search last: on iOS 26 the search tab collapses the bar into one button, so
    // there is no "Home" tab button to go back with.
    XCTAssertTrue(tabBar.buttons["Search"].waitForExistence(timeout: 5))
    tabBar.buttons["Search"].tap()
    XCTAssertTrue(el(app, "search.placeholder").waitForExistence(timeout: 5))
    try audit(app)
  }

  /// A bell row closes the sheet and opens its screen (spec 10 §4.4): the late bill inside
  /// Home, then the transactions to sort as the review deck once the sheet has gone.
  @MainActor
  func testTheBellOpensWhatNeedsALook() throws {
    let app = launch(scenario: "maya")
    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: 15))

    app.buttons["header.notifications"].firstMatch.tap()
    tap(app, "bell.row.bill.axa")
    XCTAssertTrue(el(app, "bell.sheet").waitForNonExistence(timeout: 5))
    // The bill is pushed inside Home: the tab root's header (and its bell) has gone.
    XCTAssertTrue(app.buttons["header.notifications"].waitForNonExistence(timeout: 5), "no bill pushed")
    XCTAssertEqual(app.tabBars.firstMatch.buttons["Home"].isSelected, true)
    attach(app, "Bell · AXA Insurance")
    back(app)
    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: 5))

    app.buttons["header.notifications"].firstMatch.tap()
    tap(app, "bell.row.review")
    XCTAssertTrue(el(app, "review.card").waitForExistence(timeout: 10), "the deck did not open")
    attach(app, "Bell · Review deck")
    el(app, "review.close").tap()
    XCTAssertTrue(el(app, "review.tab.count").waitForExistence(timeout: 5), "not on the Review tab")
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
    XCTAssertTrue(hero.waitForLabel("AED 10,288.34"), hero.label)
    attach(app, "AX3 · Home")
    try audit(app, atLargeText: true)
    // Down the whole page: the tiles, then each widget. The audit can move the scroll
    // position, so each stop scrolls to its own element first.
    for id in ["widget.budgetPace", "widget.nextBill", "widget.netWorth", "widget.project.Japan trip",
               "widget.goal.Emergency fund", "widget.today"] {
      let target = el(app, id)
      XCTAssertTrue(target.waitForExistence(timeout: 5), "\(id) is missing")
      XCTAssertTrue(scroll(app, toShow: target), "could not scroll to \(id)")
      attach(app, "AX3 · \(id)")
      try audit(app, atLargeText: true)
    }

    // The bell's sheet at AX3: rows stack, nothing clips.
    for _ in 0..<6 where !app.buttons["header.notifications"].firstMatch.isHittable { app.swipeDown() }
    app.buttons["header.notifications"].firstMatch.tap()
    XCTAssertTrue(el(app, "bell.sheet").waitForExistence(timeout: 5))
    attach(app, "AX3 · Notifications")
    try audit(app, atLargeText: true)
    el(app, "bell.close").tap()
    XCTAssertTrue(el(app, "bell.sheet").waitForNonExistence(timeout: 5))

    let tabBar = app.tabBars.firstMatch
    for (tab, id) in [("Plan", "plan.readyToAssign"), ("Activity", "activity.count"),
                      ("Search", "search.placeholder")] {
      tabBar.buttons[tab].tap()
      XCTAssertTrue(el(app, id).waitForExistence(timeout: 5))
      attach(app, "AX3 · \(tab)")
      try audit(app, atLargeText: true)
    }
  }

  /// The first reveal after launch keeps the owner's timing with amounts shown, so the figure
  /// rolls with the fill: the bar fills over 300 ms, the tick starts to drop as it lands, the
  /// verdict fades in after the tick and is in by 570 ms (0–300–420–570). The app stamps the
  /// frames it draws (Debug, `-HasalaRevealTiming`), in milliseconds from the frame the fill
  /// started on. A frame is 17 ms; each bound allows a frame or two dropped on a busy machine.
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
    XCTAssertTrue((250...350).contains(filled), value)
    XCTAssertTrue((280...370).contains(tick), value)
    // The verdict follows the tick's 120 ms and is fully in by 570 ms.
    XCTAssertTrue((tick + 90...490).contains(verdict), value)
    XCTAssertTrue((verdict...620).contains(done), value)
    XCTAssertEqual(el(app, "home.hero.left").label, "AED 10,288.34")
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
