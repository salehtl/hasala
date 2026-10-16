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
    // The code is kept until the new way to sign in is chosen: `recover/verify` sends
    // both (spec 04 §6.2 C4 step 3).
    m.recoverCode = "000000"
    #expect(m.submitRecoveryCode())
    #expect(await m.finishRecovery(.passkey) == .codeRejected)
    #expect(m.failure == .codeWrong(triesLeft: 4))
    #expect(m.recoverCode.isEmpty)
    m.recoverCode = MockAccountService.emailCode
    #expect(m.submitRecoveryCode())
    #expect(await m.finishRecovery(.passkey) == .done)
    #expect(account.recoveryKind == .passkey)
    m.recoveryDone()
    #expect(outcome == .ready)
  }

  @Test func recoveryIsBoundToTheVerifiedKind() async {
    let account = MockAccountService(existing: .passkey)
    account.delay = .zero
    let m = SignInModel(account: account) { _ in }
    m.phraseText = MockAccountService.phraseWords.joined(separator: " ")
    #expect(await m.submitRecoveryWords())
    m.recoverCode = MockAccountService.emailCode
    #expect(m.submitRecoveryCode())
    m.newPassword = "a brand new passphrase"
    m.confirmPassword = "a brand new passphrase"
    #expect(await m.finishRecovery(.password("a brand new passphrase")) == .done)
    #expect(account.recoveryKind == .password)
  }

  @Test func codeTimersComeFromTheSend() async {
    let account = MockAccountService(existing: .passwordOnly)
    account.delay = .zero
    let m = SignInModel(account: account) { _ in }
    #expect(m.resetCodeSentAt == nil)
    m.resetEmail = "maya@example.com"
    #expect(await m.submitResetEmail())
    let sent = m.resetCodeSentAt
    #expect(sent != nil)
    m.resetCodeText = "000000"
    #expect(!(await m.submitResetCode()))
    #expect(m.resetCodeSentAt == sent)
    let t = SignupTicket(id: "s", emailProven: false, email: "m@example.com", displayName: "M",
                         startedAt: .now.addingTimeInterval(-11 * 60))
    #expect(t.codeExpired(now: .now))
    #expect(!t.isExpired(now: .now))
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
    #expect(session.leftFrozen == FreezeInfo(by: .holder, when: "just now"))
    await m.request(.addPasskey)
    #expect(m.failure == .frozen)
    await m.request(.deleteAccount)
    #expect(session.phase == .signedOut)
  }

  @Test func anOperatorFreezeStaysAnOperatorFreeze() async {
    let account = MockAccountService(existing: .passkey, signedIn: true)
    account.delay = .zero
    account.freezeForScenario(by: .operator)
    let info = FreezeInfo(by: .operator, when: nil)
    let session = AccountSession(services: services(account), phase: .frozen(info))
    session.leaveFrozen()
    #expect(session.leftFrozen == info)
    // The banner's wall is the operator's again, never the holder's.
    session.showFrozenWall()
    #expect(session.phase == .frozen(info))
    // Sign-in & security never sends #66 for it.
    session.leaveFrozen()
    let m = SecurityModel(session: session)
    await m.load()
    await m.request(.unfreeze)
    #expect(account.frozenInfo == info.with(when: "on Sun 11 Oct at 21:20"))
    #expect(session.leftFrozen == info)
  }

  /// A wall shown as the holder's (`frozen_by` couldn't be read) never sends #66 for an
  /// operator freeze: the service refuses it first, and the wall becomes the operator's.
  @Test func aStaleHolderWallLearnsItIsTheOperators() async {
    let account = MockAccountService(existing: .passkey, signedIn: true)
    account.delay = .zero
    account.freezeForScenario(by: .operator)
    let shown = FreezeInfo(by: .holder, when: "on Sun 11 Oct at 21:20")
    let session = AccountSession(services: services(account), phase: .frozen(shown))
    await #expect(throws: AuthFailure.frozenByOperator) { try await session.unfreeze(password: nil) }
    #expect(session.phase == .frozen(FreezeInfo(by: .operator, when: "on Sun 11 Oct at 21:20")))
    #expect(account.frozenInfo?.by == .operator)
    // Left frozen with the holder's banner: the banner learns it too.
    let left = AccountSession(services: services(account), phase: .frozen(FreezeInfo(by: .holder, when: nil)))
    left.leaveFrozen()
    left.learnedOperatorFreeze()
    #expect(left.leftFrozen == FreezeInfo(by: .operator, when: nil))
    #expect(left.phase == .ready)
  }

  @Test func aHolderUnfreezeOpensTheApp() async throws {
    let account = MockAccountService(existing: .passkey, signedIn: true)
    account.delay = .zero
    account.freezeForScenario(by: .holder)
    let session = AccountSession(services: services(account), phase: .frozen(FreezeInfo(by: .holder, when: nil)))
    try await session.unfreeze(password: nil)
    #expect(session.phase == .ready)
    #expect(account.frozenInfo == nil)
  }

  @Test func aSignInToAFrozenAccountKeepsWhoFrozeIt() {
    let session = AccountSession(services: services(MockAccountService()), phase: .signedOut)
    session.signedIn(.frozen(FreezeInfo(by: .operator, when: nil)))
    #expect(session.phase == .frozen(FreezeInfo(by: .operator, when: nil)))
    // A holder's wall says when the freeze was triggered.
    let holder = FreezeInfo(by: .holder, when: "on Sun 11 Oct at 21:20")
    session.signedIn(.frozen(holder))
    #expect(session.phase == .frozen(holder))
  }

  /// A run that finds the account frozen again keeps the "Leave it frozen" banner, and an
  /// unanswered `GET /account` never turns a known operator freeze into the holder's.
  @Test func aRunFindingTheFreezeKeepsTheBanner() {
    let op = FreezeInfo(by: .operator, when: nil)
    let session = AccountSession(services: services(MockAccountService()), phase: .frozen(op))
    session.runFoundFrozen(nil)
    #expect(session.phase == .frozen(op))
    session.leaveFrozen()
    session.runFoundFrozen(nil)
    #expect(session.phase == .ready)
    #expect(session.leftFrozen == op)
    let holder = FreezeInfo(by: .holder, when: "on Sun 11 Oct at 21:20")
    session.runFoundFrozen(holder)
    #expect(session.phase == .ready)
    #expect(session.leftFrozen == holder)
    // Nothing known: the holder's wall.
    let fresh = AccountSession(services: services(MockAccountService()), phase: .ready)
    fresh.runFoundFrozen(nil)
    #expect(fresh.phase == .frozen(FreezeInfo(by: .holder, when: nil)))
  }

  // MARK: Relaunch (spec 04 §6.5)

  @Test func aRelaunchedSignInGoesToUnlockNotToTheKeysStep() async {
    let account = MockAccountService(existing: .passkey, signedIn: true)
    account.resumeOutcome = .needsUnlock(passkeyCanUnlock: true)
    let session = AccountSession(services: services(account), phase: .checking)
    await session.resume()
    #expect(session.phase == .needsUnlock(passkeyCanUnlock: true))
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
    #expect(m.step == .mailbox)
    #expect(m.providers == [.gmail, .outlook])
    await m.choose(.gmail)
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
    // No cards step: the result, finished or not, then notifications.
    #expect(m.path.last == .result)
    #expect(m.step == .notifications)
    for _ in 0..<400 where !m.scanDone { try await Task.sleep(for: .milliseconds(10)) }
    #expect(m.scanDone)
    #expect(m.summary?.total == 268)
    #expect(m.facts.mailbox == .linked)
    m.afterResult()
    #expect(m.path.last == .notifications)
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

  // MARK: Connect a mailbox after setup (spec 04 §6.6 row 4, §7.4)

  func connectServices(
    _ offer: MailboxOffer?, banks: [SupportedBank] = SupportedBank.allCases, linked: MailboxProvider? = nil
  ) -> (AccountServices, MockMailbox) {
    let s = services(MockAccountService(existing: .passkey, signedIn: true))
    let mailbox = s.mailbox as! MockMailbox
    mailbox.providers = MailboxProvider.allCases
    if let linked { mailbox.linkTo(linked) }
    mailbox.mailboxOffer = offer
    mailbox.banks = banks
    return (s, mailbox)
  }

  @Test func connectingGmailAfterSetupRunsGmailThenTheResult() async throws {
    let (s, mailbox) = connectServices(.connect, banks: [.dib])
    var finished = 0, closed = 0
    let m = SetupModel.connectingMailbox(.connect, services: s, onClose: { closed += 1 }, onFinished: { finished += 1 })
    #expect(!m.startsAtBank)
    #expect(m.orderedBanks == [.dib])
    #expect(m.steps(2) == nil)
    #expect(m.mailboxIsFirst)
    #expect(m.connectTitle(.gmail) == "Connect Gmail" && m.connectTitle(.outlook) == "Connect Outlook")
    await m.openConnect()
    #expect(m.path.isEmpty)
    await m.choose(.gmail)
    #expect(m.path == [.result])
    #expect(mailbox.linkedProvider == .gmail && mailbox.mailboxOffer == .change(.gmail))
    #expect(finished == 0)
    // "Continue" doesn't wait for the import.
    m.afterResult()
    #expect(finished == 1 && closed == 0)
  }

  @Test func reconnectingGmailIsDoneOnceGoogleSaysYes() async {
    let (s, mailbox) = connectServices(.reconnect(.gmail), linked: .gmail)
    var finished = 0
    let m = SetupModel.connectingMailbox(.reconnect(.gmail), services: s, onClose: {}, onFinished: { finished += 1 })
    #expect(m.providers == [.gmail, .outlook])
    #expect(m.connectTitle(.gmail) == "Reconnect Gmail" && m.connectTitle(.outlook) == "Use Outlook instead")
    await m.choose(.gmail)
    #expect(m.confirmingSwitch == nil)
    #expect(finished == 1)
    #expect(m.path.isEmpty)
    #expect(mailbox.linkedProvider == .gmail)
  }

  @Test func connectingGmailWithNoBankStartsAtTheBank() async {
    let (s, _) = connectServices(.connect, banks: [])
    var closed = 0
    let m = SetupModel.connectingMailbox(.connect, services: s, onClose: { closed += 1 }, onFinished: {})
    #expect(m.startsAtBank)
    await m.continueWithBanks()
    #expect((s.setup as? MockSetupAuthoring)?.banks == [.enbd, .dib])
    #expect(m.path == [.mailbox])
    #expect(!m.mailboxIsFirst)
    m.close()
    #expect(closed == 1)
  }

  /// Opened again during the scan (a reconnect cut short mid-scan): the result shows it.
  @Test func connectingGmailResumesAtTheResult() async throws {
    let (s, mailbox) = connectServices(.connect)
    try await mailbox.connectMailbox(.gmail, banks: [.enbd])
    let m = SetupModel.connectingMailbox(.connect, services: s, onClose: {}, onFinished: {})
    await m.openConnect()
    #expect(m.path == [.result])
    for _ in 0..<400 where !m.scanDone { try await Task.sleep(for: .milliseconds(10)) }
    #expect(m.summary?.total == 268)
  }

  @Test func setupResumedWithTheScanStillRunningGoesOnToNotifications() {
    let s = services(MockAccountService(existing: .passkey, signedIn: true))
    var facts = OnboardingStep.Facts(hasSession: true, keysReady: true, banksChosen: true)
    facts.mailbox = .scanning
    facts.scanDeferred = true
    facts.incomeSkipped = true
    facts.planSkipped = true
    let m = SetupModel(services: s, displayName: "Maya", facts: facts) {}
    m.resume()
    #expect(m.path == [.notifications])
  }

  @Test func resumesAtTheDerivedStep() {
    let s = services(MockAccountService(existing: .passkey, signedIn: true))
    var facts = OnboardingStep.Facts(hasSession: true, keysReady: true, banksChosen: true)
    facts.mailboxSkipped = true
    let m = SetupModel(services: s, displayName: "Maya", facts: facts) {}
    m.resume()
    #expect(m.path == [.income])
  }

  /// Gmail skipped at setup, Outlook connected later from Home: a first connect, no
  /// confirmation (nothing is replaced), then the scan's result.
  @Test func connectingOutlookAfterSkippingScans() async throws {
    let (s, mailbox) = connectServices(.connect, banks: [.enbd])
    let m = SetupModel.connectingMailbox(.connect, services: s, onClose: {}, onFinished: {})
    await m.choose(.outlook)
    #expect(m.confirmingSwitch == nil)
    #expect(m.path == [.result])
    #expect(mailbox.linkedProvider == .outlook)
  }

  /// Gmail works; Profile's "Use another email" offers Outlook alone, and switching asks
  /// first ("This replaces your Gmail connection."). Cancelling changes nothing.
  @Test func switchingFromGmailToOutlookIsConfirmed() async throws {
    let (s, mailbox) = connectServices(.change(.gmail), linked: .gmail)
    let m = SetupModel.connectingMailbox(.change(.gmail), services: s, onClose: {}, onFinished: {})
    #expect(m.providers == [.outlook])
    #expect(m.connectTitle(.outlook) == "Use Outlook instead")
    await m.choose(.outlook)
    #expect(m.confirmingSwitch == .outlook)
    #expect(m.switchMessage?.hasPrefix("This replaces your Gmail connection.") == true)
    #expect(mailbox.linkedProvider == .gmail)
    m.confirmingSwitch = nil
    #expect(mailbox.linkedProvider == .gmail && m.path.isEmpty)
    await m.choose(.outlook)
    m.confirmingSwitch = nil  // the dialog closes before its button's action runs
    await m.confirmSwitch(.outlook)
    #expect(mailbox.linkedProvider == .outlook)
    #expect(m.path == [.result])  // a switch scans the new mailbox
  }

  /// Reconnecting Outlook offers Outlook first; Gmail instead is a switch, confirmed.
  @Test func reconnectingOutlookOffersItFirst() async {
    let (s, _) = connectServices(.reconnect(.outlook), linked: .outlook)
    let m = SetupModel.connectingMailbox(.reconnect(.outlook), services: s, onClose: {}, onFinished: {})
    #expect(m.providers == [.outlook, .gmail])
    #expect(m.connectTitle(.outlook) == "Reconnect Outlook")
    await m.choose(.gmail)
    #expect(m.confirmingSwitch == .gmail)
    #expect(m.switchMessage?.hasPrefix("This replaces your Outlook connection.") == true)
  }
}

/// A mock whose phrase is chosen by the test (the phrase check's edge cases).
@MainActor
final class StubPhraseAccount: AccountService {
  let mock = MockAccountService()
  let phrase: RecoveryPhrase
  init(phrase: RecoveryPhrase) { self.phrase = phrase }

  func makeRecoveryPhrase() throws(AuthFailure) -> RecoveryPhrase { phrase }

  var profile: AccountProfile? { mock.profile }
  func beginSignup(code: InviteCode, linkKey: String?, email: String, displayName: String)
    async throws(AuthFailure) -> SignupTicket
  { try await mock.beginSignup(code: code, linkKey: linkKey, email: email, displayName: displayName) }
  func verifySignupEmail(_ ticket: SignupTicket, code: String) async throws(AuthFailure) {
    try await mock.verifySignupEmail(ticket, code: code)
  }
  func resendSignupCode(_ ticket: SignupTicket) async throws(AuthFailure) -> SignupTicket {
    try await mock.resendSignupCode(ticket)
  }
  func registerPasskey(_ ticket: SignupTicket) async throws(AuthFailure) { try await mock.registerPasskey(ticket) }
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

extension FreezeInfo {
  func with(when: String?) -> FreezeInfo { FreezeInfo(by: by, when: when) }
}
