import Foundation
import Testing

@testable import Hasala

/// Setup after the account (bank to done), on the in-memory mock.
@MainActor
@Suite("Setup flows")
struct SetupFlowTests: AccountSuite {
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
    facts.gmailSkipped = true
    let m = SetupModel(services: s, displayName: "Maya", facts: facts) {}
    m.resume()
    #expect(m.path == [.income])
  }
}
