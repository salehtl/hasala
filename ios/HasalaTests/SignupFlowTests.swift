import Foundation
import HasalaDesign
import SwiftUI
import Testing

@testable import Hasala

/// Signup (C1, C1-P), the interrupted signup and invite links, on the in-memory mock.
@MainActor
@Suite("Signup flows")
struct SignupFlowTests: AccountSuite {
  @Test func typedCodeSignupWithPasskey() async throws {
    let account = MockAccountService()
    account.delay = .zero
    let m = SignupModel(account: account)
    m.inviteText = Self.code
    m.submitInvite()
    #expect(m.path == [.aboutYou])
    m.displayName = " Maya  Rahman "
    m.email = "Maya@Example.com"
    await m.submitAboutYou()
    #expect(m.ticket?.emailProven == false)
    #expect(m.path.last == .verifyEmail)
    #expect(m.email == "maya@example.com")

    m.code = "000000"
    await m.submitCode()
    #expect(m.failure == .codeWrong(triesLeft: 4))
    // "Resend code" starts a fresh ceremony and resets the tries.
    let firstID = m.ticket?.id
    await m.resendCode()
    #expect(m.ticket?.id != firstID)
    m.code = "000001"
    await m.submitCode()
    #expect(m.failure == .codeWrong(triesLeft: 4))
    m.code = MockAccountService.emailCode
    await m.submitCode()
    #expect(m.path.last == .method)

    m.method = .passkey
    await m.continueWithMethod()
    #expect(m.path.last == .phraseIntro)
    #expect(m.phrase?.words == MockAccountService.phraseWords)

    // The words are shown, then "I've written them down" publishes: no word check.
    m.go(.phraseShow)
    #expect(!m.phraseSeen)
    showPhrase(m)
    #expect(m.phraseSeen)
    m.phraseRevealed = false  // "Hide" keeps them seen
    #expect(m.phraseSeen)
    await m.finish()
    #expect(m.path.last == .accountReady)
    #expect(m.profile == AccountProfile(displayName: "Maya Rahman", email: "maya@example.com", method: .passkey))
    #expect(m.phrase == nil)
  }

