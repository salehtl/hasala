import Foundation
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
