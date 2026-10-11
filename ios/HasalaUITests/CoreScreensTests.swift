import XCTest

/// The core screens on the Maya mock (spec 04 §15.3: UI tests walk flows over the mutable
/// in-memory ledger). Each test starts from a fresh launch, so one flow's edits never leak
/// into another's. Every screen reached passes the accessibility audit (spec 04 §17).
final class CoreScreensTests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  @MainActor
  private func launch(_ scenario: String = "maya") -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-HasalaScenario", scenario]
    app.launch()
    XCTAssertTrue(app.descendants(matching: .any)["home.hero.left"].waitForExistence(timeout: 15))
    return app
  }

  @MainActor
  private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
    app.descendants(matching: .any)[id].firstMatch
  }

  /// Activity: the overview's figures, a filter chip, search, then the Carrefour sheet.
  @MainActor
  func testActivityFiltersSearchAndTransactionSheet() throws {
    let app = launch()
    app.tabBars.firstMatch.buttons["Activity"].tap()
    let count = element(app, "activity.count")
    XCTAssertTrue(count.waitForExistence(timeout: 5))
    XCTAssertEqual(count.label, "26 transactions this month")
    XCTAssertTrue(app.staticTexts["6 to sort"].exists)
    XCTAssertTrue(app.staticTexts["Coming up"].exists)
    attach(app, "Activity · Overview")
    try audit(app)

    // To review: only the six cards, with the to-review rows.
    element(app, "activity.chip.toReview").tap()
    XCTAssertTrue(element(app, "txn.lulu").waitForExistence(timeout: 5))
    XCTAssertFalse(element(app, "txn.carrefour").exists)
    attach(app, "Activity · To review")
    element(app, "activity.chip.all").tap()

    // The Carrefour sheet: amount, embedded pace, provenance.
    let carrefour = element(app, "txn.carrefour")
    XCTAssertTrue(reveal(app, carrefour))
    carrefour.tap()
    let merchant = element(app, "txn.merchant")
    XCTAssertTrue(merchant.waitForExistence(timeout: 5))
    XCTAssertEqual(merchant.label, "Carrefour")
    XCTAssertEqual(element(app, "txn.amount").label, "AED 342.15")
    XCTAssertTrue(app.staticTexts["Groceries this month"].exists)
    XCTAssertTrue(element(app, "txn.rawMerchant").exists)
    attach(app, "Transaction · Carrefour")
    try audit(app)

    // A note is saved and shown on the sheet.
    element(app, "txn.note").tap()
    let field = element(app, "note.field")
    XCTAssertTrue(field.waitForExistence(timeout: 5))
    field.tap()
    field.typeText("Weekly shop")
    element(app, "note.save").tap()
    XCTAssertTrue(element(app, "txn.note").waitForLabel(containing: "Weekly shop"))

    // Split: put 45.15 into Shopping, the rest stays in Groceries.
    let split = element(app, "txn.split")
    XCTAssertTrue(reveal(app, split))
    split.tap()
    XCTAssertTrue(element(app, "split.verdict").waitForExistence(timeout: 5))
    let second = element(app, "split.amount.2")
    second.tap()
    second.typeText("45.15")
    app.buttons["Put the rest in Groceries"].tap()
    XCTAssertTrue(element(app, "split.verdict").waitForLabel("Adds up exactly"))
    attach(app, "Transaction · Split")
    element(app, "split.save").tap()
    XCTAssertTrue(element(app, "txn.category").waitForLabel(containing: "Split · 2"))
    element(app, "txn.close").tap()
  }

  /// Review: sort with a direction pill and the pick sheet, use a suggestion, undo, skip,
  /// and finish on All caught up.
  @MainActor
  func testReviewDeckSortsUndoesAndCatchesUp() throws {
    let app = launch()
    element(app, "needsYou.review").buttons["Start"].tap()
    let position = element(app, "review.position")
    XCTAssertTrue(position.waitForExistence(timeout: 5))
    XCTAssertEqual(position.label, "1 of 6")
    attach(app, "Review · Deck")
    try audit(app)

    // Swipe the first card (the ATM withdrawal) up: Transfer.
    let card = element(app, "review.card")
    card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
      .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)))
    let sort = element(app, "pick.sort")
    XCTAssertTrue(sort.waitForExistence(timeout: 5))
    attach(app, "Review · Pick transfer")
    element(app, "pick.transfer").tap()
    sort.tap()
    XCTAssertTrue(app.staticTexts["Sorted into Transfer"].waitForExistence(timeout: 5))
    XCTAssertEqual(position.label, "2 of 6")

    // Undo puts it back.
    element(app, "toast").buttons["Undo"].tap()
    XCTAssertTrue(position.waitForLabel("1 of 6"))

    // Sort it again from the pill, then the next with the "Need" pill.
    element(app, "review.pill.transfer").tap()
    XCTAssertTrue(sort.waitForExistence(timeout: 5))
    element(app, "pick.transfer").tap()
    sort.tap()
    XCTAssertTrue(position.waitForLabel("2 of 6"))

    // Card 2: money in; skip it for now.
    XCTAssertTrue(sort.waitForNonExistence(timeout: 5))
    let skip = element(app, "review.skip")
    XCTAssertTrue(skip.waitForExistence(timeout: 5) && skip.isHittable)
    skip.tap()
    let merchant = element(app, "review.merchant")
    XCTAssertTrue(merchant.waitForLabel(containing: "Apple.com"), merchant.debugDescription)

    // Card 3 onward: use each suggestion.
    for _ in 0..<4 {
      let use = element(app, "review.use")
      XCTAssertTrue(use.waitForExistence(timeout: 5))
      use.tap()
    }
    XCTAssertTrue(element(app, "review.done").waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["5 sorted"].exists)
    attach(app, "Review · All caught up")
    try audit(app)
    element(app, "review.backToActivity").tap()
    XCTAssertTrue(element(app, "activity.count").waitForExistence(timeout: 5))
    // The skipped card is still waiting; the others left the queue.
    XCTAssertTrue(app.staticTexts["1 to sort"].waitForExistence(timeout: 5))
  }

  /// Plan: Ready to assign, a category's month, Move money from Ready to assign, Undo.
  @MainActor
  func testPlanMoveMoneyAndBudget() throws {
    let app = launch()
    app.tabBars.firstMatch.buttons["Plan"].tap()
    let rta = element(app, "plan.readyToAssign")
    XCTAssertTrue(rta.waitForExistence(timeout: 5))
    XCTAssertEqual(rta.label, "AED 1,000.00")
    attach(app, "Plan · October")
    try audit(app)

    let groceries = element(app, "plan.row.groceries")
    XCTAssertTrue(reveal(app, groceries))
    attach(app, "Plan · Needs")
    groceries.tap()
    let total = element(app, "activity.summary.total")
    XCTAssertTrue(total.waitForExistence(timeout: 5))
    XCTAssertEqual(total.label, "AED 812.40")
    attach(app, "Plan · Groceries")
    try audit(app)

    let move = element(app, "category.moveMoney")
    XCTAssertTrue(reveal(app, move))
    move.tap()
    let save = element(app, "move.save")
    XCTAssertTrue(save.waitForExistence(timeout: 5))
    XCTAssertEqual(save.label, "Move AED 318.00")
    XCTAssertTrue(element(app, "move.preview").exists)
    attach(app, "Plan · Move money")
    try audit(app)
    save.tap()
    XCTAssertTrue(app.staticTexts["Moved to Groceries"].waitForExistence(timeout: 5))
    app.navigationBars.buttons.firstMatch.tap()
    XCTAssertTrue(rta.waitForExistence(timeout: 5))
    XCTAssertTrue(scroll(app, toShow: rta))
    XCTAssertEqual(rta.label, "AED 682.00")

    // Change Dining's budget to 1,800: Ready to assign follows.
    let dining = element(app, "plan.row.dining")
    XCTAssertTrue(reveal(app, dining))
    dining.tap()
    let change = element(app, "category.changeBudget")
    XCTAssertTrue(reveal(app, change))
    change.tap()
    let field = element(app, "budget.amount")
    XCTAssertTrue(field.waitForExistence(timeout: 5))
    app.buttons["+ 200"].tap()
    XCTAssertEqual(element(app, "budget.save").label, "Set Dining to AED 1,800")
    XCTAssertEqual(element(app, "budget.consequence").label, "Ready to assign becomes AED 482.00")
    attach(app, "Plan · Dining budget")
    element(app, "budget.save").tap()
    XCTAssertTrue(app.staticTexts["Dining budget changed"].waitForExistence(timeout: 5))
  }

  /// Profile: the sheet, Bills (track a found bill), rules, notifications, Hide amounts.
  @MainActor
  func testProfileBillsAndSettings() throws {
    let app = launch()
    app.buttons["header.profile"].firstMatch.tap()
    XCTAssertTrue(element(app, "profile.name").waitForExistence(timeout: 5))
    XCTAssertTrue(element(app, "profile.bankAlerts").label.contains("Bank alerts are working"))
    attach(app, "Profile")
    try audit(app)

    element(app, "profile.bills").tap()
    let next14 = element(app, "bills.next14")
    XCTAssertTrue(next14.waitForExistence(timeout: 5))
    XCTAssertEqual(next14.label, "AED 1,039.15")
    attach(app, "Bills")
    try audit(app)
    let track = element(app, "bills.track.apple-bill")
    XCTAssertTrue(reveal(app, track))
    track.tap()
    XCTAssertTrue(app.staticTexts["Tracking Apple.com/bill"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["10 tracked"].waitForExistence(timeout: 5))
    app.navigationBars.buttons.firstMatch.tap()

    element(app, "profile.rules").tap()
    XCTAssertTrue(element(app, "rule.r-carrefour").waitForExistence(timeout: 5))
    attach(app, "Categories and rules")
    try audit(app)
    app.navigationBars.buttons.firstMatch.tap()

    let notifications = element(app, "profile.notifications")
    XCTAssertTrue(reveal(app, notifications))
    notifications.tap()
    element(app, "notifications.everything").tap()
    app.navigationBars.buttons.firstMatch.tap()
    XCTAssertTrue(element(app, "profile.notifications").waitForLabel(containing: "Everything"))
    element(app, "profile.close").tap()

    // Hide amounts reaches Activity and the transaction sheet.
    app.buttons["header.hideAmounts"].firstMatch.tap()
    app.tabBars.firstMatch.buttons["Activity"].tap()
    let talabat = element(app, "txn.talabat")
    XCTAssertTrue(talabat.waitForExistence(timeout: 5))
    talabat.tap()
    XCTAssertTrue(element(app, "txn.amount").waitForLabel("Amount hidden"))
    attach(app, "Transaction · Amounts hidden")
  }

  /// The core screens at `.accessibility3`: layouts reflow instead of clipping, and the
  /// audit passes on each screenful (spec 04 §17).
  @MainActor
  func testCoreScreensAtLargeTextSizes() throws {
    let app = XCUIApplication()
    app.launchArguments = [
      "-HasalaScenario", "maya",
      "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL",
    ]
    app.launch()
    XCTAssertTrue(element(app, "home.hero.left").waitForExistence(timeout: 15))

    // Activity, down the page, then the Carrefour sheet.
    app.tabBars.firstMatch.buttons["Activity"].tap()
    XCTAssertTrue(element(app, "activity.count").waitForExistence(timeout: 5))
    for id in ["activity.startReview", "bill.dewa", "txn.talabat", "txn.carrefour"] {
      let target = element(app, id)
      XCTAssertTrue(reveal(app, target), "could not reach \(id)")
      attach(app, "AX3 · Activity · \(id)")
      try audit(app, atLargeText: true)
    }
    element(app, "txn.carrefour").tap()
    XCTAssertTrue(element(app, "txn.merchant").waitForExistence(timeout: 5))
    attach(app, "AX3 · Transaction")
    try audit(app, atLargeText: true)
    for id in ["txn.note", "txn.rawMerchant", "txn.archive"] {
      XCTAssertTrue(reveal(app, element(app, id)), "could not reach \(id)")
      try audit(app, atLargeText: true)
    }
    element(app, "txn.close").tap()

    // Plan, down to the projects.
    app.tabBars.firstMatch.buttons["Plan"].tap()
    XCTAssertTrue(element(app, "plan.readyToAssign").waitForExistence(timeout: 5))
    try audit(app, atLargeText: true)
    for id in ["plan.row.rent", "plan.row.insurance", "plan.row.dining", "plan.row.subscriptions",
               "plan.row.emergency-fund", "plan.project.japan"] {
      XCTAssertTrue(reveal(app, element(app, id)), "could not reach \(id)")
      attach(app, "AX3 · Plan · \(id)")
      try audit(app, atLargeText: true)
    }

    // The review deck.
    app.tabBars.firstMatch.buttons["Home"].tap()
    let start = element(app, "needsYou.review").buttons["Start"]
    XCTAssertTrue(reveal(app, start))
    start.tap()
    XCTAssertTrue(element(app, "review.card").waitForExistence(timeout: 5))
    attach(app, "AX3 · Review")
    try audit(app, atLargeText: true)
    element(app, "review.close").tap()

    // Profile and Bills.
    app.buttons["header.profile"].firstMatch.tap()
    XCTAssertTrue(element(app, "profile.name").waitForExistence(timeout: 5))
    try audit(app, atLargeText: true)
    for id in ["profile.rules", "profile.faceID", "profile.signOut"] {
      XCTAssertTrue(reveal(app, element(app, id)), "could not reach \(id)")
      attach(app, "AX3 · Profile · \(id)")
      try audit(app, atLargeText: true)
    }
  }

  /// The caught-up scenario has nothing to review: no To review card, no deck.
  @MainActor
  func testCaughtUpScenarioHasNothingToReview() throws {
    let app = launch("mayaCaughtUp")
    XCTAssertFalse(element(app, "needsYou.review").exists)
    app.tabBars.firstMatch.buttons["Activity"].tap()
    XCTAssertTrue(element(app, "activity.count").waitForExistence(timeout: 5))
    XCTAssertFalse(app.staticTexts["To review"].exists)
  }
}

extension XCTestCase {
  /// Drags the page up until `element` can be tapped, for rows near the end of a page
  /// that can never reach the upper half. Returns whether it got there.
  @MainActor
  func reveal(_ app: XCUIApplication, _ element: XCUIElement) -> Bool {
    for _ in 0..<12 {
      if element.exists, element.isHittable, element.frame.maxY < app.frame.height - 120 { return true }
      let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
      let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
      from.press(forDuration: 0.05, thenDragTo: to)
    }
    return element.exists && element.isHittable
  }
}

extension XCUIElement {
  /// Waits until the element's label reads `label`.
  func waitForLabel(_ label: String, timeout: TimeInterval = 5) -> Bool {
    let predicate = NSPredicate(format: "label == %@", label)
    return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: self)], timeout: timeout)
      == .completed
  }

  /// Waits until the element's label contains `text`.
  func waitForLabel(containing text: String, timeout: TimeInterval = 5) -> Bool {
    let predicate = NSPredicate(format: "label CONTAINS %@", text)
    return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: self)], timeout: timeout)
      == .completed
  }
}
