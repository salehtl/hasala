import XCTest

final class BankTextsUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  static let largeText = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"]

  @MainActor
  func testTextsSetUpThroughToHome() throws {
    let app = launch(scenario: "setupTexts")
    XCTAssertTrue(el(app, "source.texts").waitForExistence(timeout: 15), "the choice is missing")
    XCTAssertTrue(app.staticTexts["How do your banks reach you?"].exists)
    XCTAssertTrue(el(app, "source.email").exists)
    XCTAssertFalse(el(app, "source.continue").isEnabled, "a source was picked for the person")
    XCTAssertFalse(el(app, "source.texts").isSelected || el(app, "source.email").isSelected, "a card was preselected")
    attach(app, "How do your banks reach you")
    try audit(app)

    tap(app, "source.texts")
    XCTAssertTrue(el(app, "source.texts").isSelected)
    tap(app, "source.continue", opening: "textsBanks.continue")
    XCTAssertTrue(app.staticTexts["Which banks text you?"].exists)
    XCTAssertTrue(el(app, "bank.dib").label.contains("Read automatically"))
    XCTAssertTrue(el(app, "bank.enbd").label.contains("You check each one in Review"))
    attach(app, "Which banks text you")
    try audit(app)
    tap(app, "textsBanks.continue", opening: "texts.steps")
    XCTAssertTrue(app.staticTexts["Make the automation"].exists)
    XCTAssertTrue(el(app, "texts.keepsOnly").exists, "the privacy line is missing")
    XCTAssertTrue(el(app, "texts.banksLine").label.contains("DIB texts are read automatically"))
    XCTAssertTrue(el(app, "texts.openShortcuts").exists)
    attach(app, "Make the automation")
    try audit(app)

    tap(app, "texts.showMeHow", opening: "textsGuide.step6")
    attach(app, "Show me how")
    try audit(app, overSheet: true)
    tap(app, "textsGuide.done")
    XCTAssertTrue(el(app, "texts.toTest").waitForExistence(timeout: uiWait))

    tap(app, "texts.toTest", opening: "textsTest.phrase")
    XCTAssertTrue(app.staticTexts["Send yourself a test"].exists)
    XCTAssertTrue(el(app, "textsTest.skip").exists)
    let received = el(app, "textsTest.received")
    XCTAssertTrue(received.waitForExistence(timeout: uiWait), "the test text never arrived")
    XCTAssertTrue(app.staticTexts["Your automation works"].exists)
    attach(app, "Your automation works")
    try audit(app)

    tap(app, "textsTest.done")
    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: 15), "Home did not open")
    XCTAssertFalse(el(app, "home.finish.connectEmail").exists, "Home asked for email after texts")
  }

  @MainActor
  func testNothingArrivedShowsTheChecklistAndSkipGoesHome() throws {
    let app = launch(scenario: nil, screen: "setup.texts.nothing")
    XCTAssertTrue(el(app, "textsTest.checklist").waitForExistence(timeout: 30), "the checklist is missing")
    XCTAssertTrue(app.staticTexts["Nothing arrived yet"].exists)
    XCTAssertTrue(el(app, "textsTest.again").exists)
    attach(app, "Nothing arrived yet")
    try audit(app)
    tap(app, "textsTest.skip")
    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: 15), "Skip did not finish setup")
  }

  @MainActor
  func testEmailFromTheChoiceKeepsTheBankStep() throws {
    let app = launch(scenario: "setupTexts")
    tap(app, "source.email")
    tap(app, "source.continue", opening: "bank.enbd")
    XCTAssertTrue(app.staticTexts["Connect your bank alerts"].exists)
    let sms = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'not only SMS'"))
    XCTAssertEqual(sms.count, 0, "the email-only line is still there")
    back(app)
    XCTAssertTrue(el(app, "source.texts").waitForExistence(timeout: uiWait), "back did not return to the choice")
    XCTAssertTrue(el(app, "source.email").isSelected)
  }

  @MainActor
  func testTextsSetUpAtLargeText() throws {
    let app = launch(scenario: "setupTexts", arguments: Self.largeText)
    XCTAssertTrue(el(app, "source.texts").waitForExistence(timeout: 15))
    attach(app, "Choice · AX")
    try audit(app, atLargeText: true)
    tap(app, "source.texts")
    tap(app, "source.continue", opening: "textsBanks.continue")
    attach(app, "Which banks text you · AX")
    try audit(app, atLargeText: true)
    tap(app, "textsBanks.continue", opening: "texts.steps")
    attach(app, "Make the automation · AX")
    try audit(app, atLargeText: true)
    tap(app, "texts.toTest", opening: "textsTest.phrase")
    XCTAssertTrue(el(app, "textsTest.received").waitForExistence(timeout: uiWait))
    attach(app, "It works · AX")
    try audit(app, atLargeText: true)
  }

  @MainActor
  func testBankAlertsForTexts() throws {
    let app = launch(scenario: nil, screen: "bankAlerts.texts")
    let status = el(app, "bankAlerts.status")
    XCTAssertTrue(status.waitForExistence(timeout: 30))
    XCTAssertTrue(status.label.contains("Working") && status.label.contains("ran 4 min ago"), status.label)
    XCTAssertTrue(el(app, "bankAlerts.texts.automation").label.contains("Ran 4 min ago"))
    XCTAssertTrue(el(app, "bankAlerts.texts.bank.dib").label.contains("Read automatically"))
    XCTAssertTrue(el(app, "bankAlerts.texts.bank.adib").label.contains("No text yet"))
    attach(app, "Bank alerts · Texts · Working")
    try audit(app, overSheet: true)

    tap(app, "bankAlerts.texts.showMeHow", opening: "textsGuide.step1")
    tap(app, "textsGuide.done")

    tap(app, "bankAlerts.texts.test", opening: "textsTest.phrase")
    XCTAssertTrue(el(app, "textsTest.received").waitForExistence(timeout: uiWait))
    tap(app, "textsTest.done")

    let useEmail = el(app, "bankAlerts.texts.useEmail")
    XCTAssertTrue(useEmail.waitForExistence(timeout: uiWait))
    tap(app, "bankAlerts.texts.useEmail")
    let alert = app.alerts["Switch to bank email?"]
    XCTAssertTrue(alert.waitForExistence(timeout: uiWait), "the switch alert did not open")
    let message = alert.staticTexts.matching(NSPredicate(format: "label CONTAINS 'may be the same payment as a bank text waits in Review'"))
    XCTAssertEqual(message.count, 1, "the overlap sentence is missing")
    attach(app, "Switch to bank email")
    alert.buttons["Connect email"].firstMatch.tap()
    XCTAssertTrue(el(app, "mail.choose.gmail").waitForExistence(timeout: uiWait), "Add a mailbox did not open")
    back(app)
    XCTAssertTrue(el(app, "bankAlerts.texts.automation").waitForExistence(timeout: uiWait), "backing out left bank texts")
  }

  @MainActor
  func testTheAutomationStepCanBeSkipped() throws {
    let app = launch(scenario: nil, screen: "setup.texts")
    let skip = el(app, "texts.skip")
    XCTAssertTrue(skip.waitForExistence(timeout: 30), "Skip is missing from the automation step")
    dragUntilHittable(app, skip)
    skip.tap()
    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: 15), "Skip did not finish setup")
  }

  @MainActor
  func testBankAlertsWaitingForTheFirstText() throws {
    let app = launch(scenario: nil, screen: "bankAlerts.texts.waiting", arguments: Self.largeText)
    let status = el(app, "bankAlerts.status")
    XCTAssertTrue(status.waitForExistence(timeout: 30))
    XCTAssertTrue(status.label.contains("Waiting for your first bank text"), status.label)
    XCTAssertTrue(el(app, "bankAlerts.texts.automation").label.contains("Test passed"))
    attach(app, "Bank alerts · Waiting · AX")
    try audit(app, atLargeText: true, overSheet: true)
  }

  @MainActor
  func testUseBankTextsInsteadOfEmail() throws {
    let app = launch(scenario: nil, screen: "bankAlerts.emailOrTexts")
    let use = el(app, "bankAlerts.useTexts")
    XCTAssertTrue(use.waitForExistence(timeout: 30), "Use bank texts instead is missing")
    dragUntilHittable(app, use)
    attach(app, "Bank alerts · Email in use")
    try audit(app, overSheet: true)
    use.tap()
    let alert = app.alerts["Switch to bank texts?"]
    XCTAssertTrue(alert.waitForExistence(timeout: uiWait))
    XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS 'disconnects your mailbox'")).count == 1)
    alert.buttons["Switch to texts"].tap()
    XCTAssertTrue(el(app, "textsGuide.step1").waitForExistence(timeout: uiWait), "the guide did not open")
    tap(app, "textsGuide.done")
    let status = el(app, "bankAlerts.status")
    XCTAssertTrue(status.waitForExistence(timeout: uiWait))
    XCTAssertTrue(status.label.contains("Waiting for your first bank text"), status.label)
  }

  @MainActor
  func testPasteABankTextFromReview() throws {
    let app = launch(scenario: nil, screen: "review.pasteText")
    let read = el(app, "pasteText.read")
    XCTAssertTrue(read.waitForExistence(timeout: 30), "Hasala's reading is missing")
    XCTAssertTrue(el(app, "pasteText.paste").exists, "the system paste button is missing")
    XCTAssertTrue(app.staticTexts["Sample Grocer"].exists)
    attach(app, "Paste a bank text")
    try audit(app, overSheet: true)
    tap(app, "pasteText.add")
    XCTAssertTrue(el(app, "pasteText").waitForNonExistence(timeout: uiWait), "the sheet stayed")
    XCTAssertTrue(el(app, "review.tab.pasteText").waitForExistence(timeout: uiWait))
  }

  @MainActor
  func testAPasteThatMayReplaceAnUnreadTextAsks() throws {
    let app = launch(scenario: nil, screen: "review.pasteText.match")
    XCTAssertTrue(el(app, "pasteText.match").waitForExistence(timeout: 30), "the matching row is missing")
    XCTAssertTrue(el(app, "pasteText.undated").exists, "the undated note is missing")
    XCTAssertTrue(el(app, "pasteText.addNew").exists)
    XCTAssertEqual(el(app, "pasteText.add").label, "Replace it")
    attach(app, "Paste a bank text · Matches an unread text")
    try audit(app, overSheet: true)
    tap(app, "pasteText.addNew")
    XCTAssertTrue(el(app, "pasteText").waitForNonExistence(timeout: uiWait), "the sheet stayed")
  }

  @MainActor
  func testPasteAtLargeText() throws {
    let app = launch(scenario: nil, screen: "review.pasteText", arguments: Self.largeText)
    XCTAssertTrue(el(app, "pasteText.read").waitForExistence(timeout: 30))
    attach(app, "Paste a bank text · AX")
    try audit(app, atLargeText: true, overSheet: true)
  }
}
