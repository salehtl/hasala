import Foundation
import HasalaDesign
import HasalaMocks
import HasalaModels
import Observation
import Testing

@testable import Hasala

/// Setup after the account (bank and email, then Home), on the in-memory mock: the email
/// step's providers and failures, and what setup remembers for the life of the process
/// (plan B3: Back never reverts, nothing is sent or signed in twice).
@MainActor
@Suite("Setup flows")
struct SetupFlowTests: AccountSuite {
  func model(_ s: AccountServices, facts: OnboardingStep.Facts = .init(hasSession: true, keysReady: true),
             finished: @escaping () -> Void = {}) -> SetupModel {
    SetupModel(services: s, displayName: "Maya Rahman", facts: facts, onFinished: finished)
  }

  @Test func setupEndsOnHomeOnceTheEmailIsConnected() async throws {
    let base = MockMailbox()
    base.step = .milliseconds(1)
    let mailbox = CountingMailbox(base)
    let s = services(with: mailbox)
    var finished = 0
    let m = model(s) { finished += 1 }
    #expect(m.step == .bank)
    m.toggle(.dib)
    #expect(m.orderedBanks == [.enbd, .adib])
    m.toggle(.dib)
    #expect(m.connectable == [.gmail, .outlook] && m.provider == .gmail)
    await m.continueWithBanks()
    #expect((s.setup as? MockSetupAuthoring)?.banks == [.enbd, .dib, .adib])
    #expect(!m.choosingEmail && m.path.isEmpty)
    #expect(m.step == .finished && m.facts.mailbox == .scanning && finished == 1)
    #expect(m.connectedMailbox?.provider == .gmail && mailbox.scans == 1)
    for _ in 0..<400 where base.importing != nil || base.mailboxes.first?.state != .connected {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(base.importing == nil && base.mailboxes.first?.state == .connected)
    m.resume()
    m.continueConnected()
    #expect(finished == 1 && mailbox.scans == 1)
    #expect((s.setup as? MockSetupAuthoring)?.savePlanCalls == 0)
  }

  @Test func reviewAccountsCanUseSampleData() async {
    let s = services(MockAccountService(existing: .passkey, signedIn: true), sample: true)
    var finished = false
    let m = model(s) { finished = true }
    #expect(m.offersSampleData)
    for bank in SupportedBank.allCases { m.toggle(bank) }
    #expect(m.chosenBanks.isEmpty)
    await m.useSampleData()
    let setup = s.setup as? MockSetupAuthoring
    #expect(setup?.banks == [] && setup?.chooseBanksCalls == 0 && setup?.setBanksCalls == 0)
    #expect(m.step == .finished && m.path.isEmpty && finished)
  }

  @Test func skippingTheBankOrTheEmailGoesHome() {
    var finished = 0
    let manual = model(services(MockAccountService(existing: .passkey, signedIn: true))) { finished += 1 }
    manual.skipBanks()
    #expect(manual.step == .finished && finished == 1)
    let noMail = model(services(MockAccountService(existing: .passkey, signedIn: true)),
                       facts: .init(hasSession: true, keysReady: true, banksChosen: true)) { finished += 1 }
    noMail.skipMail()
    #expect(noMail.step == .finished && finished == 2)
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
    #expect(m.path.isEmpty && m.facts.mailbox == .scanning)
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

  @Test func aRelaunchMidScanRestartsTheImportOnce() async throws {
    let base = MockMailbox()
    let mailbox = CountingMailbox(base)
    let m = model(services(with: mailbox),
                  facts: .init(hasSession: true, keysReady: true, banksChosen: true, mailbox: .scanning))
    m.resume()
    m.resume()
    #expect(mailbox.scans == 1)
  }

  @Test func aConnectThatReplacesTheMailboxScansTheNewOne() async throws {
    let base = MockMailbox()
    base.total = 0
    let mailbox = CountingMailbox(base)
    let m = model(services(with: mailbox))
    await m.continueWithBanks()
    #expect(mailbox.scans == 1)
    await m.connectMail(.outlook, replacing: true, removingOld: false)
    #expect(mailbox.scans == 2 && m.facts.mailbox == .scanning)
    #expect(m.connectedMailbox?.provider == .outlook)
  }

  /// Offline, the email step says so in the provider's words (spec copy), and stays put.
  @Test func anOfflineConnectNamesTheProvider() async throws {
    let s = services(MockAccountService(existing: .passkey, signedIn: true))
    let lane = try #require(s.mailbox as? MockMailbox)
    lane.offline = true
    var finished = false
    let m = model(s) { finished = true }
    await m.continueWithBanks()
    #expect(m.failure?.message == "You're offline. Connect Gmail when you're back online.")
    #expect(m.path == [] && m.facts.mailbox == .unlinked && !finished)
    #expect(m.connectFailure(.gmail) == .offline)
    #expect(SetupModel.setupFailure(.offline, .outlook).message == "You're offline. Connect Outlook when you're back online.")
    #expect(SetupModel.setupFailure(.cancelled, .gmail) == .cancelled)
  }

  /// The two failures the design draws a screen for push it; trying again from there,
  /// once it works, goes Home. A closed Google sign-in changes nothing.
  @Test func outlookFailuresHaveTheirScreensAndTryAgainGoesOn() async throws {
    let s = services(MockAccountService(existing: .passkey, signedIn: true))
    let lane = try #require(s.mailbox as? MockMailbox)
    lane.outlookAdmin = true
    var finished = false
    let m = model(s) { finished = true }
    m.pickProvider(.outlook)
    await m.continueWithBanks()
    #expect(m.path == [.connectError(.outlook)])
    #expect(m.connectFailure(.outlook) == .adminApprovalNeeded(address: MockMailbox.workAddress))
    m.connectFailed(.outlook)
    #expect(m.path == [.connectError(.outlook)])

    lane.outlookAdmin = false
    lane.outlookCancelled = true
    await m.retryConnect(.outlook)
    #expect(m.connectFailure(.outlook) == .cancelled && m.path.last == .connectError(.outlook) && !finished)

    lane.outlookCancelled = false
    await m.retryConnect(.outlook)
    #expect(m.path == [] && m.facts.mailbox == .scanning && finished)
    #expect(m.draft.provider == .outlook && m.connectedMailbox?.provider == .outlook)
    #expect(lane.connectCalls == 3)

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
    #expect(m.path == [] && m.facts.mailbox == .scanning && m.step == .finished)
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
    #expect(m.path == [] && m.step == .finished)
  }

  @Test func aRemoveThatFailedDuringASwitchInSetupIsSaid() async throws {
    let lane = MockMailbox(mailboxes: [MockMailbox.gmail])
    lane.connectDelay = .zero
    lane.step = .milliseconds(1)
    lane.holdOneLink()
    lane.switchRemoveFails = true
    var finished = false
    let m = model(services(with: lane)) { finished = true }
    m.pickProvider(.outlook)
    #expect(await m.saveBanks())
    await m.connectMail(.outlook, replacing: true, removingOld: true)
    #expect(m.failure == .failed(
      "Outlook connected. Checking for alerts. The transactions from maya@example.com couldn't be removed. They stay."))
    #expect(!finished && m.mailConnected)
    #expect(m.coordinator(.outlook).takeRemovalFailure() == nil)
    await m.continueWithBanks()
    #expect(finished)
  }

