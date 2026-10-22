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
    #expect(OnboardingStep.derive(f) == .finished)
    f.mailbox = .linked
    #expect(OnboardingStep.derive(f) == .finished)
  }

  @Test func skippingTheBankFinishesSetup() {
    var f = F(hasSession: true, keysReady: true)
    f.bankSkipped = true
    #expect(OnboardingStep.derive(f) == .finished)
  }

  @Test func sampleDataFinishesSetup() {
    var f = F(hasSession: true, keysReady: true, banksChosen: true)
    f.sampleLoaded = true
    #expect(OnboardingStep.derive(f) == .finished)
  }

  @Test func theEmailStepIsProviderNeutral() {
    var f = F(hasSession: true, keysReady: true, banksChosen: true)
    #expect(OnboardingStep.derive(f) == .mail)
    f.mailSkipped = true
    #expect(OnboardingStep.derive(f) == .finished)
    f.mailSkipped = false
    f.mailbox = .otherDevice
    #expect(OnboardingStep.derive(f) == .finished)
  }
}
