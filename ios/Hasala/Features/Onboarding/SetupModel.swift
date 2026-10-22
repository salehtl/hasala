import Foundation
import HasalaDesign
import HasalaModels
import Observation

/// What setup last sent, so an unchanged value isn't sent again (plan B3.2 rule 3).
struct AuthoredSetup: Equatable, Sendable {
  /// The banks `chooseBanks` last sent; nil until it ran.
  var banks: [SupportedBank]?
  /// What `savePlan` last sent (income, payday, split); nil until it ran.
  var plan: SetupReadBack?
}

/// Everything typed or chosen in setup (plan B3.2), kept for the life of the process with
/// the model (`OnboardingStore`): Back never reverts it and Forward shows it again. A value
/// left nil (or an empty entry) was never chosen, so a relaunch can fill it from what the
/// account holds (`SetupModel.reconcile`).
struct SetupDraft: Equatable, Sendable {
  /// The banks picked; nil shows both picked.
  var chosenBanks: Set<SupportedBank>?
  var bankRequestSent = false
  /// The provider the person connected or picked in "Choose your email"; it skips the
  /// chooser next time (plan B3.2 rule 5).
  var provider: MailProviderKind?
  /// The salary as typed on the keypad, whole dirhams.
  var incomeEntry = AmountEntry()
  var payday: PaydayChoice?
  var split: StartingPlan?
  var showDetails = false
  enum NotificationsDecision: Equatable, Sendable { case systemAsked, notNow }
  var notificationsDecision: NotificationsDecision?
  enum CloudSortDecision: Equatable, Sendable { case on, notNow }
  var cloudSortDecision: CloudSortDecision?
  var authored = AuthoredSetup()
}

/// Setup state. The steps' facts are what `OnboardingStep.derive` reads; this model keeps
/// them and the draft for the process (`OnboardingStore` owns it), and a relaunch reads
/// them back from the projection, the lane and prefs (`reconcile`).
///
/// The first scan never holds setup up: "Set up your plan" leaves it running, the result
/// step continues whether or not it has finished, and it carries on after setup ends.
@MainActor
@Observable
final class SetupModel {
  private let services: AccountServices
  private let onFinished: () -> Void
  var path: [SetupRoute] = []
  /// The path as the navigation stack changes it: the system back button or its swipe
  /// (plan decision 7) leaves the failure of the step it left behind, as `back()` does.
  var navigationPath: [SetupRoute] {
    get { path }
    set {
      if newValue.count < path.count { failure = nil }
      path = newValue
    }
  }
  private(set) var facts: OnboardingStep.Facts
  private(set) var draft = SetupDraft()

  // Your email
  /// "Choose your email" is up: a sheet over the step it was asked from (plan decision 5).
  var choosingEmail = false
  /// The lane as the email step's coordinators see it (plan B3.2 rule 2).
  @ObservationIgnored private let mailLink: SetupMailLink
  /// One connect attempt per provider, kept for the process, so the connect screen shows
  /// what happened there when the person comes back to it.
  @ObservationIgnored private var coordinators: [MailProviderKind: MailConnectCoordinator] = [:]

  // The scan
  private(set) var scan: ScanProgress?
  /// One per account: the first scan starts once (plan B3.2 rule 4).
  private var scanTask: Task<Void, Never>?
  /// `resume()` builds the back stack once per model.
  private var didResume = false

  // Result
  private(set) var summary: SortSummary?

  var busy = false
  private(set) var connecting = false
  var connectRequest: MailProviderKind?
  @ObservationIgnored private var connectAfterChoosing: MailProviderKind?
  var failure: SetupFailure?
  var displayName: String

  init(services: AccountServices, displayName: String, facts: OnboardingStep.Facts, onFinished: @escaping () -> Void) {
    self.services = services
    self.displayName = displayName
    self.facts = facts
    self.onFinished = onFinished
    mailLink = SetupMailLink(base: services.mailbox)
    mailLink.isLinked = { [weak self] in self?.mailConnected ?? false }
  }

