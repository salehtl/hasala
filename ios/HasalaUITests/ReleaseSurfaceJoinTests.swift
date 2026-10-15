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
    tap(app, "ready.continue")
    XCTAssertTrue(el(app, "bank.enbd").waitForExistence(timeout: 10), "setup did not follow")
  }
}
