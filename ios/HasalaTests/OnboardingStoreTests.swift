import Foundation
import SwiftUI
import Testing

@testable import Hasala

/// The onboarding store (plan B3): one set of onboarding models for the life of the
/// process, kept through a re-made gate, dropped only when the account is gone.
@MainActor
@Suite("Onboarding store")
struct OnboardingStoreTests: AccountSuite {
  func store(_ account: MockAccountService = MockAccountService(existing: .passkey, signedIn: true),
             phase: AccountSession.Phase = .signedOut) -> (OnboardingStore, AccountSession) {
    let session = AccountSession(services: services(account), phase: phase)
    return (OnboardingStore(services: session.services, session: { session }), session)
  }

  @Test func signingInForgetsAnAbandonedRecovery() async {
    let (store, _) = store(MockAccountService(existing: .passkey))
    let m = store.signIn
    m.phraseText = MockAccountService.phraseWords.joined(separator: " ")
    #expect(await m.submitRecoveryWords())
    m.recoverCode = MockAccountService.emailCode
    store.phaseChanged(from: nil, to: .signedOut)
    #expect(!m.phraseText.isEmpty)
    store.phaseChanged(from: .signedOut, to: .ready)
    #expect(store.signIn === m)
    #expect(m.phraseText.isEmpty && m.recoverCode.isEmpty && m.recovery == nil)
  }

  @Test func theSameModelsComeBackOnEveryCall() {
    let (store, _) = store()
    let facts = OnboardingStep.Facts(hasSession: true, keysReady: true)
    let setup = store.setupModel(displayName: "Maya Rahman", facts: facts)
    #expect(store.setupModel(displayName: "Maya Rahman", facts: facts) === setup)
    let replacement = store.replacementModel()
    #expect(store.replacementModel() === replacement)
    let signup = store.signup
    store.signup.displayName = "Maya"
    #expect(store.signup === signup && store.signup.displayName == "Maya")
  }

  /// A gate made again (a body pass, the passcode wall, the launch view, a wall) asks the
  /// store again, as its body does, and gets the same models with what was typed. (The
  /// gate's body itself only renders in a window.)
  @Test func aRemadeGateCannotResetThem() {
    let (store, session) = store(phase: .onboarding)
    let facts = OnboardingStep.Facts(hasSession: true, keysReady: true)
    let setup = store.setupModel(displayName: "Maya", facts: facts)
    setup.toggle(.dib)
    setup.toggle(.adib)
    for _ in 0..<3 {
      _ = AccountRootView(session: session, onboarding: store, setupFacts: facts) { EmptyView() }
      _ = store.setupModel(displayName: session.account.profile?.displayName ?? "", facts: facts)
      store.phaseChanged(from: nil, to: session.phase)
    }
    let again = store.setupModel(displayName: "Maya", facts: facts)
    #expect(again === setup && again.orderedBanks == [.enbd])
    store.storyPage = 2
    store.phaseChanged(from: .onboarding, to: .ready)
    #expect(store.setup === setup && store.storyPage == 2)
  }

  /// Signing out after a signed-in phase drops every draft; the stories' page stays.
  @Test func signingOutDropsTheDrafts() {
    let (store, _) = store()
    store.phaseChanged(from: nil, to: .signedOut)
    store.signup.email = "maya@example.com"
    store.signIn.email = "maya@example.com"
    store.storyPage = 3
    // A failed sign-in, Back and walls keep everything.
    store.phaseChanged(from: .signedOut, to: .signedOut)
    #expect(store.signup.email == "maya@example.com")
    store.phaseChanged(from: .signedOut, to: .onboarding)
    let setup = store.setupModel(displayName: "Maya", facts: .init(hasSession: true, keysReady: true))
    _ = store.replacementModel()
    store.phaseChanged(from: .onboarding, to: .signedOut)
    #expect(store.setup == nil && store.replacement == nil)
    #expect(store.signup.email.isEmpty && store.signIn.email.isEmpty)
    #expect(store.storyPage == 3)
    #expect(store.setupModel(displayName: "Maya", facts: .init(hasSession: true, keysReady: true)) !== setup)
    // The gate appearing again (old phase unknown) remembers the last one it saw.
    store.phaseChanged(from: nil, to: .ready)
    store.signup.email = "someone@example.com"
    store.phaseChanged(from: nil, to: .signedOut)
    #expect(store.signup.email.isEmpty)
  }

