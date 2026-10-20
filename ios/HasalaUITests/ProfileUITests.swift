import XCTest

/// The profile on the Maya mock: one large sheet whose rows push inside it (Bills, one bill,
/// Accounts, Categories and rules, Notifications), and Hide amounts reaching it.
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

  @MainActor
  private func openProfile(_ app: XCUIApplication) {
    app.buttons["header.profile"].firstMatch.tap()
    XCTAssertTrue(el(app, "profile.name").waitForExistence(timeout: uiWait))
  }

  /// Drags the page until `element` sits clear of the header and the tab bar, each drag
  /// resting before it lifts, so the page is still when the audit reads it (a fling still
  /// coasting makes the audit see text mid-move and call it clipped). Returns whether it
  /// got there.
  @MainActor
  private func bringUp(_ app: XCUIApplication, _ element: XCUIElement) -> Bool {
    let height = app.frame.height
    for _ in 0..<16 {
      guard element.exists else { return false }
      let frame = element.frame
      if frame.minY >= 140, frame.maxY <= height - 160 { return true }
      let up = frame.maxY > height - 160
      let distance = min(0.35, (up ? frame.maxY - (height - 200) : 180 - frame.minY) / height)
      let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.7 : 0.3))
      let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.7 - distance : 0.3 + distance))
      from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .default, thenHoldForDuration: 0.3)
    }
    return element.isHittable
  }

  /// Screenshots down a long page (for the comparison with its Paper board): one per
  /// screenful, each drag resting before it lifts so the page stops where it was dragged.
  @MainActor
  private func attachPage(_ app: XCUIApplication, _ name: String, screens: Int) {
    attach(app, "\(name) · 1")
    for i in 2...max(2, screens) {
      let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
      let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
      from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .default, thenHoldForDuration: 0.3)
      attach(app, "\(name) · \(i)")
    }
  }

  /// Profile: the sheet, Bills (track a found bill), rules, notifications, Hide amounts.
  @MainActor
  func testProfileBillsAndSettings() throws {
    let app = launchHome()
    openProfile(app)
    XCTAssertTrue(el(app, "profile.bankAlerts").label.contains("Bank alerts are working"))
    XCTAssertTrue(app.buttons["profile.bankAlerts"].exists, "the bank alerts card opens Bank alerts")
    XCTAssertTrue(el(app, "profile.bills").label.hasPrefix("Recurring"), el(app, "profile.bills").label)
    XCTAssertTrue(el(app, "profile.bills").label.contains("9 tracked · 1 new found"))
    try audit(app)
    attachPage(app, "Profile", screens: 3)
    XCTAssertTrue(el(app, "profile.buildFooter").label.hasSuffix("End\u{2011}to\u{2011}end encrypted, never sold"))
    // Back to the top: the sheet's own stack keeps its place.
    app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
      .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))

    tap(app, "profile.bills")
    let next14 = el(app, "bills.next14")
    XCTAssertTrue(next14.waitForExistence(timeout: uiWait))
    XCTAssertEqual(next14.label, "AED 1,039.15")
    XCTAssertTrue(app.navigationBars["Recurring"].exists)
    XCTAssertTrue(el(app, "bills.attention.axa").exists)
    try audit(app)
    attachPage(app, "Recurring", screens: 5)
    let track = el(app, "bills.track.apple-bill")
    XCTAssertTrue(scroll(app, toShow: track))
    track.tap()
    XCTAssertTrue(app.staticTexts["Tracking Apple.com/bill"].waitForExistence(timeout: uiWait))
    back(app)
    XCTAssertTrue(el(app, "profile.bills").waitForLabel(containing: "10 tracked"))

    tap(app, "profile.rules")
    XCTAssertTrue(el(app, "rule.r-carrefour").waitForExistence(timeout: uiWait))
    XCTAssertTrue(el(app, "rules.segment").exists, "Debug shows the Categories segment")
    attach(app, "Categories and rules")
    try audit(app)
    back(app)

    tap(app, "profile.notifications")
    el(app, "notifications.everything").tap()
    back(app)
    XCTAssertEqual(el(app, "profile.notifications").value as? String, "Everything")
    el(app, "profile.close").tap()

    // Hide amounts reaches the profile sheet and the transaction sheet.
    app.buttons["header.hideAmounts"].firstMatch.tap()
    openProfile(app)
    XCTAssertTrue(el(app, "profile.accounts").waitForLabel(containing: "net worth Amount hidden"))
    XCTAssertTrue(el(app, "profile.projects").label.contains("1 active"))
    attach(app, "Profile · Amounts hidden")
    el(app, "profile.close").tap()
    app.tabBars.firstMatch.buttons["Activity"].tap()
    let talabat = el(app, "txn.talabat")
    XCTAssertTrue(talabat.waitForExistence(timeout: uiWait))
    talabat.tap()
    XCTAssertTrue(el(app, "txn.amount").waitForLabel("Amount hidden"))
    attach(app, "Transaction · Amounts hidden")
  }

  /// One bill, from Profile › Bills: what we noticed and the history; "I paid it" marks it
  /// (with Undo); stopping it asks first, then the page goes and Bills drops the bill.
  @MainActor
  func testOneBillFromTheProfile() throws {
    let app = launchHome()
    openProfile(app)
    tap(app, "profile.bills")
    tap(app, "bill.axa")
    let hero = el(app, "bills.detail.axa")
    XCTAssertTrue(hero.waitForExistence(timeout: uiWait))
    XCTAssertTrue(hero.label.contains("550.00"))
    XCTAssertTrue(el(app, "3 days past usual").exists)
    try audit(app)
    attachPage(app, "AXA Insurance", screens: 3)

    tap(app, "bills.detail.paid")
    XCTAssertTrue(app.staticTexts["AXA Insurance marked paid"].waitForExistence(timeout: uiWait))
    app.buttons["Undo"].firstMatch.tap()
    XCTAssertTrue(el(app, "bills.detail.paid").waitForExistence(timeout: uiWait), "Undo brings the late bill back")

    tap(app, "bills.detail.stop")
    let alert = app.alerts["Stop tracking AXA Insurance?"]
    XCTAssertTrue(alert.waitForExistence(timeout: uiWait))
    alert.buttons["Stop tracking"].tap()
    XCTAssertTrue(el(app, "bills.next14").waitForExistence(timeout: uiWait), "the page went back to Bills")
    XCTAssertTrue(app.staticTexts["Stopped tracking AXA Insurance"].waitForExistence(timeout: uiWait))
    XCTAssertFalse(el(app, "bills.attention.axa").exists)
  }

  /// A rule learned today (Lulu sorted into Groceries with "Always use") carries its chip, and
  /// the list still passes the audit.
  @MainActor
  func testARuleLearnedTodayShowsItsChip() throws {
    let app = launch(scenario: nil, screen: "profile.rulesLearned")
    let row = el(app, "rule.learned-lulu")
    XCTAssertTrue(row.waitForExistence(timeout: 15))
    XCTAssertTrue(row.label.contains("learned today"), row.label)
    // The chip goes under a pattern too long to share its line; the page keeps its width.
    XCTAssertLessThanOrEqual(row.frame.maxX, app.frame.width - 20, "the learned rule widens the page")
    XCTAssertTrue(bringUp(app, row))
    attach(app, "Categories and rules · Learned today")
    try audit(app)
  }

  /// A price change opens its bill from "Details"; Home's Bills pushes the bill in Home.
  @MainActor
  func testAPriceChangeOpensItsBill() throws {
    let app = launch(scenario: "maya", screen: "bills")
    XCTAssertTrue(el(app, "bills.next14").waitForExistence(timeout: 15))
    tap(app, "bills.details.du")
    XCTAssertTrue(el(app, "bills.detail.du").waitForExistence(timeout: uiWait))
    XCTAssertTrue(el(app, "bills.detail.accept").exists)
    XCTAssertTrue(app.staticTexts["Charged 38.90 more than usual (389.00) on Mon 5 Oct."].exists)
    try audit(app)
    attach(app, "du · Price change")
  }

  /// Accounts, from Profile › Accounts: net worth, the year, everyday money and tracking.
  @MainActor
  func testAccountsFromTheProfile() throws {
    let app = launchHome()
    openProfile(app)
    tap(app, "profile.accounts")
    let netWorth = el(app, "accounts.netWorth")
    XCTAssertTrue(netWorth.waitForExistence(timeout: uiWait))
    XCTAssertEqual(netWorth.label, "AED 227,568.00")
    XCTAssertTrue(el(app, "accounts.change").label.contains("plus AED 2,140.00"))
    XCTAssertTrue(el(app, "accounts.chart").exists)
    XCTAssertTrue(el(app, "accounts.row.dib").label.contains("minus AED 4,210.50"))
    XCTAssertTrue(el(app, "accounts.add").exists, "Debug shows Add an account")
    try audit(app)
    attachPage(app, "Accounts", screens: 2)
    XCTAssertTrue(el(app, "accounts.row.sarwa").label.contains("Net worth only"))
  }

  /// Profile, Bills, one bill and Accounts at `.accessibility3` (spec 04 §17).
  @MainActor
  func testProfileAtLargeTextSizes() throws {
    let app = launchHome(arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"])

    openProfile(app)
    try audit(app, atLargeText: true)
    for id in ["profile.rules", "profile.security", "profile.faceID", "profile.signOut"] {
      XCTAssertTrue(bringUp(app, el(app, id)), "could not reach \(id)")
      attach(app, "AX3 · Profile · \(id)")
      try audit(app, atLargeText: true)
    }

    app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
      .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
    tap(app, "profile.bills")
    XCTAssertTrue(el(app, "bills.next14").waitForExistence(timeout: uiWait))
    try audit(app, atLargeText: true)
    for id in ["bills.paid.axa", "bills.track.apple-bill", "bill.dewa"] {
      XCTAssertTrue(bringUp(app, el(app, id)), "could not reach \(id)")
      attach(app, "AX3 · Recurring · \(id)")
      try audit(app, atLargeText: true)
    }
    tap(app, "bill.dewa")
    XCTAssertTrue(el(app, "bills.detail.dewa").waitForExistence(timeout: uiWait))
    try audit(app, atLargeText: true)
    attach(app, "AX3 · DEWA")
    back(app)
    back(app)

    tap(app, "profile.accounts")
    XCTAssertTrue(el(app, "accounts.netWorth").waitForExistence(timeout: uiWait))
    try audit(app, atLargeText: true)
    XCTAssertTrue(bringUp(app, el(app, "accounts.row.cash")))
    attach(app, "AX3 · Accounts")
    try audit(app, atLargeText: true)
  }
  @MainActor
  private func flip(_ app: XCUIApplication, _ toggle: XCUIElement) {
    let knob = toggle.switches.firstMatch
    if knob.exists { knob.tap() } else { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap() }
  }

  @MainActor
  private func merchantSuggestionsSwitch(_ app: XCUIApplication) -> XCUIElement {
    let toggle = app.switches["profile.merchantSuggestions"].firstMatch
    XCTAssertTrue(toggle.waitForExistence(timeout: uiWait), "Cloud suggestions is missing")
    XCTAssertTrue(app.staticTexts["Cloud suggestions"].exists)
    XCTAssertTrue(bringUp(app, toggle), "could not reach Merchant suggestions")
    if toggle.value as? String == "1" {
      flip(app, toggle)
      XCTAssertTrue(toggle.waitForValue("0"))
    }
    return toggle
  }

  @MainActor
  func testMerchantSuggestionsAskBeforeTurningOn() throws {
    let app = launchHome()
    openProfile(app)
    let toggle = merchantSuggestionsSwitch(app)
    XCTAssertEqual(toggle.value as? String, "0", "Merchant suggestions starts off")
    let auto = app.switches["profile.merchantAutoSort"].firstMatch
    XCTAssertTrue(auto.exists, "Sort automatically shows while Merchant suggestions is off")
    XCTAssertFalse(auto.isEnabled, "Sort automatically waits for Merchant suggestions")
    XCTAssertEqual(auto.value as? String, "0")
    try audit(app)

    flip(app, toggle)
    let sheet = el(app, "merchantSuggestions.sheet")
    XCTAssertTrue(sheet.waitForExistence(timeout: uiWait), "turning it on asks first")
    XCTAssertTrue(app.staticTexts["What's not sent"].exists)
    attach(app, "Merchant suggestions · consent")
    try audit(app, overSheet: true)
    tap(app, "merchantSuggestions.notNow")
    XCTAssertTrue(sheet.waitForNonExistence(timeout: uiWait))
    XCTAssertEqual(toggle.value as? String, "0", "Not now keeps it off")

    flip(app, toggle)
    XCTAssertTrue(sheet.waitForExistence(timeout: uiWait))
    tap(app, "merchantSuggestions.turnOn")
    XCTAssertTrue(sheet.waitForNonExistence(timeout: uiWait))
    XCTAssertTrue(toggle.waitForValue("1"), "Turn on turns it on")
    XCTAssertTrue(auto.isEnabled, "Sort automatically can be turned on now")
    XCTAssertEqual(auto.value as? String, "0")
    attach(app, "Merchant suggestions · on")

    flip(app, auto)
    let autoSheet = el(app, "merchantAutoSort.sheet")
    XCTAssertTrue(autoSheet.waitForExistence(timeout: uiWait), "sorting automatically asks first")
    XCTAssertTrue(app.staticTexts["Counted right away"].exists)
    attach(app, "Sort automatically · consent")
    try audit(app, overSheet: true)
    tap(app, "merchantAutoSort.notNow")
    XCTAssertTrue(autoSheet.waitForNonExistence(timeout: uiWait))
    XCTAssertEqual(auto.value as? String, "0", "Not now keeps it off")

    flip(app, auto)
    XCTAssertTrue(autoSheet.waitForExistence(timeout: uiWait))
    tap(app, "merchantAutoSort.turnOn")
    XCTAssertTrue(autoSheet.waitForNonExistence(timeout: uiWait))
    XCTAssertTrue(auto.waitForValue("1"), "Turn on sorts automatically")
    attach(app, "Sort automatically · on")

    flip(app, auto)
    XCTAssertTrue(auto.waitForValue("0"), "turning it off asks nothing")
    XCTAssertFalse(autoSheet.exists)
    flip(app, auto)
    tap(app, "merchantAutoSort.turnOn")
    XCTAssertTrue(auto.waitForValue("1"))

    flip(app, toggle)
    XCTAssertTrue(toggle.waitForValue("0"), "turning it off asks nothing")
    XCTAssertFalse(sheet.exists)
    XCTAssertTrue(auto.waitForValue("0"), "turning suggestions off turns sorting off")
    XCTAssertFalse(auto.isEnabled)
  }

  @MainActor
  func testMerchantSuggestionsAtTheLargestText() throws {
    let app = launchHome(arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"])
    openProfile(app)
    let toggle = merchantSuggestionsSwitch(app)
    attach(app, "AX3 · Profile · Cloud suggestions")
    try audit(app, atLargeText: true)
    flip(app, toggle)
    let sheet = el(app, "merchantSuggestions.sheet")
    XCTAssertTrue(sheet.waitForExistence(timeout: uiWait))
    attach(app, "AX3 · Merchant suggestions · consent")
    try audit(app, atLargeText: true, overSheet: true)
    tap(app, "merchantSuggestions.notNow")
    XCTAssertTrue(sheet.waitForNonExistence(timeout: uiWait))
    XCTAssertEqual(toggle.value as? String, "0")
  }
}
