import XCTest

/// Activity, the transaction sheet and Review on the Release surface.
final class ReleaseSurfaceActivityTests: ReleaseSurfaceTestCase {
  /// Activity has no "+"; a row opens its sheet; every Review control sorts, skips or
  /// closes.
  @MainActor
  func testActivityAndReviewShowOnlyWhatWorks() throws {
    let app = launchRelease()
    let tabBar = app.tabBars.firstMatch
    tabBar.buttons["Activity"].tap()
    XCTAssertTrue(el(app, "activity.count").waitForExistence(timeout: 5))
    attach(app, "Release · Activity")
    assertNoPlaceholders(app, "Activity")
    assertNoOutlook(app, "Activity")
    assertAbsent(app, ["header.add"], "Activity")
    try audit(app)
    let carrefour = el(app, "txn.carrefour")
    XCTAssertTrue(reveal(app, carrefour))
    carrefour.tap()
    XCTAssertTrue(el(app, "txn.merchant").waitForExistence(timeout: 5))
    attach(app, "Release · Transaction")
    assertNoPlaceholders(app, "Transaction")
    // A row read from email shows where it came from, not the sample note.
    XCTAssertTrue(el(app, "txn.rawMerchant").exists)
    assertAbsent(app, ["txn.sample"], "Transaction")
    el(app, "txn.close").tap()

    tabBar.buttons["Review"].tap()
    XCTAssertTrue(el(app, "review.tab.start").waitForExistence(timeout: 5))
    attach(app, "Release · Review tab")
    assertNoPlaceholders(app, "Review tab")
    assertNoOutlook(app, "Review tab")
    try audit(app)
    el(app, "review.tab.start").tap()
    XCTAssertTrue(el(app, "review.position").waitForExistence(timeout: 5))
    attach(app, "Release · Review")
    assertNoPlaceholders(app, "Review")
    el(app, "review.close").tap()
  }

  /// The App Review demo account: Home says "Sample data", and a sample row's sheet says
  /// there's no email behind it.
  @MainActor
  func testTheReviewAccountShowsSampleData() throws {
    let app = launchRelease("mayaSample")
    XCTAssertTrue(el(app, "home.sampleData").waitForExistence(timeout: 5))
    attach(app, "Release · Home · Sample data")
    try audit(app)
    app.tabBars.firstMatch.buttons["Activity"].tap()
    let carrefour = el(app, "txn.carrefour")
    XCTAssertTrue(carrefour.waitForExistence(timeout: 5))
    XCTAssertTrue(reveal(app, carrefour))
    carrefour.tap()
    let note = el(app, "txn.sample")
    XCTAssertTrue(note.waitForExistence(timeout: 5))
    XCTAssertEqual(note.label, "This is sample data. There's no email behind it.")
    assertAbsent(app, ["txn.rawMerchant"], "Sample transaction")
    attach(app, "Release · Transaction · Sample data")
    try audit(app)
  }
}
