import XCTest

final class ReleaseSurfaceBankTextsTests: ReleaseSurfaceTestCase {
  @MainActor
  func testBankTextsPageOnTheReleaseSurface() throws {
    let app = launchRelease("textsWorking", waitForHome: false, screen: "bankAlerts.texts")
    XCTAssertTrue(el(app, "bankAlerts.texts.automation").waitForExistence(timeout: 15), "the texts page is missing")
    XCTAssertTrue(el(app, "bankAlerts.texts.paste").exists, "Paste a bank text is missing")
    XCTAssertTrue(el(app, "bankAlerts.texts.setAside").exists, "the set-aside counts are missing")
    assertNoPlaceholders(app, "Bank alerts · Texts")
    assertPersonalAccountsOnly(app, "Bank alerts · Texts")
  }

  @MainActor
  func testAnEmailAccountShowsIgnoredTextsAndNoPaste() throws {
    let app = launchRelease("gmailTexts", waitForHome: false, screen: "bankAlerts.emailOrTexts")
    XCTAssertTrue(el(app, "bankAlerts.useTexts").waitForExistence(timeout: 15), "Use bank texts instead is missing")
    XCTAssertTrue(el(app, "bankAlerts.useTexts.ignored").exists, "the ignored count is missing")
    XCTAssertFalse(el(app, "bankAlerts.useTexts.paste").exists, "paste is offered while the account reads email")
    assertNoPlaceholders(app, "Bank alerts · Email")
  }

  @MainActor
  func testTheNoticeAfterUnlockOnTheReleaseSurface() throws {
    let app = launch(scenario: "textsWorking", release: true, arguments: ["-HasalaLockedTexts", "1"])
    let alert = app.alerts["Bank texts while locked"]
    XCTAssertTrue(alert.waitForExistence(timeout: 30), "the notice did not show")
    XCTAssertEqual(
      alert.staticTexts.matching(NSPredicate(format: "label CONTAINS '1 text that looks like a payment arrived'")).count, 1)
    alert.buttons["OK"].tap()
    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: 15), "Home did not appear")
  }
}
