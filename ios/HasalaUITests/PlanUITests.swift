import XCTest

/// Plan on the Maya mock: Ready to assign, a category's month, Move money, a budget and where
/// its money comes from, the project, and the large-text layouts.
final class PlanUITests: XCTestCase {
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

  /// Waits until `element` stops moving (a sheet settling into its detent), at most 5 s, so
  /// an audit reads the frames the screen shows.
  @MainActor
  private func waitUntilStill(_ element: XCUIElement) {
    var last = element.frame
    for _ in 0..<20 {
      Thread.sleep(forTimeInterval: 0.25)
      let now = element.frame
      if now == last { return }
      last = now
    }
  }

  /// Plan: Ready to assign, Groceries' month, Move money from Ready to assign, then Dining's
  /// budget from Ready to assign (with the shortfall it would leave) and saved.
  @MainActor
  func testPlanMoveMoneyAndBudget() throws {
    let app = launchHome()
    openPlan(app)
    let rta = el(app, "plan.readyToAssign")
    XCTAssertTrue(rta.waitForExistence(timeout: uiWait))
    XCTAssertEqual(rta.label, "AED 1,000.00")
    attach(app, "Plan · October")
    try audit(app)

    let groceries = el(app, "plan.row.groceries")
    XCTAssertTrue(reveal(app, groceries))
    XCTAssertTrue(groceries.label.hasPrefix("Groceries, AED 1,387.60 left. 812.40 of 2,200, Over pace"), groceries.label)
    attach(app, "Plan · Needs")
    groceries.tap()
    let hero = el(app, "category.hero")
    XCTAssertTrue(hero.waitForExistence(timeout: uiWait))
    XCTAssertTrue(hero.label.contains("AED 1,387.60 left of 2,200 this month. Over pace, on course for 2,518"),
                  hero.label)
    XCTAssertTrue(app.navigationBars["Groceries"].exists)
    attach(app, "Plan · Groceries")
    try audit(app)

    let move = el(app, "category.moveMoney")
    XCTAssertTrue(reveal(app, move))
    move.tap()
    let save = el(app, "move.save")
    XCTAssertTrue(save.waitForExistence(timeout: uiWait))
    XCTAssertEqual(save.label, "Move AED 318.00")
    // A large sheet: its Close sits at the top of the screen (page 14 §02, top 62).
    XCTAssertLessThan(el(app, "move.close").frame.minY, app.frame.height * 0.2)
    XCTAssertTrue(el(app, "move.to").label.contains("On course for 2,518 of 2,200"))
    XCTAssertTrue(el(app, "move.preview").exists)
    // Paper's sources: Ready to assign, Travel, Shopping, Entertainment; Dining is over pace.
    for id in ["rta", "travel", "shopping", "entertainment"] {
      XCTAssertTrue(el(app, "move.from.\(id)").exists, "\(id) is not offered")
    }
    XCTAssertFalse(el(app, "move.from.dining").exists)
    XCTAssertFalse(el(app, "move.from.transport").exists)
    XCTAssertTrue(el(app, "move.from.rta").isSelected)
    attach(app, "Plan · Move money")
    try audit(app)
    save.tap()
    XCTAssertTrue(app.staticTexts["Moved to Groceries"].waitForExistence(timeout: uiWait))
    back(app)
    XCTAssertTrue(rta.waitForExistence(timeout: uiWait))
    XCTAssertTrue(scroll(app, toShow: rta))
    XCTAssertEqual(rta.label, "AED 682.00")

    // Change Dining's budget to 1,800: Ready to assign follows.
    let dining = el(app, "plan.row.dining")
    XCTAssertTrue(reveal(app, dining))
    dining.tap()
    let change = el(app, "category.changeBudget")
    XCTAssertTrue(reveal(app, change))
    change.tap()
    let field = el(app, "budget.amount")
    XCTAssertTrue(field.waitForExistence(timeout: uiWait))
    XCTAssertEqual(field.value as? String, "1,600")
    // A medium sheet that fits its content, with Dining showing above it (page 14 §02); it
    // stays that height while the amount changes.
    let close = el(app, "budget.close")
    waitUntilStill(close)
    let top = close.frame.minY
    XCTAssertGreaterThan(top, app.frame.height * 0.25)
    // Audited where Paper draws it, over the top of Dining (`testABudgetRiseCanComeFromAnother
    // Category`): from down here, rows behind the scrim straddle the sheet's edge, and the audit
    // reads their cut-off words as text no element describes.
    attach(app, "Plan · Dining budget")
    app.buttons["Add 200"].tap()
    XCTAssertEqual(close.frame.minY, top, accuracy: 1)
    XCTAssertEqual(el(app, "budget.save").label, "Set Dining to AED 1,800")
    XCTAssertEqual(el(app, "budget.consequence").label, "Ready to assign becomes AED 482.00")
    // Over-assigning shows the shortfall with its minus sign.
    for _ in 0..<4 { app.buttons["Add 200"].tap() }
    XCTAssertEqual(el(app, "budget.consequence").label, "Ready to assign becomes \u{2212}AED 318.00")
    for _ in 0..<8 { app.buttons["Less"].tap() }
    XCTAssertEqual(el(app, "budget.save").label, "Set Dining to AED 1,800")
    el(app, "budget.save").tap()
    XCTAssertTrue(app.staticTexts["Dining budget changed"].waitForExistence(timeout: uiWait))
    XCTAssertTrue(el(app, "category.hero").label.contains("AED 1,157.25 left of 1,800 this month"))
  }

