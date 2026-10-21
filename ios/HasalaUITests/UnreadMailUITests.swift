import XCTest

final class UnreadMailUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  @MainActor
  func testUnreadEmailsAreCountedListedDismissedAndAddedByHand() throws {
    let app = launch(scenario: "mayaUnreadMail")
    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: 15))
    XCTAssertEqual(app.buttons["header.notifications"].firstMatch.label, "Notifications, 5 need a look")
    app.buttons["header.notifications"].firstMatch.tap()
    let bellRow = el(app, "bell.row.unread")
    XCTAssertTrue(bellRow.waitForExistence(timeout: uiWait))
    XCTAssertTrue(bellRow.label.contains("2 bank emails we couldn't read"), bellRow.label)
    XCTAssertTrue(el(app, "bell.row.review").label.contains("6 transactions to sort"))
    attach(app, "Unread mail · Bell")
    try audit(app)
    bellRow.tap()
    XCTAssertTrue(el(app, "unread.intro").waitForExistence(timeout: uiWait), "the bell did not open the list")
    XCTAssertTrue(app.tabBars.firstMatch.buttons["Review"].isSelected)
    app.navigationBars.buttons.firstMatch.tap()

    let line = el(app, "review.tab.unreadable")
    XCTAssertTrue(line.waitForExistence(timeout: uiWait))
    XCTAssertTrue(line.label.contains("3 bank emails we couldn't read"), line.label)
    XCTAssertEqual(el(app, "review.tab.count").label, "6 to sort · about a minute")
    attach(app, "Unread mail · Review tab")
    try audit(app)
    line.tap()

    XCTAssertTrue(el(app, "unread.row.unread-gmail").waitForExistence(timeout: uiWait))
    XCTAssertTrue(el(app, "unread.row.unread-outlook").exists)
    let received = NSPredicate(format: "label CONTAINS 'Received Fri 9 Oct · in Gmail'")
    XCTAssertTrue(app.descendants(matching: .any).matching(received).firstMatch.exists)
    XCTAssertTrue(el(app, "unread.notDownloaded").label.contains("1 more email couldn't be downloaded."))
    for (row, title) in [("unread-gmail", "DIB email"), ("unread-outlook", "Bank email")] {
      let named = NSPredicate(format: "label BEGINSWITH %@", title)
      XCTAssertTrue(el(app, "unread.row.\(row)").descendants(matching: .any).matching(named).firstMatch.exists, title)
    }
    attach(app, "Unread mail · List")
    try audit(app)

    tap(app, "unread.dismiss.unread-gmail")
    XCTAssertTrue(el(app, "unread.row.unread-gmail").waitForNonExistence(timeout: uiWait))
    XCTAssertTrue(app.staticTexts["Dismissed"].waitForExistence(timeout: uiWait))
    el(app, "toast").buttons["Undo"].tap()
    XCTAssertTrue(el(app, "unread.row.unread-gmail").waitForExistence(timeout: uiWait), "Undo did not bring it back")

    tap(app, "unread.add.unread-gmail", opening: "add.amount")
    XCTAssertTrue(el(app, "add.account").label.contains("DIB card"), el(app, "add.account").label)
    tap(app, "add.close")
    XCTAssertTrue(el(app, "add.amount").waitForNonExistence(timeout: uiWait))
    XCTAssertTrue(el(app, "unread.row.unread-gmail").exists)

    tap(app, "unread.add.unread-outlook", opening: "add.amount")
    attach(app, "Unread mail · Add by hand")
    try audit(app)
    typeOnKeypad(app, "120")
    type(app, "add.merchant", "Transfer to a friend")
    app.toolbars.buttons["Done"].firstMatch.tap()
    XCTAssertTrue(el(app, "keypad.1").waitForExistence(timeout: uiWait))
    tap(app, "add.category", opening: "addCategory.transfer")
    tap(app, "addCategory.transfer")
    XCTAssertTrue(el(app, "add.save").waitForExistence(timeout: uiWait))
    tap(app, "add.save")
    XCTAssertTrue(el(app, "add.amount").waitForNonExistence(timeout: uiWait))
    XCTAssertTrue(el(app, "unread.row.unread-outlook").waitForNonExistence(timeout: uiWait))
    XCTAssertTrue(el(app, "unread.row.unread-gmail").exists)

    tap(app, "unread.dismiss.unread-gmail")
    XCTAssertTrue(el(app, "unread.row.unread-gmail").waitForNonExistence(timeout: uiWait))
    XCTAssertTrue(el(app, "unread.notDownloaded").exists)
    XCTAssertFalse(el(app, "unread.intro").exists)
    attach(app, "Unread mail · Only a download failure left")
    app.navigationBars.buttons.firstMatch.tap()
    let rest = el(app, "review.tab.unreadable")
    XCTAssertTrue(rest.waitForExistence(timeout: uiWait))
    XCTAssertTrue(rest.label.contains("1 bank email we couldn't read"), rest.label)
    XCTAssertFalse(app.buttons["review.tab.unreadable"].exists, "a line with nothing to open is a button")
  }

  @MainActor
  func testTheMayaLedgerShowsNoUnreadLine() throws {
    let app = launch(scenario: "maya")
    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: 15))
    app.tabBars.firstMatch.buttons["Review"].tap()
    XCTAssertTrue(el(app, "review.tab.start").waitForExistence(timeout: uiWait))
    XCTAssertFalse(el(app, "review.tab.unreadable").exists)
  }

  @MainActor
  func testUnreadEmailsAtLargeTextSizes() throws {
    let large = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"]
    let tab = launch(scenario: "mayaUnreadMail", screen: "review.unread", arguments: large)
    XCTAssertTrue(el(tab, "review.tab.unreadable").waitForExistence(timeout: 15))
    attach(tab, "AX3 · Unread mail · Review tab")
    try audit(tab, atLargeText: true)
    tab.terminate()

    let list = launch(scenario: "mayaUnreadMail", screen: "review.unread.list", arguments: large)
    XCTAssertTrue(el(list, "unread.row.unread-gmail").waitForExistence(timeout: 15))
    attach(list, "AX3 · Unread mail · List")
    try audit(list, atLargeText: true)
    let outlook = el(list, "unread.add.unread-outlook")
    XCTAssertTrue(scroll(list, toShow: outlook))
    attach(list, "AX3 · Unread mail · List end")
    try audit(list, atLargeText: true)
  }
}
