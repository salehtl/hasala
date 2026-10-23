import XCTest

final class SortingReworkUITests: XCTestCase {
  static let tailscale = "out.n:tailscale"
  static let brightwell = "out.n:brightwell academy"
  static let qasr = "out.n:qasr corner store"
  static let largeText = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"]

  override func setUp() {
    continueAfterFailure = false
  }

  @MainActor
  func openReview(_ app: XCUIApplication) {
    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: 30))
    app.tabBars.firstMatch.buttons["Review"].tap()
    XCTAssertTrue(el(app, "review.tab.start").waitForExistence(timeout: uiWait))
  }

  @MainActor
  func openGroup(_ app: XCUIApplication, _ group: String) {
    let row = el(app, "review.tab.group.\(group)")
    XCTAssertTrue(row.waitForExistence(timeout: uiWait), "no row for \(group)")
    XCTAssertTrue(scroll(app, toShow: row), "could not reach \(group)")
    row.tap()
    XCTAssertTrue(el(app, "review.card.group.\(group)").waitForExistence(timeout: uiWait), "the deck did not open at \(group)")
  }

  @MainActor
  func testTheTabShowsOneRowPerMerchantAndCountsPayments() throws {
    let app = launch(scenario: "mayaBacklog")
    openReview(app)
    let count = el(app, "review.tab.count")
    XCTAssertTrue(count.label.contains("payments to sort, from "), count.label)
    XCTAssertTrue(count.label.hasSuffix("more merchants"), count.label)
    XCTAssertTrue(el(app, "review.tab.group.\(Self.tailscale)").waitForExistence(timeout: uiWait))
    XCTAssertTrue(el(app, "review.tab.group.\(Self.brightwell)").exists)
    XCTAssertTrue(el(app, "review.tab.row.bl-ts-unverified").exists, "the unverified payment keeps its own row")
    XCTAssertTrue(app.staticTexts["Need, want or save. One card per merchant."].exists)
    attach(app, "Review · Tab · one row per merchant")
    try audit(app)
  }

  @MainActor
  func testAGroupSortsAllItsPaymentsInOneCommitAndTheResultRowUndoes() throws {
    let app = launch(scenario: "mayaBacklog")
    openReview(app)
    openGroup(app, Self.tailscale)
    let merchant = el(app, "review.card.group.\(Self.tailscale)")
    XCTAssertTrue(merchant.label.hasPrefix("Tailscale, "), merchant.label)
    XCTAssertTrue(merchant.label.contains("repeats monthly"), merchant.label)
    XCTAssertTrue(el(app, "review.card.leftOut").exists, "the unverified payment is named as left out")
    XCTAssertTrue(el(app, "review.sortEach").exists)
    attach(app, "Review · Deck · group card")
    try audit(app)

    tap(app, "review.pill.want", opening: "pick.close")
    let commit = el(app, "pick.commit")
    XCTAssertTrue(commit.waitForExistence(timeout: uiWait))
    XCTAssertFalse(commit.isEnabled, "nothing is filed before a category is picked")
    XCTAssertTrue(el(app, "pick.sortEach").exists)
    el(app, "pick.subscriptions").tap()
    XCTAssertTrue(commit.waitForLabel("Sort all 30 Tailscale payments as Subscriptions"), commit.label)
    attach(app, "Review · Pick sheet · group")
    try audit(app, overSheet: true)
    commit.tap()

    let result = el(app, "review.result")
    XCTAssertTrue(result.waitForExistence(timeout: uiWait))
    XCTAssertTrue(result.label.hasPrefix("Sorted 30 Tailscale payments as Subscriptions"), result.label)
    XCTAssertFalse(el(app, "review.card.group.\(Self.tailscale)").exists)
    XCTAssertFalse(el(app, "review.result.stopRule").exists, "no rule without Always use it")
    attach(app, "Review · Deck · result row")
    try audit(app)

    tap(app, "review.result.undo")
    XCTAssertTrue(el(app, "review.card.group.\(Self.tailscale)").waitForExistence(timeout: uiWait))
    XCTAssertTrue(result.waitForNonExistence(timeout: uiWait))
  }

  @MainActor
  func testAlwaysUseItMakesARuleThatTheResultRowCanStop() throws {
    let app = launch(scenario: "mayaBacklog")
    openReview(app)
    openGroup(app, Self.tailscale)
    tap(app, "review.pill.want", opening: "pick.close")
    el(app, "pick.subscriptions").tap()
    tap(app, "pick.alwaysUse")
    tap(app, "pick.commit")
    let stop = el(app, "review.result.stopRule")
    XCTAssertTrue(stop.waitForExistence(timeout: uiWait))
    stop.tap()
    XCTAssertTrue(app.staticTexts["Stopped sorting Tailscale as Subscriptions"].waitForExistence(timeout: uiWait))
    XCTAssertTrue(stop.waitForNonExistence(timeout: uiWait))
    tap(app, "review.result.dismiss")
    XCTAssertTrue(el(app, "review.result").waitForNonExistence(timeout: uiWait))
  }

  @MainActor
  func testNotThisLeavesTheCardForYouAndUndoBringsTheGuessBack() throws {
    let app = launch(scenario: "mayaBacklog")
    openReview(app)
    openGroup(app, Self.brightwell)
    let use = el(app, "review.strip.use")
    XCTAssertTrue(use.waitForExistence(timeout: uiWait))
    XCTAssertEqual(use.label, "Use Shopping for all 4")
    tap(app, "review.strip.notThis")
    let note = el(app, "review.notThis.note")
    XCTAssertTrue(note.waitForExistence(timeout: uiWait))
    XCTAssertEqual(note.label, "Hasala won't suggest Shopping for Brightwell Academy again.")
    XCTAssertFalse(use.exists)
    attach(app, "Review · Deck · after Not this")
    try audit(app)
    tap(app, "review.notThis.undo")
    XCTAssertTrue(use.waitForExistence(timeout: uiWait))
    XCTAssertFalse(note.exists)
  }

  @MainActor
  func testSortEachOneSortsOnePaymentThenTheRestAndSortedForYouListsTheRule() throws {
    let app = launch(scenario: "mayaBacklog")
    openReview(app)
    openGroup(app, Self.qasr)
    tap(app, "review.sortEach", opening: "review.sortEach.done")
    attach(app, "Review · Sort each one")
    try audit(app, overSheet: true)
    let row = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'review.sortEach.row.'")).firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: uiWait))
    row.tap()
    tap(app, "pick.alwaysUse")
    tap(app, "pick.groceries")
    let close = el(app, "review.sortEach.close")
    XCTAssertTrue(close.waitForNonExistence(timeout: uiWait), "the rule sorted the rest, so the sheet closed")
    let result = el(app, "review.result")
    XCTAssertTrue(result.waitForExistence(timeout: uiWait))
    XCTAssertTrue(result.label.hasPrefix("Sorted 6 Qasr Corner Store payments as Groceries"), result.label)
    XCTAssertTrue(el(app, "review.result.stopRule").exists)

    tap(app, "review.close")
    app.tabBars.firstMatch.buttons["Home"].tap()
    let look = el(app, "home.sortedForYou")
    XCTAssertTrue(look.waitForExistence(timeout: uiWait))
    XCTAssertEqual(look.label, "5 payments sorted for you this week. Look.")
    XCTAssertTrue(scroll(app, toShow: look))
    look.tap()
    let undoAll = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'sortedForYou.undoAll.'")).firstMatch
    XCTAssertTrue(undoAll.waitForExistence(timeout: uiWait))
    XCTAssertEqual(undoAll.label, "Undo all 5")
    let stopRule = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'sortedForYou.stopRule.'")).firstMatch
    XCTAssertTrue(stopRule.exists)
    attach(app, "Home · Sorted for you")
    try audit(app)
    undoAll.tap()
    XCTAssertTrue(el(app, "sortedForYou.empty").waitForExistence(timeout: uiWait))
  }

  @MainActor
  func testTheGroupCardAndThePickSheetReadAtTheLargestTextSizes() throws {
    let app = launch(scenario: "mayaBacklog", arguments: Self.largeText)
    openReview(app)
    attach(app, "Review · Tab · accessibility3")
    try audit(app, atLargeText: true)
    openGroup(app, Self.brightwell)
    XCTAssertTrue(el(app, "review.strip.use").waitForExistence(timeout: uiWait))
    attach(app, "Review · Deck · group card · accessibility3")
    try audit(app, atLargeText: true)
    tap(app, "review.pill.want", opening: "pick.close")
    XCTAssertTrue(el(app, "pick.commit").waitForExistence(timeout: uiWait))
    attach(app, "Review · Pick sheet · group · accessibility3")
    try audit(app, atLargeText: true, overSheet: true)
  }
}
