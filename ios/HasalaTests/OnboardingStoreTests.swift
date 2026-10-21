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
    let (store, session) = store(phase: .onboarding(.bank))
    let facts = OnboardingStep.Facts(hasSession: true, keysReady: true)
    let setup = store.setupModel(displayName: "Maya", facts: facts)
    setup.incomeText = "25000"
    setup.toggle(.dib)
    setup.toggle(.adib)
    for _ in 0..<3 {
      _ = AccountRootView(session: session, onboarding: store, setupFacts: facts) { EmptyView() }
      _ = store.setupModel(displayName: session.account.profile?.displayName ?? "", facts: facts)
      store.phaseChanged(from: nil, to: session.phase)
    }
    let again = store.setupModel(displayName: "Maya", facts: facts)
    #expect(again === setup && again.incomeText == "25000" && again.orderedBanks == [.enbd])
    store.storyPage = 2
    store.phaseChanged(from: .onboarding(.bank), to: .ready)
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
    store.phaseChanged(from: .signedOut, to: .onboarding(.bank))
    let setup = store.setupModel(displayName: "Maya", facts: .init(hasSession: true, keysReady: true))
    _ = store.replacementModel()
    store.phaseChanged(from: .onboarding(.bank), to: .signedOut)
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
  /// this process did), the mailbox from the lane, and values are read back.
  @Test func reconcileOrsTheFactsAndFillsAnEmptyDraft() {
    let account = MockAccountService(existing: .passkey, signedIn: true)
    account.delay = .zero
    let saved = SetupReadBack(incomeMinor: 2_500_000, payday: 25,
                              split: StartingPlan(needsPercent: 60, wantsPercent: 20, savingsPercent: 20))
    let mailbox = MockMailbox()
    mailbox.banks = [.dib]
    let services = AccountServices(account: account, mailbox: mailbox, setup: MockSetupAuthoring(saved: saved),
                                   notifications: MockNotificationPermission())
    let session = AccountSession(services: services, phase: .onboarding(.bank))
    let store = OnboardingStore(services: services, session: { session })
    var facts = OnboardingStep.Facts(hasSession: true, keysReady: true, banksChosen: true)
    facts.incomeSet = true
    facts.mailbox = .linked
    let setup = store.setupModel(displayName: "Maya", facts: facts)
    #expect(setup.incomeText == "25000" && setup.payday == 25 && setup.plan.needsPercent == 60)
    #expect(setup.orderedBanks == [.dib])
    #expect(setup.step == .plan)
    // What the account holds counts as sent: the same plan again sends nothing.
    #expect(setup.draft.authored.plan == saved && setup.draft.authored.banks == [.dib])

    // The same process: what was done here stays done, what was typed wins.
    setup.incomeText = "30000"
    var later = facts
    later.incomeSet = false  // a runtime opened again, the projection not read yet
    later.mailbox = .scanning
    _ = store.setupModel(displayName: "Maya", facts: later)
    #expect(setup.facts.incomeSet && setup.facts.mailbox == .scanning && setup.incomeText == "30000")
  }

  /// A store that failed to open draws setup under its wall with the gate's placeholder
  /// facts (the bank step), so the first `resume()` has nothing to build; once the runtime
  /// opens on "Try again", the real facts reach the same model and its stack is built for
  /// them, as a fresh model's would be. A person who moved on in this process keeps their
  /// place.
  @Test func aResumeAtThePlaceholderStepWaitsForTheRealFacts() {
    let (store, _) = store(phase: .onboarding(.bank))
    let placeholder = OnboardingStep.Facts(hasSession: true, keysReady: true)
    let setup = store.setupModel(displayName: "Maya", facts: placeholder)
    setup.resume()
    #expect(setup.step == .bank && setup.path.isEmpty)
    var real = placeholder
    real.banksChosen = true
    real.mailbox = .linked
    real.incomeSet = true
    #expect(store.setupModel(displayName: "Maya", facts: real) === setup)
    setup.resume()
    let (other, _) = self.store(phase: .onboarding(.plan))
    let fresh = other.setupModel(displayName: "Maya", facts: real)
    fresh.resume()
    #expect(setup.step == .plan && fresh.step == .plan)
    #expect(setup.path == fresh.path && setup.path == [.connect(.gmail), .income, .plan])
    // Built once: Back, then a later call, leave the stack as the person left it.
    setup.back()
    setup.resume()
    #expect(setup.path == [.connect(.gmail), .income])

    // Moved on here before the facts changed: nothing is rebuilt over that place.
    let (third, _) = self.store(phase: .onboarding(.bank))
    let moving = third.setupModel(displayName: "Maya", facts: placeholder)
    moving.resume()
    moving.skipBanks()
    moving.resume()
    #expect(moving.path == [.income])
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
    signup.path = [.welcome, .invite, .aboutYou]
    signup.failure = .notInvited
    signup.navigationPath = [.welcome, .invite]
    #expect(signup.failure == nil && signup.path == [.welcome, .invite])
    signup.failure = .notInvited
    signup.path.removeAll { $0 == .invite }
    #expect(signup.failure == .notInvited)

    let setup = store.setupModel(displayName: "Maya", facts: .init(hasSession: true, keysReady: true))
    setup.path = [.connect(.gmail), .scan]
    setup.failure = .offline
    setup.navigationPath = [.connect(.gmail)]
    #expect(setup.failure == nil && setup.path == [.connect(.gmail)])
  }
}