  /// "Take it from" pushes the sources inside the budget sheet; a rise from Travel moves the
  /// money from Travel, and Travel's row says what is left.
  @MainActor
  func testABudgetRiseCanComeFromAnotherCategory() throws {
    let app = launch(screen: "plan.budget")
    let field = el(app, "budget.amount")
    XCTAssertTrue(field.waitForExistence(timeout: 15))
    waitUntilStill(el(app, "budget.close"))
    try audit(app)
    // The medium sheet is drawn at 386/402 of its size (the system's inset sheet); its
    // small targets still take 44 on the screen.
    for button in ["Add 200", "Less", "More", "Close"] {
      let target = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != 'plan.more'", button)).firstMatch
      XCTAssertGreaterThanOrEqual(target.frame.height, 44, button)
    }
    app.buttons["Add 200"].tap()
    attach(app, "Plan · Dining budget · 1,800")
    let source = el(app, "budget.source")
    XCTAssertTrue(source.label.hasPrefix("Take it from"))
    source.tap()
    let travel = el(app, "source.travel")
    XCTAssertTrue(travel.waitForExistence(timeout: uiWait))
    XCTAssertTrue(el(app, "source.rta").isSelected)
    attach(app, "Plan · Dining budget · Take it from")
    try audit(app)
    travel.tap()
    XCTAssertTrue(el(app, "budget.consequence").waitForExistence(timeout: uiWait))
    XCTAssertEqual(el(app, "budget.consequence").label, "Travel keeps AED 2,300.00")
    // More than Travel has is refused here, before anything is sent.
    for _ in 0..<12 { app.buttons["Add 200"].tap() }
    XCTAssertTrue(el(app, "budget.refusal").waitForExistence(timeout: uiWait))
    XCTAssertFalse(el(app, "budget.save").isEnabled)
    for _ in 0..<24 { app.buttons["Less"].tap() }
    XCTAssertEqual(el(app, "budget.save").label, "Set Dining to AED 1,800")
    el(app, "budget.save").tap()
    XCTAssertTrue(app.staticTexts["Moved to Dining"].waitForExistence(timeout: uiWait))
    back(app)
    let row = el(app, "plan.row.travel")
    XCTAssertTrue(reveal(app, row))
    XCTAssertTrue(row.label.hasPrefix("Travel, AED 2,300.00 left"), row.label)
  }

  /// Plan · Dining's rows: a payment opens its transaction sheet, a rule opens Categories
  /// and rules in Your profile; Day by day is one element with its summary.
  @MainActor
  func testDiningOpensItsPaymentsAndRules() throws {
    let app = launch(screen: "plan.dining")
    let chart = el(app, "plan.chart")
    XCTAssertTrue(chart.waitForExistence(timeout: 15))
    XCTAssertEqual(chart.label, "Day by day, 1–10 Oct")
    XCTAssertEqual(chart.value as? String, "Largest day Wed 7 Oct, Zuma, AED 412.00. Daily budget AED 51.61.")
    attach(app, "Plan · Dining")
    try audit(app)

    let rule = el(app, "plan.rule.r-talabat")
    XCTAssertTrue(reveal(app, rule))
    XCTAssertTrue(rule.label.contains("Merchant contains"))
    attach(app, "Plan · Dining · Rules")
    try audit(app)
    rule.tap()
    XCTAssertTrue(el(app, "rule.r-talabat").waitForExistence(timeout: uiWait))
    back(app)

    let zuma = el(app, "plan.txn.zuma")
    XCTAssertTrue(zuma.waitForExistence(timeout: uiWait))
    XCTAssertTrue(reveal(app, zuma))
    attach(app, "Plan · Dining · This month")
    zuma.tap()
    XCTAssertTrue(el(app, "txn.merchant").waitForExistence(timeout: uiWait))
    tap(app, "txn.close")
  }

