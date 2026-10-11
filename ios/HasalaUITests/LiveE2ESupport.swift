import XCTest

// The live end-to-end tests' plumbing (LiveE2ETests; integration plan §4, Lane E). The
// harness, ios/scripts/e2e-app.sh, runs a local hasalad and passes its settings to the
// test runner as TEST_RUNNER_HASALA_E2E_* (xcodebuild strips the prefix). Without
// HASALA_E2E_API every live test is skipped, so a plain `xcodebuild test` of the UI
// tests is unaffected.
//
// The runner never talks to the server itself: the emailed codes, the account E1
// creates and the wake requests pass through files under the harness's temporary
// directory, which the simulator's processes can read and write.

/// What the harness set for this run.
struct LiveE2EEnvironment {
  /// The local hasalad, e.g. http://127.0.0.1:18453; the app gets it as its Debug-only
  /// `HASALA_API_BASE_URL` launch override.
  let api: String
  /// Where ios/scripts/e2e/mail-capture.ts writes each email as <n>.json.
  let mailDir: URL
  /// Shared between the tests of one run: account.json, wake-request / wake-sent.
  let stateDir: URL
  /// A review invite minted for this run (E1 signs up with it).
  let invite: String?

  static func current() throws -> LiveE2EEnvironment {
    let env = ProcessInfo.processInfo.environment
    func value(_ name: String) -> String? {
      for key in [name, "TEST_RUNNER_" + name] {
        if let v = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty { return v }
      }
      return nil
    }
    guard let api = value("HASALA_E2E_API") else {
      throw XCTSkip("A live end-to-end test: it runs only under ios/scripts/e2e-app.sh (TEST_RUNNER_HASALA_E2E_API is unset).")
    }
    guard let mail = value("HASALA_E2E_MAIL_DIR"), let state = value("HASALA_E2E_STATE") else {
      throw LiveE2EError("HASALA_E2E_API is set without HASALA_E2E_MAIL_DIR and HASALA_E2E_STATE")
    }
    return LiveE2EEnvironment(
      api: api, mailDir: URL(fileURLWithPath: mail, isDirectory: true),
      stateDir: URL(fileURLWithPath: state, isDirectory: true), invite: value("HASALA_E2E_INVITE"))
  }
}

struct LiveE2EError: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}

/// The account E1 creates and the later tests sign in to. Synthetic: an @example.test
/// address on a throwaway server; the file lives in the harness's temporary directory.
struct LiveE2EAccount: Codable, Equatable {
  var name: String
  var email: String
  var password: String
  var words: [String]

  /// A new address and password for this run: `e2e+<uuid>@example.test`, and a
  /// passphrase of 30-odd characters the password rules accept.
  static func fresh() -> LiveE2EAccount {
    let id = UUID().uuidString.lowercased()
    let salt = String(UUID().uuidString.lowercased().prefix(8))
    return LiveE2EAccount(
      name: "Maya Tester", email: "e2e+\(id)@example.test", password: "copper lantern \(salt) quietly", words: [])
  }
}

/// One email the capture received.
struct CapturedMail: Decodable {
  let to: String
  let subject: String
  let text: String
}

/// The figures the Maya sample shows on every device (Lane A's `expectMayaSample`:
/// 26 October transactions, 6 to review, 8 bills, the "Japan trip" project).
enum MayaSample {
  static let transactions = "26 transactions this month"
  static let toSort = "6 to sort"
  static let afterOneSorted = "5 to sort"
  static let bills = "8 tracked"
  static let project = "Japan trip"
}

/// The shared steps of the live tests. Subclasses get `e2e` in `setUpWithError` (or a
/// skip); the first `launchLive()` adds a handler for the system prompts a password app
/// meets on the simulator.
class LiveE2ECase: XCTestCase {
  private(set) var e2e: LiveE2EEnvironment!
  private var monitoring = false

  override func setUpWithError() throws {
    try super.setUpWithError()
    continueAfterFailure = false
    e2e = try LiveE2EEnvironment.current()
  }

  static let promptButtons = [
    "Not Now", "Choose My Own Password", "Don\u{2019}t Allow", "Don't Allow", "Never for This Website",
  ]

  // MARK: The app

  /// Launches the Debug build against the local server: no `-HasalaScenario`, so the
  /// live graph runs.
  @MainActor
  func launchLive() -> XCUIApplication {
    if !monitoring {
      monitoring = true
      // "Save Password?" (Not Now), the strong-password offer (Choose My Own Password)
      // and the notification permission (Don't Allow), when one of them blocks a step.
      _ = addUIInterruptionMonitor(withDescription: "System prompts") { alert in
        for title in LiveE2ECase.promptButtons where alert.buttons[title].exists {
          alert.buttons[title].tap()
          return true
        }
        return false
      }
    }
    let app = XCUIApplication()
    app.launchEnvironment["HASALA_API_BASE_URL"] = e2e.api
    app.launch()
    return app
  }

