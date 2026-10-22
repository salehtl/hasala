import XCTest

final class RecurringManageUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  @MainActor
  private func launchRecurring(arguments: [String] = []) -> XCUIApplication {
    let app = launch(scenario: "maya", screen: "bills", arguments: arguments)
    XCTAssertTrue(el(app, "bills.next14").waitForExistence(timeout: 15), "Recurring did not appear")
    return app
  }

  @MainActor
  private func open(_ app: XCUIApplication, _ bill: String) {
    let row = el(app, "bill.\(bill)")
    XCTAssertTrue(row.waitForExistence(timeout: uiWait), "bill.\(bill) is missing")
    XCTAssertTrue(reveal(app, row), "could not reach bill.\(bill)")
    row.tap()
    XCTAssertTrue(el(app, "bills.detail.\(bill)").waitForExistence(timeout: uiWait), "\(bill) did not open")
  }

  @MainActor
  private func manage(_ app: XCUIApplication, _ id: String, _ label: String, file: StaticString = #filePath,
                      line: UInt = #line) {
    tap(app, "bills.detail.manage", file: file, line: line)
    let byID = app.buttons[id].firstMatch
    let byLabel = app.buttons[label].firstMatch
    XCTAssertTrue(byID.waitForExistence(timeout: uiWait) || byLabel.exists, "\(label) is not in Manage",
                  file: file, line: line)
    (byID.exists ? byID : byLabel).tap()
  }

  @MainActor
  private func toast(_ app: XCUIApplication, _ title: String, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: uiWait), "no toast \(title)", file: file, line: line)
  }

  @MainActor
  func testAddAnItemFromAPaymentAndLinkIt() throws {
    let app = launchRecurring()
    tap(app, "bills.add", opening: "bills.add.fromPayment")
    try audit(app, overSheet: true)
    attach(app, "Add recurring")
    tap(app, "bills.add.fromPayment", opening: "bills.recent.apple")
    attach(app, "Start from a payment")
    tap(app, "bills.recent.apple")
    let name = el(app, "bills.add.name")
    XCTAssertTrue(name.waitForExistence(timeout: uiWait))
    XCTAssertEqual(name.value as? String, "Apple.com")
    XCTAssertEqual(el(app, "bills.add.amount").value as? String, "14.99")
    XCTAssertTrue(el(app, "bills.add.category").label.contains("Subscriptions"), el(app, "bills.add.category").label)

    tap(app, "bills.add.next", opening: "bills.past.apple")
    let past = el(app, "bills.past.apple")
    XCTAssertFalse(past.isSelected, "a past payment is ticked before a tap")
    try audit(app, overSheet: true)
    attach(app, "Past payments")
    past.tap()
    XCTAssertTrue(el(app, "Add and link 1 payment").waitForExistence(timeout: uiWait))
    tap(app, "bills.add.save")
    toast(app, "Added Apple.com")

    open(app, "bill-manual-1")
    let linked = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Linked by you'"))
    XCTAssertTrue(linked.firstMatch.waitForExistence(timeout: uiWait), "the linked payment is not in the history")
    XCTAssertTrue(el(app, "bills.detail.manage").exists)
    attach(app, "Apple.com · manual")
  }

  @MainActor
  func testEditAmountPauseAndEnd() throws {
    let app = launchRecurring()
    open(app, "netflix")

    manage(app, "bills.manage.editAmount", "Edit amount…")
    XCTAssertTrue(el(app, "bills.amount.field").waitForExistence(timeout: uiWait))
    XCTAssertTrue(el(app, "Earlier payments keep their price.").exists)
    replaceText(app, "bills.amount.field", "63.00")
    app.toolbars.buttons["Done"].firstMatch.tap()
    tap(app, "Sun 6 Dec")
    try audit(app, overSheet: true)
    attach(app, "Edit amount")
    tap(app, "bills.amount.save")
    toast(app, "Netflix amount changed")
    let banner = el(app, "bills.detail.banner.nextAmount")
    XCTAssertTrue(banner.waitForExistence(timeout: uiWait))
    XCTAssertTrue(banner.label.contains("Changes to 63.00 from 6 Dec"), banner.label)

    manage(app, "bills.manage.pause", "Pause…")
    tap(app, "bills.pause.save")
    toast(app, "Paused Netflix")
    XCTAssertTrue(el(app, "bills.detail.banner.paused").waitForExistence(timeout: uiWait))
    try audit(app)
    attach(app, "Netflix · Paused")
    back(app)
    let paused = el(app, "bills.section.paused")
    XCTAssertTrue(reveal(app, paused))
    XCTAssertTrue(el(app, "bill.netflix").label.contains("Paused"), el(app, "bill.netflix").label)

    open(app, "netflix")
    tap(app, "bills.detail.resume")
    toast(app, "Resumed Netflix")
    XCTAssertFalse(el(app, "bills.detail.banner.paused").exists)

    tap(app, "bills.detail.end", opening: "bills.end.save")
    attach(app, "End Netflix")
    tap(app, "bills.end.save")
    toast(app, "Ended Netflix")
    XCTAssertTrue(el(app, "bills.detail.banner.ended").waitForExistence(timeout: uiWait))
    tap(app, "bills.detail.reactivate")
    toast(app, "Tracking Netflix again")
    XCTAssertTrue(el(app, "bills.detail.end").waitForExistence(timeout: uiWait))
  }

  @MainActor
  func testDeleteWithUndoAndEditTheSalary() throws {
    let app = launchRecurring()
    open(app, "dewa")
    manage(app, "bills.manage.delete", "Not a bill")
    let alert = app.alerts["DEWA is not a bill?"]
    XCTAssertTrue(alert.waitForExistence(timeout: uiWait))
    alert.buttons["Not a bill"].tap()
    let undo = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Undo'")).firstMatch
    XCTAssertTrue(undo.waitForExistence(timeout: uiWait), "the toast has no Undo")
    XCTAssertTrue(app.staticTexts["DEWA is not a bill"].exists)
    undo.tap()
    XCTAssertTrue(el(app, "bills.next14").waitForExistence(timeout: uiWait), "the page went back to Recurring")
    XCTAssertTrue(el(app, "bill.dewa").waitForExistence(timeout: uiWait), "Undo brings DEWA back")

    let salary = el(app, "bill.salary")
    XCTAssertTrue(reveal(app, salary))
    salary.tap()
    XCTAssertTrue(el(app, "bills.salary.amount").waitForExistence(timeout: uiWait))
    try audit(app, overSheet: true)
    attach(app, "Salary")
    replaceText(app, "bills.salary.amount", "26000")
    tap(app, "bills.salary.save")
    toast(app, "Income updated")
    XCTAssertTrue(el(app, "bill.salary").waitForLabel(containing: "26,000.00"), el(app, "bill.salary").label)
  }

  @MainActor
  func testRecurringSheetsAtLargeTextSizes() throws {
    let app = launchRecurring(arguments: ["-UIPreferredContentSizeCategoryName",
                                          "UICTContentSizeCategoryAccessibilityXL"])
    let details = el(app, "bills.details.du")
    XCTAssertTrue(details.waitForExistence(timeout: uiWait))
    XCTAssertTrue(reveal(app, details))
    details.tap()
    XCTAssertTrue(el(app, "bills.detail.du").waitForExistence(timeout: uiWait))
    XCTAssertTrue(scroll(app, toShow: el(app, "bills.detail.accept")))
    try audit(app, atLargeText: true)
    attach(app, "AX3 · du · Price change")
    tap(app, "bills.detail.end", opening: "bills.end.save")
    try audit(app, atLargeText: true, overSheet: true)
    attach(app, "AX3 · End du")
    tap(app, "bills.end.close")
    back(app)
    tap(app, "bills.add", opening: "bills.add.fromPayment")
    try audit(app, atLargeText: true, overSheet: true)
    attach(app, "AX3 · Add recurring")
  }
}

