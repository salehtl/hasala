import XCTest

final class CloudSortUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
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
  func testTheImportOverAnEmptyQueueDoesNotInviteAStart() throws {
    let app = launch(scenario: nil, screen: "review.empty.importing")
    let card = el(app, "review.slot.importing")
    XCTAssertTrue(card.waitForExistence(timeout: 30))
    XCTAssertEqual(card.label, "Reading your mail, 312 so far. Hasala is reading your bank alerts. Payments to sort show up here.")
    XCTAssertTrue(el(app, "review.tab.empty").exists)
    XCTAssertFalse(el(app, "review.tab.start").exists)
    attach(app, "Review · Reading your mail, nothing to sort")
    try audit(app)
  }

  @MainActor
  func testTheUnreadRowShowsWithEverySlotCard() throws {
    let cases: [(screen: String, phase: String?, slot: String)] = [
      ("review.unread.ask", nil, "review.cloudSort"),
      ("review.unread.importing", nil, "review.slot.importing"),
      ("review.unread", "running", "review.tab.start"),
      ("review.unread.empty", nil, "review.tab.empty"),
    ]
    for c in cases {
      let name = "\(c.screen) \(c.phase ?? "")"
      let app = launch(scenario: nil, screen: c.screen, arguments: c.phase.map { ["-HasalaCloudSortPhase", $0] } ?? [])
      XCTAssertTrue(el(app, c.slot).waitForExistence(timeout: 30), name)
      let row = el(app, "review.tab.unreadable")
      XCTAssertTrue(row.exists, name)
      XCTAssertTrue(row.label.contains("bank emails we couldn't read"), "\(name): \(row.label)")
      app.terminate()
    }
  }

  @MainActor
  func testTheUnreadRowAtTheLargestSizes() throws {
    let cases: [(screen: String, phase: String?, slot: String)] = [
      ("review.unread.importing", nil, "review.slot.importing"),
      ("review.unread", "running", "review.tab.start"),
    ]
    for c in cases {
      let name = "\(c.screen) \(c.phase ?? "")"
      var arguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"]
      if let phase = c.phase { arguments += ["-HasalaCloudSortPhase", phase] }
      let app = launch(scenario: nil, screen: c.screen, arguments: arguments)
      XCTAssertTrue(el(app, c.slot).waitForExistence(timeout: 30), name)
      let row = el(app, "review.tab.unreadable")
      XCTAssertTrue(row.exists, name)
      XCTAssertTrue(scroll(app, toShow: row), name)
      XCTAssertTrue(row.label.contains("bank emails we couldn't read"), "\(name): \(row.label)")
      attach(app, "AX3 · Review · Unread mail under \(name)")
      try audit(app, atLargeText: true)
      app.terminate()
    }
  }

  @MainActor
  func testNoSortingCardShowsWhateverTheBackgroundStageIsDoing() throws {
    for phase in ["off", "running", "busy", "done"] {
      let app = launch(scenario: "maya", arguments: ["-HasalaCloudSortPhase", phase])
      XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: 30), phase)
      app.tabBars.firstMatch.buttons["Review"].tap()
      XCTAssertTrue(el(app, "review.tab.start").waitForExistence(timeout: uiWait), phase)
      XCTAssertFalse(el(app, "review.sort.card").exists, phase)
      XCTAssertFalse(el(app, "review.cloudSort").exists, phase)
      XCTAssertFalse(app.staticTexts["Sorting with Cloudflare AI"].exists, phase)
      XCTAssertFalse(app.staticTexts["Sort with Cloudflare AI"].exists, phase)
      XCTAssertFalse(app.buttons["Check suggestions"].exists, phase)
      app.terminate()
    }
  }

  @MainActor
  func testTheDeckHoldsNoCardBackWhileCloudflareSorts() throws {
    let app = launch(scenario: "maya", arguments: ["-HasalaCloudSortPhase", "running"])
    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: 30))
    app.tabBars.firstMatch.buttons["Review"].tap()
    XCTAssertTrue(el(app, "review.tab.start").waitForExistence(timeout: uiWait))
    let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'review.tab.row.'"))
    let merchants = rows.allElementsBoundByIndex.map { $0.label.components(separatedBy: ", ")[0] }
    XCTAssertEqual(merchants.count, 6, "\(merchants)")

    tap(app, "review.tab.start")
    let position = el(app, "review.position")
    let card = el(app, "review.merchant")
    for (i, merchant) in merchants.enumerated() {
      XCTAssertTrue(position.waitForLabel("\(i + 1) of 6"), position.label)
      XCTAssertTrue(card.label.hasPrefix(merchant + ","), "card \(i + 1): \(card.label), the tab has \(merchant)")
      if i == 0 {
        XCTAssertFalse(el(app, "review.waitingForCloud").exists)
        attach(app, "Review deck · while Cloudflare AI sorts")
        try audit(app)
      }
      tap(app, "review.skip")
    }
    XCTAssertTrue(el(app, "review.done").waitForExistence(timeout: uiWait))
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
  func testProfileSendsCloudflaresSortingBack() throws {
    let app = launch(scenario: nil, screen: "profile.cloudSort")
    let row = el(app, "profile.cloudSendBack")
    XCTAssertTrue(row.waitForExistence(timeout: 30))
    XCTAssertTrue(bringUp(app, row), "could not reach Send back")
    XCTAssertFalse(el(app, "profile.cloudLastSort").exists)
    attach(app, "Profile · Cloud suggestions · Send back")
    try audit(app)

    row.tap()
    let alert = app.alerts["Send 104 payments back to Review?"]
    XCTAssertTrue(alert.waitForExistence(timeout: uiWait))
    alert.buttons["Send back"].firstMatch.tap()
    XCTAssertTrue(app.staticTexts["Sent 104 payments back to Review"].waitForExistence(timeout: uiWait))
    XCTAssertTrue(row.waitForNonExistence(timeout: uiWait))
  }

  @MainActor
  func testTurningSuggestionsOnOffersNothingMore() throws {
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
    XCTAssertTrue(el(app, "merchantSuggestions.sheet").waitForNonExistence(timeout: uiWait))
    XCTAssertTrue(toggle.waitForValue("1"))
    XCTAssertFalse(app.alerts.firstMatch.waitForExistence(timeout: 2), "turning on offered a sort")
    attach(app, "Profile · Merchant suggestions on")

    el(app, "profile.close").tap()
    app.tabBars.firstMatch.buttons["Review"].tap()
    XCTAssertTrue(el(app, "review.tab.start").waitForExistence(timeout: uiWait))
    XCTAssertFalse(el(app, "review.sort.card").exists)

    el(app, "header.profile").tap()
    let again = app.switches["profile.merchantSuggestions"].firstMatch
    XCTAssertTrue(again.waitForExistence(timeout: uiWait))
    XCTAssertTrue(bringUp(app, again))
    flip(again)
    XCTAssertTrue(again.waitForValue("0"))
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
