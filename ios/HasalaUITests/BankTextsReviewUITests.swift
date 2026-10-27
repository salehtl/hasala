import XCTest

final class BankTextsReviewUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  @MainActor
  func testUnreadTextsAreListedWithTheirCopyPastedDismissedAndAddedByHand() throws {
    let app = launch(scenario: "mayaTexts")
    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: 15))
    app.tabBars.firstMatch.buttons["Review"].tap()
    let line = el(app, "review.tab.unreadTexts")
    XCTAssertTrue(line.waitForExistence(timeout: uiWait))
    XCTAssertTrue(line.label.contains("2 bank texts we couldn't read"), line.label)
    XCTAssertFalse(el(app, "review.tab.unreadable").exists)
    attach(app, "Unread texts · Review tab")
    try audit(app)
    line.tap()

    let dib = el(app, "unreadTexts.body.unread-text-dib")
    XCTAssertTrue(dib.waitForExistence(timeout: uiWait))
    XCTAssertEqual(
      dib.label,
      "Hasala couldn't read this bank text. Find the text from DIB at 09:58 in Messages, copy it and paste it here, or add the payment yourself.")
    XCTAssertTrue(
      el(app, "unreadTexts.body.unread-text-other").label.contains("Find the text at 19:12 on Thu 8 Oct in Messages"),
      el(app, "unreadTexts.body.unread-text-other").label)
    let titled = NSPredicate(format: "label BEGINSWITH 'Text from DIB'")
    XCTAssertTrue(el(app, "unreadTexts.row.unread-text-dib").descendants(matching: .any).matching(titled).firstMatch.exists)
    attach(app, "Unread texts · List")
    try audit(app)

    tap(app, "unreadTexts.paste.unread-text-dib", opening: "pasteText")
    attach(app, "Unread texts · Paste sheet")
    app.swipeDown(velocity: .fast)
    XCTAssertTrue(el(app, "pasteText").waitForNonExistence(timeout: uiWait))

    tap(app, "unreadTexts.dismiss.unread-text-other")
    XCTAssertTrue(el(app, "unreadTexts.row.unread-text-other").waitForNonExistence(timeout: uiWait))
    XCTAssertTrue(app.staticTexts["Dismissed"].waitForExistence(timeout: uiWait))
    el(app, "toast").buttons["Undo"].tap()
    XCTAssertTrue(el(app, "unreadTexts.row.unread-text-other").waitForExistence(timeout: uiWait), "Undo did not bring it back")

    tap(app, "unreadTexts.add.unread-text-dib", opening: "add.amount")
    XCTAssertTrue(el(app, "add.account").label.contains("DIB"), el(app, "add.account").label)
    tap(app, "add.close")
    XCTAssertTrue(el(app, "add.amount").waitForNonExistence(timeout: uiWait))
  }

  @MainActor
  func testUnreadTextsAtTheLargestTextSize() throws {
    let app = launch(scenario: "mayaTexts", arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"])
    XCTAssertTrue(app.tabBars.firstMatch.buttons["Review"].waitForExistence(timeout: 15))
    app.tabBars.firstMatch.buttons["Review"].tap()
    tap(app, "review.tab.unreadTexts", opening: "unreadTexts.row.unread-text-dib")
    try audit(app, atLargeText: true)
  }

  @MainActor
  func testAMailThatMayRepeatATextNamesItAndArchives() throws {
    let app = launch(scenario: "mayaTexts")
    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: 15))
    app.tabBars.firstMatch.buttons["Review"].tap()
    let row = el(app, "review.tab.row.mail-twin")
    XCTAssertTrue(row.waitForExistence(timeout: uiWait))
    XCTAssertTrue(row.label.contains("Same payment? · you decide"), row.label)
    XCTAssertTrue(el(app, "review.tab.row.text-transfer").label.contains("Same payment? · you decide"))
    tap(app, "review.tab.row.mail-twin", opening: "review.reasonStrip.may_repeat")
    let strip = el(app, "review.reasonStrip.may_repeat")
    XCTAssertTrue(strip.label.contains("This may be the same payment as a bank text from DIB on 9 October."), strip.label)
    attach(app, "Repeat · Deck")
    try audit(app)
    strip.tap()
    XCTAssertTrue(el(app, "reason.archive").waitForExistence(timeout: uiWait))
    XCTAssertTrue(el(app, "reason.sort").exists)
    attach(app, "Repeat · About this alert")
    try audit(app, overSheet: true)
    tap(app, "reason.archive")
    XCTAssertTrue(el(app, "reason.archive").waitForNonExistence(timeout: uiWait))
    XCTAssertTrue(app.staticTexts["Archived"].waitForExistence(timeout: uiWait))
  }

  @MainActor
  func testATextRowShowsBankTextAsItsSource() throws {
    let app = launch(scenario: "mayaTexts")
    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: 15))
    app.tabBars.firstMatch.buttons["Activity"].tap()
    tap(app, "txn.text-grocer", opening: "txn.source")
    XCTAssertEqual(el(app, "txn.source").label, "Bank text from DIB")
    XCTAssertFalse(el(app, "txn.viewEmail").exists)
    attach(app, "Bank text · Transaction")
    try audit(app, overSheet: true)
  }
}
