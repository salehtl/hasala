import XCTest

/// The app end to end against a local hasalad (integration plan §4, Lane E: E1-E5), on
/// two simulators, A and B. Run by ios/scripts/e2e-app.sh, one test per
/// `xcodebuild test-without-building`, in this order; each builds on the ones before it
/// (E1 creates the account the others use). Skipped unless the harness set
/// TEST_RUNNER_HASALA_E2E_API (see LiveE2ESupport).
///
/// Passwords only: passkeys need the real relying party (hasala.app), which a local
/// server can't be. Gmail and the full upload/pull/replay chain from mail are covered at
/// core level (HasalaCoreE2ETests); here the data is the review account's sample.
final class LiveE2ETests: LiveE2ECase {
  /// A fresh simulator opens the live app (no mock scenario) on the stories, and the
  /// account gate does not stop on its retry wall.
  @MainActor
  func test00_launch() throws {
    let app = launchLive()
    XCTAssertTrue(el(app, "stories.getStarted").waitForExistence(timeout: 30), "the stories did not open")
    XCTAssertTrue(el(app, "stories.signIn").exists)
    XCTAssertFalse(el(app, "boot.retry").exists)
    attach(app, "Launch · stories")
  }

  /// E1 on A, path B (spec §2.5): a review invite, about you, the emailed code, a
  /// password, the 12 words read off the screen and four of them checked, ENBD, "Use
  /// sample data", notifications allowed, then Maya's month on Home, Activity, Bills and
  /// Plan, and Home's "Sample data" label.
  @MainActor
  func test01_pathB() throws {
    let invite = try XCTUnwrap(e2e.invite, "the harness passes a review invite (HASALA_E2E_INVITE)")
    var account = LiveE2EAccount.fresh()
    let app = launchLive()

    tap(app, "stories.getStarted", timeout: 30)
    tap(app, "welcome.join")
    type(app, "invite.field", invite)
    tap(app, "invite.continue")

    type(app, "about.name", account.name)
    type(app, "about.email", account.email)
    let before = capturedMailNames()
    tap(app, "about.continue")
    attach(app, "About you")

    // The code email (signup/begin, #43) through the capture.
    XCTAssertTrue(el(app, "code.field").waitForExistence(timeout: 30), "the code screen did not open")
    let code = try waitForEmailCode(to: account.email, excluding: before)
    type(app, "code.field", code)

    // "Use a password instead".
    tap(app, "method.password", timeout: 30)
    tap(app, "method.continue")
    typePassword(app, "password.new", account.password)
    typePassword(app, "password.confirm", account.password)
    XCTAssertTrue(app.staticTexts["Passwords match."].waitForExistence(timeout: 10), "the passwords do not match")
    attach(app, "Create a password")
    tap(app, "password.create")
    dismissSystemPrompts(app)

    // The 12 words, read off the grid ("Word 3, scissors").
    tap(app, "phrase.start", timeout: 30)
    tap(app, "phrase.reveal")
    account.words = try readPhrase(app)
    try saveAccount(account)
    attach(app, "Recovery phrase")
    tap(app, "phrase.written")

    // Check 4: each slot asks for a word by position.
    for i in 0..<4 {
      let slot = el(app, "phrase.slot.\(i)")
      XCTAssertTrue(slot.waitForExistence(timeout: 10))
      let position = try XCTUnwrap(Int(slot.label.replacingOccurrences(of: "Word ", with: "")),
                                   "slot \(i) reads '\(slot.label)'")
      tap(app, "chip.\(account.words[position - 1])")
    }
    attach(app, "Check 4 words")
    tap(app, "phrase.confirm")

    // Publishing the keys (password register #45, then GET /keys and /account).
    tap(app, "ready.continue", timeout: 90)

    // Setup: ENBD, then the review account's sample instead of Gmail.
    tap(app, "bank.enbd", timeout: 30)
    tap(app, "bank.continue")
    let sample = el(app, "gmail.sample")
    XCTAssertTrue(sample.waitForExistence(timeout: 60),
                  "no 'Use sample data': the review flag (#40 review_account) did not reach setup")
    attach(app, "Gmail · sample offered")
    sample.tap()

    // Notifications: Allow (the reviewer taps "Not now"; either finishes setup). Allowing
    // is what lets A receive E3's push: the simulator delivers only a push with visible
    // content, and only to an app the user allowed (see ios/scripts/e2e/wake.apns).
    try recordNotificationsAllowed(allowNotifications(app))
    driveToHome(app)
    try markSignedIn(true)
    attach(app, "Home")

    assertMayaFigures(app)
    XCTAssertTrue(el(app, "home.sampleData").waitForExistence(timeout: 10),
                  "Home shows no 'Sample data' label on the review account")
  }