  var step: OnboardingStep { OnboardingStep.derive(facts) }

  /// Today in the ledger's clock (the payday line, the plan's month).
  var today: LocalDate { (services.setup as? SetupClock)?.today() ?? LedgerToday.device() }

  // MARK: The draft, as the steps bind it

  var chosenBanks: Set<SupportedBank> {
    get { draft.chosenBanks ?? Set(SupportedBank.allCases) }
    set { draft.chosenBanks = newValue }
  }
  var bankRequestSent: Bool { draft.bankRequestSent }

  /// The salary on the keypad. Whole dirhams only on this step: the decimal key is
  /// ignored, as page 11 ignores any key that breaks the rules.
  var incomeEntry: AmountEntry {
    get { draft.incomeEntry }
    set {
      guard !newValue.text.contains(".") else { return }
      draft.incomeEntry = newValue
    }
  }

  /// The salary as text ("25000"), for callers that type it.
  var incomeText: String {
    get { draft.incomeEntry.text }
    set { incomeEntry = AmountEntry(typing: newValue.filter { $0 != "." }) }
  }

  var paydayChoice: PaydayChoice {
    get { draft.payday ?? .standard }
    set { draft.payday = newValue }
  }

  /// The payday as the income op carries it (a day of the month).
  var payday: Int {
    get { paydayChoice.opDay(today: today) }
    set { draft.payday = .day(newValue) }
  }

  /// The next payday from today ("Next one Wed, 28 Oct").
  var nextPayday: LocalDate { paydayChoice.next(onOrAfter: today) }

  var plan: StartingPlan {
    get { draft.split ?? StartingPlan() }
    set { draft.split = newValue }
  }
  var showDetails: Bool {
    get { draft.showDetails }
    set { draft.showDetails = newValue }
  }

  /// The provider setup connects: the one remembered or connected, else the one the
  /// account's link is to (a relaunch before the lane's status is read), else the first
  /// this build can.
  var provider: MailProviderKind {
    draft.provider ?? readingMailbox?.provider ?? services.mailbox.linkedProvider ?? services.mailbox.connectable.first
      ?? .gmail
  }

  /// The providers this build connects (live: those it has a client id for).
  var connectable: [MailProviderKind] { services.mailbox.connectable }

  /// The mailbox the account reads, the one setup connected first.
  private var readingMailbox: MailboxSnapshot? {
    let reading = services.mailbox.mailboxes.filter { $0.state != .disconnected }
    if let provider = draft.provider, let m = reading.first(where: { $0.provider == provider }) { return m }
    return reading.first
  }

  // MARK: Reconciling (plan B3.3)

  /// Brings the model in line with what the account holds after a relaunch or a runtime
  /// open: done flags are OR-ed (a step done here stays done), the mailbox comes from the
  /// lane, and a value never chosen in this process is read back.
  func reconcile(facts new: OnboardingStep.Facts, readBack: SetupReadBack, banks: [SupportedBank]) {
    facts.hasPasscode = new.hasPasscode
    facts.hasSession = facts.hasSession || new.hasSession
    facts.keysReady = facts.keysReady || new.keysReady
    facts.banksChosen = facts.banksChosen || new.banksChosen || draft.authored.banks != nil
    facts.incomeSet = facts.incomeSet || new.incomeSet || draft.authored.plan?.incomeMinor != nil
    facts.planSet = facts.planSet || new.planSet || draft.authored.plan?.split != nil
    facts.sampleLoaded = facts.sampleLoaded || new.sampleLoaded
    facts.notificationsAsked = facts.notificationsAsked || new.notificationsAsked || draft.notificationsDecision != nil
    facts.mailbox = new.mailbox
    if draft.incomeEntry.isEmpty, let minor = readBack.incomeMinor, minor > 0 {
      // Whole dirhams on this step: fils a later edit added are dropped from the figure only.
      draft.incomeEntry = AmountEntry(minor: minor - minor % 100)
    }
    if draft.payday == nil, let day = readBack.payday { draft.payday = .day(day) }
    if draft.split == nil, let split = readBack.split { draft.split = split }
    if draft.chosenBanks == nil, !banks.isEmpty { draft.chosenBanks = Set(banks) }
    // What the account holds was sent before this process: the same values aren't sent again.
    if draft.authored.banks == nil, new.banksChosen, !banks.isEmpty { draft.authored.banks = banks }
    if draft.authored.plan == nil, readBack != SetupReadBack() { draft.authored.plan = readBack }
  }

