import XCTest

/// The shell on the Release surface: the tab bar holds Home, Plan, Review and Activity, and
/// no Search (its engine isn't built). Each area's own checks are in its `ReleaseSurface*Tests`
/// class (plan B7.4); the shared assertions are `ReleaseSurfaceTestCase`'s.
final class ReleaseSurfaceTests: ReleaseSurfaceTestCase {
  @MainActor
  func testTheTabBarShowsOnlyWhatWorks() throws {
    let app = launchRelease()
    let tabBar = app.tabBars.firstMatch
    XCTAssertEqual(tabBar.buttons.count, 4, "tabs: \(tabBar.buttons.allElementsBoundByIndex.map(\.label))")
    for tab in ["Home", "Plan", "Review", "Activity"] {
      XCTAssertTrue(tabBar.buttons[tab].exists, "no \(tab) tab")
    }
    XCTAssertFalse(tabBar.buttons["Search"].exists)
    assertNoPlaceholders(app, "Home")
    assertNoOutlook(app, "Home")
  }
}