  /// Assign from Ready to assign: Move money with "To" to choose, pushed inside the sheet.
  @MainActor
  func testAssignChoosesWhereTheMoneyGoes() throws {
    let app = launch(screen: "plan.assign")
    let to = el(app, "move.to")
    XCTAssertTrue(to.waitForExistence(timeout: 15))
    XCTAssertFalse(el(app, "move.save").isEnabled)
    attach(app, "Plan · Assign")
    to.tap()
    tap(app, "destination.shopping")
    XCTAssertTrue(to.waitForLabel(containing: "Shopping"))
    XCTAssertFalse(el(app, "move.from.shopping").exists)
    XCTAssertTrue(el(app, "move.save").isEnabled)
    XCTAssertEqual(el(app, "move.save").label, "Move AED 1,000.00")
    try audit(app)
  }

  /// With amounts hidden, the figures are dots and the words stay; VoiceOver hears "Amount
  /// hidden" (spec 04 §12).
  @MainActor
  func testHiddenAmountsReachEveryPlanFigure() throws {
    let app = launch(scenario: "mayaHidden", screen: "plan.dining")
    let hero = el(app, "category.hero")
    XCTAssertTrue(hero.waitForExistence(timeout: 15))
    XCTAssertTrue(hero.label.hasPrefix("Dining, Amount hidden left of Amount hidden this month. Over pace"), hero.label)
    XCTAssertFalse(hero.label.contains("957"))
    XCTAssertEqual(el(app, "plan.chart").value as? String,
                   "Largest day Wed 7 Oct, Zuma, Amount hidden. Daily budget Amount hidden.")
    attach(app, "Plan · Dining · Amounts hidden")
    tap(app, "category.changeBudget")
    // The chip's figure hides; the field it fills is an input and shows its real value.
    XCTAssertTrue(app.buttons["Cover the pace, Amount hidden"].waitForExistence(timeout: uiWait))
    XCTAssertEqual(el(app, "budget.amount").value as? String, "1,600")
    attach(app, "Plan · Dining budget · Amounts hidden")
  }

  /// The project from its card: hero, the plan setting, By category and Transactions.
  @MainActor
  func testJapanTripFromItsCard() throws {
    let app = launchHome()
    openPlan(app)
    let card = el(app, "plan.project.japan")
    XCTAssertTrue(reveal(app, card))
    XCTAssertEqual(card.label,
                   "Japan trip, 14–28 Dec, 65 days to go. AED 7,140.00 left of 12,000. Not counted in your monthly plan.")
    card.tap()
    let hero = el(app, "project.hero")
    XCTAssertTrue(hero.waitForExistence(timeout: uiWait))
    XCTAssertEqual(hero.label, "Japan trip, AED 7,140.00 left of 12,000. 14–28 Dec, 65 days to go.")
    XCTAssertTrue(el(app, "project.countInPlan").exists)
    attach(app, "Plan · Japan trip")
    try audit(app)
    let jr = el(app, "project.txn.jr-pass")
    XCTAssertTrue(reveal(app, jr))
    attach(app, "Plan · Japan trip · Transactions")
    try audit(app)
  }