  @MainActor
  func el(_ app: XCUIApplication, _ id: String) -> XCUIElement {
    app.descendants(matching: .any)[id].firstMatch
  }

  /// Any element whose label contains `text` (static texts, buttons, combined cells).
  @MainActor
  func labelled(_ app: XCUIApplication, containing text: String) -> XCUIElement {
    app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
  }

  @MainActor
  func tap(_ app: XCUIApplication, _ id: String, timeout: TimeInterval = 15,
           file: StaticString = #filePath, line: UInt = #line) {
    let e = el(app, id)
    XCTAssertTrue(e.waitForExistence(timeout: timeout), "\(id) is missing", file: file, line: line)
    var tries = 0
    while !e.isHittable && tries < 4 {
      app.swipeUp()
      tries += 1
    }
    e.tap()
  }

  @MainActor
  func type(_ app: XCUIApplication, _ id: String, _ text: String, file: StaticString = #filePath, line: UInt = #line) {
    let e = el(app, id)
    XCTAssertTrue(e.waitForExistence(timeout: 15), "\(id) is missing", file: file, line: line)
    e.tap()
    e.typeText(text)
  }

  /// Types into a password field: the strong-password offer is declined first, and
  /// anything AutoFill put in the field is deleted.
  @MainActor
  func typePassword(_ app: XCUIApplication, _ id: String, _ password: String,
                    file: StaticString = #filePath, line: UInt = #line) {
    let e = el(app, id)
    XCTAssertTrue(e.waitForExistence(timeout: 15), "\(id) is missing", file: file, line: line)
    e.tap()
    dismissSystemPrompts(app)
    let filled = (e.value as? String) ?? ""
    if !filled.isEmpty, filled != e.placeholderValue {
      e.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: filled.count + 2))
    }
    e.typeText(password)
  }

  /// Taps away the system prompts a password app meets on the simulator, wherever they
  /// are drawn (the app or SpringBoard). Returns whether it tapped one.
  @MainActor
  @discardableResult
  func dismissSystemPrompts(_ app: XCUIApplication) -> Bool {
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    for host in [app, springboard] {
      for title in Self.promptButtons {
        let b = host.buttons[title].firstMatch
        if b.exists, b.isHittable {
          b.tap()
          return true
        }
      }
    }
    return false
  }

  /// Waits until one of `ids` exists and returns it, or nil after `timeout`.
  @MainActor
  func waitForAny(_ app: XCUIApplication, _ ids: [String], timeout: TimeInterval) -> String? {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      for id in ids where el(app, id).exists { return id }
      RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    } while Date() < deadline
    return nil
  }

  /// Waits until `element`'s label contains `text`.
  @MainActor
  func waitForLabel(_ element: XCUIElement, containing text: String, timeout: TimeInterval) -> Bool {
    let done = NSPredicate(format: "exists == true AND label CONTAINS %@", text)
    return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: done, object: element)], timeout: timeout)
      == .completed
  }

  /// Drives a fresh sign-in or the end of setup to Home: "Not now" on the notification
  /// step and "Go to Home" on the last one, whichever of them the account still needs.
  @MainActor
  func driveToHome(_ app: XCUIApplication, timeout: TimeInterval = 120,
                   file: StaticString = #filePath, line: UInt = #line) {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      guard let seen = waitForAny(app, ["home.hero.left", "notifications.notNow", "done.home", "boot.retry"],
                                  timeout: deadline.timeIntervalSinceNow)
      else { break }
      switch seen {
      case "home.hero.left": return
      case "boot.retry":
        attach(app, "Boot · could not open the account")
        XCTFail("the account gate stopped at its retry wall", file: file, line: line)
        return
      default:
        el(app, seen).tap()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
      }
    }
    attach(app, "Home never opened")
    XCTFail("Home did not open within \(Int(timeout)) s", file: file, line: line)
  }

  /// Signs out of this iPhone from the profile ("Sign out" and its confirmation).
  @MainActor
  func signOut(_ app: XCUIApplication) {
    app.buttons["header.profile"].firstMatch.tap()
    tap(app, "profile.signOut")
    let confirm = app.alerts.buttons["Sign out"].firstMatch
    XCTAssertTrue(confirm.waitForExistence(timeout: 10), "the sign-out confirmation did not appear")
    confirm.tap()
  }

  /// Password sign-in from the stories screen (C2-P on a new iPhone, C2b-P on one that
  /// was bound before).
  @MainActor
  func signInWithPassword(_ app: XCUIApplication, _ account: LiveE2EAccount) {
    tap(app, "stories.signIn", timeout: 30)
    type(app, "signIn.email", account.email)
    typePassword(app, "signIn.password", account.password)
    tap(app, "signIn.withPassword")
    dismissSystemPrompts(app)
  }

  // MARK: The figures

  /// The Maya sample's figures on this device: Activity's month and review count, the
  /// tracked bills in the profile, and the "Japan trip" project on Plan. Every check runs
  /// even when an earlier one fails, so one run reports them all.
  @MainActor
  func assertMayaFigures(_ app: XCUIApplication, toSort: String = MayaSample.toSort,
                         file: StaticString = #filePath, line: UInt = #line) {
    let stop = continueAfterFailure
    continueAfterFailure = true
    defer { continueAfterFailure = stop }

    app.tabBars.firstMatch.buttons["Activity"].tap()
    let count = el(app, "activity.count")
    XCTAssertTrue(waitForLabel(count, containing: MayaSample.transactions, timeout: 90),
                  "Activity reads '\(count.exists ? count.label : "nothing")', not '\(MayaSample.transactions)'",
                  file: file, line: line)
    XCTAssertTrue(app.staticTexts[toSort].waitForExistence(timeout: 30), "Activity does not say '\(toSort)'",
                  file: file, line: line)
    attach(app, "Activity")

    app.buttons["header.profile"].firstMatch.tap()
    let bills = el(app, "profile.bills")
    XCTAssertTrue(waitForLabel(bills, containing: MayaSample.bills, timeout: 15),
                  "Profile's Bills row reads '\(bills.exists ? bills.label : "nothing")', not '\(MayaSample.bills)'",
                  file: file, line: line)
    attach(app, "Profile")
    if el(app, "profile.close").exists { el(app, "profile.close").tap() }

    app.tabBars.firstMatch.buttons["Plan"].tap()
    let project = labelled(app, containing: MayaSample.project)
    var swipes = 0
    while !project.exists && swipes < 8 {
      app.swipeUp()
      swipes += 1
    }
    XCTAssertTrue(project.waitForExistence(timeout: 10), "Plan shows no '\(MayaSample.project)'", file: file, line: line)
    attach(app, "Plan")
    app.tabBars.firstMatch.buttons["Home"].tap()
  }

  // MARK: Files shared with the harness

  var accountURL: URL { e2e.stateDir.appendingPathComponent("account.json") }

  func saveAccount(_ account: LiveE2EAccount) throws {
    let data = try JSONEncoder().encode(account)
    try data.write(to: accountURL, options: .atomic)
  }

  func loadAccount() throws -> LiveE2EAccount {
    guard let data = try? Data(contentsOf: accountURL) else {
      throw LiveE2EError("no \(accountURL.path): test01_pathB creates the account the later tests use")
    }
    return try JSONDecoder().decode(LiveE2EAccount.self, from: data)
  }

  /// The capture's files so far, so a wait can ignore the emails sent before a step.
  func capturedMailNames() -> Set<String> {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: e2e.mailDir.path)) ?? []
    return Set(names.filter { $0.hasSuffix(".json") })
  }

  /// The six-digit code in the newest email to `address` that is not in `seen`.
  func waitForEmailCode(to address: String, excluding seen: Set<String>, timeout: TimeInterval = 60) throws -> String {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      for name in capturedMailNames().subtracting(seen).sorted().reversed() {
        guard let data = try? Data(contentsOf: e2e.mailDir.appendingPathComponent(name)),
          let mail = try? JSONDecoder().decode(CapturedMail.self, from: data), mail.to == address
        else { continue }
        if let match = mail.text.firstMatch(of: /code is ([0-9]{6})/) { return String(match.1) }
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    } while Date() < deadline
    throw LiveE2EError("no email with a code reached \(address) within \(Int(timeout)) s (capture: \(e2e.mailDir.path))")
  }

  /// Asks the harness for a silent push to this simulator (`simctl push` with
  /// ios/scripts/e2e/wake.apns) and waits until it was sent.
  func requestWake(timeout: TimeInterval = 30) throws {
    let sent = e2e.stateDir.appendingPathComponent("wake-sent")
    let failed = e2e.stateDir.appendingPathComponent("wake-failed")
    try? FileManager.default.removeItem(at: sent)
    try Data("wake\n".utf8).write(to: e2e.stateDir.appendingPathComponent("wake-request"), options: .atomic)
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      if FileManager.default.fileExists(atPath: sent.path) { return }
      if FileManager.default.fileExists(atPath: failed.path) { throw LiveE2EError("the harness's simctl push failed") }
      RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    } while Date() < deadline
    throw LiveE2EError("the harness sent no push within \(Int(timeout)) s (is ios/scripts/e2e-app.sh running?)")
  }
}
