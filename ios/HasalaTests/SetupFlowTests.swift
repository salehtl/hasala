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
    #expect(m.step == .mail)
    #expect(m.path == [.connect(.gmail)])
    await m.connectMail(.gmail)
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

  /// Offline, the email step says so in the provider's words (spec copy), and stays put.
  @Test func anOfflineConnectNamesTheProvider() async throws {
    let s = services(MockAccountService(existing: .passkey, signedIn: true))
    let lane = try #require(s.mailbox as? MockMailbox)
    lane.offline = true
    let m = SetupModel(services: s, displayName: "Maya", facts: .init(hasSession: true, keysReady: true)) {}
    await m.continueWithBanks()
    await m.connectMail(.gmail)
    #expect(m.failure?.message == "You're offline. Connect Gmail when you're back online.")
    #expect(m.path == [.connect(.gmail)] && m.facts.mailbox == .unlinked)
    #expect(SetupModel.setupFailure(.offline, .outlook).message == "You're offline. Connect Outlook when you're back online.")
    #expect(SetupModel.setupFailure(.cancelled, .gmail) == .cancelled)
  }

  /// A relaunch mid-scan follows the scan again, and Back walks the real steps before the
  /// derived one (plan B3.3: an honest back stack, built once).
  @Test func setupResumedWithTheScanStillRunningGoesOnToNotifications() {
    let s = services(MockAccountService(existing: .passkey, signedIn: true))
    var facts = OnboardingStep.Facts(hasSession: true, keysReady: true, banksChosen: true)
    facts.mailbox = .scanning
    facts.scanDeferred = true
    facts.incomeSkipped = true
    facts.planSkipped = true
    let m = SetupModel(services: s, displayName: "Maya", facts: facts) {}
    m.resume()
    #expect(m.path == [.connect(.gmail), .scan, .income, .plan, .result, .notifications])
    m.path = [.connect(.gmail)]
    m.resume()  // once per model
    #expect(m.path == [.connect(.gmail)])
  }

  @Test func resumesAtTheDerivedStep() {
    let s = services(MockAccountService(existing: .passkey, signedIn: true))
    var facts = OnboardingStep.Facts(hasSession: true, keysReady: true, banksChosen: true)
    facts.mailSkipped = true
    let m = SetupModel(services: s, displayName: "Maya", facts: facts) {}
    m.resume()
    #expect(m.path == [.connect(.gmail), .income])
  }

  /// Back to the email step after connecting shows it connected: Continue goes on to the
  /// scan without a second sign-in, and an unchanged bank choice sends nothing again
  /// (plan B3.2 rules 2 and 3).
  @Test func backAndForwardNeverConnectsOrAuthorsTwice() async throws {
    let s = services(MockAccountService(existing: .passkey, signedIn: true))
    let mailbox = try #require(s.mailbox as? MockMailbox)
    let setup = try #require(s.setup as? MockSetupAuthoring)
    let m = SetupModel(services: s, displayName: "Maya", facts: .init(hasSession: true, keysReady: true)) {}
    await m.continueWithBanks()
    await m.connectMail(.gmail)
    #expect(m.path == [.connect(.gmail), .scan])
    m.back()
    m.back()
    #expect(m.path.isEmpty && m.mailConnected)
    await m.continueWithBanks()
    await m.connectMail(.gmail)
    #expect(m.path == [.connect(.gmail), .scan])
    #expect(mailbox.connectCalls == 1 && setup.chooseBanksCalls == 1)
    m.planWhileScanning()
    m.incomeText = "25000"
    m.payday = 25
    m.continueWithIncome()
    await m.savePlan()
    m.back()
    m.back()
    #expect(m.incomeText == "25000" && m.payday == 25)
    m.continueWithIncome()
    await m.savePlan()
    #expect(setup.savePlanCalls == 1)
    m.back()
    m.plan = StartingPlan(needsPercent: 60, wantsPercent: 20, savingsPercent: 20)
    await m.savePlan()
    #expect(setup.savePlanCalls == 2 && setup.plan?.needsPercent == 60)
  }

  /// "Allow notifications" asks iOS once; back there it only goes on.
  @Test func notificationsAreAskedOnce() async throws {
    let s = services(MockAccountService(existing: .passkey, signedIn: true))
    let m = SetupModel(services: s, displayName: "Maya", facts: .init(hasSession: true, keysReady: true)) {}
    #expect(!m.notificationsAllowed)
    await m.allowNotifications()
    #expect(m.notificationsAllowed && m.path.last == .done)
    m.back()
    m.notNow()
    #expect(m.notificationsAllowed)
  }
}