  /// A closed Google sign-in is not an error: the screen stays as it was.
  @Test func aClosedGoogleSignInChangesNothing() async throws {
    let mailbox = CountingMailbox(MockMailbox())
    mailbox.cancelGmail = true
    let m = model(services(with: mailbox))
    await m.continueWithBanks()
    #expect(m.path == [] && m.failure == nil && m.connectFailure(.gmail) == nil)
    #expect(m.facts.mailbox == .unlinked && m.step == .mail)
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
    #expect(await m.saveBanks())
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
    #expect(m.step == .finished && m.connectedMailbox?.provider == .outlook)

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
    #expect(m.failure == nil && m.step == .finished)
  }

  /// A relaunch whose facts say the mail is linked to Outlook, before the lane's status is
  /// read (no rows yet): setup's provider is Outlook's.
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

  /// The payday strip's days: the next one from the ledger's today, a day a month doesn't
  /// have on its last day, and the last working day (Monday to Friday) sent as its day.
  @Test func paydaysFallOnRealDays() {
    let today = LocalDate(2026, 10, 10)
    #expect(PaydayChoice.day(28).next(onOrAfter: today) == LocalDate(2026, 10, 28))
    #expect(PaydayChoice.day(5).next(onOrAfter: today) == LocalDate(2026, 11, 5))
    #expect(PaydayChoice.day(10).next(onOrAfter: today) == today)
    #expect(PaydayChoice.day(31).next(onOrAfter: LocalDate(2026, 11, 2)) == LocalDate(2026, 11, 30))
    #expect(PaydayChoice.lastWorkingDay.next(onOrAfter: today) == LocalDate(2026, 10, 30))
    #expect(PaydayChoice.lastWorkingDay.opDay(today: today) == 30)
    #expect(PaydayChoice.day(31).opDay(today: today) == 31)
    #expect(PaydayChoice.all.count == 32 && PaydayChoice.all.last == .lastWorkingDay)
    #expect(PaydayChoice.all.allSatisfy { PaydayChoice.all[$0.index] == $0 })
    #expect(["1st", "2nd", "3rd", "4th", "11th", "12th", "13th", "21st", "22nd", "23rd", "31st"]
      == [1, 2, 3, 4, 11, 12, 13, 21, 22, 23, 31].map { PaydayChoice.day($0).spoken })
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

