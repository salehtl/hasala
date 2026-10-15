import Foundation
import HasalaModels
import Observation

/// The salary day the income step offers (Paper "Setup · 3 of 4 · Monthly income"): a day
/// of the month, or the last working day.
enum PaydayChoice: Hashable, Sendable {
  case day(Int)
  case lastWorkingDay

  /// The day the income op carries. The op has no "last working day"; it is sent as the
  /// 28th until it does.
  var day: Int {
    switch self {
    case .day(let d): d
    case .lastWorkingDay: 28
    }
  }
}

/// What setup last sent, so an unchanged value isn't sent again (plan B3.2 rule 3).
struct AuthoredSetup: Equatable, Sendable {
  /// The banks `chooseBanks` last sent; nil until it ran.
  var banks: [SupportedBank]?
  /// What `savePlan` last sent (income, payday, split); nil until it ran.
  var plan: SetupReadBack?
}

/// Everything typed or chosen in setup (plan B3.2), kept for the life of the process with
/// the model (`OnboardingStore`): Back never reverts it and Forward shows it again. A value
/// left nil was never chosen, so a relaunch can fill it from what the account holds
/// (`SetupModel.reconcile`).
struct SetupDraft: Equatable, Sendable {
  /// The banks picked; nil shows both picked.
  var chosenBanks: Set<SupportedBank>?
  var bankRequestSent = false
  /// The provider the person connected or chose; it skips "Choose your email" next time.
  var provider: MailProviderKind?
  /// The salary typed, whole dirhams.
  // TODO(plan P2): `AmountEntry` (HasalaDesign's keypad) once the keypad is in.
  var incomeText = ""
  var payday: PaydayChoice?
  var split: StartingPlan?
  var showDetails = false
  enum NotificationsDecision: Equatable, Sendable { case allowed, notNow }
  var notificationsDecision: NotificationsDecision?
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

  // Bank
  var bankRequest = ""

  // The email and the scan
  private(set) var scan: ScanProgress?
  /// One per account: the first scan starts once (plan B3.2 rule 4).
  private var scanTask: Task<Void, Never>?
  /// `resume()` builds the back stack once per model.
  private var didResume = false

  // Result
  private(set) var summary: SortSummary?

  var busy = false
  var failure: SetupFailure?
  var displayName: String

  init(services: AccountServices, displayName: String, facts: OnboardingStep.Facts, onFinished: @escaping () -> Void) {
    self.services = services
    self.displayName = displayName
    self.facts = facts
    self.onFinished = onFinished
  }

  var step: OnboardingStep { OnboardingStep.derive(facts) }

  // MARK: The draft, as the steps bind it

  var chosenBanks: Set<SupportedBank> {
    get { draft.chosenBanks ?? Set(SupportedBank.allCases) }
    set { draft.chosenBanks = newValue }
  }
  var bankRequestSent: Bool { draft.bankRequestSent }
  var incomeText: String {
    get { draft.incomeText }
    set { draft.incomeText = newValue }
  }
  var payday: Int {
    get { draft.payday?.day ?? 28 }
    set { draft.payday = .day(newValue) }
  }
  var plan: StartingPlan {
    get { draft.split ?? StartingPlan() }
    set { draft.split = newValue }
  }
  var showDetails: Bool {
    get { draft.showDetails }
    set { draft.showDetails = newValue }
  }

  /// The provider setup connects: the one remembered, else the first this build can.
  var provider: MailProviderKind { draft.provider ?? services.mailbox.connectable.first ?? .gmail }

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
    if draft.incomeText.isEmpty, let minor = readBack.incomeMinor, minor > 0 { draft.incomeText = String(minor / 100) }
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
    if !manual { stack.append(.connect(provider)) }
    // A scan the lane is still running is followed again, and its screen is in the stack;
    // a finished one has nothing to show there, so Back goes to the connected email step.
    if !manual, facts.mailbox == .scanning, !facts.mailSkipped, !facts.sampleLoaded { startScan() }
    if target >= .scan, scanTask != nil { stack.append(.scan) }
    if target >= .income, !facts.sampleLoaded { stack.append(.income) }
    if target >= .plan, !facts.sampleLoaded { stack.append(.plan) }
    if target >= .notifications, scanTask != nil, !facts.sampleLoaded { stack.append(.result) }
    if target >= .notifications { stack.append(.notifications) }
    if target >= .done { stack.append(.done) }
    path = stack
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

  // MARK: Bank (step 3)

  var orderedBanks: [SupportedBank] { SupportedBank.allCases.filter { chosenBanks.contains($0) } }