  @Test func linkWithKeySkipsTheEmailCode() async throws {
    let account = MockAccountService()
    account.delay = .zero
    let m = SignupModel(account: account)
    let key = String(repeating: "k", count: 43)
    m.applyInviteLink(try #require(InviteLink.parse(URL(string: "https://hasala.app/i/\(Self.code)#\(key)")!)))
    #expect(m.inviteFromLink)
    m.submitInvite()
    m.displayName = "Maya Rahman"
    m.email = "maya@example.com"
    await m.submitAboutYou()
    #expect(m.ticket?.emailProven == true)
    #expect(m.path.last == .method)
  }

  @Test func editingALinkedCodeDropsTheKey() throws {
    let m = SignupModel(account: MockAccountService())
    let key = String(repeating: "k", count: 43)
    m.applyInviteLink(try #require(InviteLink.parse(URL(string: "https://hasala.app/i/\(Self.code)#\(key)")!)))
    m.inviteText = "ABCDEFGHIJKLMNOPQRSTUVWY"
    #expect(!m.inviteFromLink)
  }

  @Test func unknownInviteGoesBackToTheCode() async {
    let account = MockAccountService()
    account.delay = .zero
    let m = SignupModel(account: account)
    m.inviteText = "ZZZZ" + String(Self.code.dropFirst(4))
    m.path = [.welcome, .invite]
    m.submitInvite()
    m.displayName = "Maya"
    m.email = "maya@example.com"
    await m.submitAboutYou()
    #expect(m.failure == .notInvited)
    #expect(m.path == [.welcome, .invite])
  }

  @Test func badNameAndEmailAreCaughtLocally() async {
    let m = SignupModel(account: MockAccountService())
    m.inviteText = Self.code
    m.displayName = "M4ya"
    m.email = "nope"
    await m.submitAboutYou()
    #expect(m.nameError == AuthFailure.badName.message)
    #expect(m.emailError == AuthFailure.badEmail.message)
    #expect(m.ticket == nil)
  }

  @Test func passwordSignupPublishesOnlyAfterTheWordsWereShown() async {
    let account = MockAccountService()
    account.delay = .zero
    let m = SignupModel(account: account)
    m.inviteText = Self.code
    m.displayName = "Maya Rahman"
    m.email = "maya@example.com"
    await m.submitAboutYou()
    m.code = MockAccountService.emailCode
    await m.submitCode()
    m.method = .password
    await m.continueWithMethod()
    #expect(m.path.last == .password)
    m.newPassword = "short"
    m.confirmPassword = "short"
    #expect(!m.passwordReady)
    m.newPassword = "copper lantern quietly 42"
    m.confirmPassword = "copper lantern quietly 42"
    #expect(m.passwordReady)
    m.submitPassword()
    #expect(m.path.last == .phraseIntro)
    #expect(account.profile == nil)  // nothing published yet
    await m.finish()
    #expect(account.profile == nil)  // nor before the words were shown
    showPhrase(m)
    await m.finish()
    #expect(account.profile?.method == .password)
    #expect(m.newPassword.isEmpty)
    #expect(m.phrase == nil)
  }

  /// "I've written them down" before the words were ever shown publishes nothing (Paper
  /// F6Q draws it disabled; the model refuses it too).
  @Test func finishBeforeTheRevealPublishesNothing() async {
    let account = MockAccountService()
    account.delay = .zero
    let m = SignupModel(account: account)
    m.inviteText = Self.code
    m.displayName = "Maya Rahman"
    m.email = "maya@example.com"
    await m.submitAboutYou()
    m.code = MockAccountService.emailCode
    await m.submitCode()
    m.method = .passkey
    await m.continueWithMethod()
    #expect(m.phrase != nil)
    await m.finish()
    #expect(account.profile == nil)
    #expect(m.path.last == .phraseIntro)
    #expect(m.phrase?.words == MockAccountService.phraseWords)
  }

  /// While the screen is recorded or mirrored the grid draws dots, so a reveal then shows
  /// the person nothing: it doesn't count, and "I've written them down" publishes nothing.
  /// Once capture stops, a reveal counts.
  @Test func aRevealWhileTheScreenIsCapturedPublishesNothing() async {
    let account = MockAccountService()
    account.delay = .zero
    let m = SignupModel(account: account)
    m.inviteText = Self.code
    m.displayName = "Maya Rahman"
    m.email = "maya@example.com"
    await m.submitAboutYou()
    m.code = MockAccountService.emailCode
    await m.submitCode()
    m.method = .password
    await m.continueWithMethod()
    m.newPassword = "copper lantern quietly 42"
    m.confirmPassword = "copper lantern quietly 42"
    m.submitPassword()
    m.go(.phraseShow)

    m.phraseMasked = true
    showPhrase(m)
    #expect(!m.phraseRevealed && !m.phraseSeen)
    await m.finish()
    #expect(account.profile == nil)
    #expect(m.path.last == .phraseShow)

    // Capture starting while the words are up hides them; what was drawn before counts.
    m.phraseMasked = false
    showPhrase(m)
    #expect(m.phraseRevealed && m.phraseSeen)
    m.phraseMasked = true
    #expect(!m.phraseRevealed && m.phraseSeen)
    await m.finish()
    #expect(account.profile?.method == .password)
  }

  @Test func anInterruptedSignupMakesANewPhraseThenOpensSetup() async {
    let account = MockAccountService(existing: .passkey, signedIn: true)
    account.resumeOutcome = .needsKeys
    let session = AccountSession(services: services(account), phase: .checking)
    await session.resume()
    #expect(session.phase == .needsKeys)
    let m = SignupModel(account: account)
    m.startReplacement()
    #expect(m.replacing)
    #expect(m.phrase?.words.count == 12)
    await m.finish()
    #expect(m.path.isEmpty)  // not before the words were shown
    showPhrase(m)
    await m.finish()
    #expect(m.path.last == .accountReady)
    #expect(m.phrase == nil)
    session.accountCreated()
    #expect(session.phase == .onboarding(.bank))
  }

  // MARK: Back and Forward (plan B3: everything typed stays)

  /// Typed code to the method screen, then the system back twice: About you still holds the
  /// name and the address, and Continue carries on with the open ticket (no second signup,
  /// no second email) straight to the method, the address already confirmed.
  @Test func backFromTheMethodKeepsNameAndEmail() async {
    let account = CountingAccount()
    let m = SignupModel(account: account)
    m.path = [.welcome, .invite]
    m.inviteText = Self.code
    m.submitInvite()
    m.displayName = "Maya Rahman"
    m.email = "maya@example.com"
    await m.submitAboutYou()
    m.code = MockAccountService.emailCode
    await m.submitCode()
    #expect(m.path == [.welcome, .invite, .aboutYou, .verifyEmail, .method])
    m.method = .password

    // The system back button pops the stack through `navigationPath`.
    m.navigationPath = Array(m.path.dropLast())
    m.navigationPath = Array(m.path.dropLast())
    #expect(m.path.last == .aboutYou)
    #expect(m.displayName == "Maya Rahman" && m.email == "maya@example.com")
    #expect(m.emailConfirmed)

    await m.submitAboutYou()
    #expect(account.signupsBegun == 1)
    #expect(m.path.last == .method)
    #expect(m.method == .password)

    // A changed address is a new signup, and needs its own code.
    m.navigationPath = Array(m.path.dropLast())
    m.email = "maya.k@example.com"
    #expect(!m.emailConfirmed)
    await m.submitAboutYou()
    #expect(account.signupsBegun == 2)
    #expect(m.path.last == .verifyEmail)
  }

  /// The link path, Back to About you, then a changed name: the screen still promises no
  /// code, and Continue keeps the promise. The new signup (the name is part of it) sends the
  /// link's key again, so the address is proven and no code is emailed. A changed address
  /// loses the "Confirmed" chip and says when there's no code.
  @Test func aChangedNameOnTheLinkPathStillNeedsNoCode() async throws {
    let account = CountingAccount()
    let m = SignupModel(account: account)
    let key = String(repeating: "k", count: 43)
    m.applyInviteLink(try #require(InviteLink.parse(URL(string: "https://hasala.app/i/\(Self.code)#\(key)")!)))
    m.path = [.welcome, .inviteReady]
    m.submitInvite()
    m.displayName = "Maya Rahman"
    m.email = "maya@example.com"
    #expect(m.emailHelp == "If it's the address your invite went to, there's no code. Security alerts go here.")
    await m.submitAboutYou()
    #expect(m.ticket?.emailProven == true && m.path.last == .method)

    m.navigationPath = Array(m.path.dropLast())
    #expect(m.path.last == .aboutYou)
    m.displayName = "Maya K Rahman"
    #expect(m.emailConfirmed)
    #expect(m.emailHelp == "Your invite link confirmed it, so there's no code. Security alerts go here.")
    await m.submitAboutYou()
    #expect(account.signupsBegun == 2)
    #expect(m.ticket?.emailProven == true && m.ticket?.displayName == "Maya K Rahman")
    #expect(m.path.last == .method)

    m.navigationPath = Array(m.path.dropLast())
    m.email = "maya.k@example.com"
    #expect(!m.emailConfirmed)
    #expect(m.emailHelp == "If it's the address your invite went to, there's no code. Security alerts go here.")
  }

  /// The typed-code path, Back to About you, then a changed name: a new signup needs a new
  /// code, so "Your code confirmed it." and the chip go before Continue, not after.
  @Test func aChangedNameOnTheTypedPathSaysANewCodeIsComing() async {
    let account = CountingAccount()
    let m = SignupModel(account: account)
    m.path = [.welcome, .invite]
    m.inviteText = Self.code
    m.submitInvite()
    m.displayName = "Maya Rahman"
    m.email = "maya@example.com"
    await m.submitAboutYou()
    m.code = MockAccountService.emailCode
    await m.submitCode()
    m.navigationPath = Array(m.path.dropLast(2))
    #expect(m.path.last == .aboutYou)
    #expect(m.emailConfirmed)
    #expect(m.emailHelp == "Your code confirmed it. Security alerts go here.")

    m.displayName = "Maya K Rahman"
    #expect(!m.emailConfirmed)
    #expect(m.emailHelp == "We'll send a code to confirm it. Security alerts go here too.")
    await m.submitAboutYou()
    #expect(account.signupsBegun == 2)
    #expect(m.path.last == .verifyEmail)
    #expect(m.codeState(now: .now) == .typing)
  }

  /// A link without its key proves nothing, so About you doesn't promise "no code".
  @Test func aLinkWithoutItsKeyPromisesACode() async throws {
    let m = SignupModel(account: CountingAccount())
    m.applyInviteLink(try #require(InviteLink.parse(URL(string: "https://hasala.app/i/\(Self.code)")!)))
    #expect(m.inviteFromLink && !m.linkProvesAddress)
    m.submitInvite()
    m.displayName = "Maya Rahman"
    m.email = "maya@example.com"
    #expect(m.emailHelp == "We'll send a code to confirm it. Security alerts go here too.")
    await m.submitAboutYou()
    #expect(m.ticket?.emailProven == false && m.path.last == .verifyEmail)
  }

  /// Five wrong codes use the code up. "Change email" (or the system back), then Continue
  /// with nothing changed, comes back to the same signup with the code still used up: the
  /// cells stay expired with "Send a new code", not ready for a seventh try the server would
  /// refuse. A new code starts clean.
  @Test func aUsedUpCodeStaysUsedUpThroughBackAndForward() async {
    let account = CountingAccount()
    let m = SignupModel(account: account)
    m.path = [.welcome, .invite]
    m.inviteText = Self.code
    m.submitInvite()
    m.displayName = "Maya Rahman"
    m.email = "maya@example.com"
    await m.submitAboutYou()
    for _ in 0..<5 {
      m.code = "000000"
      await m.submitCode()
    }
    #expect(m.codeState(now: .now) == .expired)

    m.back()  // "Change email"
    #expect(m.path.last == .aboutYou && m.failure == nil)
    await m.submitAboutYou()
    #expect(account.signupsBegun == 1)
    #expect(m.path.last == .verifyEmail)
    #expect(m.codeState(now: .now) == .expired)

    // The system back and Forward again: still used up.
    m.navigationPath = Array(m.path.dropLast())
    await m.submitAboutYou()
    #expect(m.codeState(now: .now) == .expired)

    await m.resendCode()
    #expect(m.codeState(now: .now) == .typing)
    m.code = MockAccountService.emailCode
    await m.submitCode()
    #expect(m.path.last == .method)
  }

  /// The password and the "Show" choice stay through Back and Forward, so Create account is
  /// ready again without typing.
  @Test func backAndForwardKeepThePassword() async {
    let m = SignupModel(account: CountingAccount())
    m.inviteText = Self.code
    m.submitInvite()
    m.displayName = "Maya Rahman"
    m.email = "maya@example.com"
    await m.submitAboutYou()
    m.code = MockAccountService.emailCode
    await m.submitCode()
    m.method = .password
    await m.continueWithMethod()
    m.newPassword = "copper lantern quietly 42"
    m.confirmPassword = "copper lantern quietly 42"
    m.passwordShown = true
    m.navigationPath = Array(m.path.dropLast())
    #expect(m.path.last == .method)
    await m.continueWithMethod()
    #expect(m.path.last == .password)
    #expect(m.passwordReady && m.passwordShown)
  }

  /// Back to the method after the passkey was saved, then Forward again: no second Face ID
  /// sheet for the same signup, and the same words.
  @Test func aSavedPasskeyIsNeverSavedTwice() async {
    let account = CountingAccount()
    let m = SignupModel(account: account)
    m.inviteText = Self.code
    m.submitInvite()
    m.displayName = "Maya Rahman"
    m.email = "maya@example.com"
    await m.submitAboutYou()
    m.code = MockAccountService.emailCode
    await m.submitCode()
    await m.continueWithMethod()
    #expect(account.passkeysSaved == 1 && m.passkeyRegistered)
    let words = m.phrase?.words
    m.navigationPath = Array(m.path.dropLast())
    #expect(m.path.last == .method)
    await m.continueWithMethod()
    #expect(account.passkeysSaved == 1)
    #expect(m.path.last == .phraseIntro)
    #expect(m.phrase?.words == words)
  }

  @Test func passwordBackAndCreateAgainKeepsThePhrase() async {
    let account = CountingAccount()
    let m = SignupModel(account: account)
    m.inviteText = Self.code
    m.submitInvite()
    m.displayName = "Maya Rahman"
    m.email = "maya@example.com"
    await m.submitAboutYou()
    m.code = MockAccountService.emailCode
    await m.submitCode()
    m.method = .password
    await m.continueWithMethod()
    m.newPassword = "copper lantern quietly 42"
    m.confirmPassword = "copper lantern quietly 42"
    m.submitPassword()
    #expect(m.path.last == .phraseIntro)
    let words = m.phrase?.words
    #expect(words != nil && account.phrasesMade == 1)
    m.navigationPath = Array(m.path.dropLast())
    #expect(m.path.last == .password)
    m.submitPassword()
    #expect(m.path.last == .phraseIntro)
    #expect(m.phrase?.words == words)
    #expect(account.phrasesMade == 1)
  }

  /// A wrong code keeps its six digits on screen until the person types again; five wrong
  /// codes use the code up ("Send a new code"), and a new code starts clean.
  @Test func aWrongCodeStaysUntilTypingAgain() async {
    let m = SignupModel(account: CountingAccount())
    m.inviteText = Self.code
    m.submitInvite()
    m.displayName = "Maya Rahman"
    m.email = "maya@example.com"
    await m.submitAboutYou()
    m.code = "482931"
    await m.submitCode()
    #expect(m.codeState(now: .now) == .wrong)
    #expect(m.wrongCode == "482931" && m.code.isEmpty)
    m.code = "1"
    #expect(m.failure == nil && m.wrongCode.isEmpty)
    #expect(m.codeState(now: .now) == .typing)
    for _ in 0..<5 {
      m.code = "000000"
      await m.submitCode()
    }
    #expect(m.codeState(now: .now) == .expired)
    #expect(m.wrongCode.isEmpty)
    await m.resendCode()
    #expect(m.codeState(now: .now) == .typing)
    // Ten minutes after it was sent a code is expired, whatever the last answer was.
    #expect(m.codeState(now: .now.addingTimeInterval(10 * 60 + 1)) == .expired)
  }

  /// The gate is made again (a body pass, the passcode wall, a wall, the launch view): the
  /// store hands back the same signup, with what was typed and where the person was.
  @Test func theStoreKeepsTheSignupWhenTheGateIsRebuilt() {
    let session = AccountSession(services: services(MockAccountService()), phase: .signedOut)
    let store = OnboardingStore(services: session.services, session: { session })
    let signup = store.signup
    signup.path = [.welcome, .invite, .aboutYou]
    signup.inviteText = Self.code
    signup.displayName = "Maya Rahman"
    signup.email = "maya@example.com"
    store.storyPage = 3
    for _ in 0..<3 {
      _ = AccountRootView(session: session, onboarding: store, setupFacts: .init()) { EmptyView() }
      _ = WelcomeFlowView(store: store)
      store.phaseChanged(from: nil, to: session.phase)
    }
    #expect(store.signup === signup)
    #expect(signup.path == [.welcome, .invite, .aboutYou])
    #expect(signup.displayName == "Maya Rahman" && signup.email == "maya@example.com")
    #expect(signup.normalizedInvite == Self.code)
    #expect(store.storyPage == 3)
  }

  /// An invite link that arrives mid-signup opens "Your invite is ready" (as
  /// `WelcomeFlowView` does), and leaves the typed name and address; with its key, the
  /// address needs no code.
  @Test func anInviteLinkMidSignupKeepsNameAndEmail() async throws {
    let m = SignupModel(account: CountingAccount())
    m.path = [.welcome, .invite, .aboutYou]
    m.inviteText = "ABCDEFGHIJKLMNOPQRSTUVWY"
    m.displayName = "Maya Rahman"
    m.email = "maya@example.com"
    let key = String(repeating: "k", count: 43)
    m.applyInviteLink(try #require(InviteLink.parse(URL(string: "https://hasala.app/i/\(Self.code)#\(key)")!)))
    m.path = [.welcome, .inviteReady]
    #expect(m.normalizedInvite == Self.code && m.inviteFromLink)
    m.submitInvite()
    #expect(m.path == [.welcome, .inviteReady, .aboutYou])
    #expect(m.displayName == "Maya Rahman" && m.email == "maya@example.com")
    await m.submitAboutYou()
    #expect(m.ticket?.emailProven == true)
    #expect(m.path.last == .method)
    #expect(m.emailConfirmed)
  }

  /// A link's code that the server doesn't know goes back to the code field (with the
  /// code in it, to check), not to "Your invite is ready".
  @Test func anUnknownLinkedInviteGoesToTheCodeField() async throws {
    let m = SignupModel(account: CountingAccount())
    let key = String(repeating: "k", count: 43)
    let unknown = "ZZZZ" + String(Self.code.dropFirst(4))
    m.applyInviteLink(try #require(InviteLink.parse(URL(string: "https://hasala.app/i/\(unknown)#\(key)")!)))
    m.path = [.welcome, .inviteReady]
    m.submitInvite()
    m.displayName = "Maya Rahman"
    m.email = "maya@example.com"
    await m.submitAboutYou()
    #expect(m.failure == .notInvited)
    #expect(m.path == [.welcome, .invite])
    #expect(m.normalizedInvite == unknown)
    // Fixing the code clears "not found" at once.
    m.inviteText = Self.code
    #expect(m.failure == nil)
  }

  // MARK: Session

  @Test func inviteLinksOnlyActSignedOut() {
    let url = URL(string: "https://hasala.app/i/\(Self.code)")!
    let out = AccountSession(services: services(MockAccountService()), phase: .signedOut)
    out.open(url)
    #expect(out.pendingInvite?.code.value == Self.code)
    let signedIn = AccountSession(services: services(MockAccountService()), phase: .ready)
    signedIn.open(url)
    #expect(signedIn.pendingInvite == nil)
    #expect(signedIn.notice == "You already have an account")
  }
}

/// The welcome stories' clock (spec 04 §2.3): 6 s a story, paused while nobody can watch,
/// carrying on where it stopped.
@MainActor
@Suite("Welcome story clock")
struct StoryClockTests {
  let t0 = Date(timeIntervalSinceReferenceDate: 0)

  @Test func aStoryPlaysSixSeconds() {
    var c = StoryClock()
    c.restart(at: t0, running: true)
    #expect(c.progress(at: t0.addingTimeInterval(3)) == 0.5)
    #expect(c.remaining(at: t0.addingTimeInterval(3)) == 3)
    #expect(c.progress(at: t0.addingTimeInterval(9)) == 1)
    #expect(c.remaining(at: t0.addingTimeInterval(9)) == 0)
  }

  @Test func pausedItKeepsItsPlace() {
    var c = StoryClock()
    c.restart(at: t0, running: true)
    c.pause(at: t0.addingTimeInterval(2))
    #expect(!c.isRunning)
    // Under the sheet for a minute: nothing moves.
    #expect(c.progress(at: t0.addingTimeInterval(62)) == 2.0 / 6)
    c.resume(at: t0.addingTimeInterval(62))
    #expect(c.remaining(at: t0.addingTimeInterval(63)) == 3)
    // Resuming while running changes nothing.
    c.resume(at: t0.addingTimeInterval(63))
    #expect(c.remaining(at: t0.addingTimeInterval(63)) == 3)
  }

  @Test func aNewStoryStartsFromNothingAndTheLastStaysFull() {
    var c = StoryClock()
    c.restart(at: t0, running: true)
    c.restart(at: t0.addingTimeInterval(4), running: false)
    #expect(c.progress(at: t0.addingTimeInterval(10)) == 0 && !c.isRunning)
    c.finish()
    #expect(c.progress(at: t0) == 1 && !c.isRunning)
    // A finished story doesn't run again.
    c.resume(at: t0)
    #expect(!c.isRunning)
  }
}

/// The welcome cards' idle float: every phase stays finite and within ±4 pt for the whole
/// loop, starting and ending at rest, so a card never loses its place on screen.
@MainActor
@Suite("Welcome idle float")
struct IdleFloatTests {
  @Test(arguments: 0..<4) func theFloatStaysInPlace(phase: Int) {
    let timeline = KeyframeTimeline(initialValue: CGFloat.zero) { IdleFloat.track(phase: phase) }
    #expect(abs(timeline.duration - HMotion.idlePeriod) < 0.001)
    for step in 0...400 {
      let y = timeline.value(time: timeline.duration * Double(step) / 400)
      #expect(y.isFinite)
      #expect(abs(y) <= HMotion.idleFloat + 0.5)
    }
    #expect(abs(timeline.value(time: 0)) < 0.001)
    #expect(abs(timeline.value(time: timeline.duration)) < 0.001)
  }
}

/// The mock account, counting the calls that must not repeat on Back and Forward.
@MainActor
final class CountingAccount: AccountService {
  let mock: MockAccountService
  private(set) var signupsBegun = 0
  private(set) var passkeysSaved = 0
  private(set) var phrasesMade = 0

  init(_ mock: MockAccountService = MockAccountService()) {
    mock.delay = .zero
    self.mock = mock
  }

  var profile: AccountProfile? { mock.profile }
  func beginSignup(code: InviteCode, linkKey: String?, email: String, displayName: String)
    async throws(AuthFailure) -> SignupTicket
  {
    signupsBegun += 1
    return try await mock.beginSignup(code: code, linkKey: linkKey, email: email, displayName: displayName)
  }
  func verifySignupEmail(_ ticket: SignupTicket, code: String) async throws(AuthFailure) {
    try await mock.verifySignupEmail(ticket, code: code)
  }
  func resendSignupCode(_ ticket: SignupTicket) async throws(AuthFailure) -> SignupTicket {
    try await mock.resendSignupCode(ticket)
  }
  func registerPasskey(_ ticket: SignupTicket) async throws(AuthFailure) {
    passkeysSaved += 1
    try await mock.registerPasskey(ticket)
  }
  func makeRecoveryPhrase() throws(AuthFailure) -> RecoveryPhrase {
    phrasesMade += 1
    return try mock.makeRecoveryPhrase()
  }
  func finishAccount(_ ticket: SignupTicket, credential: NewCredential, phrase: RecoveryPhrase)
    async throws(AuthFailure) -> AccountProfile
  { try await mock.finishAccount(ticket, credential: credential, phrase: phrase) }
  func signInWithPasskey() async throws(AuthFailure) -> SignInOutcome { try await mock.signInWithPasskey() }
  func signInWithPassword(email: String, password: String) async throws(AuthFailure) -> SignInOutcome {
    try await mock.signInWithPassword(email: email, password: password)
  }
  func unlockWithPasskey() async throws(AuthFailure) { try await mock.unlockWithPasskey() }
  func unlockWithPhrase(_ words: [String]) async throws(AuthFailure) { try await mock.unlockWithPhrase(words) }
  func resumeSignedIn() async throws(AuthFailure) -> SignInOutcome { try await mock.resumeSignedIn() }
  func finishInterruptedSetup(phrase: RecoveryPhrase) async throws(AuthFailure) -> AccountProfile {
    try await mock.finishInterruptedSetup(phrase: phrase)
  }
  func beginPasswordReset(email: String) async throws(AuthFailure) -> ResetTicket {
    try await mock.beginPasswordReset(email: email)
  }
  func verifyPasswordReset(_ ticket: ResetTicket, code: String) async throws(AuthFailure) -> ResetTicket {
    try await mock.verifyPasswordReset(ticket, code: code)
  }
  func requestResetApproval(_ ticket: ResetTicket, newPassword: String) async throws(AuthFailure) -> ResetTicket {
    try await mock.requestResetApproval(ticket, newPassword: newPassword)
  }
  func pollResetApproval(_ ticket: ResetTicket) async throws(AuthFailure) -> Bool {
    try await mock.pollResetApproval(ticket)
  }
  func beginRecovery(words: [String]) async throws(AuthFailure) -> RecoveryTicket {
    try await mock.beginRecovery(words: words)
  }
  func verifyRecovery(_ ticket: RecoveryTicket, code: String, kind: SignInMethod) async throws(AuthFailure) {
    try await mock.verifyRecovery(ticket, code: code, kind: kind)
  }
  func finishRecovery(_ ticket: RecoveryTicket, credential: NewCredential) async throws(AuthFailure) {
    try await mock.finishRecovery(ticket, credential: credential)
  }
  func securityState() async throws(AuthFailure) -> SecurityState { try await mock.securityState() }
  func perform(_ action: SecurityAction, password: String?) async throws(AuthFailure) {
    try await mock.perform(action, password: password)
  }
  func viewRecoveryPhrase() async throws(AuthFailure) -> [String] { try await mock.viewRecoveryPhrase() }
  func signOut() async { await mock.signOut() }
  func pendingResetRequest() async -> PendingReset? { await mock.pendingResetRequest() }
  func approveReset(_ request: PendingReset, code: String) async throws(AuthFailure) {
    try await mock.approveReset(request, code: code)
  }
}
