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
    XCTAssertTrue(count.waitForExistence(timeout: uiWait))
    XCTAssertEqual(count.label, "26 transactions this month")
    XCTAssertTrue(app.staticTexts["6 to sort"].exists)
    XCTAssertTrue(app.staticTexts["Coming up"].exists)
    attach(app, "Activity · Overview")
    try audit(app)

    // To review: only the six cards, with the to-review rows.
    element(app, "activity.chip.toReview").tap()
    XCTAssertTrue(element(app, "txn.lulu").waitForExistence(timeout: uiWait))
    XCTAssertFalse(element(app, "txn.carrefour").exists)
    attach(app, "Activity · To review")
    element(app, "activity.chip.all").tap()

    // Search across months: three Carrefour rows, nothing else.
    let search = app.searchFields["Search transactions"]
    XCTAssertTrue(search.waitForExistence(timeout: uiWait))
    type("carrefour", into: search)
    let carrefour = element(app, "txn.carrefour")
    XCTAssertTrue(carrefour.waitForExistence(timeout: uiWait))
    XCTAssertFalse(element(app, "txn.talabat").exists)
    attach(app, "Activity · Search")

    // The Carrefour sheet: amount, embedded pace, provenance.
    carrefour.tap()
    let merchant = element(app, "txn.merchant")
    XCTAssertTrue(merchant.waitForExistence(timeout: uiWait))
    XCTAssertEqual(merchant.label, "Carrefour")
    XCTAssertEqual(element(app, "txn.amount").label, "AED 342.15")
    XCTAssertTrue(app.staticTexts["Groceries this month"].exists)
    XCTAssertTrue(element(app, "txn.rawMerchant").exists)
    attach(app, "Transaction · Carrefour")
    try audit(app)

    // Choose a category pushes inside the sheet, with its rule switch; Back returns.
    element(app, "txn.category").tap()
    XCTAssertTrue(element(app, "picker.save").waitForExistence(timeout: uiWait))
    XCTAssertTrue(element(app, "picker.alwaysUse").exists)
    XCTAssertTrue(element(app, "picker.groceries").isSelected)
    attach(app, "Transaction · Category")
    try audit(app)
    app.navigationBars["Category"].buttons.firstMatch.tap()
    XCTAssertTrue(merchant.waitForExistence(timeout: uiWait))

    // A note is saved and shown on the sheet.
    element(app, "txn.note").tap()
    let field = element(app, "note.field")
    XCTAssertTrue(field.waitForExistence(timeout: uiWait))
    type("Weekly shop", into: field)
    element(app, "note.save").tap()
    XCTAssertTrue(element(app, "txn.note").waitForLabel(containing: "Weekly shop"))

    // Split: 45.15 into the second line on the keypad, the rest stays in Groceries.
    let split = element(app, "txn.split")
    XCTAssertTrue(reveal(app, split))
    split.tap()
    XCTAssertTrue(element(app, "split.verdict").waitForExistence(timeout: uiWait))
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
    XCTAssertTrue(element(app, "keypad.4").waitForNonExistence(timeout: uiWait))
    app.buttons["Put the rest in Groceries"].tap()
    XCTAssertTrue(element(app, "split.verdict").waitForLabel("Adds up exactly"))
    attach(app, "Transaction · Split")
    try audit(app)
    element(app, "split.save").tap()
    XCTAssertTrue(element(app, "txn.category").waitForLabel(containing: "Split · 2"))
    element(app, "txn.close").tap()
  }

  @MainActor
  func testReviewDeckOffersMergeOrKeepBothForACopy() throws {
    let app = launch(scenario: "mayaCopy", screen: "review.copy")
    let line = element(app, "review.copy")
    XCTAssertTrue(line.waitForExistence(timeout: 15))
    XCTAssertEqual(line.label, "Looks like a copy of Starbucks DIFC AED 27.00 from your other inbox")
    XCTAssertTrue(element(app, "review.reason.probable_copy").exists)
    XCTAssertTrue(element(app, "review.merge").exists && element(app, "review.keepBoth").exists)
    attach(app, "Review · Copy")
    try audit(app)
    element(app, "review.merge").tap()
    XCTAssertTrue(line.waitForNonExistence(timeout: uiWait), "the copy stayed on the deck")
    attach(app, "Review · Copy merged")
  }

  /// Review from the Review tab: Transfer by a drag up and the pick sheet, Undo, the pill,
  /// skip, Use for the rest, then All caught up and "See activity".
  @MainActor
  func testReviewDeckSortsUndoesAndCatchesUp() throws {
    let app = launchHome()
    app.tabBars.firstMatch.buttons["Review"].tap()
    let start = element(app, "review.tab.start")
    XCTAssertTrue(start.waitForExistence(timeout: uiWait))
    XCTAssertEqual(element(app, "review.tab.count").label, "6 to sort · about a minute")
    attach(app, "Review · Tab")
    try audit(app)
    start.tap()
    let position = element(app, "review.position")
    XCTAssertTrue(position.waitForExistence(timeout: uiWait))
    XCTAssertEqual(position.label, "1 of 6")
    attach(app, "Review · Deck")
    try audit(app)

    // Drag the first card (the ATM withdrawal) up: Transfer.
    drag(app, to: CGVector(dx: 0.5, dy: 0.05))
    let sheet = element(app, "pick.close")
    XCTAssertTrue(sheet.waitForExistence(timeout: uiWait))
    XCTAssertTrue(app.staticTexts["Transfer · which one?"].exists)
    attach(app, "Review · Pick transfer")
    try audit(app)
    element(app, "pick.transfer").tap()
    XCTAssertTrue(app.staticTexts["Sorted into Transfer"].waitForExistence(timeout: uiWait))
    XCTAssertTrue(sheet.waitForNonExistence(timeout: uiWait))
    XCTAssertEqual(position.label, "2 of 6")
    attach(app, "Review · Deck after a one-tap sort")

    // Undo puts it back.
    element(app, "toast").buttons["Undo"].tap()
    XCTAssertTrue(position.waitForLabel("1 of 6"))

    // Sort it again from the pill.
    element(app, "review.pill.transfer").tap()
    XCTAssertTrue(sheet.waitForExistence(timeout: uiWait))
    element(app, "pick.transfer").tap()
    XCTAssertTrue(position.waitForLabel("2 of 6"))

    // Card 2: money in; skip it for now.
    XCTAssertTrue(sheet.waitForNonExistence(timeout: uiWait))
    let skip = element(app, "review.skip")
    XCTAssertTrue(skip.waitForExistence(timeout: uiWait) && skip.isHittable)
    skip.tap()
    let merchant = element(app, "review.merchant")
    XCTAssertTrue(merchant.waitForLabel(containing: "Apple.com"), merchant.debugDescription)

    for _ in 0..<3 {
      let use = element(app, "review.use")
      XCTAssertTrue(use.waitForExistence(timeout: uiWait))
      use.tap()
    }
    XCTAssertTrue(merchant.waitForLabel(containing: "Steam"), merchant.debugDescription)
    XCTAssertFalse(element(app, "review.use").exists)
    element(app, "review.pill.want").tap()
    XCTAssertTrue(sheet.waitForExistence(timeout: uiWait))
    element(app, "pick.alwaysUse").tap()
    element(app, "pick.entertainment").tap()
    XCTAssertTrue(element(app, "review.done").waitForExistence(timeout: uiWait))
    XCTAssertEqual(element(app, "review.done.tally").label, "5 sorted")
    attach(app, "Review · All caught up")
    try audit(app)
    element(app, "review.seeActivity").tap()
    XCTAssertTrue(element(app, "activity.count").waitForExistence(timeout: uiWait))
    // The skipped card is still waiting; the others left the queue.
    XCTAssertTrue(app.staticTexts["1 to sort"].waitForExistence(timeout: uiWait))
  }

  /// A To sort row opens the deck at its own card; a pick sheet closed without a choice sends
  /// the card back; Close leaves the rest for later.
  @MainActor
  func testAToSortRowOpensTheDeckAtItsCard() throws {
    let app = launchHome()
    app.tabBars.firstMatch.buttons["Review"].tap()
    let row = element(app, "review.tab.row.lulu")
    XCTAssertTrue(row.waitForExistence(timeout: uiWait))
    XCTAssertTrue(reveal(app, row))
    row.tap()
    let merchant = element(app, "review.merchant")
    XCTAssertTrue(merchant.waitForLabel(containing: "Lulu Hypermarket"), merchant.debugDescription)
    XCTAssertEqual(element(app, "review.position").label, "1 of 6")

    // Drag left: Want asks which one; closing the sheet sorts nothing.
    drag(app, to: CGVector(dx: 0.02, dy: 0.5))
    XCTAssertTrue(app.staticTexts["Want · which one?"].waitForExistence(timeout: uiWait))
    element(app, "pick.close").tap()
    XCTAssertTrue(element(app, "pick.close").waitForNonExistence(timeout: uiWait))
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
    XCTAssertTrue(start.waitForExistence(timeout: uiWait))
    start.tap()
    let merchant = element(app, "review.merchant")
    XCTAssertTrue(merchant.waitForLabel(containing: "ADCB ATM withdrawal"), merchant.debugDescription)
    let middle = element(app, "review.card").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    for offset in [CGVector(dx: 60, dy: 0), CGVector(dx: -60, dy: 0), CGVector(dx: 0, dy: -50), CGVector(dx: 0, dy: 50)] {
      middle.press(forDuration: 0.05, thenDragTo: middle.withOffset(offset), withVelocity: 120,
                   thenHoldForDuration: 0.3)
      XCTAssertFalse(element(app, "pick.close").waitForExistence(timeout: 1), "a short drag committed")
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
    XCTAssertTrue(start.waitForExistence(timeout: uiWait))
    start.tap()
    let position = element(app, "review.position")
    XCTAssertTrue(position.waitForLabel("1 of 6"))

    // Need by a drag right, for the ATM withdrawal: Rent. Let go, the card goes back to
    // rest and waits there under the sheet (a static card, spec 12), not leaning.
    let card = element(app, "review.card")
    let rest = card.frame
    drag(app, to: CGVector(dx: 0.98, dy: 0.5))
    let sheet = element(app, "pick.close")
    XCTAssertTrue(sheet.waitForExistence(timeout: uiWait))
    XCTAssertEqual(card.frame.midX, rest.midX, accuracy: 1, "the card leans with Reduce Motion")
    XCTAssertEqual(card.frame.midY, rest.midY, accuracy: 1, "the card leans with Reduce Motion")
    attach(app, "Reduce Motion · Pick a need")
    element(app, "pick.rent").tap()
    XCTAssertTrue(position.waitForLabel("2 of 6"))
    attach(app, "Reduce Motion · Deck")
    try audit(app)

    // Money in: the Transfer pill (the card stays put); then Use for the four suggestions.
    let second = card.frame
    element(app, "review.pill.transfer").tap()
    XCTAssertTrue(sheet.waitForExistence(timeout: uiWait))
    XCTAssertEqual(card.frame.midY, second.midY, accuracy: 1, "the card rises with Reduce Motion")
    element(app, "pick.salary").tap()
    for _ in 0..<3 {
      let use = element(app, "review.use")
      XCTAssertTrue(use.waitForExistence(timeout: uiWait))
      use.tap()
    }
    // Steam's sender is not verified: no Use, so a pill and the pick sheet, without a rule.
    element(app, "review.pill.want").tap()
    XCTAssertTrue(sheet.waitForExistence(timeout: uiWait))
    element(app, "pick.alwaysUse").tap()
    element(app, "pick.entertainment").tap()
    XCTAssertTrue(element(app, "review.done").waitForExistence(timeout: uiWait))
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
    XCTAssertTrue(element(app, "activity.count").waitForExistence(timeout: uiWait))
    for id in ["activity.startReview", "bill.dewa", "txn.talabat", "txn.carrefour"] {
      let target = element(app, id)
      XCTAssertTrue(reveal(app, target), "could not reach \(id)")
      attach(app, "AX3 · Activity · \(id)")
      try audit(app, atLargeText: true)
    }
    element(app, "txn.carrefour").tap()
    XCTAssertTrue(element(app, "txn.merchant").waitForExistence(timeout: uiWait))
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
    XCTAssertTrue(start.waitForExistence(timeout: uiWait))
    attach(app, "AX3 · Review tab")
    try audit(app, atLargeText: true)
    XCTAssertTrue(reveal(app, start))
    start.tap()
    XCTAssertTrue(element(app, "review.card").waitForExistence(timeout: uiWait))
    attach(app, "AX3 · Review")
    try audit(app, atLargeText: true)
    for id in ["review.use", "review.pill.save", "review.skip"] {
      XCTAssertTrue(reveal(app, element(app, id)), "could not reach \(id)")
      try audit(app, atLargeText: true)
    }
    element(app, "review.close").tap()
  }

  /// Search: Ready under its large title with the field focused (Paper "Search ·
  /// Ready"); the first letters swap "Try asking" for results and the title makes room
  /// (S3 has none); a transaction result opens its sheet.
  @MainActor
  func testDebugSearchReadyThenResults() throws {
    let app = launchHome()
    app.tabBars.firstMatch.buttons["Search"].tap()
    XCTAssertTrue(element(app, "search.placeholder").waitForExistence(timeout: uiWait))
    let title = app.navigationBars.staticTexts["Search"]
    XCTAssertTrue(title.waitForExistence(timeout: uiWait) && title.isHittable, "Ready has no large title")
    attach(app, "Search · Ready")
    // Search's own parts are audited with the keyboard put away: with it up, the audit
    // flags the keyboard's empty prediction cells, system UI the shared filter does not
    // skip yet (requests/p6.md 4).
    // (A drag from the content down through the keys: Search dismisses it interactively.)
    element(app, "search.placeholder").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
      .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
    XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: uiWait), "the keyboard stayed up")
    try audit(app)

    let field = app.searchFields["Ask about your money"]
    XCTAssertTrue(field.waitForExistence(timeout: uiWait))
    type("carre", into: field)
    let result = element(app, "search.txn.carrefour")
    XCTAssertTrue(result.waitForExistence(timeout: uiWait))
    XCTAssertTrue(element(app, "search.top").exists)
    XCTAssertFalse(element(app, "search.placeholder").exists)
    let titleGone = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == false OR hittable == false"), object: title)
    XCTAssertEqual(XCTWaiter().wait(for: [titleGone], timeout: uiWait), .completed, "results kept the large title")
    attach(app, "Search · Results as you type")

    result.tap()
    XCTAssertTrue(element(app, "txn.merchant").waitForLabel("Carrefour"))
    element(app, "txn.close").tap()
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
    XCTAssertTrue(element(app, "activity.count").waitForExistence(timeout: uiWait))
    XCTAssertFalse(app.staticTexts["To review"].exists)
  }

  @MainActor
  func testSenderUnverifiedReasonOnTheDeckActivityAndSheet() throws {
    let app = launchHome()
    app.tabBars.firstMatch.buttons["Review"].tap()
    let row = element(app, "review.tab.row.steam")
    XCTAssertTrue(row.waitForExistence(timeout: uiWait))
    XCTAssertTrue(reveal(app, row))
    XCTAssertTrue(row.label.contains("Couldn't verify sender"), row.label)
    XCTAssertFalse(element(app, "review.tab.row.lulu").label.contains("Couldn't verify sender"))
    attach(app, "Sender · Review tab")
    row.tap()

    let merchant = element(app, "review.merchant")
    XCTAssertTrue(merchant.waitForLabel(containing: "Steam"), merchant.debugDescription)
    XCTAssertTrue(merchant.label.contains("Couldn't verify the sender."), merchant.label)
    XCTAssertTrue(element(app, "review.reason.sender_unverified").exists)
    let strip = element(app, "review.reasonStrip.sender_unverified")
    XCTAssertTrue(strip.exists)
    attach(app, "Sender · Deck")
    try audit(app)

    strip.tap()
    let sort = element(app, "reason.sort")
    XCTAssertTrue(sort.waitForExistence(timeout: uiWait))
    XCTAssertTrue(app.staticTexts["Couldn't verify the sender"].exists)
    attach(app, "Sender · About this alert")
    try audit(app, overSheet: true)
    sort.tap()
    XCTAssertTrue(sort.waitForNonExistence(timeout: uiWait))
    XCTAssertTrue(merchant.waitForLabel(containing: "Steam"))
    XCTAssertEqual(element(app, "review.position").label, "1 of 6")

    element(app, "review.reason.sender_unverified").tap()
    let archive = element(app, "reason.archive")
    XCTAssertTrue(archive.waitForExistence(timeout: uiWait))
    archive.tap()
    XCTAssertTrue(archive.waitForNonExistence(timeout: uiWait))
    XCTAssertTrue(merchant.waitForLabel(containing: "ADCB ATM withdrawal"), merchant.debugDescription)
    element(app, "toast").buttons["Undo"].tap()
    element(app, "review.close").tap()
    XCTAssertTrue(element(app, "review.tab.count").waitForLabel("6 to sort · about a minute"))

    app.tabBars.firstMatch.buttons["Activity"].tap()
    XCTAssertTrue(element(app, "activity.count").waitForExistence(timeout: uiWait))
    element(app, "activity.chip.toReview").tap()
    let steam = element(app, "txn.steam")
    XCTAssertTrue(steam.waitForExistence(timeout: uiWait))
    XCTAssertTrue(steam.label.contains("Couldn't verify sender"), steam.label)
    XCTAssertTrue(element(app, "txn.lulu").label.contains("To review"))
    attach(app, "Sender · Activity To review")
    try audit(app)
    steam.tap()
    let callout = element(app, "txn.reviewReason.sender_unverified")
    XCTAssertTrue(callout.waitForExistence(timeout: uiWait))
    attach(app, "Sender · Transaction")
    try audit(app, overSheet: true)
    callout.tap()
    XCTAssertTrue(element(app, "reason.sort").waitForExistence(timeout: uiWait))
    attach(app, "Sender · Transaction · About this alert")
    try audit(app, overSheet: true)
    element(app, "reason.sort").tap()
    XCTAssertTrue(callout.waitForExistence(timeout: uiWait))
    element(app, "txn.close").tap()
  }

  @MainActor
  func testSenderUnverifiedAtLargeTextSizes() throws {
    let app = launch(arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"])
    XCTAssertTrue(element(app, "home.hero.left").waitForExistence(timeout: 15))
    app.tabBars.firstMatch.buttons["Review"].tap()
    let row = element(app, "review.tab.row.steam")
    XCTAssertTrue(row.waitForExistence(timeout: uiWait))
    XCTAssertTrue(reveal(app, row))
    row.tap()
    let strip = element(app, "review.reasonStrip.sender_unverified")
    XCTAssertTrue(strip.waitForExistence(timeout: uiWait))
    XCTAssertTrue(reveal(app, strip))
    attach(app, "AX3 · Sender · Deck")
    try audit(app, atLargeText: true)
    strip.tap()
    let archive = element(app, "reason.archive")
    XCTAssertTrue(archive.waitForExistence(timeout: uiWait))
    attach(app, "AX3 · Sender · About this alert")
    try audit(app, overSheet: true)
    XCTAssertTrue(reveal(app, archive))
    attach(app, "AX3 · Sender · About this alert · actions")
    try audit(app, overSheet: true)
    element(app, "reason.close").tap()
  }
}
