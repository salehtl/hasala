import XCTest

/// The core screens on the Maya mock (spec 04 §15.3: UI tests walk flows over the mutable
/// in-memory ledger). Each test starts from a fresh launch, so one flow's edits never leak
/// into another's. Every screen reached passes the accessibility audit (spec 04 §17).
final class CoreScreensTests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  @MainActor
  private func launchHome(_ scenario: String = "maya", motion: String? = nil) -> XCUIApplication {
    let app = launch(scenario: scenario, motion: motion)
    XCTAssertTrue(app.descendants(matching: .any)["home.hero.left"].waitForExistence(timeout: 15))
    return app
  }

  @MainActor
  private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
    app.descendants(matching: .any)[id].firstMatch
  }

  /// Drags the top review card from its middle to a point on the screen (normalized).
  @MainActor
  private func drag(_ app: XCUIApplication, to point: CGVector) {
    element(app, "review.card").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
      .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: point))
  }

  /// Activity: the overview's figures, a filter chip, search, then the Carrefour sheet with
  /// its editors pushed inside it (one sheet at a time).
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

    // Search across months: three Carrefour rows, nothing else.
    let search = app.searchFields["Search transactions"]
    XCTAssertTrue(search.waitForExistence(timeout: 5))
    search.tap()
    search.typeText("carrefour")
    let carrefour = element(app, "txn.carrefour")
    XCTAssertTrue(carrefour.waitForExistence(timeout: 5))
    XCTAssertFalse(element(app, "txn.talabat").exists)
    attach(app, "Activity · Search")

    // The Carrefour sheet: amount, embedded pace, provenance.
    carrefour.tap()
    let merchant = element(app, "txn.merchant")
    XCTAssertTrue(merchant.waitForExistence(timeout: 5))
    XCTAssertEqual(merchant.label, "Carrefour")
    XCTAssertEqual(element(app, "txn.amount").label, "AED 342.15")
    XCTAssertTrue(app.staticTexts["Groceries this month"].exists)
    XCTAssertTrue(element(app, "txn.rawMerchant").exists)
    attach(app, "Transaction · Carrefour")
    try audit(app)

    // Choose a category pushes inside the sheet, with its rule switch; Back returns.
    element(app, "txn.category").tap()
    XCTAssertTrue(element(app, "picker.save").waitForExistence(timeout: 5))
    XCTAssertTrue(element(app, "picker.alwaysUse").exists)
    XCTAssertTrue(element(app, "picker.groceries").isSelected)
    attach(app, "Transaction · Category")
    try audit(app)
    app.navigationBars["Category"].buttons.firstMatch.tap()
    XCTAssertTrue(merchant.waitForExistence(timeout: 5))

    // A note is saved and shown on the sheet.
    element(app, "txn.note").tap()
    let field = element(app, "note.field")
    XCTAssertTrue(field.waitForExistence(timeout: 5))
    field.tap()
    field.typeText("Weekly shop")
    element(app, "note.save").tap()
    XCTAssertTrue(element(app, "txn.note").waitForLabel(containing: "Weekly shop"))

    // Split: 45.15 into the second line on the keypad, the rest stays in Groceries.
    let split = element(app, "txn.split")
    XCTAssertTrue(reveal(app, split))
    split.tap()
    XCTAssertTrue(element(app, "split.verdict").waitForExistence(timeout: 5))
    // The seed puts everything on line 1 and leaves line 2 empty: not savable yet.
    XCTAssertTrue(element(app, "split.verdict").waitForLabel("Every line needs an amount"))
    XCTAssertFalse(element(app, "split.save").isEnabled)
    let second = element(app, "split.amount.2")
    second.tap()
    for key in ["4", "5", "decimal", "1", "5"] { element(app, "keypad.\(key)").tap() }
    XCTAssertEqual(second.value as? String, "45.15")
    XCTAssertTrue(element(app, "split.verdict").waitForLabel("45 dirhams 15 too much"))
    // Tapping the field again puts the keypad away.
    second.tap()
    XCTAssertTrue(element(app, "keypad.4").waitForNonExistence(timeout: 5))
    app.buttons["Put the rest in Groceries"].tap()
    XCTAssertTrue(element(app, "split.verdict").waitForLabel("Adds up exactly"))
    attach(app, "Transaction · Split")
    try audit(app)
    element(app, "split.save").tap()
    XCTAssertTrue(element(app, "txn.category").waitForLabel(containing: "Split · 2"))
    element(app, "txn.close").tap()
  }

  /// Review from the Review tab: Transfer by a drag up and the pick sheet, Undo, the pill,
  /// skip, Use for the rest, then All caught up and "See activity".
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

    // Drag the first card (the ATM withdrawal) up: Transfer.
    drag(app, to: CGVector(dx: 0.5, dy: 0.05))
    let sort = element(app, "pick.sort")
    XCTAssertTrue(sort.waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Transfer · which one?"].exists)
    attach(app, "Review · Pick transfer")
    try audit(app)
    element(app, "pick.transfer").tap()
    sort.tap()
    XCTAssertTrue(app.staticTexts["Sorted into Transfer"].waitForExistence(timeout: 5))
    XCTAssertEqual(position.label, "2 of 6")

    // Undo puts it back.
    element(app, "toast").buttons["Undo"].tap()
    XCTAssertTrue(position.waitForLabel("1 of 6"))

    // Sort it again from the pill.
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
    XCTAssertEqual(element(app, "review.done.tally").label, "5 sorted")
    attach(app, "Review · All caught up")
    try audit(app)
    element(app, "review.seeActivity").tap()
    XCTAssertTrue(element(app, "activity.count").waitForExistence(timeout: 5))
    // The skipped card is still waiting; the others left the queue.
    XCTAssertTrue(app.staticTexts["1 to sort"].waitForExistence(timeout: 5))
  }

  /// A To sort row opens the deck at its own card; a pick sheet closed without a choice sends
  /// the card back; Close leaves the rest for later.
  @MainActor
  func testAToSortRowOpensTheDeckAtItsCard() throws {
    let app = launchHome()
    app.tabBars.firstMatch.buttons["Review"].tap()
    let row = element(app, "review.tab.row.lulu")
    XCTAssertTrue(row.waitForExistence(timeout: 5))
    XCTAssertTrue(reveal(app, row))
    row.tap()
    let merchant = element(app, "review.merchant")
    XCTAssertTrue(merchant.waitForLabel(containing: "Lulu Hypermarket"), merchant.debugDescription)
    XCTAssertEqual(element(app, "review.position").label, "1 of 6")

    // Drag left: Want asks which one; closing the sheet sorts nothing.
    drag(app, to: CGVector(dx: 0.02, dy: 0.5))
    XCTAssertTrue(app.staticTexts["Want · which one?"].waitForExistence(timeout: 5))
    element(app, "pick.close").tap()
    XCTAssertTrue(element(app, "pick.sort").waitForNonExistence(timeout: 5))
    XCTAssertTrue(merchant.waitForLabel(containing: "Lulu Hypermarket"))
    XCTAssertEqual(element(app, "review.position").label, "1 of 6")

    // Use files the suggestion; the deck reads on down the list.
    element(app, "review.use").tap()
    XCTAssertTrue(merchant.waitForLabel(containing: "Dubai Taxi"), merchant.debugDescription)
    XCTAssertEqual(element(app, "review.position").label, "2 of 6")
    element(app, "review.close").tap()
    XCTAssertTrue(element(app, "review.tab.count").waitForLabel("5 to sort · about a minute"))
  }

  /// Let go before the commit point and the card springs back: no pick sheet, nothing
  /// filed, the same card in front. Slow drags each way, short of the 100 pt point.
  @MainActor
  func testAShortDragSpringsBack() throws {
    let app = launchHome()
    app.tabBars.firstMatch.buttons["Review"].tap()
    let start = element(app, "review.tab.start")
    XCTAssertTrue(start.waitForExistence(timeout: 5))
    start.tap()
    let merchant = element(app, "review.merchant")
    XCTAssertTrue(merchant.waitForLabel(containing: "ADCB ATM withdrawal"), merchant.debugDescription)
    let middle = element(app, "review.card").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    for offset in [CGVector(dx: 60, dy: 0), CGVector(dx: -60, dy: 0), CGVector(dx: 0, dy: -50), CGVector(dx: 0, dy: 50)] {
      middle.press(forDuration: 0.05, thenDragTo: middle.withOffset(offset), withVelocity: 120,
                   thenHoldForDuration: 0.3)
      XCTAssertFalse(element(app, "pick.sort").waitForExistence(timeout: 1), "a short drag committed")
    }
    XCTAssertTrue(merchant.label.contains("ADCB ATM withdrawal"))
    XCTAssertEqual(element(app, "review.position").label, "1 of 6")
  }

  /// The deck with Reduce Motion (`-HasalaMotion reduce`): nothing travels, but every sort
  /// still works, by drag, pill and Use, through to All caught up.
  @MainActor
  func testReviewDeckWithReduceMotion() throws {
    let app = launchHome(motion: "reduce")
    app.tabBars.firstMatch.buttons["Review"].tap()
    let start = element(app, "review.tab.start")
    XCTAssertTrue(start.waitForExistence(timeout: 5))
    start.tap()
    let position = element(app, "review.position")
    XCTAssertTrue(position.waitForLabel("1 of 6"))

    // Need by a drag right, for the ATM withdrawal: Rent.
    drag(app, to: CGVector(dx: 0.98, dy: 0.5))
    let sort = element(app, "pick.sort")
    XCTAssertTrue(sort.waitForExistence(timeout: 5))
    attach(app, "Reduce Motion · Pick a need")
    element(app, "pick.rent").tap()
    sort.tap()
    XCTAssertTrue(position.waitForLabel("2 of 6"))
    attach(app, "Reduce Motion · Deck")
    try audit(app)

    // Money in: the Transfer pill; then Use for the four suggestions.
    element(app, "review.pill.transfer").tap()
    XCTAssertTrue(sort.waitForExistence(timeout: 5))
    element(app, "pick.salary").tap()
    sort.tap()
    for _ in 0..<4 {
      let use = element(app, "review.use")
      XCTAssertTrue(use.waitForExistence(timeout: 5))
      use.tap()
    }
    XCTAssertTrue(element(app, "review.done").waitForExistence(timeout: 5))
    // Need asks to remember the merchant by default: one rule.
    XCTAssertEqual(element(app, "review.done.tally").label, "6 sorted · 1 new rule")
    attach(app, "Reduce Motion · All caught up")
    element(app, "review.close").tap()
    XCTAssertTrue(element(app, "review.tab.count").waitForLabel("All caught up"))
  }

  /// Activity, its transaction sheet and the review deck at `.accessibility3`: layouts
  /// reflow instead of clipping, and the audit passes on each screenful (spec 04 §17).
  @MainActor
  func testCoreScreensAtLargeTextSizes() throws {
    let app = launch(arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"])
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

    // The Review tab, then the deck, which scrolls and doesn't drag at these sizes.
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
    for id in ["review.use", "review.pill.save", "review.skip"] {
      XCTAssertTrue(reveal(app, element(app, id)), "could not reach \(id)")
      try audit(app, atLargeText: true)
    }
    element(app, "review.close").tap()
  }

  /// The caught-up scenario has nothing to review: no To review card, no Start, no deck.
  @MainActor
  func testCaughtUpScenarioHasNothingToReview() throws {
    let app = launchHome("mayaCaughtUp")
    app.tabBars.firstMatch.buttons["Review"].tap()
    XCTAssertTrue(element(app, "review.tab.count").waitForLabel("All caught up"))
    XCTAssertTrue(element(app, "review.tab.empty").exists)
    XCTAssertFalse(element(app, "review.tab.start").exists)
    app.tabBars.firstMatch.buttons["Activity"].tap()
    XCTAssertTrue(element(app, "activity.count").waitForExistence(timeout: 5))
    XCTAssertFalse(app.staticTexts["To review"].exists)
  }
}