  /// E2 on B: a new iPhone signs in with the password (C2-P), unlocks with the 12 words
  /// pasted into one field (C3), pulls and replays Maya's month, then sorts one review row.
  @MainActor
  func test02_pathA_secondDevice() throws {
    let account = try loadAccount()
    let app = launchLive()
    signInWithPassword(app, account)

    // A password can't unlock the data on a new iPhone: the words do.
    let next = waitForAny(app, ["unlock.words", "phraseEntry.field"], timeout: 60)
    XCTAssertNotNil(next, "the unlock screen did not open after the password sign-in")
    if next == "unlock.words" { tap(app, "unlock.words") }
    type(app, "phraseEntry.field", account.words.joined(separator: " "))
    attach(app, "Unlock · 12 words")
    tap(app, "unlock.submit")
    tap(app, "unlock.open", timeout: 120)
    driveToHome(app)
    try markSignedIn(true)

    assertMayaFigures(app)
    continueAfterFailure = false

    // Sort the first review card as a transfer (no rule: "Always use" is off for it).
    app.tabBars.firstMatch.buttons["Activity"].tap()
    tap(app, "activity.startReview")
    let position = el(app, "review.position")
    XCTAssertTrue(waitForLabel(position, containing: "1 of 6", timeout: 15),
                  "the deck reads '\(position.exists ? position.label : "nothing")'")
    tap(app, "review.pill.transfer")
    tap(app, "pick.sort")
    XCTAssertTrue(waitForLabel(position, containing: "2 of 6", timeout: 15), "the card was not sorted")
    attach(app, "Review · one sorted")
    tap(app, "review.close")
    XCTAssertTrue(app.staticTexts[MayaSample.afterOneSorted].waitForExistence(timeout: 15))

    // Leave time for the coordinator's authored run to seal and upload the edit (#30)
    // before the next test relaunches anything.
    RunLoop.current.run(until: Date().addingTimeInterval(10))
  }

  /// E3 on A: the session survived the relaunch (Keychain), sign out, sign in again with
  /// the password (C2b-P: this iPhone is still bound, so no words and the data is kept),
  /// then a push (`simctl push`, content-available) runs the coordinator's wake, and B's
  /// sorted card shows here. The sign-in's own pull may already have brought it; the
  /// push must be accepted (when E1 could allow notifications) and leave the figures right.
  @MainActor
  func test03_rebind() throws {
    let account = try loadAccount()
    let app = launchLive()
    let first = waitForAny(app, ["home.hero.left", "stories.signIn"], timeout: 60)
    XCTAssertEqual(first, "home.hero.left", "A relaunched signed out: its session did not survive in the Keychain")
    signOut(app)
    XCTAssertTrue(el(app, "stories.signIn").waitForExistence(timeout: 30), "sign-out did not reach the stories")
    try markSignedIn(false)

    signInWithPassword(app, account)
    let back = waitForAny(app, ["home.hero.left", "unlock.words", "phraseEntry.field", "notifications.notNow"],
                          timeout: 90)
    XCTAssertTrue(back == "home.hero.left" || back == "notifications.notNow",
                  "signing in again on a bound iPhone asked for \(back ?? "nothing") instead of opening the kept data")
    driveToHome(app)
    try markSignedIn(true)
    attach(app, "Signed in again")

    if let refused = try requestWake() {
      if notificationsAllowed {
        XCTFail("simctl push was refused although A allowed notifications: \(refused)")
      } else {
        // E1 met no permission alert, so the simulator refuses every push to the app
        // (UNErrorDomain 2003): reported as an expected failure, not hidden.
        XCTExpectFailure("the simulator refuses a push to an app without notification permission") {
          XCTFail("simctl push was refused: \(refused)")
        }
      }
    }
    app.tabBars.firstMatch.buttons["Activity"].tap()
    XCTAssertTrue(app.staticTexts[MayaSample.afterOneSorted].waitForExistence(timeout: 60),
                  "B's sorted card did not reach A")
    XCTAssertTrue(waitForLabel(el(app, "activity.count"), containing: MayaSample.transactions, timeout: 5))
    attach(app, "Activity after the wake")
  }