  func toggle(_ bank: SupportedBank) {
    var banks = chosenBanks
    if banks.contains(bank) { banks.remove(bank) } else { banks.insert(bank) }
    chosenBanks = banks
  }

  /// "Continue with N banks": the bank ops, unless these banks were sent already (Back
  /// then Continue sends nothing again), then your email.
  func continueWithBanks() async {
    guard !chosenBanks.isEmpty else { return }
    let banks = orderedBanks
    if draft.authored.banks != banks {
      busy = true
      defer { busy = false }
      do {
        try await services.setup.chooseBanks(banks)
        draft.authored.banks = banks
      } catch {
        failure = error
        return
      }
    }
    facts.banksChosen = true
    go(.connect(provider))
  }

  /// "Skip": manual-entry mode; your email and the scan are skipped too.
  func skipBanks() {
    facts.bankSkipped = true
    go(.income)
  }

  func sendBankRequest() async {
    let name = bankRequest.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return }
    do {
      try await services.setup.requestBank(String(name.prefix(80)))
      draft.bankRequestSent = true
      bankRequest = ""
    } catch {
      failure = error
    }
  }

  // MARK: Your email (step 4) and the scan (step 5)

  var offersSampleData: Bool { services.mailbox.offersSampleData }

  /// The email step already ran here: its screen shows the connected state and Continue,
  /// never a second sign-in (plan B3.2 rule 2).
  var mailConnected: Bool { facts.mailbox != .unlinked }

  /// The provider's sign-in, then the first scan; or, once connected, on to the scan.
  func connectMail(_ provider: MailProviderKind) async {
    guard !mailConnected else {
      go(scanTask != nil ? .scan : .income)
      return
    }
    busy = true
    defer { busy = false }
    do {
      try await services.mailbox.connect(provider)
    } catch {
      failure = Self.setupFailure(error, provider)
      return
    }
    draft.provider = provider
    facts.mailSkipped = false
    facts.mailbox = .scanning
    startScan()
    go(.scan)
  }

  /// A connect failure as the setup banner shows it (a closed sign-in shows nothing).
  static func setupFailure(_ f: MailConnectFailure, _ provider: MailProviderKind) -> SetupFailure {
    switch f {
    case .cancelled: .cancelled
    case .offline: .offline
    default: .failed(f.message(for: provider) ?? "")
    }
  }

  func skipMail() {
    facts.mailSkipped = true
    go(.income)
  }

  func useSampleData() async {
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

  private func startScan() {
    guard scanTask == nil else { return }
    let stream = services.mailbox.firstScan()
    scanTask = Task { [weak self] in
      for await p in stream {
        guard let self else { return }
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

  // MARK: Income (step 6) and plan (step 7)

  /// The income in fils, from the digits typed (whole dirhams).
  var incomeMinor: Int64? {
    let digits = incomeText.filter(\.isNumber)
    guard !digits.isEmpty, let v = Int64(digits.prefix(9)), v > 0 else { return nil }
    return v * 100
  }

  var incomeDisplay: String {
    guard let v = incomeMinor else { return "0" }
    return (v / 100).formatted(.number.grouping(.automatic))
  }

  func continueWithIncome() {
    facts.incomeSet = incomeMinor != nil
    facts.incomeSkipped = incomeMinor == nil
    go(.plan)
  }

  func skipIncome() {
    incomeText = ""
    facts.incomeSkipped = true
    go(.plan)
  }

  /// "Use this plan" (or Skip): one enqueue of the income and plan ops, unless exactly
  /// these were sent already (a changed value is a real change, and is sent again).
  func savePlan(skip: Bool = false) async {
    let values = SetupReadBack(incomeMinor: incomeMinor, payday: incomeMinor == nil ? nil : payday,
                               split: skip ? nil : plan)
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

  /// "Continue" on the result, whether or not the scan has finished.
  func afterResult() { go(.notifications) }

  // MARK: Notifications (step 9) and done (step 10)

  /// The system was asked here already: the step shows "Continue" (plan B3.2 rule 2).
  var notificationsAllowed: Bool { draft.notificationsDecision == .allowed }

  /// "Allow notifications": iOS asks once; after that the step's button only continues.
  func allowNotifications() async {
    if draft.notificationsDecision != .allowed {
      services.notifications.showsDetails = showDetails
      _ = await services.notifications.requestAuthorization()
      draft.notificationsDecision = .allowed
    }
    facts.notificationsAsked = true
    go(.done)
  }

  func notNow() {
    if draft.notificationsDecision != .allowed { draft.notificationsDecision = .notNow }
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
