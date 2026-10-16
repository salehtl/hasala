import XCTest

/// How long a UI test waits for the app to show what a step expects. Not 5 s: on a
/// loaded CI runner one snapshot of the hierarchy can take seconds, so a 5 s wait can
/// end after one or two looks at a screen that is still on its way (seen: a sheet's
/// saved note, the split sheet's verdict).
let uiWait: TimeInterval = 15

/// Helpers every UI test shares: scrolling an element into view, the accessibility audit
/// (spec 04 §17) and screenshot attachments.
extension XCTestCase {
  /// Drags the page until the top of `element` sits in the upper part of the screen,
  /// below the header. Each drag rests before the finger lifts, so the page does not
  /// coast on past the measured distance. Returns whether it got there.
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
      from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .default, thenHoldForDuration: 0.3)
    }
    return false
  }

  /// Drags the page up until `element` is hittable, at most `limit` times; for a tap on
  /// a row below the fold. Not `swipeUp()`: a fling leaves the page coasting after the
  /// gesture, and a tap that lands while it still moves can only stop the scroll, leaving
  /// the row unopened (seen at large text sizes on a slow CI runner). Each drag rests
  /// before the finger lifts, so the page stops where it was dragged, and starts
  /// mid-screen, above where a keyboard sits. Fails the test, at the caller's line, when
  /// the element never becomes hittable, so the tap that follows isn't blamed for it.
  /// Returns whether the element is hittable.
  @MainActor
  @discardableResult
  func dragUntilHittable(
    _ app: XCUIApplication, _ element: XCUIElement, limit: Int = 8, file: StaticString = #filePath, line: UInt = #line
  ) -> Bool {
    for _ in 0..<limit {
      if element.isHittable { return true }
      let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
      let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
      from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .default, thenHoldForDuration: 0.3)
    }
    let hittable = element.isHittable
    XCTAssertTrue(hittable, "\(element) is not hittable after \(limit) drags", file: file, line: line)
    return hittable
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
  /// - An issue with no element while content is scrolled under the header. Labelled
  ///   text there shows faintly through the bar's scroll-edge blur, and the audit reads
  ///   those pixels as text it cannot match to an element ("Potentially inaccessible
  ///   text: no element"), depending on which glyphs the blur lets through. Every screen
  ///   is also audited at the top, where nothing sits under the header, so text drawn
  ///   without an element is still caught there.
  ///
  /// The audit runs once the screen stands still (`waitForStill`), and again when it
  /// reports issues or does not finish in time; only issues that a second audit of the
  /// same still screen reports again fail the test. An audit of content that is still
  /// moving (a tab's or a sheet's transition, a scroll coasting, a figure's animation)
  /// sees text change place while it changes the text size, and reports Dynamic Type as
  /// "partially unsupported" on text that does scale, the page's title included (seen
  /// on a slow CI runner); a real defect reports again on a still screen. On a slow
  /// runner the audit can also stop with "Audit failed to complete in time" (code -56);
  /// it gets three tries.
  @MainActor
  func audit(
    _ app: XCUIApplication, atLargeText: Bool = false, file: StaticString = #filePath, line: UInt = #line
  ) throws {
    var reported: [[String]] = []
    for attempt in 1...3 {
      waitForStill(app)
      do {
        let issues = try auditIssues(app, atLargeText: atLargeText)
        if issues.isEmpty { return }
        reported.append(issues)
        if reported.count == 2 { break }
        // In the log, so a run shows how often the retry was needed and for what.
        print("audit attempt \(attempt) reported, auditing again:\n" + issues.joined(separator: "\n"))
      } catch let error as NSError where error.domain == "com.apple.xcode.xctest.accessibilityAudit"
        && error.code == -56 && attempt < 3
      {
        print("audit attempt \(attempt) did not finish in time, auditing again")
      }
    }
    if let issues = reported.last {
      XCTFail("accessibility audit:\n" + issues.joined(separator: "\n"), file: file, line: line)
    }
  }

  /// One run of the system accessibility audit; the issues that count, described.
  @MainActor
  private func auditIssues(_ app: XCUIApplication, atLargeText: Bool) throws -> [String] {
    let bars = [app.navigationBars.firstMatch, app.tabBars.firstMatch].filter(\.exists).map(\.frame)
    let underHeader = contentUnderHeader(app)
    var types = XCUIAccessibilityAuditType.all.subtracting(.contrast)
    if !atLargeText { types.remove(.textClipped) }
    var issues: [String] = []
    try app.performAccessibilityAudit(for: types) { issue in
      // The keyboard is the system's, not ours.
      if let e = issue.element, e.elementType == .key || e.elementType == .keyboard { return true }
      // The system search field (UISearchBarTextField) sizes its own text.
      if issue.auditType == .textClipped, issue.element?.elementType == .searchField { return true }
      if issue.auditType == .dynamicType, let element = issue.element {
        if element.identifier == "hasala.cappedFigure" { return true }
        if bars.contains(where: { $0.intersects(element.frame) }) { return true }
      }
      if issue.element == nil, underHeader { return true }
      let element = issue.element.map { "'\($0.label)' [\($0.identifier)] \($0.elementType.rawValue) \($0.frame)" }
      issues.append("\(issue.compactDescription): \(element ?? "no element") — \(issue.detailedDescription)")
      return true
    }
    return issues
  }

  /// Waits, up to `timeout`, until nothing on screen moves: two snapshots of the
  /// hierarchy in a row put every element in the same place. For the end of a
  /// transition, a scroll's coast or an animation, before an audit or a drag that
  /// measures where things are.
  @MainActor
  func waitForStill(_ app: XCUIApplication, timeout: TimeInterval = 10) {
    let deadline = Date(timeIntervalSinceNow: timeout)
    var last: [CGRect]?
    while Date() < deadline {
      guard let root = try? app.snapshot() else { return }
      var frames: [CGRect] = []
      var stack = [root]
      while let node = stack.popLast() {
        frames.append(node.frame)
        stack.append(contentsOf: node.children)
      }
      if frames == last { return }
      last = frames
      RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
    }
  }

  /// Taps `field` until it has the keyboard focus, then types `text` into it. One tap
  /// is not always enough on a slow CI runner: a tap that lands while a sheet still
  /// settles, or while the app is busy, can leave the field without focus, and
  /// `typeText` then fails ("Neither element nor any descendant has keyboard focus").
  @MainActor
  func type(_ text: String, into field: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
    for _ in 0..<3 {
      field.tap()
      if field.waitForKeyboardFocus() {
        field.typeText(text)
        return
      }
    }
    XCTFail("\(field) did not get the keyboard focus after 3 taps", file: file, line: line)
  }

  /// Whether any labelled element outside the bars lies under the navigation bar (or
  /// the blur just below it), from one snapshot of the hierarchy.
  @MainActor
  func contentUnderHeader(_ app: XCUIApplication) -> Bool {
    let header = app.navigationBars.firstMatch
    guard header.exists, let root = try? app.snapshot() else { return false }
    let band = CGRect(x: 0, y: 0, width: app.frame.width, height: header.frame.maxY + 16)
    var stack = [root]
    while let node = stack.popLast() {
      switch node.elementType {
      case .navigationBar, .tabBar, .statusBar: continue
      case .application, .window: break
      default:
        if !node.label.isEmpty, node.frame.intersects(band), node.frame.height < band.height * 2 { return true }
      }
      stack.append(contentsOf: node.children)
    }
    return false
  }

  @MainActor
  func attach(_ app: XCUIApplication, _ name: String) {
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = name
    shot.lifetime = .keepAlways
    add(shot)
  }
}