  /// E4 on B: Profile › Delete your account, confirmed with the password and this
  /// iPhone's key, ends on the stories.
  @MainActor
  func test04_delete() throws {
    let account = try loadAccount()
    let app = launchLive()
    XCTAssertEqual(waitForAny(app, ["home.hero.left", "stories.signIn"], timeout: 60), "home.hero.left",
                   "B relaunched signed out: its session did not survive in the Keychain")

    app.buttons["header.profile"].firstMatch.tap()
    // The profile's own row (Lane C), else Sign-in & security's.
    if waitForAny(app, ["profile.delete"], timeout: 5) != nil {
      tap(app, "profile.delete")
    } else {
      tap(app, "profile.security")
      tap(app, "security.delete", timeout: 20)
    }
    tap(app, "delete.confirm", timeout: 20)
    let delete = app.alerts.buttons["Delete"].firstMatch
    XCTAssertTrue(delete.waitForExistence(timeout: 10), "the delete confirmation did not appear")
    delete.tap()

    typePassword(app, "confirm.password", account.password)
    attach(app, "Delete · confirm it's you")
    tap(app, "confirm.submit")
    XCTAssertTrue(el(app, "stories.getStarted").waitForExistence(timeout: 60), "deleting did not end on the stories")
    try markSignedIn(false)
    attach(app, "Deleted")
  }

  /// E5 on A: the account was deleted on B; A's next call gets 410, A wipes itself and
  /// shows the stories.
  @MainActor
  func test05_deletedElsewhere() throws {
    // Only meaningful on a device that still holds the account: one that was never
    // signed in shows the stories anyway.
    XCTAssertTrue(wasLeftSignedIn, "A was not left signed in by test01_pathB / test03_rebind")
    let app = launchLive()
    XCTAssertTrue(el(app, "stories.getStarted").waitForExistence(timeout: 90),
                  "A did not wipe itself after the account was deleted elsewhere")
    attach(app, "Deleted elsewhere")
    try markSignedIn(false)
    app.terminate()
    // Nothing is left to open: a second launch also starts signed out.
    let again = launchLive()
    XCTAssertTrue(el(again, "stories.getStarted").waitForExistence(timeout: 30))
  }

  // MARK: Helpers

  /// The revealed phrase grid's words, in order ("Word 1, absurd" ... "Word 12, camera").
  @MainActor
  private func readPhrase(_ app: XCUIApplication) throws -> [String] {
    let grid = el(app, "phrase.grid")
    XCTAssertTrue(grid.waitForExistence(timeout: 10))
    var words: [Int: String] = [:]
    let deadline = Date().addingTimeInterval(10)
    while words.count < 12 && Date() < deadline {
      let cells = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Word '"))
      for cell in cells.allElementsBoundByIndex {
        if let m = cell.label.firstMatch(of: /^Word ([0-9]+), ([a-z]+)$/), let n = Int(m.1) {
          words[n] = String(m.2)
        }
      }
      if words.count < 12 { RunLoop.current.run(until: Date().addingTimeInterval(0.5)) }
    }
    let ordered = (1...12).compactMap { words[$0] }
    guard ordered.count == 12 else { throw LiveE2EError("read \(words.count) of the 12 words off the screen") }
    return ordered
  }
}
