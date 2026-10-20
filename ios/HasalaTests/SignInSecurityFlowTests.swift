import Foundation
import Testing

@testable import Hasala

/// Sign-in, unlock, recovery, Sign-in & security, freeze and reset approval, on the
/// in-memory mock.
@MainActor
@Suite("Sign-in and security flows")
struct SignInSecurityFlowTests: AccountSuite {
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
    let after = try? await account.securityState()
    #expect(after?.passkeys.count == 1)
    #expect(after?.hasPassword == false)
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
    let after = try? await account.securityState()
    #expect(after?.passkeys.isEmpty == true)
    #expect(after?.hasPassword == true)
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
    #expect(m.confirming == .perform(.signOutEverywhere))
    #expect(m.confirmFactor == .password)
    m.confirmPassword = "not it at all"
    await m.confirm()
    // A wrong password keeps the sheet up, emptied, with the field's line.
    #expect(m.failure == .stepUpFailed)
    #expect(m.confirming == .perform(.signOutEverywhere))
    #expect(m.confirmPassword.isEmpty)
    #expect(session.phase == .ready)
    await m.request(.addPasskey)
    m.confirmPassword = MockAccountService.existingPassword
    await m.confirm()
    #expect(m.failure == nil)
    #expect(m.state?.hasPasskey == true)
  }

  /// c2 §12 rule 7: a typed password leaves memory once it was used or its page closed.
  @Test func typedPasswordsGoWhenTheirPageOrSheetCloses() async {
    let account = MockAccountService(existing: .passwordOnly, signedIn: true)
    account.delay = .zero
    let session = AccountSession(services: services(account), phase: .ready)
    let m = SecurityModel(session: session)
    await m.load()
    // Back from the Change password page: the new password and its repeat go with it.
    m.editingPassword = true
    m.newPassword = "harbor lights at dawn 7"
    m.confirmNewPassword = "harbor lights at dawn 7"
    await m.savePassword()
    #expect(m.confirming == .perform(.changePassword(new: "harbor lights at dawn 7")))
    m.cancelConfirmation()
    // A cancelled confirmation leaves the page as it was...
    #expect(m.newPassword == "harbor lights at dawn 7")
    m.editingPassword = false
    // ...and closing the page empties it.
    #expect(m.newPassword.isEmpty)
    #expect(m.confirmNewPassword.isEmpty)
    // The passkey sheet closed after the password step-up: the sheet stays, emptied.
    await m.request(.addPasskey)
    m.confirmPassword = MockAccountService.existingPassword
    account.closesNextSystemSheet = true
    await m.confirm()
    #expect(m.confirming == .perform(.addPasskey))
    #expect(m.confirmPassword.isEmpty)
    #expect(m.failure == nil)
    #expect(m.state?.hasPasskey == false)
    // Welcome back's "Add a passkey" does the same.
    let unlock = UnlockModel(account: account, passkeyCanUnlock: false, onUnlocked: {})
    unlock.addingPasskey = true
    unlock.confirmPassword = MockAccountService.existingPassword
    account.closesNextSystemSheet = true
    await unlock.addPasskey()
    #expect(unlock.addingPasskey)
    #expect(unlock.confirmPassword.isEmpty)
  }

  /// Paper IHY names the passkey being removed; a row that's gone doesn't read "the this".
  @Test func removingAPasskeyNamesIt() {
    let state = MockAccountService.securityState(for: .passkey)
    let named = SecurityModel.words(for: .perform(.removePasskey(id: "pk-2")), email: "maya@example.com", state: state)
    #expect(named.0 == "Remove the Work iPad passkey")
    #expect(named.1 == ["The Work iPad passkey can't sign in any more", "We email maya@example.com about it"])
    let unknown = SecurityModel.words(for: .perform(.removePasskey(id: "gone")), email: "", state: state)
    #expect(unknown.0 == "Remove this passkey")
    #expect(unknown.1 == ["This passkey can't sign in any more", "We email you about it"])
  }

  @Test func theLastWayInCannotBeRemoved() async {
    let account = MockAccountService(existing: .passkey, signedIn: true)
    account.delay = .zero
    let session = AccountSession(services: services(account), phase: .ready)
    let m = SecurityModel(session: session)
    await m.load()
    // The other Apple Account's passkey goes after Face ID.
    await m.request(.removePasskey(id: "pk-2"))
    #expect(m.confirmFactor == .faceID)
    await m.confirm()
    #expect(m.failure == nil)
    #expect(m.state?.passkeys.map(\.id) == ["pk-1"])
    // Then the only passkey, no password: refused.
    await m.request(.removePasskey(id: "pk-1"))
    await m.confirm()
    #expect(m.failure == .lastAuthenticator)
    #expect(m.confirming == nil)
    #expect(m.state?.hasPasskey == true)
  }

  @Test func freezeAndDelete() async {
    let account = MockAccountService(existing: .passkey, signedIn: true)
    account.delay = .zero
    let session = AccountSession(services: services(account), phase: .ready)
    let m = SecurityModel(session: session)
    await m.load()
    await m.request(.freeze)
    // Nothing happens before "Confirm it's you".
    #expect(session.phase == .ready)
    await m.confirm()
    guard case .frozen = session.phase else { Issue.record("not frozen: \(session.phase)"); return }
    session.leaveFrozen()
    #expect(session.leftFrozen == FreezeInfo(by: .holder, when: "just now", inApp: true))
    await m.request(.addPasskey)
    #expect(m.failure == .frozen)
    #expect(m.confirming == nil)
    await m.request(.deleteAccount)
    await m.confirm()
    #expect(session.phase == .signedOut)
  }

  /// Paper MTO: the holder's wall says the freeze came from our email (the cue for
  /// "Someone may be reading your email"), unless it was made here.
  @Test func theHolderWallSaysWhereTheFreezeCameFrom() {
    #expect(FrozenWall.holderBody(FreezeInfo(by: .holder, when: "on Sun 11 Oct at 21:20"))
      == "\u{201C}Freeze my account\u{201D} was used from our email on Sun 11 Oct at 21:20. Nobody can sign in or change your keys until you sign in fully.")
    #expect(FrozenWall.holderBody(FreezeInfo(by: .holder, when: nil))
      == "\u{201C}Freeze my account\u{201D} was used from our email. Nobody can sign in or change your keys until you sign in fully.")
    #expect(FrozenWall.holderBody(FreezeInfo(by: .holder, when: "just now", inApp: true))
      == "\u{201C}Freeze my account\u{201D} was used just now. Nobody can sign in or change your keys until you sign in fully.")
  }

  /// H9F's other-device row promises only what that device can do: only a passkey
  /// account's device shows the words, and a password account's can't even after it adds
  /// a passkey there.
  @Test func theHonestEndPromisesOnlyWhatTheOtherDeviceCanDo() {
    let paper = "An iPad or old iPhone with Hasala open can add a passkey or show your words after Face ID."
    #expect(HonestEndScreen.otherDevice(addsPasskeys: true, method: .passkey) == paper)
    #expect(HonestEndScreen.otherDevice(addsPasskeys: false, method: .passkey).contains("can show your words"))
    for adds in [true, false] {
      let passwordOnly = HonestEndScreen.otherDevice(addsPasskeys: adds, method: .password)
      #expect(!passwordOnly.contains("can show your words"))
      #expect(passwordOnly.contains("can't be shown again"))
      #expect(HonestEndScreen.otherDevice(addsPasskeys: adds, method: nil).contains("where your passkey works"))
    }
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

  @Test func viewingThePhraseIsForPasskeyAccounts() async {
    let account = MockAccountService(existing: .passkey, signedIn: true)
    account.delay = .zero
    let m = SecurityModel(session: AccountSession(services: services(account), phase: .ready))
    await m.load()
    m.requestPhrase()
    #expect(m.confirming == .viewPhrase)
    await m.confirm()
    // The words wait for the sheet to go: a cover never presents over a sheet.
    #expect(m.viewedPhrase == nil)
    m.confirmationDismissed()
    #expect(m.viewedPhrase == MockAccountService.phraseWords)
    #expect(!m.phraseRevealed)
    m.phraseRevealed = true
    m.closePhrase()
    #expect(m.viewedPhrase == nil)
    #expect(!m.phraseRevealed)
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
}
