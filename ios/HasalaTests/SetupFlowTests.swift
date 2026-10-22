import Foundation
import HasalaDesign
import HasalaMocks
import HasalaModels
import Observation
import Testing

@testable import Hasala

/// Setup after the account (bank to done), on the in-memory mock: the steps, the email
/// step's providers and failures, and what setup remembers for the life of the process
/// (plan B3: Back never reverts, Forward shows what was left, nothing is sent or signed in
/// twice).
@MainActor
@Suite("Setup flows")
struct SetupFlowTests: AccountSuite {
  func model(_ s: AccountServices, facts: OnboardingStep.Facts = .init(hasSession: true, keysReady: true),
             finished: @escaping () -> Void = {}) -> SetupModel {
    SetupModel(services: s, displayName: "Maya Rahman", facts: facts, onFinished: finished)
  }

  /// Waits for the mock's first scan to finish.
  func scanFinishes(_ m: SetupModel) async throws {
    for _ in 0..<400 where !m.scanDone { try await Task.sleep(for: .milliseconds(10)) }
    #expect(m.scanDone)
  }

  @Test func setupRunsBankToDone() async throws {
    let s = services(MockAccountService(existing: .passkey, signedIn: true))
    var finished = false
    let m = model(s) { finished = true }
    #expect(m.step == .bank)
    m.toggle(.dib)
    #expect(m.orderedBanks == [.enbd, .adib])
    m.toggle(.dib)
    #expect(m.connectable == [.gmail, .outlook] && m.provider == .gmail)
    await m.continueWithBanks()
    #expect((s.setup as? MockSetupAuthoring)?.banks == [.enbd, .dib, .adib])
    #expect(!m.choosingEmail)
    #expect(m.step == .scan && m.path == [.scan])
    #expect(m.connectedMailbox?.provider == .gmail)
    m.planWhileScanning()
    #expect(m.step == .income)
    for d in [2, 5, 0, 0, 0] { m.incomeEntry.type(.digit(d)) }
    #expect(m.incomeMinor == 2_500_000 && m.incomeDisplay == "25,000")
    m.continueWithIncome()
    await m.savePlan()
    let setup = try #require(s.setup as? MockSetupAuthoring)
    #expect(setup.income == 2_500_000 && setup.payday == 28)
    #expect(setup.plan == StartingPlan())
    #expect(m.plan.amounts(income: 2_500_000) == (1_250_000, 750_000, 500_000))
    // No cards step: the result, finished or not, then notifications.
    #expect(m.path.last == .result)
    #expect(m.step == .notifications)
    try await scanFinishes(m)
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

  /// A review account's email step offers the sample month, which completes the email,
  /// the scan, income and plan.
  @Test func reviewAccountsCanUseSampleData() async {
    let s = services(MockAccountService(existing: .passkey, signedIn: true), sample: true)
    let m = model(s)
    #expect(m.offersSampleData)
    for bank in SupportedBank.allCases { m.toggle(bank) }
    #expect(m.chosenBanks.isEmpty)
    await m.useSampleData()
    let setup = s.setup as? MockSetupAuthoring
    #expect(setup?.banks == [] && setup?.chooseBanksCalls == 0 && setup?.setBanksCalls == 0)
    #expect(m.step == .notifications && m.path == [.notifications])
  }

  @Test func aSecondConnectWhileOneRunsDoesNothing() async throws {
    let s = services(MockAccountService(existing: .passkey, signedIn: true))
    let lane = try #require(s.mailbox as? MockMailbox)
    lane.connectDelay = .milliseconds(50)
    let m = model(s)
    async let first: Void = m.connectMail(.gmail)
    async let second: Void = m.connectMail(.gmail)
    _ = await (first, second)
    #expect(lane.connectCalls == 1 && !m.connecting)
    #expect(m.path == [.scan])
  }

  @Test func aPickInTheChooserStartsItsConnect() async throws {
    let m = model(services(MockAccountService(existing: .passkey, signedIn: true)))
    m.chooseEmail()
    m.choosingEnded()
    #expect(m.connectRequest == nil)
    m.chooseEmail()
    m.choose(.outlook)
    #expect(!m.choosingEmail && m.provider == .outlook && m.connectRequest == nil)
    m.choosingEnded()
    #expect(m.connectRequest == .outlook)
    m.connectRequest = nil
    m.choosingEnded()
    #expect(m.connectRequest == nil)
  }

  @Test func noAlertsCanMoveToAnotherMailboxAndScansIt() async throws {
    let base = MockMailbox()
    base.total = 0
    let mailbox = CountingMailbox(base)
    let m = model(services(with: mailbox))
    await m.continueWithBanks()
    try await scanFinishes(m)
    m.planWhileScanning()
    #expect(m.foundNoAlerts && mailbox.scans == 1)
    m.useDifferentEmail()
    #expect(m.path.isEmpty && m.choosingEmail)
    m.choose(.outlook)
    m.choosingEnded()
    #expect(m.connectRequest == .outlook)
    m.connectRequest = nil
    await m.connectMail(.outlook, replacing: true, removingOld: false)
    #expect(m.path == [.scan] && mailbox.scans == 2)
    #expect(m.connectedMailbox?.provider == .outlook && !m.facts.scanDeferred)
    try await scanFinishes(m)
  }

  /// Offline, the email step says so in the provider's words (spec copy), and stays put.
  @Test func anOfflineConnectNamesTheProvider() async throws {
    let s = services(MockAccountService(existing: .passkey, signedIn: true))
    let lane = try #require(s.mailbox as? MockMailbox)
    lane.offline = true
    let m = model(s)
    await m.continueWithBanks()
    #expect(m.failure?.message == "You're offline. Connect Gmail when you're back online.")
    #expect(m.path == [] && m.facts.mailbox == .unlinked)
    #expect(m.connectFailure(.gmail) == .offline)
    #expect(SetupModel.setupFailure(.offline, .outlook).message == "You're offline. Connect Outlook when you're back online.")
    #expect(SetupModel.setupFailure(.cancelled, .gmail) == .cancelled)
  }

  /// The two failures the design draws a screen for push it; trying again from there,
  /// once it works, replaces it with the first scan. A closed Google sign-in changes
  /// nothing.
  @Test func outlookFailuresHaveTheirScreensAndTryAgainGoesOn() async throws {
    let s = services(MockAccountService(existing: .passkey, signedIn: true))
    let lane = try #require(s.mailbox as? MockMailbox)
    lane.outlookAdmin = true
    let m = model(s)
    m.pickProvider(.outlook)
    await m.continueWithBanks()
    #expect(m.path == [.connectError(.outlook)])
    #expect(m.connectFailure(.outlook) == .adminApprovalNeeded(address: MockMailbox.workAddress))
    // The view's own outcome watch arriving too pushes nothing more.
    m.connectFailed(.outlook)
    #expect(m.path == [.connectError(.outlook)])

    lane.outlookAdmin = false
    lane.outlookCancelled = true
    await m.retryConnect(.outlook)
    #expect(m.connectFailure(.outlook) == .cancelled && m.path.last == .connectError(.outlook))

    lane.outlookCancelled = false
    await m.retryConnect(.outlook)
    #expect(m.path == [.scan] && m.facts.mailbox == .scanning)
    #expect(m.draft.provider == .outlook && m.connectedMailbox?.provider == .outlook)
    #expect(lane.connectCalls == 3)

    // "Choose a different email" from an error screen: the chooser, then the pick takes the
    // email step's place.
    let other = model(services(MockAccountService(existing: .passkey, signedIn: true)))
    let otherLane = try #require(other.mailbox as? MockMailbox)
    otherLane.outlookCancelled = true
    other.pickProvider(.outlook)
    await other.continueWithBanks()
    #expect(other.path == [.connectError(.outlook)])
    other.chooseEmail()
    #expect(other.choosingEmail)
    other.pickProvider(.gmail)
    #expect(other.path == [] && !other.choosingEmail && other.provider == .gmail)
  }

  @Test func aMicrosoftAccountWithNoMailboxHasItsScreenInSetup() async throws {
    let s = services(MockAccountService(existing: .passkey, signedIn: true))
    let lane = try #require(s.mailbox as? MockMailbox)
    lane.outlookNoMailbox = true
    let m = model(s)
    m.pickProvider(.outlook)
    await m.continueWithBanks()
    #expect(m.path == [.connectError(.outlook)])
    #expect(m.connectFailure(.outlook) == .noMailbox(.outlook))
    await m.retryConnect(.outlook)
    #expect(m.path == [.scan] && m.facts.mailbox == .scanning)
    #expect(lane.connectCalls == 2)
  }

  @Test func aRetryInSetupKeepsAConfirmedSwitch() async throws {
    let s = services(MockAccountService(existing: .passkey, signedIn: true))
    let lane = try #require(s.mailbox as? MockMailbox)
    lane.outlookNoMailbox = true
    let m = model(s)
    m.pickProvider(.outlook)
    #expect(await m.saveBanks())
    await m.connectMail(.outlook, replacing: true, removingOld: false)
    #expect(m.path == [.connectError(.outlook)])
    await m.retryConnect(.outlook)
    #expect(lane.replacingCalls == [true, true])
    #expect(m.path == [.scan])
  }

  @Test func aRemoveThatFailedDuringASwitchInSetupIsSaid() async throws {
    let lane = MockMailbox(mailboxes: [MockMailbox.gmail])
    lane.connectDelay = .zero
    lane.step = .milliseconds(1)
    lane.holdOneLink()
    lane.switchRemoveFails = true
    let m = model(services(with: lane))
    m.pickProvider(.outlook)
    #expect(await m.saveBanks())
    await m.connectMail(.outlook, replacing: true, removingOld: true)
    #expect(m.failure == .failed(
      "Outlook connected. Checking for alerts. The transactions from maya@example.com couldn't be removed. They stay."))
    #expect(m.coordinator(.outlook).takeRemovalFailure() == nil)
  }

  /// A closed Google sign-in is not an error: the screen stays as it was.
  @Test func aClosedGoogleSignInChangesNothing() async throws {
    let mailbox = CountingMailbox(MockMailbox())
    mailbox.cancelGmail = true
    let m = model(services(with: mailbox))
    await m.continueWithBanks()
    #expect(m.path == [] && m.failure == nil && m.connectFailure(.gmail) == nil)
    #expect(m.facts.mailbox == .unlinked)
  }

  /// The memory test (owner requirement 4): connect, Back to the bank, Continue: the email
  /// step shows connected and goes on without a second sign-in, scan or bank ops; the
  /// salary, payday and split survive Back and Forward; an unchanged plan isn't sent
  /// again, a changed one is.
  @Test func backAndForwardKeepsEverythingAndNeverRepeatsAnything() async throws {
    let mailbox = CountingMailbox(MockMailbox())
    let s = services(with: mailbox)
    let setup = try #require(s.setup as? MockSetupAuthoring)
    let m = model(s)
    await m.continueWithBanks()
    #expect(m.path == [.scan])
    m.navigationPath = []
    #expect(m.mailConnected)
    #expect(m.coordinator(.gmail).outcome == .connected(mailboxID: "gmail-1"))
    await m.continueWithBanks()
    #expect(!m.choosingEmail && m.path == [.scan])
    m.continueConnected()
    #expect(m.path == [.scan])
    #expect(mailbox.base.connectCalls == 1 && mailbox.scans == 1 && setup.chooseBanksCalls == 1)

    // 25,000 on the keypad, payday the 25th, the split moved: all of it stays.
    m.planWhileScanning()
    for d in [2, 5, 0, 0, 0] { m.incomeEntry.type(.digit(d)) }
    m.paydayChoice = .day(25)
    m.continueWithIncome()
    m.plan = m.plan.moving(handle: 0, to: 60)
    await m.savePlan()
    #expect(setup.savePlanCalls == 1 && setup.income == 2_500_000 && setup.payday == 25)
    #expect(setup.plan == StartingPlan(needsPercent: 60, wantsPercent: 20, savingsPercent: 20))
    m.navigationPath = [.scan, .income, .plan]
    m.navigationPath = [.scan, .income]
    m.navigationPath = [.scan]
    m.navigationPath = []
    await m.continueWithBanks()
    #expect(m.path == [.scan])
    m.planWhileScanning()
    #expect(m.incomeDisplay == "25,000" && m.paydayChoice == .day(25) && m.plan.needsPercent == 60)
    m.continueWithIncome()
    await m.savePlan()
    #expect(setup.savePlanCalls == 1)  // unchanged: not sent again
    #expect(mailbox.base.connectCalls == 1 && mailbox.scans == 1 && setup.chooseBanksCalls == 1)

    m.back()
    m.plan = m.plan.moving(handle: 1, to: 90)
    await m.savePlan()
    #expect(setup.savePlanCalls == 2 && setup.plan?.savingsPercent == 10)  // a real change is sent
  }

  @Test func untickingABankAfterBackRemovesIt() async throws {
    let s = services(MockAccountService(existing: .passkey, signedIn: true))
    let setup = try #require(s.setup as? MockSetupAuthoring)
    let m = model(s)
    m.toggle(.adib)
    #expect(m.orderedBanks == [.enbd, .dib])
    #expect(await m.saveBanks())
    #expect(setup.banks == [.enbd, .dib] && setup.chooseBanksCalls == 1 && setup.setBanksCalls == 0)
    #expect(m.path.isEmpty)
    m.toggle(.dib)
    #expect(await m.saveBanks())
    #expect(setup.banks == [.enbd])
    #expect(setup.chooseBanksCalls == 1 && setup.setBanksCalls == 1)
  }

  @Test func useOtherProviderOpensTheChooserAndThePickStaysOnTheBankStep() async throws {
    let m = model(services(MockAccountService(existing: .passkey, signedIn: true)))
    #expect(m.canChooseEmail && m.provider == .gmail)
    m.chooseEmail()
    #expect(m.choosingEmail && m.path.isEmpty)
    m.pickProvider(.outlook)
    #expect(!m.choosingEmail && m.path.isEmpty && m.provider == .outlook)
    await m.continueWithBanks()
    #expect(m.path == [.scan] && m.connectedMailbox?.provider == .outlook)

    let s = services(MockAccountService(existing: .passkey, signedIn: true))
    let lane = try #require(s.mailbox as? MockMailbox)
    lane.connectable = [.gmail]
    let single = model(s)
    single.chooseEmail()
    #expect(!single.choosingEmail && !single.canChooseEmail)
  }

  @Test func aMissingGmailGrantHasItsOwnLine() async throws {
    let s = services(MockAccountService(existing: .passkey, signedIn: true))
    let lane = try #require(s.mailbox as? MockMailbox)
    lane.connectDelay = .zero
    lane.gmailPermissionMissing = true
    let m = model(s)
    await m.continueWithBanks()
    #expect(m.connectFailure(.gmail) == .permissionMissing(.gmail))
    #expect(m.failure?.message == "Hasala needs \u{201C}View your email messages and settings\u{201D} ticked. Try again and tick it.")
    #expect(m.path == [] && m.facts.mailbox == .unlinked)
    await m.continueWithBanks()
    #expect(m.failure == nil && m.path == [.scan])
  }

  @Test func checkAgainAfterNoAlertsReadsTheMailboxAgain() async throws {
    let base = MockMailbox()
    base.total = 0
    let mailbox = CountingMailbox(base)
    let m = model(services(with: mailbox))
    await m.continueWithBanks()
    try await scanFinishes(m)
    #expect(m.foundNoAlerts && mailbox.scans == 1)
    await m.checkAgain()
    #expect(m.foundNoAlerts && mailbox.scans == 2 && !m.checkingAgain)
    base.total = 24
    await m.checkAgain()
    #expect(!m.foundNoAlerts && m.summary?.total == 24 && mailbox.scans == 3)
    await m.checkAgain()
    #expect(mailbox.scans == 3)
  }

  /// A relaunch whose facts say the mail is linked to Outlook, before the lane's status is
  /// read (no rows yet): setup's email step is Outlook's and shows it connected; Gmail's
  /// screen would be a new connect, not "Gmail is connected".
  @Test func aRelaunchLinkedToOutlookShowsOutlookConnected() async throws {
    let lane = CountingMailbox(MockMailbox())
    lane.linkedOverride = .outlook
    var facts = OnboardingStep.Facts(hasSession: true, keysReady: true)
    facts.banksChosen = true
    facts.mailbox = .linked
    let m = model(services(with: lane), facts: facts)
    #expect(lane.mailboxes.isEmpty && lane.linkedProvider == .outlook)
    #expect(m.provider == .outlook)
    let link = SetupMailLink(base: lane)
    link.isLinked = { true }
    #expect(link.existing(.outlook) == "outlook")
    #expect(link.existing(.gmail) == nil)
  }

  /// Whole dirhams on this step: the decimal key is ignored, as page 11 ignores any key that
  /// breaks the rules. Skip keeps what was typed for Back but sends no income.
  @Test func incomeIsWholeDirhamsAndSkipKeepsWhatWasTyped() async throws {
    let s = services(MockAccountService(existing: .passkey, signedIn: true))
    let setup = try #require(s.setup as? MockSetupAuthoring)
    let m = model(s)
    m.skipBanks()
    for key in [AmountKey.digit(4), .digit(8), .decimal, .digit(5)] { m.incomeEntry.type(key) }
    #expect(m.incomeText == "485" && m.incomeMinor == 48_500)
    m.incomeEntry = AmountEntry(typing: "12.50")
    #expect(m.incomeText == "485")
    m.incomeEntry.type(.delete)
    m.incomeEntry.type(.delete)
    m.incomeEntry.type(.delete)
    #expect(m.incomeMinor == nil)
    m.continueWithIncome()  // disabled at 0: nothing happens
    #expect(m.path == [.income])
    m.incomeText = "25000"
    m.skipIncome()
    #expect(m.savedIncomeMinor == nil && m.incomeText == "25000" && m.step == .plan)
    await m.savePlan()
    #expect(setup.planSaved && setup.income == nil && setup.payday == nil)
    m.back()
    m.back()
    #expect(m.path == [.income] && m.incomeDisplay == "25,000")
    m.continueWithIncome()
    #expect(m.savedIncomeMinor == 2_500_000 && !m.facts.incomeSkipped)
  }

  /// The payday strip's days: the next one from the ledger's today, a day a month doesn't
  /// have on its last day, and the last working day (Monday to Friday) sent as its day.
  @Test func paydaysFallOnRealDays() {
    let today = LocalDate(2026, 10, 10)  // Saturday
    #expect(PaydayChoice.day(28).next(onOrAfter: today) == LocalDate(2026, 10, 28))
    #expect(PaydayChoice.day(5).next(onOrAfter: today) == LocalDate(2026, 11, 5))
    #expect(PaydayChoice.day(10).next(onOrAfter: today) == today)
    #expect(PaydayChoice.day(31).next(onOrAfter: LocalDate(2026, 11, 2)) == LocalDate(2026, 11, 30))
    // 31 Oct 2026 is a Saturday: the last working day is Friday the 30th.
    #expect(PaydayChoice.lastWorkingDay.next(onOrAfter: today) == LocalDate(2026, 10, 30))
    #expect(PaydayChoice.lastWorkingDay.opDay(today: today) == 30)
    #expect(PaydayChoice.day(31).opDay(today: today) == 31)
    #expect(PaydayChoice.all.count == 32 && PaydayChoice.all.last == .lastWorkingDay)
    #expect(PaydayChoice.all.allSatisfy { PaydayChoice.all[$0.index] == $0 })
    #expect(["1st", "2nd", "3rd", "4th", "11th", "12th", "13th", "21st", "22nd", "23rd", "31st"]
      == [1, 2, 3, 4, 11, 12, 13, 21, 22, 23, 31].map { PaydayChoice.day($0).spoken })

    let m = model(services(MockAccountService(existing: .passkey, signedIn: true)))
    #expect(m.today == MayaLedger.now.date && m.paydayChoice == .day(28) && m.nextPayday == LocalDate(2026, 10, 28))
    m.paydayChoice = .lastWorkingDay
    #expect(m.payday == 30)
  }

  /// The split's handles move in 5% steps; no bucket goes under 0% and the three make 100.
  @Test func theSplitHandlesKeepTheSplitWhole() {
    let start = StartingPlan()
    #expect(start.moving(handle: 0, to: 62) == StartingPlan(needsPercent: 60, wantsPercent: 20, savingsPercent: 20))
    #expect(start.moving(handle: 0, to: 95) == StartingPlan(needsPercent: 80, wantsPercent: 0, savingsPercent: 20))
    #expect(start.moving(handle: 0, to: -10) == StartingPlan(needsPercent: 0, wantsPercent: 80, savingsPercent: 20))
    #expect(start.moving(handle: 1, to: 40) == StartingPlan(needsPercent: 50, wantsPercent: 0, savingsPercent: 50))
    #expect(start.moving(handle: 1, to: 103) == StartingPlan(needsPercent: 50, wantsPercent: 50, savingsPercent: 0))
    #expect(start.moving(handle: 1, to: 87) == StartingPlan(needsPercent: 50, wantsPercent: 35, savingsPercent: 15))
    for i in [0, 1] {
      for b in stride(from: -20, through: 120, by: 7) { #expect(start.moving(handle: i, to: b).isValid) }
    }
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
    let m = model(s, facts: facts)
    m.resume()
    #expect(m.path == [.scan, .income, .plan, .result, .notifications])
    m.path = []
    m.resume()  // once per model
    #expect(m.path == [])
  }

  @Test func resumesAtTheDerivedStep() {
    let s = services(MockAccountService(existing: .passkey, signedIn: true))
    var facts = OnboardingStep.Facts(hasSession: true, keysReady: true, banksChosen: true)
    facts.mailSkipped = true
    let m = model(s, facts: facts)
    m.resume()
    #expect(m.path == [.income])
  }

  /// After a relaunch (a new model, the account's facts and values read back), the email
  /// step under the stack comes back connected without a sign-in, and the salary, payday
  /// and split are what the account holds.
  @Test func aRelaunchReadsBackTheValuesAndShowsTheEmailStepConnected() async throws {
    let lane = MockMailbox(mailboxes: [MockMailbox.gmail])
    let mailbox = CountingMailbox(lane)
    let saved = SetupReadBack(incomeMinor: 2_500_000, payday: 25,
                              split: StartingPlan(needsPercent: 60, wantsPercent: 20, savingsPercent: 20))
    let setup = MockSetupAuthoring(saved: saved)
    let s = services(with: mailbox, setup: setup)
    let session = AccountSession(services: s, phase: .onboarding(.plan))
    let store = OnboardingStore(services: s, session: { session })
    var facts = OnboardingStep.Facts(hasSession: true, keysReady: true, banksChosen: true)
    facts.mailbox = .linked
    facts.incomeSet = true
    facts.planSet = true
    let m = store.setupModel(displayName: "Maya", facts: facts)
    #expect(m.incomeDisplay == "25,000" && m.paydayChoice == .day(25) && m.plan.needsPercent == 60)
    #expect(m.step == .notifications)
    m.resume()
    #expect(m.path == [.income, .plan, .notifications])
    for _ in 0..<100 where m.coordinator(.gmail).outcome == nil { try await Task.sleep(for: .milliseconds(5)) }
    #expect(m.coordinator(.gmail).outcome == .connected(mailboxID: "gmail-1"))
    #expect(lane.connectCalls == 0)
    // Values the account holds count as sent: the same plan isn't sent again.
    m.path = [.income, .plan]
    await m.savePlan()
    #expect(setup.savePlanCalls == 0)
  }

  /// The store's model resumed twice keeps the person's place.
  @Test func resumeTwiceKeepsThePosition() {
    let s = services(MockAccountService(existing: .passkey, signedIn: true))
    var facts = OnboardingStep.Facts(hasSession: true, keysReady: true, banksChosen: true)
    facts.mailbox = .linked
    let m = model(s, facts: facts)
    m.resume()
    #expect(m.path == [.income])
    m.back()
    m.resume()
    #expect(m.path == [])
  }

  /// "Allow notifications" asks iOS once; back there it only goes on.
  @Test func notificationsAreAskedOnce() async throws {
    let s = services(MockAccountService(existing: .passkey, signedIn: true))
    let m = model(s)
    #expect(!m.systemAskedForNotifications)
    await m.allowNotifications()
    #expect(m.systemAskedForNotifications && m.path.last == .done)
    m.back()
    m.notNow()
    #expect(m.systemAskedForNotifications)
  }

  // MARK: Support

  func services(with mailbox: MailboxConnecting, setup: MockSetupAuthoring = MockSetupAuthoring()) -> AccountServices {
    let account = MockAccountService(existing: .passkey, signedIn: true)
    account.delay = .zero
    if let counting = mailbox as? CountingMailbox {
      counting.base.step = .milliseconds(1)
      counting.base.connectDelay = .zero
    }
    return AccountServices(account: account, mailbox: mailbox, setup: setup,
                           notifications: MockNotificationPermission())
  }
}

