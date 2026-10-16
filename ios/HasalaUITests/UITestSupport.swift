import XCTest

/// Helpers every UI test shares: launching a mock scenario, finding, tapping and typing
/// into elements by identifier, scrolling an element into view, the accessibility audit
/// (spec 04 §17) and screenshot attachments. Every class uses these, so a package's test
/// file holds its flows only (plan B7.4).
extension XCTestCase {
  /// The Debug app on a mock: `-HasalaScenario <scenario>`, and optionally straight to a
  /// screen (`-HasalaScreen <screen>`, which picks its own scenario unless one is given),
  /// on the Release surface (`-HasalaReleaseSurface`), with motion settled or reduced
  /// (`-HasalaMotion off|reduce`), and any further launch arguments.
  @MainActor
  func launch(
    scenario: String? = "maya", screen: String? = nil, release: Bool = false, motion: String? = nil,
    arguments: [String] = []
  ) -> XCUIApplication {
    let app = XCUIApplication()
    var args: [String] = []
    if let scenario { args += ["-HasalaScenario", scenario] }
    if let screen { args += ["-HasalaScreen", screen] }
    if release { args.append("-HasalaReleaseSurface") }
    if let motion { args += ["-HasalaMotion", motion] }
    app.launchArguments = args + arguments
    app.launch()
    return app
  }

  /// The first element with this identifier (or label), of any type.
  @MainActor
  func el(_ app: XCUIApplication, _ id: String) -> XCUIElement {
    app.descendants(matching: .any)[id].firstMatch
  }

  /// Waits for `id`, drags it into reach, then taps it; fails at the caller's line when
  /// it never appears.
  @MainActor
  func tap(
    _ app: XCUIApplication, _ id: String, timeout: TimeInterval = 15, file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let e = el(app, id)
    XCTAssertTrue(e.waitForExistence(timeout: timeout), "\(id) is missing", file: file, line: line)
    dragUntilHittable(app, e, file: file, line: line)
    e.tap()
  }

  /// Taps the field `id`, then types `text` into it.
  @MainActor
  func type(
    _ app: XCUIApplication, _ id: String, _ text: String, file: StaticString = #filePath, line: UInt = #line
  ) {
    let e = el(app, id)
    XCTAssertTrue(e.waitForExistence(timeout: 15), "\(id) is missing", file: file, line: line)
    e.tap()
    e.typeText(text)
  }

  /// Replaces a text field's whole contents: the cursor goes to the end (a tap can land
  /// mid-text), then one delete per character.
  @MainActor
  func replaceText(
    _ app: XCUIApplication, _ id: String, _ text: String, file: StaticString = #filePath, line: UInt = #line
  ) {
    let e = el(app, id)
    XCTAssertTrue(e.waitForExistence(timeout: 10), "\(id) is missing", file: file, line: line)
    e.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
    let current = (e.value as? String) ?? ""
    e.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 2))
    XCTAssertEqual((e.value as? String).map { $0 == (e.placeholderValue ?? "") || $0.isEmpty }, true,
                   "\(id) was not cleared", file: file, line: line)
    e.typeText(text)
  }

  /// Back on a pushed screen: the first button of the navigation bar.
  @MainActor
  func back(_ app: XCUIApplication) {
    app.navigationBars.buttons.firstMatch.tap()
  }

  /// Drags the page up until `element` can be tapped, for rows near the end of a page
  /// that can never reach the upper half. Returns whether it got there.
  @MainActor
  func reveal(_ app: XCUIApplication, _ element: XCUIElement) -> Bool {
    for _ in 0..<12 {
      if element.exists, element.isHittable, element.frame.maxY < app.frame.height - 120 { return true }
      let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
      let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
      from.press(forDuration: 0.05, thenDragTo: to)
    }
    return element.exists && element.isHittable
  }

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
  /// - The keyboard and its prediction bar (system UI, laid out by iOS).
  /// - An issue with no element while content is scrolled under the header. Labelled
  ///   text there shows faintly through the bar's scroll-edge blur, and the audit reads
  ///   those pixels as text it cannot match to an element ("Potentially inaccessible
  ///   text: no element"), depending on which glyphs the blur lets through. Every screen
  ///   is also audited at the top, where nothing sits under the header, so text drawn
  ///   without an element is still caught there.
  @MainActor
  func audit(
    _ app: XCUIApplication, atLargeText: Bool = false, file: StaticString = #filePath, line: UInt = #line
  ) throws {
    let bars = [app.navigationBars.firstMatch, app.tabBars.firstMatch].filter(\.exists).map(\.frame)
    let underHeader = contentUnderHeader(app)
    // The keyboard's top edge, when it is up: its prediction bar sits on it.
    let keyboard = app.keyboards.firstMatch
    let keyboardTop = keyboard.exists ? keyboard.frame.minY : nil
    var types = XCUIAccessibilityAuditType.all.subtracting(.contrast)
    if !atLargeText { types.remove(.textClipped) }
    var issues: [String] = []
    try app.performAccessibilityAudit(for: types) { issue in
      // The keyboard is the system's, not ours.
      if let e = issue.element, e.elementType == .key || e.elementType == .keyboard { return true }
      // So is its prediction bar: three empty cells (TUIPredictionViewCell, "Element has no
      // description") along the keyboard's top edge, which turning autocorrection off on the
      // field does not remove on iOS 27. Only unlabelled elements in that band are skipped, so
      // the app's own controls just above the keyboard (a dock, the word list) are still audited.
      if issue.auditType == .sufficientElementDescription, let e = issue.element, e.label.isEmpty,
        let keyboardTop, e.frame.minY >= keyboardTop - 44
      {
        return true
      }
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
    if !issues.isEmpty {
      XCTFail("accessibility audit:\n" + issues.joined(separator: "\n"), file: file, line: line)
    }
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

extension XCUIElement {
  /// Waits until the element's label reads `label`.
  func waitForLabel(_ label: String, timeout: TimeInterval = 5) -> Bool {
    let predicate = NSPredicate(format: "label == %@", label)
    return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: self)], timeout: timeout)
      == .completed
  }

  /// Waits until the element's label contains `text`.
  func waitForLabel(containing text: String, timeout: TimeInterval = 5) -> Bool {
    let predicate = NSPredicate(format: "label CONTAINS %@", text)
    return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: self)], timeout: timeout)
      == .completed
  }
}
