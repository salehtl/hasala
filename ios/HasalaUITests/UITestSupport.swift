import UIKit
import XCTest

/// How long a UI test waits for the app to show what a step expects. Not 5 s: on a
/// loaded CI runner one snapshot of the hierarchy can take seconds, so a 5 s wait can
/// end after one or two looks at a screen that is still on its way (seen: a sheet's
/// saved note, the split sheet's verdict).
let uiWait: TimeInterval = 15

/// Helpers every UI test shares: launching a mock scenario, finding, tapping and typing
/// into elements by identifier, scrolling an element into view, the accessibility audit
/// (spec 04 §17) and screenshot attachments. Every class uses these, so a package's test
/// file holds its flows only (plan B7.4).
extension XCTestCase {
  /// The Debug app on a mock: `-HasalaScenario <scenario>`, and optionally straight to a
  /// screen (`-HasalaScreen <screen>`, which picks its own scenario unless one is given),
  /// on the Release surface (`-HasalaReleaseSurface`), with motion settled or reduced
  /// (`-HasalaMotion off|reduce`), with the Review order (`-HasalaReviewOrder newest|oldest`;
  /// the scripted deck flows read oldest first), and any further launch arguments.
  @MainActor
  func launch(
    scenario: String? = "maya", screen: String? = nil, release: Bool = false, motion: String? = nil,
    reviewOrder: String? = "oldest", arguments: [String] = [], pasteboard: String? = nil
  ) -> XCUIApplication {
    if let pasteboard {
      UIPasteboard.general.string = pasteboard
    } else {
      UIPasteboard.general.items = []
    }
    let app = XCUIApplication()
    var args: [String] = []
    if let scenario { args += ["-HasalaScenario", scenario] }
    if let screen { args += ["-HasalaScreen", screen] }
    if release { args.append("-HasalaReleaseSurface") }
    if let motion { args += ["-HasalaMotion", motion] }
    if let reviewOrder { args += ["-HasalaReviewOrder", reviewOrder] }
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

  /// Taps `id` and waits for `next`, the element the tap brings up. A tap that a slow CI
  /// runner swallows (one that lands as the keyboard goes or the page settles) gets one
  /// more try, while `id` is still on screen; fails at the caller's line when `next`
  /// never appears.
  @MainActor
  func tap(
    _ app: XCUIApplication, _ id: String, opening next: String, file: StaticString = #filePath, line: UInt = #line
  ) {
    tap(app, id, file: file, line: line)
    let shown = el(app, next)
    if shown.waitForExistence(timeout: uiWait) { return }
    let again = el(app, id)
    if again.exists, again.isHittable { again.tap() }
    XCTAssertTrue(shown.waitForExistence(timeout: uiWait), "\(id) did not open \(next)", file: file, line: line)
  }

  /// Taps the field `id`, then types `text` into it.
  @MainActor
  func type(
    _ app: XCUIApplication, _ id: String, _ text: String, file: StaticString = #filePath, line: UInt = #line
  ) {
    let e = el(app, id)
    XCTAssertTrue(e.waitForExistence(timeout: 15), "\(id) is missing", file: file, line: line)
    type(text, into: e, file: file, line: line)
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

  @MainActor
  func openPlan(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
    app.buttons["header.profile"].firstMatch.tap()
    let row = el(app, "profile.plan")
    XCTAssertTrue(row.waitForExistence(timeout: uiWait), "Profile has no Plan row", file: file, line: line)
    XCTAssertTrue(reveal(app, row), "could not reach Profile's Plan row", file: file, line: line)
    row.tap()
    XCTAssertTrue(el(app, "plan.readyToAssign").waitForExistence(timeout: uiWait), "Plan did not open",
                  file: file, line: line)
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
      // Overshot: the element went up under the header, so drag back down.
      let down = element.exists && element.frame.maxY < 160
      let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: down ? 0.4 : 0.75))
      let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: down ? 0.65 : 0.45))
      from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .default, thenHoldForDuration: 0.3)
    }
    waitForStill(app)
    return element.exists && element.isHittable
  }

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
  /// Returns whether the element is hittable. After a drag it waits for the page to come
  /// to rest: a drag past the end springs back once the finger lifts, and a tap during
  /// that bounce only stops it (seen: "about.continue" at large text, on a CI runner).
  @MainActor
  @discardableResult
  func dragUntilHittable(
    _ app: XCUIApplication, _ element: XCUIElement, limit: Int = 8, file: StaticString = #filePath, line: UInt = #line
  ) -> Bool {
    for i in 0..<limit {
      if element.isHittable, !isUnderKeyboard(app, element) {
        if i > 0 { waitForStill(app) }
        return true
      }
      let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
      let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
      from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .default, thenHoldForDuration: 0.3)
    }
    waitForStill(app)
    let hittable = element.isHittable && !isUnderKeyboard(app, element)
    XCTAssertTrue(hittable, "\(element) is not hittable after \(limit) drags", file: file, line: line)
    return hittable
  }

  @MainActor
  private func isUnderKeyboard(_ app: XCUIApplication, _ element: XCUIElement) -> Bool {
    let keyboard = app.keyboards.firstMatch
    guard keyboard.exists else { return false }
    return element.frame.midY > keyboard.frame.minY
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
  /// - With `overSheet`, an issue with no element while a sheet that fits its content is up
  ///   (setup's "Choose your email"). The page behind shows above the sheet, dimmed and,
  ///   rightly, out of the accessibility tree, so the audit reads its text as text with no
  ///   element. That page is audited on its own before the sheet opens; an issue that names
  ///   an element of the sheet still fails.
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
    _ app: XCUIApplication, atLargeText: Bool = false, overSheet: Bool = false, file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    var reported: [[String]] = []
    for attempt in 1...3 {
      waitForStill(app)
      do {
        let issues = try auditIssues(app, atLargeText: atLargeText, overSheet: overSheet)
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
  private func auditIssues(_ app: XCUIApplication, atLargeText: Bool, overSheet: Bool) throws -> [String] {
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
      if issue.element == nil, underHeader || overSheet { return true }
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

  /// A mailbox a connect just added, on Bank alerts: its row is listed and reads Syncing
  /// (checking for alerts) or, once checked, Connected. The row, not the toast that says
  /// "… connected. Checking for alerts.": the toast leaves after 4 s, which a slow CI
  /// runner's waits can outlast (AppModelTests checks its words).
  @MainActor
  func assertMailboxAdded(_ app: XCUIApplication, _ id: String, file: StaticString = #filePath, line: UInt = #line) {
    let row = el(app, "bankAlerts.mailbox.\(id)")
    XCTAssertTrue(row.waitForExistence(timeout: uiWait), "\(id) is not listed", file: file, line: line)
    let checking = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value IN %@", ["Syncing", "Connected"]), object: row)
    XCTAssertEqual(XCTWaiter().wait(for: [checking], timeout: uiWait), .completed,
                   "\(id) reads \(row.value ?? "nothing"), not Syncing or Connected", file: file, line: line)
  }

  /// The keyboard is up: each of `shown` is on screen above it (and above the dock's
  /// `button`, when there is one), and none of `hidden` (the dock's links) is there to
  /// cover a field. Attaches a screenshot.
  @MainActor
  func assertClearOfKeyboard(
    _ app: XCUIApplication, shown: [String], button: String? = nil, hidden: [String], _ name: String,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    let keyboard = app.keyboards.firstMatch
    XCTAssertTrue(keyboard.waitForExistence(timeout: uiWait), "\(name): the keyboard did not open", file: file,
                  line: line)
    waitForStill(app)
    for id in hidden {
      XCTAssertTrue(el(app, id).waitForNonExistence(timeout: uiWait), "\(name): \(id) stayed over the keyboard",
                    file: file, line: line)
    }
    let top = keyboard.frame.minY
    let dock = button.map { el(app, $0) }
    if let button, let dock {
      XCTAssertTrue(dock.exists && dock.isHittable, "\(name): \(button) can't be reached", file: file, line: line)
      XCTAssertLessThanOrEqual(dock.frame.maxY, top + 1, "\(name): \(button) is under the keyboard", file: file,
                               line: line)
    }
    for id in shown {
      let e = el(app, id)
      XCTAssertTrue(e.exists && e.isHittable, "\(name): \(id) can't be reached", file: file, line: line)
      XCTAssertLessThanOrEqual(e.frame.maxY, (dock?.frame.minY ?? top) + 1, "\(name): \(id) is covered",
                               file: file, line: line)
    }
    attach(app, name)
  }

  @MainActor
  func attach(_ app: XCUIApplication, _ name: String) {
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = name
    shot.lifetime = .keepAlways
    add(shot)
  }

  // MARK: Setup's keypad and split, for the setup and the journey tests

  /// Types digits on the app's keypad, key by key.
  @MainActor
  func typeOnKeypad(_ app: XCUIApplication, _ digits: String, file: StaticString = #filePath, line: UInt = #line) {
    for d in digits { tap(app, "keypad.\(d)", file: file, line: line) }
  }

  /// What setup's salary figure reads ("Amount", "25,000 dirhams").
  @MainActor
  func incomeFigure(_ app: XCUIApplication) -> String {
    let e = el(app, "income.figure")
    guard e.waitForExistence(timeout: uiWait) else { return "" }
    return [e.label, e.value as? String].compactMap { $0 }.joined(separator: " ")
  }

  /// Drags a split handle sideways by `steps` of 5% (a step is a twentieth of the bar
  /// between the two 20 pt handle slots, 322 pt on a 402 pt screen), as a finger does.
  @MainActor
  func nudge(_ handle: XCUIElement, steps: Int) {
    let start = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    let end = start.withOffset(CGVector(dx: 17 * CGFloat(steps), dy: 0))
    start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
  }
}

extension XCUIElement {
  /// Waits until the element has the keyboard focus.
  func waitForKeyboardFocus(timeout: TimeInterval = 5) -> Bool {
    let predicate = NSPredicate(format: "hasKeyboardFocus == true")
    return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: self)], timeout: timeout)
      == .completed
  }

  /// Waits until the element's value reads `value` (an adjustable's "55%").
  func waitForValue(_ value: String, timeout: TimeInterval = 5) -> Bool {
    let predicate = NSPredicate(format: "value == %@", value)
    return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: self)], timeout: timeout)
      == .completed
  }

  /// Waits until the element's label reads `label`.
  func waitForLabel(_ label: String, timeout: TimeInterval = uiWait) -> Bool {
    let predicate = NSPredicate(format: "label == %@", label)
    return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: self)], timeout: timeout)
      == .completed
  }

  /// Waits until the element's label contains `text`.
  func waitForLabel(containing text: String, timeout: TimeInterval = uiWait) -> Bool {
    let predicate = NSPredicate(format: "label CONTAINS %@", text)
    return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: self)], timeout: timeout)
      == .completed
  }
}