  /// After a relaunch the draft is empty: done flags come from the account (OR-ed with what
  /// this process did), the mailbox from the lane, and the banks are read back.
  @Test func reconcileOrsTheFactsAndFillsAnEmptyDraft() {
    let account = MockAccountService(existing: .passkey, signedIn: true)
    account.delay = .zero
    let mailbox = MockMailbox()
    mailbox.banks = [.dib]
    let services = AccountServices(account: account, mailbox: mailbox, setup: MockSetupAuthoring(),
                                   notifications: MockNotificationPermission())
    let session = AccountSession(services: services, phase: .onboarding)
    let store = OnboardingStore(services: services, session: { session })
    var facts = OnboardingStep.Facts(hasSession: true, keysReady: true, banksChosen: true)
    let setup = store.setupModel(displayName: "Maya", facts: facts)
    #expect(setup.orderedBanks == [.dib])
    #expect(setup.step == .mail)
    #expect(setup.draft.authored.banks == [.dib])

    setup.toggle(.enbd)
    facts.banksChosen = false
    facts.mailbox = .scanning
    _ = store.setupModel(displayName: "Maya", facts: facts)
    #expect(setup.facts.banksChosen && setup.facts.mailbox == .scanning && setup.orderedBanks == [.enbd, .dib])
    #expect(setup.step == .finished)
  }

  /// A store that failed to open draws setup under its wall with the gate's placeholder
  /// facts (the bank step), so the first `resume()` stays there; once the runtime opens on
  /// "Try again", the real facts reach the same model, and an account already past the
  /// email step opens Home.
  @Test func aResumeAtThePlaceholderStepWaitsForTheRealFacts() {
    let (store, session) = store(phase: .onboarding)
    let placeholder = OnboardingStep.Facts(hasSession: true, keysReady: true)
    let setup = store.setupModel(displayName: "Maya", facts: placeholder)
    setup.resume()
    #expect(setup.step == .bank && setup.path.isEmpty && session.phase == .onboarding)
    var real = placeholder
    real.banksChosen = true
    real.mailbox = .linked
    #expect(store.setupModel(displayName: "Maya", facts: real) === setup)
    setup.resume()
    #expect(setup.step == .finished && session.phase == .ready)

    let (other, otherSession) = self.store(phase: .onboarding)
    let moving = other.setupModel(displayName: "Maya", facts: placeholder)
    moving.resume()
    moving.skipBanks()
    #expect(otherSession.phase == .ready)
  }

  /// The replacement phrase is made once, not on every render of its flow.
  @Test func theReplacementPhraseIsMadeOnce() {
    let (store, _) = store(phase: .needsKeys)
    let first = store.replacementModel()
    let words = first.phrase?.words
    #expect(words?.count == 12 && first.replacing)
    first.phraseRevealed = true
    #expect(store.replacementModel().phraseSeen && store.replacementModel().phrase?.words == words)
  }

  /// The system back button (plan decision 7) pops through `navigationPath` and leaves the
  /// failure of the screen it left behind; a pop the model makes itself keeps the failure it
  /// set for the screen it lands on ("We couldn't find that invite").
  @Test func goingBackLeavesTheFailureBehindButAModelPopKeepsIt() {
    let (store, _) = store()
    let signup = store.signup
    signup.path = [.invite, .aboutYou]
    signup.failure = .notInvited
    signup.navigationPath = [.invite]
    #expect(signup.failure == nil && signup.path == [.invite])
    signup.failure = .notInvited
    signup.path.removeAll { $0 == .invite }
    #expect(signup.failure == .notInvited)

    let setup = store.setupModel(displayName: "Maya", facts: .init(hasSession: true, keysReady: true))
    setup.path = [.connectError(.outlook)]
    setup.failure = .offline
    setup.navigationPath = []
    #expect(setup.failure == nil && setup.path.isEmpty)
  }
}