  @Test func theSplitLabelsStayApartInsideTheTrack() {
    let gap: CGFloat = 8
    let width: CGFloat = 342
    let track = width - 40
    let seventyThirty = SplitLabelLayout.positions(
      ideal: [0, track * 0.70 + 40], widths: [40, 40], width: width, gap: gap)
    #expect(seventyThirty == [0, track * 0.70 + 40])
    let crowded = SplitLabelLayout.positions(
      ideal: [0, track * 0.95 + 20], widths: [40, 30], width: width, gap: gap)
    #expect(crowded[1] + 30 <= width)
    #expect(crowded[1] >= crowded[0] + 40 + gap)
    let squeezed = SplitLabelLayout.positions(
      ideal: [0, track * 0.90 + 20, track + 40], widths: [40, 40, 30], width: width, gap: gap)
    #expect(squeezed[2] == width - 30)
    #expect(squeezed[1] + 40 + gap <= squeezed[2])
    #expect(squeezed[0] + 40 + gap <= squeezed[1])
    #expect(squeezed[0] >= 0)
  }

  @Test func anAccountPastTheEmailStepResumesOnHome() {
    for mailbox in [OnboardingStep.Facts.Mailbox.scanning, .linked, .otherDevice] {
      var facts = OnboardingStep.Facts(hasSession: true, keysReady: true, banksChosen: true)
      facts.mailbox = mailbox
      var finished = 0
      let m = model(services(MockAccountService(existing: .passkey, signedIn: true)), facts: facts) { finished += 1 }
      m.resume()
      m.resume()
      #expect(finished == 1 && m.path.isEmpty)
    }
    var facts = OnboardingStep.Facts(hasSession: true, keysReady: true, banksChosen: true)
    var finished = false
    let atEmail = model(services(MockAccountService(existing: .passkey, signedIn: true)), facts: facts) { finished = true }
    atEmail.resume()
    #expect(!finished && atEmail.step == .mail)
    facts.mailSkipped = true
    let skipped = model(services(MockAccountService(existing: .passkey, signedIn: true)), facts: facts) { finished = true }
    skipped.resume()
    #expect(finished)
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
  @ObservationIgnored var scanEndsAtOnce = false
  /// The link a relaunch remembers before the lane's rows are read.
  @ObservationIgnored var linkedOverride: MailProviderKind?
  /// The account's link held by another iPhone (live: a new install or a recovered account).
  @ObservationIgnored var heldElsewhere: MailProviderKind?
  @ObservationIgnored var known = true
  @ObservationIgnored var offerOverride: MailOffer??

  init(_ base: MockMailbox) { self.base = base }

  var mailboxesKnown: Bool { known }

  var connectable: [MailProviderKind] { base.connectable }
  var capabilities: MailboxCapabilities { base.capabilities }
  var mailboxes: [MailboxSnapshot] { base.mailboxes }
  var offer: MailOffer? { offerOverride ?? base.offer }
  var linkedProvider: MailProviderKind? { linkedOverride ?? base.linkedProvider }
  var offersSampleData: Bool { base.offersSampleData }
  func chosenBanks() -> [SupportedBank] { base.chosenBanks() }
  func linkState() async -> OnboardingStep.Facts.Mailbox { await base.linkState() }
  func connect(
    _ provider: MailProviderKind, replacing: Bool, removingOld: Bool, pastMail: MailPastChoice,
    ask: @escaping MailSwitchAsk
  ) async throws(MailConnectFailure) -> MailLinked {
    if cancelGmail, provider == .gmail { throw .cancelled }
    return try await base.connect(provider, replacing: replacing, removingOld: removingOld, pastMail: pastMail, ask: ask)
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
    if scanEndsAtOnce { return AsyncStream { $0.finish() } }
    return base.firstScan()
  }
  func loadSampleData() async throws(SetupFailure) { try await base.loadSampleData() }
  var importing: MailImport? { base.importing }
  var firstScanFinished: Bool { base.firstScanFinished }
}
