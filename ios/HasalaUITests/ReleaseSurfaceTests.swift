import XCTest

/// The shell on the Release surface: the tab bar holds Home, Plan, Review and Activity, and
/// Search beside them, which finds in this iPhone's own ledger. Each area's own checks are
/// in its `ReleaseSurface*Tests` class (plan B7.4); the shared assertions are
/// `ReleaseSurfaceTestCase`'s.
final class ReleaseSurfaceTests: ReleaseSurfaceTestCase {
  @MainActor
  func testTheTabBarShowsOnlyWhatWorks() throws {
    let app = launchRelease()
    let tabBar = app.tabBars.firstMatch
    XCTAssertEqual(tabBar.buttons.count, 5, "tabs: \(tabBar.buttons.allElementsBoundByIndex.map(\.label))")
    for tab in ["Home", "Plan", "Review", "Activity", "Search"] {
      XCTAssertTrue(tabBar.buttons[tab].exists, "no \(tab) tab")
    }
    assertNoPlaceholders(app, "Home")
    assertPersonalAccountsOnly(app, "Home")
  }

  /// Search on the Release surface: "Try asking" offers what the ledger can answer, the
  /// first letters ("carre") find Carrefour, and its row opens the transaction sheet.
  @MainActor
  func testSearchFindsAndOpensATransaction() throws {
    let app = launchRelease()
    app.tabBars.firstMatch.buttons["Search"].tap()
    assertPresent(app, ["search.placeholder", "search.ask.dining", "search.ask.rent", "search.ask.carrefour"], "Search")
    assertNoPlaceholders(app, "Search")

    let field = app.searchFields["Ask about your money"]
    XCTAssertTrue(field.waitForExistence(timeout: uiWait))
    type("carre", into: field)
    let result = el(app, "search.txn.carrefour")
    XCTAssertTrue(result.waitForExistence(timeout: uiWait), "carre found no Carrefour")
    XCTAssertTrue(el(app, "search.top").exists)
    XCTAssertFalse(el(app, "search.placeholder").exists)
    assertNoPlaceholders(app, "Search results")

    result.tap()
    XCTAssertTrue(el(app, "txn.merchant").waitForLabel("Carrefour"))
  }

  @MainActor
  func testAQuestionAnswersOrFallsBackToWords() throws {
    let app = launchRelease()
    app.tabBars.firstMatch.buttons["Search"].tap()
    let field = app.searchFields["Ask about your money"]
    XCTAssertTrue(field.waitForExistence(timeout: uiWait))
    type("carrefour september", into: field)
    XCTAssertTrue(el(app, "search.ask.thinking").waitForNonExistence(timeout: 30), "the question never settled")
    let answered = el(app, "search.answer").waitForExistence(timeout: 2)
    if !answered {
      XCTAssertTrue(el(app, "search.txn.carrefour").exists || el(app, "search.none").exists, "no keyword fallback")
    }
    attach(app, answered ? "Search · Release · answered" : "Search · Release · keyword fallback")
    assertNoPlaceholders(app, "Search question")
  }
}