final class ReleaseSurfaceRecurringTests: ReleaseSurfaceTestCase {
  @MainActor
  func testRecurringOffersOnlyWhatWorks() throws {
    let app = launchRelease()
    app.buttons["header.profile"].firstMatch.tap()
    XCTAssertTrue(el(app, "profile.name").waitForExistence(timeout: uiWait))
    tap(app, "profile.bills")
    XCTAssertTrue(el(app, "bills.next14").waitForExistence(timeout: uiWait))
    assertPresent(app, ["bills.add"], "Profile › Recurring")

    tap(app, "bills.add", opening: "bills.add.fromPayment")
    assertNoPlaceholders(app, "Add recurring")
    tap(app, "bills.add.close")

    tap(app, "bill.netflix")
    XCTAssertTrue(el(app, "bills.detail.netflix").waitForExistence(timeout: uiWait))
    assertPresent(app, ["bills.detail.manage", "bills.detail.end"], "Netflix")
    assertAbsent(app, ["bills.detail.stop", "bills.detail.remind"], "Netflix")
    tap(app, "bills.detail.manage")
    XCTAssertTrue(app.buttons["Edit amount…"].waitForExistence(timeout: uiWait))
    attach(app, "Release · Netflix · Manage")
    assertNoPlaceholders(app, "Netflix · Manage")
  }
}