  /// The back stack for the derived step, built once per model: every step before it, in
  /// order, so Back walks real screens that show what they hold. A scan that is still
  /// running is followed again; one that runs here already is never restarted.
  ///
  /// `SetupFlowView` calls it on appear and whenever the derived step changes. At the bank
  /// step there is nothing to build, and the facts may still be the gate's placeholder (a
  /// store that failed to open draws setup under its wall), so the stack is built by the
  /// first call that finds a later step, unless the person has moved on here already.
  func resume() {
    guard !didResume else { return }
    let target = step
    if target == .finished {
      didResume = true
      onFinished()
      return
    }
    guard target > .bank else { return }
    didResume = true
    guard path.isEmpty else { return }
    let manual = facts.bankSkipped && !facts.banksChosen
    var stack: [SetupRoute] = []
    // A scan the lane is still running is followed again, and its screen is in the stack;
    // a finished one has nothing to show there, so Back goes to the connected email step.
    if !manual, facts.mailbox == .scanning, !facts.mailSkipped, !facts.sampleLoaded { startScan() }
    if target >= .scan, scanTask != nil { stack.append(.scan) }
    if target >= .income, !facts.sampleLoaded { stack.append(.income) }
    if target >= .plan, !facts.sampleLoaded { stack.append(.plan) }
    if target >= .notifications, scanTask != nil, !facts.sampleLoaded { stack.append(.result) }
    if target >= .notifications, offersCloudSort { stack.append(.sort) }
    if target >= .notifications { stack.append(.notifications) }
    if target >= .done { stack.append(.done) }
    path = stack
    // The email step under the stack shows its connected state when Back reaches it.
    if !manual, mailConnected {
      let provider = provider
      Task { await settle(provider) }
    }
  }

  /// Setup's step numbers ("2 of 4").
  func steps(_ n: Int) -> (current: Int, of: Int)? { (n, 4) }

  func back() {
    failure = nil
    if !path.isEmpty { path.removeLast() }
  }

  private func go(_ r: SetupRoute) {
    failure = nil
    path.append(r)
  }

  var firstName: String { displayName.split(separator: " ").first.map(String.init) ?? displayName }

  // MARK: Bank (step 1)

  var orderedBanks: [SupportedBank] { SupportedBank.allCases.filter { chosenBanks.contains($0) } }

  /// "Emirates NBD and DIB".
  var bankList: String { orderedBanks.map(\.shortName).formatted(.list(type: .and)) }

  func toggle(_ bank: SupportedBank) {
    var banks = chosenBanks
    if banks.contains(bank) { banks.remove(bank) } else { banks.insert(bank) }
    chosenBanks = banks
  }

  func saveBanks() async -> Bool {
    guard !chosenBanks.isEmpty, !busy else { return false }
    didResume = true
    let banks = orderedBanks
    if draft.authored.banks != banks {
      busy = true
      defer { busy = false }
      do {
        if draft.authored.banks == nil {
          try await services.setup.chooseBanks(banks)
        } else {
          try await services.setup.setBanks(banks)
        }
        draft.authored.banks = banks
      } catch {
        failure = error
        return false
      }
    }
    facts.banksChosen = true
    return true
  }

  /// The bank step's button: the banks, then the provider's sign-in, or, once connected,
  /// on without a second sign-in.
  func continueWithBanks() async {
    guard await saveBanks() else { return }
    if mailConnected {
      continueConnected()
    } else {
      await connectMail(provider)
    }
  }

