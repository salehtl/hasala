import XCTest

final class ReviewDeckFitUITests: XCTestCase {
  static let xxxLarge = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXXXL"]

  override func setUp() {
    continueAfterFailure = false
  }

  @MainActor
  private func assertInReach(_ app: XCUIApplication, _ ids: [String], file: StaticString = #filePath, line: UInt = #line) {
    for id in ids {
      let e = el(app, id)
      XCTAssertTrue(e.waitForExistence(timeout: 15), "\(id) is missing", file: file, line: line)
      if !e.isHittable || e.frame.maxY > app.frame.maxY {
        XCTAssertTrue(reveal(app, e), "\(id) is out of reach", file: file, line: line)
      }
      XCTAssertTrue(e.isHittable, "\(id) is clipped", file: file, line: line)
      let card = el(app, "review.card")
      XCTAssertLessThanOrEqual(e.frame.maxY, card.frame.maxY + 1, "\(id) runs past the card's edge", file: file, line: line)
      XCTAssertLessThanOrEqual(e.frame.maxY, app.frame.maxY, id, file: file, line: line)
    }
  }

  @MainActor
  func testACopyCardKeepsItsAnswersInReach() throws {
    let app = launch(scenario: "mayaCopy", screen: "review.copy")
    assertInReach(app, ["review.keepBoth", "review.merge"])
    attach(app, "Review · Copy · fit")
    try audit(app)
  }

  @MainActor
  func testASuggestionCardKeepsUseInReach() throws {
    let app = launch(screen: "review.deck")
    assertInReach(app, ["review.use"])
    attach(app, "Review · Deck · fit")
    try audit(app)
  }

  @MainActor
  func testACopyCardKeepsItsAnswersInReachAtTheLargestStandardSize() throws {
    let app = launch(scenario: "mayaCopy", screen: "review.copy", arguments: Self.xxxLarge)
    assertInReach(app, ["review.keepBoth", "review.merge"])
    attach(app, "Review · Copy · xxxLarge")
  }

  @MainActor
  func testASuggestionCardKeepsUseInReachAtTheLargestStandardSize() throws {
    let app = launch(screen: "review.deck", arguments: Self.xxxLarge)
    assertInReach(app, ["review.use"])
    attach(app, "Review · Deck · xxxLarge")
  }
}
