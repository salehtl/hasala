import XCTest

final class CloudSortCardUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  @MainActor
  func testTheReadyCardStartsARunThatCanStop() throws {
    let app = launch(scenario: nil, screen: "review.sort.ready")
    let start = el(app, "review.sort.start")
    XCTAssertTrue(start.waitForExistence(timeout: 30))
    XCTAssertEqual(start.label, "Sort 147 merchants")
    XCTAssertEqual(el(app, "review.sort.title").label, "Sort with Cloudflare AI")
    XCTAssertTrue(el(app, "review.sort.lead").label.hasPrefix("147 merchants in Review aren't on Hasala's list."))
    attach(app, "Review · Sort with Cloudflare AI")
    try audit(app)

    start.tap()
    let stop = el(app, "review.sort.stop")
    XCTAssertTrue(stop.waitForExistence(timeout: uiWait))
    XCTAssertEqual(el(app, "review.sort.title").label, "Sorting with Cloudflare AI")
    XCTAssertEqual(el(app, "review.sort.line").label, "83 of 147 merchants · 41 payments sorted so far")
    XCTAssertEqual(el(app, "review.sort.eta").label, "About 3 minutes. Keep Hasala open.")
    XCTAssertFalse(el(app, "review.sort.start").exists)
    attach(app, "Review · Sorting with Cloudflare AI")
    try audit(app)

    stop.tap()
    XCTAssertTrue(el(app, "review.sort.undo").waitForExistence(timeout: uiWait))
    XCTAssertEqual(el(app, "review.sort.title").label, "Done")
  }

  @MainActor
  func testABusyPauseCanTryNow() throws {
    let app = launch(scenario: nil, screen: "review.sort.paused")
    let tryNow = el(app, "review.sort.tryNow")
    XCTAssertTrue(tryNow.waitForExistence(timeout: 30))
    XCTAssertTrue(el(app, "review.sort.pause").label.hasPrefix("Cloudflare's AI is busy. Hasala will try again at "))
    XCTAssertTrue(el(app, "review.sort.stop").exists)
    attach(app, "Review · Sort paused, busy")
    try audit(app)
    tryNow.tap()
    XCTAssertTrue(el(app, "review.sort.eta").waitForExistence(timeout: uiWait))
    XCTAssertFalse(el(app, "review.sort.tryNow").exists)
  }

  @MainActor
  func testTheRunCapOffersTheNextNames() throws {
    let app = launch(scenario: "maya", arguments: ["-HasalaCloudSortPhase", "runCap"])
    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: 30))
    app.tabBars.firstMatch.buttons["Review"].tap()
    let next = el(app, "review.sort.next")
    XCTAssertTrue(next.waitForExistence(timeout: uiWait))
    XCTAssertEqual(next.label, "Sort the next 147")
    XCTAssertEqual(el(app, "review.sort.pause").label, "Paused after 250 merchants, today's limit for one run.")
    next.tap()
    XCTAssertTrue(el(app, "review.sort.eta").waitForExistence(timeout: uiWait))
  }

  @MainActor
  func testDoneUndoAsksThenSendsBack() throws {
    let app = launch(scenario: nil, screen: "review.sort.done")
    let undo = el(app, "review.sort.undo")
    XCTAssertTrue(undo.waitForExistence(timeout: 30))
    XCTAssertEqual(el(app, "review.sort.line").label, "104 payments sorted, 33 suggestions to check, 25 for you to sort.")
    XCTAssertTrue(el(app, "review.sort.check").exists)
    XCTAssertFalse(el(app, "review.tab.checkSuggestions").exists, "Check suggestions opens only from the result")
    XCTAssertFalse(el(app, "review.slot.importing").exists, "two cards in the slot")
    attach(app, "Review · Sort done")
    try audit(app)

    undo.tap()
    let alert = app.alerts["Send 104 payments back to Review?"]
    XCTAssertTrue(alert.waitForExistence(timeout: uiWait))
    XCTAssertTrue(alert.staticTexts["They keep Cloudflare's suggestion, and you confirm each one. Payments you've changed since stay as they are."].exists)
    alert.buttons["Cancel"].firstMatch.tap()
    XCTAssertTrue(alert.waitForNonExistence(timeout: uiWait))
    XCTAssertTrue(undo.exists)

    undo.tap()
    XCTAssertTrue(alert.waitForExistence(timeout: uiWait))
    alert.buttons["Send back"].firstMatch.tap()
    XCTAssertTrue(app.staticTexts["Sent 104 payments back to Review"].waitForExistence(timeout: uiWait))
    XCTAssertTrue(undo.waitForNonExistence(timeout: uiWait))

    tap(app, "review.sort.check", opening: "suggestions.use")
  }

  @MainActor
  func testTheDoneCardCanBeDismissed() throws {
    let app = launch(scenario: nil, screen: "review.sort.done")
    let dismiss = el(app, "review.sort.dismiss")
    XCTAssertTrue(dismiss.waitForExistence(timeout: 30))
    dismiss.tap()
    XCTAssertTrue(el(app, "review.sort.card").waitForNonExistence(timeout: uiWait))
    XCTAssertFalse(el(app, "review.tab.checkSuggestions").exists, "Check suggestions outlived the result")
    XCTAssertFalse(el(app, "review.sort.check").exists)
    XCTAssertTrue(el(app, "review.tab.start").exists)
  }

  @MainActor
  func testTheImportingCardShowsWhileMailIsRead() throws {
    let app = launch(scenario: nil, screen: "review.importing")
    let card = el(app, "review.slot.importing")
    XCTAssertTrue(card.waitForExistence(timeout: 30))
    XCTAssertTrue(card.label.hasPrefix("Reading your mail, 312 so far. You can start on the ones here now."), card.label)
    XCTAssertTrue(el(app, "review.tab.start").exists, "the import hid the queue")
    XCTAssertFalse(el(app, "review.sort.card").exists)
    XCTAssertFalse(el(app, "review.cloudSort").exists)
    attach(app, "Review · Reading your mail")
    try audit(app)
  }

  @MainActor
  func testARunShowsInsteadOfTheImport() throws {
    let app = launch(scenario: nil, screen: "review.sort.importing")
    XCTAssertTrue(el(app, "review.sort.stop").waitForExistence(timeout: 30))
    XCTAssertFalse(el(app, "review.slot.importing").exists, "two cards in the slot")
  }

  @MainActor
  func testNothingOffersARunWhileSuggestionsAreOff() throws {
    let app = launch(scenario: "maya", arguments: ["-HasalaCloudSortPhase", "off"])
    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: 30))
    app.tabBars.firstMatch.buttons["Review"].tap()
    XCTAssertTrue(el(app, "review.tab.start").waitForExistence(timeout: uiWait))
    XCTAssertFalse(el(app, "review.sort.card").exists)
    XCTAssertFalse(el(app, "review.cloudSort").exists)
  }

  @MainActor
  func testTheDeckSaysWhatWaitsForCloudflare() throws {
    let app = launch(scenario: nil, screen: "review.sort.deck")
    let waiting = el(app, "review.waitingForCloud")
    XCTAssertTrue(waiting.waitForExistence(timeout: 30))
    XCTAssertEqual(waiting.label, "Waiting for Cloudflare AI (2)")
    attach(app, "Review deck · waiting for Cloudflare AI")
    try audit(app)
  }

  @MainActor
  func testTheRunningCardAtTheLargestSizes() throws {
    let app = launch(
      scenario: nil, screen: "review.sort.running",
      arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"])
    XCTAssertTrue(el(app, "review.sort.stop").waitForExistence(timeout: 30))
    attach(app, "AX3 · Review · Sorting with Cloudflare AI")
    try audit(app, atLargeText: true)
  }

  @MainActor
  func testTheImportAtTheLargestSizes() throws {
    let app = launch(
      scenario: nil, screen: "review.importing",
      arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"])
    XCTAssertTrue(el(app, "review.slot.importing").waitForExistence(timeout: 30))
    attach(app, "AX3 · Review · Reading your mail")
    try audit(app, atLargeText: true)
  }

  @MainActor
  func testTheResultAtTheLargestSizes() throws {
    let app = launch(
      scenario: nil, screen: "review.sort.done",
      arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"])
    XCTAssertTrue(el(app, "review.sort.undo").waitForExistence(timeout: 30))
    XCTAssertTrue(el(app, "review.sort.check").exists)
    attach(app, "AX3 · Review · Sort done")
    try audit(app, atLargeText: true)
  }

  @MainActor
  func testProfileSendsCloudflaresSortingBack() throws {
    let app = launch(scenario: nil, screen: "profile.cloudSort")
    let row = el(app, "profile.cloudSendBack")
    XCTAssertTrue(row.waitForExistence(timeout: 30))
    XCTAssertTrue(bringUp(app, row), "could not reach Send back")
    let readout = el(app, "profile.cloudLastSort")
    XCTAssertTrue(readout.label.hasPrefix("Last sort, today "), readout.label)
    XCTAssertTrue(readout.label.hasSuffix("18 payments are transfers or account alerts, which stay on this iPhone."))
    attach(app, "Profile · Cloud suggestions · Last sort")
    try audit(app)

    row.tap()
    let alert = app.alerts["Send 104 payments back to Review?"]
    XCTAssertTrue(alert.waitForExistence(timeout: uiWait))
    alert.buttons["Send back"].firstMatch.tap()
    XCTAssertTrue(app.staticTexts["Sent 104 payments back to Review"].waitForExistence(timeout: uiWait))
    XCTAssertTrue(row.waitForNonExistence(timeout: uiWait))
  }

  @MainActor
  func testTurningSuggestionsOnOffersToSort() throws {
    let app = launch(scenario: nil, screen: "profile.cloudSort", arguments: ["-HasalaCloudSortPhase", "idle"])
    let toggle = app.switches["profile.merchantSuggestions"].firstMatch
    XCTAssertTrue(toggle.waitForExistence(timeout: 30))
    XCTAssertTrue(bringUp(app, toggle))
    if toggle.value as? String == "1" {
      flip(toggle)
      XCTAssertTrue(toggle.waitForValue("0"))
    }
    flip(toggle)
    tap(app, "merchantSuggestions.turnOn")
    let offer = app.alerts["Sort the 162 payments waiting in Review?"]
    XCTAssertTrue(offer.waitForExistence(timeout: uiWait))
    XCTAssertTrue(offer.staticTexts["Hasala can ask about the 147 merchant names now, a few at a time, while the app is open."].exists)
    attach(app, "Profile · Sort the payments waiting")
    offer.buttons["Sort now"].firstMatch.tap()
    XCTAssertTrue(offer.waitForNonExistence(timeout: uiWait))

    el(app, "profile.close").tap()
    app.tabBars.firstMatch.buttons["Review"].tap()
    XCTAssertTrue(el(app, "review.sort.stop").waitForExistence(timeout: uiWait))

    el(app, "header.profile").tap()
    let again = app.switches["profile.merchantSuggestions"].firstMatch
    XCTAssertTrue(again.waitForExistence(timeout: uiWait))
    XCTAssertTrue(bringUp(app, again))
    flip(again)
    XCTAssertTrue(again.waitForValue("0"))
  }

  @MainActor
  func testTheOfferScreen() throws {
    let app = launch(scenario: nil, screen: "profile.cloudSortOffer")
    let offer = app.alerts["Sort the 162 payments waiting in Review?"]
    XCTAssertTrue(offer.waitForExistence(timeout: 30))
    attach(app, "Profile · Sort offer")
    offer.buttons["Later"].firstMatch.tap()
    XCTAssertTrue(offer.waitForNonExistence(timeout: uiWait))
  }

  @MainActor
  private func flip(_ toggle: XCUIElement) {
    let knob = toggle.switches.firstMatch
    if knob.exists { knob.tap() } else { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap() }
  }

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
}