  /// "Skip": manual-entry mode; your email and the scan are skipped too.
  func skipBanks() {
    facts.bankSkipped = true
    go(.income)
  }

  var bankRequests: SetupAuthoring { services.setup }

  func noteBankRequestSent() { draft.bankRequestSent = true }

  // MARK: Your email (step 2)

  var offersSampleData: Bool { services.mailbox.offersSampleData }

  /// The email step already ran here: its screen shows the connected state and Continue,
  /// never a second sign-in (plan B3.2 rule 2).
  var mailConnected: Bool { facts.mailbox != .unlinked }

  /// The mailbox the email step connected, as the first scan shows it.
  var connectedMailbox: MailboxSnapshot? { mailConnected ? readingMailbox : nil }

  /// The lane as the connect screens see it.
  var mailbox: MailboxConnecting { services.mailbox }

  /// Whether "Choose a different one" can open the chooser (more than one provider).
  var canChooseEmail: Bool { connectable.count > 1 }

  /// "Not your email? Choose a different one.": the chooser over the screen it was asked
  /// from.
  func chooseEmail() {
    guard canChooseEmail else { return }
    choosingEmail = true
  }

  /// A row in "Choose your email": the sheet goes, and the bank step connects that
  /// provider (an error screen on the stack goes with it).
  func pickProvider(_ provider: MailProviderKind) {
    draft.provider = provider
    choosingEmail = false
    failure = nil
    if case .failed? = coordinators[provider]?.outcome { coordinators[provider]?.reset() }
    path = Array(path.prefix { !$0.isEmailStep })
  }

  func choose(_ provider: MailProviderKind) {
    pickProvider(provider)
    connectAfterChoosing = provider
  }

  func choosingEnded() {
    guard let provider = connectAfterChoosing else { return }
    connectAfterChoosing = nil
    connectRequest = provider
  }

  func useDifferentEmail() {
    failure = nil
    path = []
    if canChooseEmail {
      choosingEmail = true
    } else {
      connectRequest = provider
    }
  }

  /// The connect attempt for `provider`'s screen, made once and kept.
  func coordinator(_ provider: MailProviderKind) -> MailConnectCoordinator {
    if let c = coordinators[provider] { return c }
    let c = MailConnectCoordinator(mailbox: mailLink, context: .setup(stepOf: (2, 4)))
    coordinators[provider] = c
    return c
  }

  /// Gives a connect that already happened its connected state on its screen, without
  /// any sign-in (the link answers at once).
  func settle(_ provider: MailProviderKind) async {
    let c = coordinator(provider)
    guard c.outcome == nil, !c.busy, mailLink.existing(provider) != nil else { return }
    await c.connect(provider)
  }

  /// How the last connect of `provider` failed, for its error screen.
  func connectFailure(_ provider: MailProviderKind) -> MailConnectFailure? {
    if case .failed(let f)? = coordinators[provider]?.outcome { return f }
    return nil
  }

  /// The provider's sign-in, then the first scan; once connected, on to the scan without
  /// a second sign-in. (The connect screen's button runs the same coordinator.)
  func connectMail(_ provider: MailProviderKind) async {
    await connectMail(provider, again: false)
  }

  func connectMail(_ provider: MailProviderKind, replacing: Bool, removingOld: Bool) async {
    await connectMail(provider, again: false, replacing: replacing, removingOld: removingOld)
  }

  private func connectMail(_ provider: MailProviderKind, again: Bool, replacing: Bool = false,
                           removingOld: Bool = false) async {
    guard !connecting else { return }
    connecting = true
    defer { connecting = false }
    let before = connectedMailbox
    draft.provider = provider
    failure = nil
    if again {
      await coordinator(provider).retry(provider)
    } else {
      await coordinator(provider).connect(provider, replacing: replacing, removingOld: removingOld)
    }
    switch coordinators[provider]?.outcome {
    case .connected(let id)?:
      let now = coordinators[provider]?.nowReading ?? connectedMailbox?.address
      emailConnected(provider, fresh: before.map { $0.id != id || $0.address != now } ?? false)
    case .failed?: connectFailed(provider)
    case nil: break
    }
  }