  /// Day by day at AX3 and AX5 (spec 04 §17): the daily budget and the tallest day's name
  /// leave the bars for a key above the plot, and the day numbers thin out rather than run
  /// into each other. The chart is one element, so the audit cannot look inside it: the
  /// shots are the check, and the chart grows by the key.
  @MainActor
  func testDayByDayKeepsItsLabelsOffTheBarsAtLargeSizes() throws {
    let plain = launch(screen: "plan.dining", motion: "off")
    XCTAssertTrue(el(plain, "plan.chart").waitForExistence(timeout: 15))
    let height = el(plain, "plan.chart").frame.height
    for (name, size) in [("AX3", "AccessibilityXL"), ("AX5", "AccessibilityXXXL")] {
      let app = launch(screen: "plan.dining", motion: "off",
                       arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategory\(size)"])
      let chart = el(app, "plan.chart")
      XCTAssertTrue(chart.waitForExistence(timeout: 15))
      XCTAssertTrue(scroll(app, toShow: chart))
      // The day numbers above the tab bar too, so the shot holds the whole chart.
      for _ in 0..<3 where chart.frame.maxY > app.frame.height - 110 {
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
        let over = min(300, chart.frame.maxY - (app.frame.height - 130))
        from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: 0, dy: -over)))
      }
      XCTAssertLessThan(chart.frame.maxY, app.frame.height - 100, "\(name): \(chart.frame)")
      XCTAssertGreaterThan(chart.frame.height, height + 40, "\(name): \(chart.frame)")
      XCTAssertLessThanOrEqual(chart.frame.maxX, app.frame.width - 20)
      attach(app, "\(name) · Plan · Dining · Day by day")
    }
  }

  /// At the largest text size the "Ready to assign" overline takes two lines rather than
  /// being cut off (the AX3 audit below lets its "may be clipped" through on this proof).
  @MainActor
  func testReadyToAssignWrapsAtTheLargestSize() throws {
    let app = launch(screen: "plan", motion: "off",
                     arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
    XCTAssertTrue(el(app, "plan.readyToAssign").waitForExistence(timeout: 15))
    let overline = app.staticTexts.matching(NSPredicate(format: "label ==[c] 'Ready to assign'")).firstMatch
    XCTAssertTrue(overline.exists)
    // One line of the overline at this size is about 44 pt; two are about 88.
    XCTAssertGreaterThan(overline.frame.height, 70, "\(overline.frame)")
    XCTAssertLessThanOrEqual(overline.frame.maxX, app.frame.width - 20)
    attach(app, "AX5 · Plan · Ready to assign")
  }

  /// Plan at `.accessibility3`, down to the projects, then the detail and both sheets
  /// (spec 04 §17).
  @MainActor
  func testPlanAtLargeTextSizes() throws {
    let large = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"]
    let app = launchHome(arguments: large)

    // Plan, down to the projects. At the top, every check but clipped text runs as usual;
    // then clipped text alone, where the audit reads the "READY TO ASSIGN" overline as text
    // that may be cut off at larger sizes. It is not: it wraps
    // (`testReadyToAssignWrapsAtTheLargestSize`). Anything else clipped still fails.
    openPlan(app)
    XCTAssertTrue(el(app, "plan.readyToAssign").waitForExistence(timeout: uiWait))
    attach(app, "AX3 · Plan")
    try audit(app)
    try app.performAccessibilityAudit(for: .textClipped) { issue in
      issue.element?.label.localizedCaseInsensitiveCompare("Ready to assign") == .orderedSame
    }
    for id in ["plan.row.rent", "plan.row.insurance", "plan.row.dining", "plan.row.subscriptions",
               "plan.row.emergency-fund", "plan.project.japan"] {
      XCTAssertTrue(reveal(app, el(app, id)), "could not reach \(id)")
      attach(app, "AX3 · Plan · \(id)")
      try audit(app, atLargeText: true)
    }

    // Dining's month, down to its actions.
    let dining = el(app, "plan.row.dining")
    XCTAssertTrue(scroll(app, toShow: dining) || reveal(app, dining))
    dining.tap()
    XCTAssertTrue(el(app, "category.hero").waitForExistence(timeout: uiWait))
    try audit(app, atLargeText: true)
    for id in ["plan.chart", "plan.txn.talabat-3", "plan.rule.r-zuma", "category.moveMoney"] {
      XCTAssertTrue(reveal(app, el(app, id)), "could not reach \(id)")
      attach(app, "AX3 · Plan · Dining · \(id)")
      try audit(app, atLargeText: true)
    }

    // Both sheets.
    tap(app, "category.changeBudget")
    XCTAssertTrue(el(app, "budget.amount").waitForExistence(timeout: uiWait))
    attach(app, "AX3 · Plan · Dining budget")
    try audit(app, atLargeText: true)
    XCTAssertTrue(reveal(app, el(app, "budget.save")))
    try audit(app, atLargeText: true)
    tap(app, "budget.close")

    tap(app, "category.moveMoney")
    XCTAssertTrue(el(app, "move.amount").waitForExistence(timeout: uiWait))
    attach(app, "AX3 · Plan · Move money")
    try audit(app, atLargeText: true)
    XCTAssertTrue(reveal(app, el(app, "move.save")))
    try audit(app, atLargeText: true)
  }
}