/// The mock lane, counting first scans (the import starts once per account) and able to
/// close Google's sign-in.
@MainActor
@Observable
final class CountingMailbox: MailboxConnecting {
  @ObservationIgnored let base: MockMailbox
  @ObservationIgnored private(set) var scans = 0
  @ObservationIgnored var cancelGmail = false
  /// The link a relaunch remembers before the lane's rows are read.
  @ObservationIgnored var linkedOverride: MailProviderKind?
  /// The account's link held by another iPhone (live: a new install or a recovered account).
  @ObservationIgnored var heldElsewhere: MailProviderKind?

  init(_ base: MockMailbox) { self.base = base }

  var connectable: [MailProviderKind] { base.connectable }
  var capabilities: MailboxCapabilities { base.capabilities }
  var mailboxes: [MailboxSnapshot] { base.mailboxes }
  var offer: MailOffer? { base.offer }
  var linkedProvider: MailProviderKind? { linkedOverride ?? base.linkedProvider }
  var offersSampleData: Bool { base.offersSampleData }
  func chosenBanks() -> [SupportedBank] { base.chosenBanks() }
  func linkState() async -> OnboardingStep.Facts.Mailbox { await base.linkState() }
  func connect(_ provider: MailProviderKind, replacing: Bool, removingOld: Bool, ask: @escaping MailSwitchAsk)
    async throws(MailConnectFailure) -> MailLinked
  {
    if cancelGmail, provider == .gmail { throw .cancelled }
    return try await base.connect(provider, replacing: replacing, removingOld: removingOld, ask: ask)
  }
  func signInAgain(_ mailboxID: String, ask: @escaping MailSwitchAsk) async throws(MailConnectFailure) -> MailLinked {
    try await base.signInAgain(mailboxID, ask: ask)
  }
  func tryAgain(_ mailboxID: String) async {
    await base.tryAgain(mailboxID)
  }
  func disconnect(_ mailboxID: String, removeTransactions: Bool) async throws(MailConnectFailure) {
    try await base.disconnect(mailboxID, removeTransactions: removeTransactions)
  }
  func disconnectImpact(_ mailboxID: String) async -> MailboxDisconnectImpact? { await base.disconnectImpact(mailboxID) }
  func firstScan() -> AsyncStream<ScanProgress> {
    scans += 1
    return base.firstScan()
  }
  func loadSampleData() async throws(SetupFailure) { try await base.loadSampleData() }
}
