import Foundation
import Testing

@testable import Hasala

@Suite("Onboarding step")
struct OnboardingStepTests {
  typealias F = OnboardingStep.Facts

  @Test func stepsFollowTheFacts() {
    var f = F()
    f.hasPasscode = false
    #expect(OnboardingStep.derive(f) == .passcode)
    f.hasPasscode = true
    #expect(OnboardingStep.derive(f) == .account)
    f.hasSession = true
    #expect(OnboardingStep.derive(f) == .keys)
    f.keysReady = true
    #expect(OnboardingStep.derive(f) == .bank)
    f.banksChosen = true
    #expect(OnboardingStep.derive(f) == .mail)
    f.mailbox = .scanning
    #expect(OnboardingStep.derive(f) == .scan)
    f.scanDeferred = true
    #expect(OnboardingStep.derive(f) == .income)
    f.incomeSet = true
    #expect(OnboardingStep.derive(f) == .plan)
    f.planSet = true
    // No cards step: a scan still running doesn't hold setup up.
    #expect(OnboardingStep.derive(f) == .notifications)
    f.mailbox = .linked
    #expect(OnboardingStep.derive(f) == .notifications)
    f.notificationsAsked = true
    #expect(OnboardingStep.derive(f) == .done)
    f.finished = true
    #expect(OnboardingStep.derive(f) == .finished)
  }

  @Test func skippingTheBankSkipsTheEmailAndTheScan() {
    var f = F(hasSession: true, keysReady: true)
    f.bankSkipped = true
    #expect(OnboardingStep.derive(f) == .income)
    f.incomeSkipped = true
    f.planSkipped = true
    #expect(OnboardingStep.derive(f) == .notifications)
  }

  @Test func sampleDataCompletesTheEmailAndTheScan() {
    var f = F(hasSession: true, keysReady: true, banksChosen: true)
    f.sampleLoaded = true
    #expect(OnboardingStep.derive(f) == .notifications)
  }

  @Test func indicatorNumbers() {
    #expect(OnboardingStep.bank.indicator == 1)
    #expect(OnboardingStep.scan.indicator == 2)
    #expect(OnboardingStep.plan.indicator == 4)
    #expect(OnboardingStep.notifications.indicator == nil)
    #expect(OnboardingStep.done.indicator == nil)
  }
}
