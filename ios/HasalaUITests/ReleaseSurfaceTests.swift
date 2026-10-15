import XCTest

/// The shell on the Release surface: the tab bar holds only tabs that work, and no Search
/// (its engine isn't built). Each area's own checks are in its `ReleaseSurface*Tests`
/// class (plan B7.4); the shared assertions are `ReleaseSurfaceTestCase`'s.
final class ReleaseSurfaceTests: ReleaseSurfaceTestCase {
  @MainActor
  func testTheTabBarShowsOnlyWhatWorks() throws {
    let app = launchRelease()
    let tabBar = app.tabBars.firstMatch
    XCTAssertEqual(tabBar.buttons.count, 3, "tabs: \(tabBar.buttons.allElementsBoundByIndex.map(\.label))")
    XCTAssertFalse(tabBar.buttons["Search"].exists)
    assertNoPlaceholders(app, "Home")
    assertNoOutlook(app, "Home")
  }
}
