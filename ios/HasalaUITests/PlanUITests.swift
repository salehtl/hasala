import XCTest

/// Plan on the Maya mock: Ready to assign, a category's month, Move money and a budget.
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

  /// Plan: Ready to assign, a category's month, Move money from Ready to assign, Undo.
  @MainActor
  func testPlanMoveMoneyAndBudget() throws {
    let app = launchHome()
    app.tabBars.firstMatch.buttons["Plan"].tap()
    let rta = el(app, "plan.readyToAssign")
    XCTAssertTrue(rta.waitForExistence(timeout: 5))
    XCTAssertEqual(rta.label, "AED 1,000.00")
    attach(app, "Plan · October")
    try audit(app)

    let groceries = el(app, "plan.row.groceries")
    XCTAssertTrue(reveal(app, groceries))
    attach(app, "Plan · Needs")
    groceries.tap()
    let total = el(app, "activity.summary.total")
    XCTAssertTrue(total.waitForExistence(timeout: 5))
    XCTAssertEqual(total.label, "AED 812.40")
    attach(app, "Plan · Groceries")
    try audit(app)

    let move = el(app, "category.moveMoney")
    XCTAssertTrue(reveal(app, move))
    move.tap()
    let save = el(app, "move.save")
    XCTAssertTrue(save.waitForExistence(timeout: 5))
    XCTAssertEqual(save.label, "Move AED 318.00")
    XCTAssertTrue(el(app, "move.preview").exists)
    // Paper's sources: Ready to assign, Travel, Shopping, Entertainment; Dining is over pace.
    for id in ["rta", "travel", "shopping", "entertainment"] {
      XCTAssertTrue(el(app, "move.from.\(id)").exists, "\(id) is not offered")
    }
    XCTAssertFalse(el(app, "move.from.dining").exists)
    XCTAssertFalse(el(app, "move.from.transport").exists)
    attach(app, "Plan · Move money")
    try audit(app)
    save.tap()
    XCTAssertTrue(app.staticTexts["Moved to Groceries"].waitForExistence(timeout: 5))
    app.navigationBars.buttons.firstMatch.tap()
    XCTAssertTrue(rta.waitForExistence(timeout: 5))
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
    XCTAssertTrue(field.waitForExistence(timeout: 5))
    app.buttons["+ 200"].tap()
    XCTAssertEqual(el(app, "budget.save").label, "Set Dining to AED 1,800")
    XCTAssertEqual(el(app, "budget.consequence").label, "Ready to assign becomes AED 482.00")
    attach(app, "Plan · Dining budget")
    // Over-assigning shows the shortfall with its minus sign.
    for _ in 0..<4 { app.buttons["+ 200"].tap() }
    XCTAssertEqual(el(app, "budget.consequence").label, "Ready to assign becomes \u{2212}AED 318.00")
    for _ in 0..<8 { app.buttons["Less"].tap() }
    XCTAssertEqual(el(app, "budget.save").label, "Set Dining to AED 1,800")
    el(app, "budget.save").tap()
    XCTAssertTrue(app.staticTexts["Dining budget changed"].waitForExistence(timeout: 5))
  }

  /// Plan at `.accessibility3`, down to the projects (spec 04 §17).
  @MainActor
  func testPlanAtLargeTextSizes() throws {
    let app = launchHome(arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"])

    // Plan, down to the projects.
    app.tabBars.firstMatch.buttons["Plan"].tap()
    XCTAssertTrue(el(app, "plan.readyToAssign").waitForExistence(timeout: 5))
    try audit(app, atLargeText: true)
    for id in ["plan.row.rent", "plan.row.insurance", "plan.row.dining", "plan.row.subscriptions",
               "plan.row.emergency-fund", "plan.project.japan"] {
      XCTAssertTrue(reveal(app, el(app, id)), "could not reach \(id)")
      attach(app, "AX3 · Plan · \(id)")
      try audit(app, atLargeText: true)
    }
  }
}
