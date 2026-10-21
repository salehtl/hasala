import XCTest

/// Activity, the transaction sheet and Review on the Release surface.
final class ReleaseSurfaceActivityTests: ReleaseSurfaceTestCase {
  /// The add button beside the tab bar opens Add a transaction; a row opens its sheet, which offers no bank email to view yet; the
  /// Review tab is there with its Start and its rows, and every deck control sorts, skips or
  /// closes, and the unreadable-email card opens Add a transaction ("Use N suggestions" and
  /// "View bank email" wait for the features behind them).
  @MainActor
  func testActivityAndReviewShowOnlyWhatWorks() throws {
    let app = launchRelease()
    let tabBar = app.tabBars.firstMatch
    tabBar.buttons["Activity"].tap()
    XCTAssertTrue(el(app, "activity.count").waitForExistence(timeout: uiWait))
    attach(app, "Release · Activity")
    assertNoPlaceholders(app, "Activity")
    assertPersonalAccountsOnly(app, "Activity")
    XCTAssertTrue(tabBar.buttons["Add a transaction"].exists, "Activity has no add button")
    try audit(app)
    tabBar.buttons["Add a transaction"].tap()
    XCTAssertTrue(el(app, "add.amount").waitForExistence(timeout: uiWait))
    attach(app, "Release · Add transaction")
    assertNoPlaceholders(app, "Add transaction")
    tap(app, "add.close")
    XCTAssertTrue(el(app, "add.amount").waitForNonExistence(timeout: uiWait))
    let carrefour = el(app, "txn.carrefour")
    XCTAssertTrue(reveal(app, carrefour))
    carrefour.tap()
    XCTAssertTrue(el(app, "txn.merchant").waitForExistence(timeout: uiWait))
    attach(app, "Release · Transaction")
    assertNoPlaceholders(app, "Transaction")
    // A row read from email shows where it came from, not the sample note.
    XCTAssertTrue(el(app, "txn.rawMerchant").exists)
    assertAbsent(app, ["txn.sample", "txn.viewEmail"], "Transaction")
    // Its editors push inside the sheet.
    el(app, "txn.category").tap()
    XCTAssertTrue(el(app, "picker.save").waitForExistence(timeout: uiWait))
    assertNoPlaceholders(app, "Category")
    app.navigationBars["Category"].buttons.firstMatch.tap()
    XCTAssertTrue(el(app, "txn.merchant").waitForExistence(timeout: uiWait))
    el(app, "txn.close").tap()

    XCTAssertTrue(tabBar.buttons["Review"].exists)
    tabBar.buttons["Review"].tap()
    XCTAssertTrue(el(app, "review.tab.start").waitForExistence(timeout: uiWait))
    attach(app, "Release · Review tab")
    assertNoPlaceholders(app, "Review tab")
    assertPersonalAccountsOnly(app, "Review tab")
    assertPresent(app, ["review.tab.count", "review.tab.row.lulu"], "Review tab")
    assertAbsent(app, ["review.tab.useSuggestions"], "Review tab")
    try audit(app)
    el(app, "review.tab.start").tap()
    XCTAssertTrue(el(app, "review.position").waitForExistence(timeout: uiWait))
    attach(app, "Release · Review")
    assertNoPlaceholders(app, "Review")
    assertPresent(app, ["review.skip", "review.pill.need", "review.pill.want", "review.pill.save",
                        "review.pill.transfer"], "Review")
    assertAbsent(app, ["review.viewEmail"], "Review")
    // The More menu offers only what works.
    el(app, "review.more").tap()
    XCTAssertTrue(app.buttons["Skip for now"].waitForExistence(timeout: uiWait))
    assertAbsent(app, ["View bank email"], "Review · More")
    assertNoPlaceholders(app, "Review · More")
    // Dismiss the menu: tap outside it, on the header.
    app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
    el(app, "review.close").tap()
  }

  @MainActor
  func testUnreadBankEmailsOpenAListThatWorks() throws {
    let app = launchRelease("mayaUnreadMail")
    app.tabBars.firstMatch.buttons["Review"].tap()
    let line = el(app, "review.tab.unreadable")
    XCTAssertTrue(line.waitForExistence(timeout: uiWait))
    XCTAssertTrue(line.label.contains("3 bank emails we couldn't read"), line.label)
    assertNoPlaceholders(app, "Review tab · unread")
    line.tap()
    XCTAssertTrue(el(app, "unread.row.unread-gmail").waitForExistence(timeout: uiWait))
    assertNoPlaceholders(app, "Unread bank emails")
    assertPersonalAccountsOnly(app, "Unread bank emails")
    assertPresent(app, ["unread.add.unread-gmail", "unread.dismiss.unread-gmail", "unread.notDownloaded"], "Unread bank emails")
    attach(app, "Release · Unread bank emails")
    try audit(app)
    tap(app, "unread.add.unread-gmail", opening: "add.amount")
    assertNoPlaceholders(app, "Add from an email")
    tap(app, "add.close")
    XCTAssertTrue(el(app, "add.amount").waitForNonExistence(timeout: uiWait))
    tap(app, "unread.dismiss.unread-gmail")
    XCTAssertTrue(el(app, "unread.row.unread-gmail").waitForNonExistence(timeout: uiWait))
  }

  /// The App Review demo account: Home says "Sample data", and a sample row's sheet says
  /// there's no email behind it.
  @MainActor
  func testTheReviewAccountShowsSampleData() throws {
    let app = launchRelease("mayaSample")
    XCTAssertTrue(el(app, "home.sampleData").waitForExistence(timeout: uiWait))
    attach(app, "Release · Home · Sample data")
    try audit(app)
    app.tabBars.firstMatch.buttons["Activity"].tap()
    let carrefour = el(app, "txn.carrefour")
    XCTAssertTrue(carrefour.waitForExistence(timeout: uiWait))
    XCTAssertTrue(reveal(app, carrefour))
    carrefour.tap()
    let note = el(app, "txn.sample")
    XCTAssertTrue(note.waitForExistence(timeout: uiWait))
    XCTAssertEqual(note.label, "This is sample data. There's no email behind it.")
    assertAbsent(app, ["txn.rawMerchant"], "Sample transaction")
    attach(app, "Release · Transaction · Sample data")
    try audit(app)
  }
}
