import Foundation
import Testing

@testable import Hasala

/// The account view models on the in-memory mock (spec 04 §15.1: previews and tests run
/// the shipped view models over mock sources).
@MainActor
@Suite("Account flows")
struct AccountFlowTests {
  static let code = "ABCDEFGHIJKLMNOPQRSTUVWX"

  func services(_ account: MockAccountService, sample: Bool = false) -> AccountServices {
    let a = account
    a.delay = .zero
    let mailbox = MockMailbox(offersSampleData: sample)
    mailbox.step = .milliseconds(1)
    return AccountServices(account: a, mailbox: mailbox, setup: MockSetupAuthoring(),
                           notifications: MockNotificationPermission())
  }

  func confirmPhrase(_ m: SignupModel) {
    for (i, pos) in m.askedPositions.enumerated() {
      _ = i
      m.place(MockAccountService.phraseWords[pos])
    }
  }

  // MARK: Signup

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

  // MARK: Sign in

  @Test func wrongPasswordIsUniform() async {
    let account = MockAccountService(existing: .passwordOnly)
    account.delay = .zero
    var outcome: SignInOutcome?
    let m = SignInModel(account: account) { outcome = $0 }
    m.email = "maya@example.com"
    m.password = "wrong password!!"
    await m.signInWithPassword()
    #expect(m.failure == .wrongCredentials)
    #expect(m.password.isEmpty)
    m.email = "nobody@example.com"
    m.password = MockAccountService.existingPassword
    await m.signInWithPassword()
    #expect(m.failure == .wrongCredentials)
    m.email = "maya@example.com"
    m.password = MockAccountService.existingPassword
    await m.signInWithPassword()
    #expect(outcome == .ready)
  }

  @Test func orphanedPasskeySaysTheBetaWasReset() async {
    let account = MockAccountService(existing: .none)
    account.delay = .zero
    let m = SignInModel(account: account) { _ in }
    await m.signInWithPasskey()
    #expect(m.failure == .orphanedPasskey)
  }

  @Test func forgotPasswordWaitsForTheOtherIPhone() async {
    let account = MockAccountService(existing: .passwordOnly)
    account.delay = .zero
    var outcome: SignInOutcome?
    let m = SignInModel(account: account) { outcome = $0 }
    m.resetEmail = "maya@example.com"
    #expect(await m.submitResetEmail())
    m.resetCodeText = MockAccountService.emailCode
    #expect(await m.submitResetCode())
    #expect(m.canApproveOnOtherPhone)
    m.newPassword = "a brand new passphrase"
    m.confirmPassword = "a brand new passphrase"
    #expect(await m.requestApproval())
    #expect(m.reset?.resetCode?.count == 16)
    #expect(m.resetCodeGroups.split(separator: " ").count == 4)
    await m.waitForApproval(interval: .milliseconds(1))
    #expect(outcome == .needsUnlock(passkeyCanUnlock: false))
  }

  @Test func recoveryTakesTheWordsThenTheCode() async {
    let account = MockAccountService(existing: .passkey)
    account.delay = .zero
    var outcome: SignInOutcome?
    let m = SignInModel(account: account) { outcome = $0 }
    m.phraseText = "abandon"
    #expect(!(await m.submitRecoveryWords()))
    m.phraseText = MockAccountService.phraseWords.joined(separator: " ")
    #expect(await m.submitRecoveryWords())
    m.recoverCode = MockAccountService.emailCode
    #expect(await m.submitRecoveryCode())
    #expect(await m.finishRecovery(.passkey))
    m.recoveryDone()
    #expect(outcome == .ready)
  }

  @Test func unlockWithTheWords() async {
    let account = MockAccountService(existing: .passwordOnly, signedIn: true)
    account.delay = .zero
    var opened = false
    let m = UnlockModel(account: account, passkeyCanUnlock: false) { opened = true }
    m.phraseText = Array(MockAccountService.phraseWords.reversed()).joined(separator: " ")
    await m.unlockWithWords()
    #expect(m.failure != nil)
    m.phraseText = MockAccountService.phraseWords.joined(separator: " ")
    await m.unlockWithWords()
    #expect(m.unlocked)
    m.openApp()
    #expect(opened)
  }

  // MARK: Sign-in & security

  @Test func passwordOnlyChangesNeedThePassword() async {
    let account = MockAccountService(existing: .passwordOnly, signedIn: true)
    account.delay = .zero
    let session = AccountSession(services: services(account), phase: .ready)
    let m = SecurityModel(session: session)
    await m.load()
    #expect(m.state?.hasPasskey == false)
    await m.request(.signOutEverywhere)
    #expect(m.confirming == .signOutEverywhere)
    m.confirmPassword = "not it at all"
    await m.confirm()
    #expect(m.failure == .stepUpFailed)
    await m.request(.addPasskey)
    m.confirmPassword = MockAccountService.existingPassword
    await m.confirm()
    #expect(m.failure == nil)
    #expect(m.state?.hasPasskey == true)
  }

