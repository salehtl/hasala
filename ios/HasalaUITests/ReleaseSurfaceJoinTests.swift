import XCTest

/// Joining on the Release surface: no promise of getting back in with an emailed code (C4
/// is not in the beta), and no placeholder on any screen.
final class ReleaseSurfaceJoinTests: ReleaseSurfaceTestCase {
  /// Path B, as a reviewer meets it: join with a password and the 12 words, up to the
  /// hand-off to setup.
  @MainActor
  func testSignupPromisesOnlyWhatWorks() throws {
    let app = launchRelease("newUser", waitForHome: false)
    tap(app, "stories.getStarted", timeout: 15)
    assertNoOutlook(app, "Welcome")
    tap(app, "welcome.join")
    assertNoPlaceholders(app, "Invite code")
    type(app, "invite.field", "ABCDEFGHIJKLMNOPQRSTUVWX")
    tap(app, "invite.continue")
    type(app, "about.name", "Maya Rahman")
    type(app, "about.email", "maya@example.com")
    assertNoPlaceholders(app, "About you")
    tap(app, "about.continue")
    type(app, "code.field", "123456")
    XCTAssertTrue(el(app, "method.password").waitForExistence(timeout: 10))
    attach(app, "Release · How do you want to sign in")
    assertNoPlaceholders(app, "Sign-in method")
    tap(app, "method.password")
    tap(app, "method.continue")
    type(app, "password.new", "copper lantern quietly 42")
    type(app, "password.confirm", "copper lantern quietly 42")
    assertNoPlaceholders(app, "Password")
    tap(app, "password.create")

    // The words: no promise of getting back in with an emailed code (C4 is not in the beta).
    XCTAssertTrue(el(app, "phrase.start").waitForExistence(timeout: 10))
    attach(app, "Release · 12 words")
    assertNoPlaceholders(app, "12 words")
    assertNoText(app, ["code we email"], "12 words")
    assertText(app, "They unlock your data on a new iPhone once you sign in there.", "12 words")
    try audit(app)
    tap(app, "phrase.start")
    tap(app, "phrase.reveal")
    tap(app, "phrase.written")
    XCTAssertTrue(el(app, "ready.continue").waitForExistence(timeout: 10))
    assertNoPlaceholders(app, "Account ready")
    assertNoOutlook(app, "Account ready")
    // "What Hasala reads, and what it doesn't": Google alone (plan B4.6 rule 4).
    tap(app, "ready.whoSees")
    XCTAssertTrue(el(app, "whoSees.close").waitForExistence(timeout: 10))
    assertNoOutlook(app, "Who can see what")
    tap(app, "whoSees.close")
    tap(app, "ready.continue")
    XCTAssertTrue(el(app, "bank.enbd").waitForExistence(timeout: 10), "setup did not follow")
  }

  /// The stories and "Who can see what" name only what a Release build connects: the mail
  /// row says "Google", never Microsoft (plan B4.6 rule 4), and nothing reads like a
  /// placeholder.
  @MainActor
  func testStoriesAndWhoCanSeeWhatNameGoogleOnly() throws {
    let app = launchRelease("newUser", waitForHome: false, screen: "welcome.whoSees")
    XCTAssertTrue(el(app, "whoSees.close").waitForExistence(timeout: 15))
    let google = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Google'")).firstMatch
    XCTAssertTrue(google.waitForExistence(timeout: 5), "the mail row does not name Google")
    assertNoOutlook(app, "Who can see what")
    assertNoPlaceholders(app, "Who can see what")
    attach(app, "Release · Who can see what")
    try audit(app)
    tap(app, "whoSees.close")
    XCTAssertTrue(el(app, "stories.getStarted").waitForExistence(timeout: 10))
    assertNoOutlook(app, "Stories")
    assertNoPlaceholders(app, "Stories")
  }
}