  /// "Continue with Google" on the error screen: on success the error screen gives way to
  /// the first scan.
  func retryConnect(_ provider: MailProviderKind) async {
    await connectMail(provider, again: true)
  }

  func continueConnected() {
    guard path.isEmpty else { return }
    emailConnected(provider)
  }

  private func emailConnected(_ provider: MailProviderKind, fresh: Bool = false) {
    if path.last == .connectError(provider) { path.removeLast() }
    if fresh {
      scanTask?.cancel()
      scanTask = nil
      scan = nil
      summary = nil
      facts.scanDeferred = false
      facts.mailbox = .unlinked
    }
    if facts.mailbox == .unlinked {
      draft.provider = provider
      facts.mailSkipped = false
      facts.mailbox = .scanning
      startScan()
      go(.scan)
    } else {
      go(scanTask != nil ? .scan : .income)
    }
    if let line = coordinators[provider]?.takeRemovalFailure() { failure = .failed(line) }
  }

  /// A connect that didn't happen: the two the design draws a screen for (an admin's
  /// approval, a Microsoft sign-in that didn't finish) push it; the rest stay on the
  /// connect screen as a line beside its button ("Errors sit next to the thing that
  /// failed", page 17). A closed Google sign-in is not a failure.
  func connectFailed(_ provider: MailProviderKind) {
    guard let f = connectFailure(provider) else { return }
    if Self.showsErrorScreen(f), path.last != .connectError(provider) { go(.connectError(provider)) }
    failure = Self.setupFailure(f, provider)
  }

  /// The failures with a screen of their own (Paper P2.9 row 2).
  static func showsErrorScreen(_ f: MailConnectFailure) -> Bool {
    switch f {
    case .adminApprovalNeeded, .cancelled, .noMailbox: true
    default: false
    }
  }

  /// A connect failure as the setup banner shows it (a closed sign-in shows nothing), in
  /// the provider's words: offline, "Connect Gmail when you're back online", not setup's
  /// generic offline line.
  static func setupFailure(_ f: MailConnectFailure, _ provider: MailProviderKind) -> SetupFailure {
    switch f {
    case .cancelled: .cancelled
    default: .failed(f.message(for: provider) ?? "")
    }
  }

  func skipMail() {
    facts.mailSkipped = true
    go(.income)
  }

  func useSampleData() async {
    guard !busy else { return }
    didResume = true
    busy = true
    defer { busy = false }
    do {
      try await services.mailbox.loadSampleData()
      facts.sampleLoaded = true
      go(.notifications)
    } catch {
      failure = error
    }
  }

  // MARK: The scan (step 2)

  private func startScan() {
    guard scanTask == nil else { return }
    let stream = services.mailbox.firstScan()
    scanTask = Task { [weak self] in
      for await p in stream {
        guard let self, !Task.isCancelled else { return }
        self.scan = p
        if let s = p.summary { self.summary = s }
        switch p.phase {
        case .finished:
          self.facts.mailbox = .linked
        case .failed(let message):
          self.failure = .failed(message)
        default: break
        }
      }
    }
  }

  /// "Set up your plan" while the scan keeps running.
  func planWhileScanning() {
    facts.scanDeferred = true
    go(.income)
  }

  /// The import still runs behind the later steps (their pill, page 17 §04 A).
  var scanRunning: Bool {
    guard let scan else { return false }
    return scan.isRunning || scan.phase == .background
  }

  // MARK: Income (step 3) and plan (step 4)

  /// The income in fils, from the whole dirhams typed; nil at 0.
  var incomeMinor: Int64? {
    guard let minor = draft.incomeEntry.minor, minor > 0 else { return nil }
    return minor
  }

  /// The income the plan uses and sends: nil when the step was skipped (what was typed
  /// stays on the keypad for Back).
  var savedIncomeMinor: Int64? { facts.incomeSkipped ? nil : incomeMinor }