@MainActor
@Suite("Account gate phases")
struct AccountGatePhaseTests: AccountSuite {
  private let holder = FreezeInfo(by: .holder, when: nil)

  private func signedInAccount() -> MockAccountService {
    MockAccountService(existing: .passkey, signedIn: true)
  }

  private func session(_ phase: AccountSession.Phase) -> AccountSession {
    AccountSession(services: services(signedInAccount()), phase: phase)
  }

  private func store(_ account: MockAccountService, phase: AccountSession.Phase) -> (OnboardingStore, AccountSession) {
    let session = AccountSession(services: services(account), phase: phase)
    return (OnboardingStore(services: session.services, session: { session }), session)
  }

  private var everyPhase: [AccountSession.Phase] {
    [.signedOut, .checking, .onboarding, .needsUnlock(passkeyCanUnlock: false), .needsKeys, .frozen(holder), .ready]
  }

  @Test func eachStepMovesTheGateOnlyFromItsOwnPhase() {
    for phase in everyPhase {
      let created = session(phase)
      created.accountCreated()
      #expect(created.phase == (phase == .signedOut || phase == .needsKeys ? .onboarding : phase), "\(phase)")
      let unlocked = session(phase)
      unlocked.unlocked()
      #expect(unlocked.phase == (phase == .needsUnlock(passkeyCanUnlock: false) ? .ready : phase), "\(phase)")
      let finished = session(phase)
      finished.setupFinished()
      #expect(finished.phase == (phase == .onboarding ? .ready : phase), "\(phase)")
      let left = session(phase)
      left.leaveFrozen()
      #expect(left.phase == (phase == .frozen(holder) ? .ready : phase), "\(phase)")
      let unfrozen = session(phase)
      unfrozen.unfroze()
      #expect(unfrozen.phase == (phase == .frozen(holder) ? .ready : phase), "\(phase)")
    }
  }

  @Test func leavingAFreezeFromSetupGoesBackToSetupWithTheBanner() {
    let s = session(.onboarding)
    s.runFoundFrozen(holder)
    #expect(s.phase == .frozen(holder))
    s.leaveFrozen()
    #expect(s.phase == .onboarding)
    #expect(s.leftFrozen == holder)
    s.runFoundFrozen(holder)
    #expect(s.phase == .onboarding)
    #expect(s.leftFrozen == holder)
    s.setupFinished()
    #expect(s.phase == .ready)
    #expect(s.leftFrozen == holder)
  }

  @Test func theWallFromTheBannerInSetupStillGoesBackToSetup() {
    let s = session(.onboarding)
    s.froze(holder)
    s.leaveFrozen()
    s.showFrozenWall()
    #expect(s.phase == .frozen(holder))
    s.runFoundFrozen(holder)
    #expect(s.phase == .frozen(holder))
    s.leaveFrozen()
    #expect(s.phase == .onboarding)
  }

  @Test func unfreezingFromSetupGoesBackToSetup() async throws {
    let account = signedInAccount()
    account.freezeForScenario(by: .holder)
    let (_, s) = store(account, phase: .onboarding)
    s.froze(holder)
    try await s.unfreeze(password: nil)
    #expect(s.phase == .onboarding)
    #expect(s.leftFrozen == nil)
  }

  @Test func aFreezeFromTheAppStillOpensTheApp() {
    let s = session(.ready)
    s.froze(holder)
    s.leaveFrozen()
    #expect(s.phase == .ready)
    #expect(s.leftFrozen == holder)
  }

  @Test func aFreezeAfterASignOutForgetsTheSetupBehindTheEarlierWall() {
    let s = session(.onboarding)
    s.froze(holder)
    s.signedOut()
    s.signedIn(.frozen(holder))
    s.leaveFrozen()
    #expect(s.phase == .ready)
  }

  @Test func setupThatFinishesUnderTheWallLeavesToTheApp() async {
    let (store, s) = store(signedInAccount(), phase: .onboarding)
    let setup = store.setupModel(displayName: "Maya", facts: .init(hasSession: true, keysReady: true))
    let load = Task { await setup.useSampleData() }
    while !setup.busy { await Task.yield() }
    s.froze(holder)
    await load.value
    #expect(s.phase == .frozen(holder))
    s.leaveFrozen()
    #expect(s.phase == .ready)
    #expect(s.leftFrozen == holder)
  }

