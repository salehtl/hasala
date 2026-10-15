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

    // A wrong word blocks the others until it is taken back.
    let wrong = MockAccountService.phraseWords.first { w in
      !m.askedPositions.map { MockAccountService.phraseWords[$0] }.contains(w)
    }!
    m.place(wrong)
    #expect(m.wrongSlot == 0)
    m.place(MockAccountService.phraseWords[m.askedPositions[1]])
    #expect(m.placed[1] == nil)
    m.takeBack(0)
    confirmPhrase(m)
    #expect(m.phraseConfirmed)
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

  @Test func passwordSignupPublishesOnlyAfterTheWords() async {
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
    confirmPhrase(m)
    await m.finish()
    #expect(account.profile?.method == .password)
    #expect(m.newPassword.isEmpty)
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
    #expect(m.path.isEmpty)  // not before the four words are confirmed
    confirmPhrase(m)
    await m.finish()
    #expect(m.path.last == .accountReady)
    #expect(m.phrase == nil)
    session.accountCreated()
    #expect(session.phase == .onboarding(.bank))
  }

  @Test func repeatedWordsInThePhraseCheckCanAllBePlaced() {
    // Positions 1 and 3 hold the same word (about 0.3% of phrases).
    var words = MockAccountService.phraseWords
    words[2] = words[0]
    let phrase = RecoveryPhrase(words: words, confirmPositions: [0, 2, 5, 7])
    let account = StubPhraseAccount(phrase: phrase)
    let m = SignupModel(account: account)
    m.startReplacement()
    let chips = m.choices
    #expect(chips.filter { $0 == words[0] }.count == 2)
    for p in phrase.confirmPositions { m.place(words[p]) }
    #expect(m.phraseConfirmed)
    #expect(m.placedChips.compactMap { $0 }.count == 4)
    #expect(Set(m.placedChips.compactMap { $0 }).count == 4)
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