  var incomeDisplay: String { draft.incomeEntry.display }

  func continueWithIncome() {
    guard incomeMinor != nil else { return }
    facts.incomeSet = true
    facts.incomeSkipped = false
    go(.plan)
  }

  /// "Skip": no income is sent, but what was typed stays for Back.
  func skipIncome() {
    facts.incomeSkipped = true
    go(.plan)
  }

  /// "Use this plan" (or Skip): one enqueue of the income and plan ops, unless exactly
  /// these were sent already (a changed value is a real change, and is sent again).
  func savePlan(skip: Bool = false) async {
    guard !busy else { return }
    let income = savedIncomeMinor
    let values = SetupReadBack(incomeMinor: income, payday: income == nil ? nil : payday, split: skip ? nil : plan)
    if draft.authored.plan != values {
      busy = true
      defer { busy = false }
      do {
        try await services.setup.savePlan(income: values.incomeMinor, payday: values.payday, plan: values.split)
        draft.authored.plan = values
      } catch {
        failure = error
        return
      }
    }
    facts.planSet = !skip
    facts.planSkipped = skip
    afterPlan()
  }

  /// After the plan: the scan's result when mail was connected here (finished or not; it
  /// never waits), else notifications.
  private func afterPlan() {
    if scanTask != nil {
      go(.result)
    } else {
      go(.notifications)
    }
  }

  // MARK: Result

  /// The scan has stopped in the foreground and filed what's shown; it may go on later.
  var scanDone: Bool { scan?.phase == .finished }

  var foundNoAlerts: Bool { scanDone && (summary?.total ?? 0) == 0 }

  private(set) var checkingAgain = false

  func checkAgain() async {
    guard foundNoAlerts, !checkingAgain else { return }
    checkingAgain = true
    defer { checkingAgain = false }
    failure = nil
    for await p in services.mailbox.firstScan() {
      switch p.phase {
      case .finished, .background:
        if let s = p.summary { summary = s }
      case .failed(let message):
        failure = .failed(message)
      default: break
      }
    }
  }

  /// "Continue" on the result, whether or not the scan has finished.
  func afterResult() { go(offersCloudSort ? .sort : .notifications) }

  var offersCloudSort: Bool { services.cloudSort?.isOffered == true && scanTask != nil && !facts.sampleLoaded }

  var cloudSortOn: Bool { draft.cloudSortDecision == .on || services.cloudSort?.isOn == true }

  func turnOnCloudSort() {
    if draft.cloudSortDecision != .on { services.cloudSort?.turnOn() }
    draft.cloudSortDecision = .on
    go(.notifications)
  }

  func cloudSortNotNow() {
    if draft.cloudSortDecision == nil { draft.cloudSortDecision = .notNow }
    go(.notifications)
  }

  // MARK: Notifications and done

  /// The system was asked here already: the step shows "Continue" (plan B3.2 rule 2).
  var systemAskedForNotifications: Bool { draft.notificationsDecision == .systemAsked }

  /// "Allow notifications": iOS asks once; after that the step's button only continues.
  func allowNotifications() async {
    if draft.notificationsDecision != .systemAsked {
      services.notifications.showsDetails = showDetails
      _ = await services.notifications.requestAuthorization()
      draft.notificationsDecision = .systemAsked
    }
    facts.notificationsAsked = true
    go(.done)
  }

  func notNow() {
    if draft.notificationsDecision != .systemAsked { draft.notificationsDecision = .notNow }
    facts.notificationsAsked = true
    go(.done)
  }

  /// Leaves setup. Only this screen stops following the scan; the import goes on.
  func finish() {
    facts.finished = true
    didResume = true  // the step it derives now is `.finished`: `resume()` must not finish again
    scanTask?.cancel()
    onFinished()
  }
}

extension SetupRoute {
  /// The email step's error screen, which a pick in "Choose your email" takes away.
  var isEmailStep: Bool {
    if case .connectError = self { return true }
    return false
  }
}
