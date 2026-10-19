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
    #expect(m.orderedBanks == [.enbd])
    m.toggle(.dib)
    await m.continueWithBanks()
    #expect((s.setup as? MockSetupAuthoring)?.banks == [.enbd, .dib])
    #expect(m.step == .mail)
    // Two providers and none chosen yet: "Choose your email" over the bank step.
    #expect(m.connectable == [.gmail, .outlook])
    #expect(m.choosingEmail && m.path.isEmpty)
    // The view resumes when the derived step changes: nothing is pushed under the chooser.
    m.resume()
    #expect(m.choosingEmail && m.path.isEmpty)
    m.pickProvider(.gmail)
    #expect(!m.choosingEmail && m.path == [.connect(.gmail)])
    await m.connectMail(.gmail)
    #expect(m.step == .scan && m.path == [.connect(.gmail), .scan])
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
    await m.continueWithBanks()
    m.pickProvider(.gmail)
    await m.useSampleData()
    #expect(m.step == .notifications && m.path == [.connect(.gmail), .notifications])
  }

  /// Offline, the email step says so in the provider's words (spec copy), and stays put.
  @Test func anOfflineConnectNamesTheProvider() async throws {
    let s = services(MockAccountService(existing: .passkey, signedIn: true))
    let lane = try #require(s.mailbox as? MockMailbox)
    lane.offline = true
    let m = model(s)
    await m.continueWithBanks()
    await m.connectMail(.gmail)
    #expect(m.failure?.message == "You're offline. Connect Gmail when you're back online.")
    #expect(m.path == [.connect(.gmail)] && m.facts.mailbox == .unlinked)
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
    await m.continueWithBanks()
    m.pickProvider(.outlook)
    await m.connectMail(.outlook)
    #expect(m.path == [.connect(.outlook), .connectError(.outlook)])
    #expect(m.connectFailure(.outlook) == .adminApprovalNeeded(address: MockMailbox.workAddress))
    // The view's own outcome watch arriving too pushes nothing more.
    m.connectFailed(.outlook)
    #expect(m.path == [.connect(.outlook), .connectError(.outlook)])

    lane.outlookAdmin = false
    lane.outlookCancelled = true
    await m.retryConnect(.outlook)
    #expect(m.connectFailure(.outlook) == .cancelled && m.path.last == .connectError(.outlook))

    lane.outlookCancelled = false
    await m.retryConnect(.outlook)
    #expect(m.path == [.connect(.outlook), .scan] && m.facts.mailbox == .scanning)
    #expect(m.draft.provider == .outlook && m.connectedMailbox?.provider == .outlook)
    #expect(lane.connectCalls == 3)

    // "Choose a different email" from an error screen: the chooser, then the pick takes the
    // email step's place.
    let other = model(services(MockAccountService(existing: .passkey, signedIn: true)))
    let otherLane = try #require(other.mailbox as? MockMailbox)
    otherLane.outlookCancelled = true
    await other.continueWithBanks()
    other.pickProvider(.outlook)
    await other.connectMail(.outlook)
    #expect(other.path == [.connect(.outlook), .connectError(.outlook)])
    other.chooseEmail()
    #expect(other.choosingEmail)
    other.pickProvider(.gmail)
    #expect(other.path == [.connect(.gmail)] && !other.choosingEmail)
  }

  @Test func aMicrosoftAccountWithNoMailboxHasItsScreenInSetup() async throws {
    let s = services(MockAccountService(existing: .passkey, signedIn: true))
    let lane = try #require(s.mailbox as? MockMailbox)
    lane.outlookNoMailbox = true
    let m = model(s)
    await m.continueWithBanks()
    m.pickProvider(.outlook)
    await m.connectMail(.outlook)
    #expect(m.path == [.connect(.outlook), .connectError(.outlook)])
    #expect(m.connectFailure(.outlook) == .noMailbox(.outlook))
    await m.retryConnect(.outlook)
    #expect(m.path == [.connect(.outlook), .scan] && m.facts.mailbox == .scanning)
    #expect(lane.connectCalls == 2)
  }

  @Test func aRetryInSetupKeepsAConfirmedSwitch() async throws {
    let s = services(MockAccountService(existing: .passkey, signedIn: true))
    let lane = try #require(s.mailbox as? MockMailbox)
    lane.outlookNoMailbox = true
    let m = model(s)
    await m.continueWithBanks()
    m.pickProvider(.outlook)
    await m.coordinator(.outlook).connect(.outlook, replacing: true)
    m.connectFailed(.outlook)
    #expect(m.path == [.connect(.outlook), .connectError(.outlook)])
    await m.retryConnect(.outlook)
    #expect(lane.replacingCalls == [true, true])
    #expect(m.path == [.connect(.outlook), .scan])
  }

  /// A closed Google sign-in is not an error: the screen stays as it was.
  @Test func aClosedGoogleSignInChangesNothing() async throws {
    let mailbox = CountingMailbox(MockMailbox())
    mailbox.cancelGmail = true
    let m = model(services(with: mailbox))
    await m.continueWithBanks()
    m.pickProvider(.gmail)
    await m.connectMail(.gmail)
    #expect(m.path == [.connect(.gmail)] && m.failure == nil && m.connectFailure(.gmail) == nil)
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
    m.pickProvider(.gmail)
    await m.connectMail(.gmail)
    #expect(m.path == [.connect(.gmail), .scan])
    // Back to the email step, then to the bank (the system back pops through the path).
    m.navigationPath = [.connect(.gmail)]
    #expect(m.coordinator(.gmail).outcome == .connected(mailboxID: "gmail-1"))
    m.navigationPath = []
    #expect(m.mailConnected)
    await m.continueWithBanks()
    // A remembered, connected provider: no chooser, its screen already connected.
    #expect(!m.choosingEmail && m.path == [.connect(.gmail)])
    #expect(m.coordinator(.gmail).outcome == .connected(mailboxID: "gmail-1"))
    m.continueFromEmail(.gmail)
    m.continueFromEmail(.gmail)  // a second tap while the push runs does nothing
    #expect(m.path == [.connect(.gmail), .scan])
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
    m.navigationPath = [.connect(.gmail), .scan, .income, .plan]
    m.navigationPath = [.connect(.gmail), .scan, .income]
    m.navigationPath = [.connect(.gmail), .scan]
    m.navigationPath = [.connect(.gmail)]
    await m.connectMail(.gmail)  // the connected screen's Continue
    #expect(m.path == [.connect(.gmail), .scan])
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

  /// A remembered provider skips the chooser; one provider in the build never shows it.
  @Test func aRememberedProviderOrTheOnlyOneSkipsTheChooser() async throws {
    let m = model(services(MockAccountService(existing: .passkey, signedIn: true)))
    await m.continueWithBanks()
    #expect(m.choosingEmail)
    m.pickProvider(.outlook)
    m.back()
    #expect(m.path.isEmpty)
    await m.continueWithBanks()
    #expect(!m.choosingEmail && m.path == [.connect(.outlook)])

    let s = services(MockAccountService(existing: .passkey, signedIn: true))
    let lane = try #require(s.mailbox as? MockMailbox)
    lane.connectable = [.gmail]
    let single = model(s)
    await single.continueWithBanks()
    #expect(!single.choosingEmail && single.path == [.connect(.gmail)] && !single.canChooseEmail)
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
    #expect(m.path == [.connect(.gmail), .scan, .income, .plan, .result, .notifications])
    m.path = [.connect(.gmail)]
    m.resume()  // once per model
    #expect(m.path == [.connect(.gmail)])
  }

  @Test func resumesAtTheDerivedStep() {
    let s = services(MockAccountService(existing: .passkey, signedIn: true))
    var facts = OnboardingStep.Facts(hasSession: true, keysReady: true, banksChosen: true)
    facts.mailSkipped = true
    let m = model(s, facts: facts)
    m.resume()
    #expect(m.path == [.connect(.gmail), .income])
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
    #expect(m.path == [.connect(.gmail), .income, .plan, .notifications])
    for _ in 0..<100 where m.coordinator(.gmail).outcome == nil { try await Task.sleep(for: .milliseconds(5)) }
    #expect(m.coordinator(.gmail).outcome == .connected(mailboxID: "gmail-1"))
    #expect(lane.connectCalls == 0)
    // Values the account holds count as sent: the same plan isn't sent again.
    m.path = [.connect(.gmail), .income, .plan]
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
    #expect(m.path == [.connect(.gmail), .income])
    m.back()
    m.resume()
    #expect(m.path == [.connect(.gmail)])
  }

  /// "Allow notifications" asks iOS once; back there it only goes on.
  @Test func notificationsAreAskedOnce() async throws {
    let s = services(MockAccountService(existing: .passkey, signedIn: true))
    let m = model(s)
    #expect(!m.notificationsAllowed)
    await m.allowNotifications()
    #expect(m.notificationsAllowed && m.path.last == .done)
    m.back()
    m.notNow()
    #expect(m.notificationsAllowed)
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
  func connect(_ provider: MailProviderKind, replacing: Bool) async throws(MailConnectFailure) -> String {
    if cancelGmail, provider == .gmail { throw .cancelled }
    return try await base.connect(provider, replacing: replacing)
  }
  func signInAgain(_ mailboxID: String) async throws(MailConnectFailure) { try await base.signInAgain(mailboxID) }
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
