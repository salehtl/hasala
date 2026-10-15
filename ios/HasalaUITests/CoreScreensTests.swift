import XCTest

/// The core screens on the Maya mock (spec 04 §15.3: UI tests walk flows over the mutable
/// in-memory ledger). Each test starts from a fresh launch, so one flow's edits never leak
/// into another's. Every screen reached passes the accessibility audit (spec 04 §17).
final class CoreScreensTests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  @MainActor
  private func launchHome(_ scenario: String = "maya") -> XCUIApplication {
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
    let app = launchHome()
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
    // The seed puts everything on line 1 and leaves line 2 empty: not savable yet.
    XCTAssertTrue(element(app, "split.verdict").waitForLabel("Every line needs an amount"))
    XCTAssertFalse(element(app, "split.save").isEnabled)
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
    let app = launchHome()
    app.tabBars.firstMatch.buttons["Review"].tap()
    let start = element(app, "review.tab.start")
    XCTAssertTrue(start.waitForExistence(timeout: 5))
    XCTAssertEqual(element(app, "review.tab.count").label, "6 to sort · about a minute")
    attach(app, "Review · Tab")
    try audit(app)
    start.tap()
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

  /// Activity, its transaction sheet and the review deck at `.accessibility3`: layouts
  /// reflow instead of clipping, and the audit passes on each screenful (spec 04 §17).
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

    // The Review tab, then the deck.
    app.tabBars.firstMatch.buttons["Review"].tap()
    let start = element(app, "review.tab.start")
    XCTAssertTrue(start.waitForExistence(timeout: 5))
    attach(app, "AX3 · Review tab")
    try audit(app, atLargeText: true)
    XCTAssertTrue(reveal(app, start))
    start.tap()
    XCTAssertTrue(element(app, "review.card").waitForExistence(timeout: 5))
    attach(app, "AX3 · Review")
    try audit(app, atLargeText: true)
    element(app, "review.close").tap()
  }

  /// The caught-up scenario has nothing to review: no To review card, no Start, no deck.
  @MainActor
  func testCaughtUpScenarioHasNothingToReview() throws {
    let app = launchHome("mayaCaughtUp")
    XCTAssertFalse(element(app, "needsYou.review").exists)
    app.tabBars.firstMatch.buttons["Review"].tap()
    XCTAssertTrue(element(app, "review.tab.count").waitForLabel("All caught up"))
    XCTAssertFalse(element(app, "review.tab.start").exists)
    app.tabBars.firstMatch.buttons["Activity"].tap()
    XCTAssertTrue(element(app, "activity.count").waitForExistence(timeout: 5))
    XCTAssertFalse(app.staticTexts["To review"].exists)
  }
}