  @Test func setupThatFinishesAfterASignOutStaysSignedOut() async {
    let (store, s) = store(signedInAccount(), phase: .onboarding)
    let setup = store.setupModel(displayName: "Maya", facts: .init(hasSession: true, keysReady: true))
    let load = Task { await setup.useSampleData() }
    while !setup.busy { await Task.yield() }
    s.signedOut()
    await load.value
    #expect(s.phase == .signedOut)
  }

  @Test func anUnfreezeAnsweredAfterTheWallLeftChangesNothing() async {
    let account = signedInAccount()
    account.freezeForScenario(by: .holder)
    let (_, s) = store(account, phase: .frozen(holder))
    account.delay = .milliseconds(20)
    let unfreeze = Task { try? await s.unfreeze(password: nil) }
    await Task.yield()
    s.signedOut()
    await unfreeze.value
    #expect(s.phase == .signedOut)
  }

  private var inviteLink: URL { URL(string: "https://hasala.app/i/\(Self.code)")! }

  @Test func anInviteLinkLeavesYoureBackInOnScreen() async {
    let (store, s) = store(MockAccountService(existing: .passkey), phase: .signedOut)
    let m = store.signIn
    m.phraseText = MockAccountService.phraseWords.joined(separator: " ")
    #expect(await m.submitRecoveryWords())
    m.recoverCode = MockAccountService.emailCode
    #expect(await m.finishRecovery(.passkey) == .done)
    store.signup.path = [.signIn, .recoverIntro, .recoverWords, .recoverCode, .recoverMethod]
    s.open(inviteLink)
    store.consumeInvite()
    #expect(s.pendingInvite == nil)
    #expect(store.signup.path.last == .recoverMethod)
    #expect(s.notice == "You already have an account")
    m.recoveryDone()
    #expect(s.phase == .ready)
  }

  @Test func anInviteLinkLeavesAMadeAccountOnScreen() async {
    let (store, s) = store(MockAccountService(), phase: .signedOut)
    let m = store.signup
    m.inviteText = Self.code
    m.submitInvite()
    m.displayName = "Maya Rahman"
    m.email = "maya@example.com"
    await m.submitAboutYou()
    m.code = MockAccountService.emailCode
    await m.submitCode()
    await m.continueWithMethod()
    showPhrase(m)
    await m.finish()
    #expect(m.path.last == .accountReady)
    s.open(inviteLink)
    store.consumeInvite()
    #expect(m.path.last == .accountReady)
    #expect(s.notice == "You already have an account")
  }

  @Test func anInviteLinkStillOpensForSomeoneWithoutAnAccount() {
    let (store, s) = store(MockAccountService(), phase: .signedOut)
    store.signup.path = [.signIn]
    s.open(inviteLink)
    store.consumeInvite()
    #expect(s.pendingInvite == nil)
    #expect(store.signup.path == [.inviteReady])
    #expect(store.signup.normalizedInvite == Self.code)
    #expect(s.notice == nil)
  }

  @Test func aReplacementPhraseThatFailedIsMadeAgainFromItsButton() {
    let account = signedInAccount()
    account.refusePhrase = .unsupported
    let (store, _) = store(account, phase: .needsKeys)
    let m = store.replacementModel()
    #expect(m.phrase == nil)
    #expect(m.failure == .unsupported)
    account.refusePhrase = .unsupported
    m.showReplacementWords()
    #expect(m.phrase == nil)
    #expect(m.failure == .unsupported)
    #expect(m.path.isEmpty)
    m.showReplacementWords()
    #expect(m.phrase?.words.count == 12)
    #expect(m.failure == nil)
    #expect(m.path == [.phraseShow])
  }

  @Test func theReplacementPhraseIsNotMadeAgainOnceItExists() {
    let (store, _) = store(signedInAccount(), phase: .needsKeys)
    let m = store.replacementModel()
    m.showReplacementWords()
    m.phraseRevealed = true
    m.back()
    m.showReplacementWords()
    #expect(m.phraseSeen)
    #expect(m.path == [.phraseShow])
  }
}