  @Test func theLastWayInCannotBeRemoved() async {
    let account = MockAccountService(existing: .passkey, signedIn: true)
    account.delay = .zero
    let session = AccountSession(services: services(account), phase: .ready)
    let m = SecurityModel(session: session)
    await m.load()
    // The only passkey, no password: refused.
    await m.request(.removePasskey(id: "pk-1"))
    #expect(m.failure == .lastAuthenticator)
    #expect(m.state?.hasPasskey == true)
  }

  @Test func freezeAndDelete() async {
    let account = MockAccountService(existing: .passkey, signedIn: true)
    account.delay = .zero
    let session = AccountSession(services: services(account), phase: .ready)
    let m = SecurityModel(session: session)
    await m.load()
    await m.request(.freeze)
    guard case .frozen = session.phase else { Issue.record("not frozen: \(session.phase)"); return }
    session.leaveFrozen()
    #expect(session.leftFrozen)
    await m.request(.addPasskey)
    #expect(m.failure == .frozen)
    await m.request(.deleteAccount)
    #expect(session.phase == .signedOut)
  }

  @Test func viewingThePhraseIsForPasskeyAccounts() async {
    let account = MockAccountService(existing: .passkey, signedIn: true)
    account.delay = .zero
    let m = SecurityModel(session: AccountSession(services: services(account), phase: .ready))
    await m.load()
    await m.viewPhrase()
    #expect(m.viewedPhrase == MockAccountService.phraseWords)
    m.closePhrase()
    #expect(m.viewedPhrase == nil)
  }

  @Test func approvingAResetChecksTheCodeFirst() async throws {
    let account = MockAccountService(existing: .passkey, signedIn: true)
    account.delay = .zero
    account.pendingReset = PendingReset(id: "reset-1", askedAgo: "now", email: MockAccountService.existingEmail)
    let request = try #require(await account.pendingResetRequest())
    let m = ResetApprovalModel(account: account, request: request)
    m.code = "ABCD EFGH IJKL MNOP"
    #expect(m.codeReady)
    await m.approve()
    #expect(m.failure == .codeMismatch)
    #expect(account.approvedResets.isEmpty)
    #expect(MockAccountService.resetCode == "WMO6C7ID7TYM2M5S")
    m.code = "wmo6-c7id-7tym-2m5s"
    await m.approve()
    #expect(m.approved)
    #expect(account.approvedResets == ["reset-1"])
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

  // MARK: Setup

  @Test func setupRunsBankToDone() async throws {
    let s = services(MockAccountService(existing: .passkey, signedIn: true))
    var finished = false
    let m = SetupModel(services: s, displayName: "Maya Rahman",
                       facts: .init(hasSession: true, keysReady: true)) { finished = true }
    #expect(m.step == .bank)
    m.toggle(.dib)
    #expect(m.orderedBanks == [.enbd])
    m.toggle(.dib)
    await m.continueWithBanks()
    #expect((s.setup as? MockSetupAuthoring)?.banks == [.enbd, .dib])
    #expect(m.step == .gmail)
    await m.connectGmail()
    #expect(m.step == .scan)
    m.planWhileScanning()
    #expect(m.step == .income)
    m.incomeText = "25,000"
    #expect(m.incomeMinor == 2_500_000)
    m.continueWithIncome()
    await m.savePlan()
    let setup = try #require(s.setup as? MockSetupAuthoring)
    #expect(setup.income == 2_500_000)
    #expect(setup.plan == StartingPlan())
    #expect(m.plan.amounts(income: 2_500_000) == (1_250_000, 750_000, 500_000))
    #expect(m.path.last == .cards)
    // Wait for the mock scan to reach the cards.
    for _ in 0..<200 where m.cards.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    #expect(m.cards.count == 3)
    #expect(m.keptCards == 2)
    await m.confirmCards()
    #expect(m.summary?.total == 264)
    #expect(m.step == .notifications)
    await m.allowNotifications()
    #expect(m.step == .done)
    m.finish()
    #expect(finished)
    #expect(m.firstName == "Maya")
  }

  @Test func reviewAccountsCanUseSampleData() async {
    let s = services(MockAccountService(existing: .passkey, signedIn: true), sample: true)
    let m = SetupModel(services: s, displayName: "Maya", facts: .init(hasSession: true, keysReady: true)) {}
    #expect(m.offersSampleData)
    await m.continueWithBanks()
    await m.useSampleData()
    #expect(m.step == .notifications)
  }

  @Test func resumesAtTheDerivedStep() {
    let s = services(MockAccountService(existing: .passkey, signedIn: true))
    var facts = OnboardingStep.Facts(hasSession: true, keysReady: true, banksChosen: true)
    facts.gmailSkipped = true
    let m = SetupModel(services: s, displayName: "Maya", facts: facts) {}
    m.resume()
    #expect(m.path == [.income])
  }
}
