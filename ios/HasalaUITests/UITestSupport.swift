import XCTest

/// Helpers every UI test shares: scrolling an element into view, the accessibility audit
/// (spec 04 §17) and screenshot attachments.
extension XCTestCase {
  /// Drags the page until the top of `element` sits in the upper part of the screen,
  /// below the header. Returns whether it got there.
  @MainActor
  func scroll(_ app: XCUIApplication, toShow element: XCUIElement) -> Bool {
    let height = app.frame.height
    for _ in 0..<24 {
      let top = element.frame.minY
      if top >= 120 && top <= height * 0.5 { return true }
      let up = top > height * 0.5
      let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.7 : 0.35))
      let distance = min(0.35, abs(top - height * 0.3) / height)
      let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.7 - distance : 0.35 + distance))
      from.press(forDuration: 0.05, thenDragTo: to)
    }
    return false
  }

  /// Runs the system accessibility audit on what is on screen and reports every issue
  /// it finds there in one failure, naming the element. Not counted:
  ///
  /// - Clipping at the default size. There the audit can only predict that text "may
  ///   be clipped at larger Dynamic Type sizes" (Paper sets one-line text that the
  ///   layouts let wrap above the default size); `testAccessibilityAtLargeTextSizes`
  ///   checks clipping at `.accessibility3` itself, where it is decided. The system
  ///   search field is not ours to lay out and is not counted at any size.
  /// - Contrast. The audit samples rendered pixels and fails ink on the grey canvas
  ///   (over 14:1) under the scroll-edge blur and the glass bars, so it cannot gate;
  ///   HasalaKit's ContrastTests checks every text/surface token pair exactly instead.
  /// - "Dynamic Type partially unsupported" on the figures that stop growing at
  ///   `.accessibility3` on purpose (spec 04 §14.4; marked `hasala.cappedFigure`), and
  ///   on text inside the navigation and tab bars, which keep their size and offer
  ///   the Large Content Viewer instead, as system bars do.
  @MainActor
  func audit(
    _ app: XCUIApplication, atLargeText: Bool = false, file: StaticString = #filePath, line: UInt = #line
  ) throws {
    let bars = [app.navigationBars.firstMatch, app.tabBars.firstMatch].filter(\.exists).map(\.frame)
    var types = XCUIAccessibilityAuditType.all.subtracting(.contrast)
    if !atLargeText { types.remove(.textClipped) }
    var issues: [String] = []
    try app.performAccessibilityAudit(for: types) { issue in
      // The system search field (UISearchBarTextField) sizes its own text.
      if issue.auditType == .textClipped, issue.element?.elementType == .searchField { return true }
      if issue.auditType == .dynamicType, let element = issue.element {
        if element.identifier == "hasala.cappedFigure" { return true }
        if bars.contains(where: { $0.intersects(element.frame) }) { return true }
      }
      let element = issue.element.map { "'\($0.label)' [\($0.identifier)] \($0.elementType.rawValue) \($0.frame)" }
      issues.append("\(issue.compactDescription): \(element ?? "no element") — \(issue.detailedDescription)")
      return true
    }
    if !issues.isEmpty {
      XCTFail("accessibility audit:\n" + issues.joined(separator: "\n"), file: file, line: line)
    }
  }

  @MainActor
  func attach(_ app: XCUIApplication, _ name: String) {
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = name
    shot.lifetime = .keepAlways
    add(shot)
  }
}
