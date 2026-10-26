import Foundation
import HasalaDesign
import HasalaModels
import Observation

/// What setup last sent, so an unchanged value isn't sent again (plan B3.2 rule 3).
struct AuthoredSetup: Equatable, Sendable {
  /// The banks `chooseBanks` last sent; nil until it ran.
  var banks: [SupportedBank]?
}

/// Everything chosen in setup (plan B3.2), kept for the life of the process with the model
/// (`OnboardingStore`): Back never reverts it and Forward shows it again. A value left nil
/// was never chosen, so a relaunch can fill it from what the account holds
/// (`SetupModel.reconcile`).
struct SetupDraft: Equatable, Sendable {
  /// The banks picked; nil shows both picked.
  var chosenBanks: Set<SupportedBank>?
  var bankRequestSent = false
  /// The provider the person connected or picked in "Choose your email"; it skips the
  /// chooser next time (plan B3.2 rule 5).
  var provider: MailProviderKind?
  var source: PaymentSource?
  var authored = AuthoredSetup()
}

/// Setup state. The steps' facts are what `OnboardingStep.derive` reads; this model keeps
/// them and the draft for the process (`OnboardingStore` owns it), and a relaunch reads
/// them back from the projection, the lane and prefs (`reconcile`).
@MainActor
@Observable
final class SetupModel {
  private let services: AccountServices
  private let onFinished: () -> Void
  @ObservationIgnored private let firstScan: FirstScanRun
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

  /// One per account: the first scan starts once (plan B3.2 rule 4).
  private var importStarted = false
  private var didResume = false
  private var left = false

  var busy = false
  private(set) var connecting = false
  var connectRequest: MailProviderKind?
  @ObservationIgnored private var connectAfterChoosing: MailProviderKind?
  var failure: SetupFailure?
  var displayName: String

  init(services: AccountServices, displayName: String, facts: OnboardingStep.Facts,
       firstScan: FirstScanRun = FirstScanRun(), onFinished: @escaping () -> Void) {
    self.services = services
    self.firstScan = firstScan
    self.displayName = displayName
    self.facts = facts
    self.onFinished = onFinished
    mailLink = SetupMailLink(base: services.mailbox)
    mailLink.isLinked = { [weak self] in self?.mailConnected ?? false }
  }

  var step: OnboardingStep { OnboardingStep.derive(facts) }

  // MARK: The draft, as the steps bind it

  var chosenBanks: Set<SupportedBank> {
    get { draft.chosenBanks ?? Set(SupportedBank.allCases) }
    set { draft.chosenBanks = newValue }
  }
  var bankRequestSent: Bool { draft.bankRequestSent }

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
  func reconcile(facts new: OnboardingStep.Facts, banks: [SupportedBank]) {
    facts.hasPasscode = new.hasPasscode
    facts.hasSession = facts.hasSession || new.hasSession
    facts.keysReady = facts.keysReady || new.keysReady
    facts.banksChosen = facts.banksChosen || new.banksChosen || draft.authored.banks != nil
    facts.sampleLoaded = facts.sampleLoaded || new.sampleLoaded
    facts.textsChosen = facts.textsChosen || new.textsChosen
    facts.mailbox = new.mailbox
    if draft.chosenBanks == nil, !banks.isEmpty { draft.chosenBanks = Set(banks) }
    if draft.authored.banks == nil, new.banksChosen, !banks.isEmpty { draft.authored.banks = banks }
  }

  func resume() {
    if facts.mailbox == .scanning, !facts.sampleLoaded { startImport() }
    guard !didResume, step == .finished else { return }
    didResume = true
    finish()
  }

  func back() {
    failure = nil
    if !path.isEmpty { path.removeLast() }
  }

  private func go(_ r: SetupRoute) {
    failure = nil
    path.append(r)
  }

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
    finish()
  }

  var bankRequests: SetupAuthoring { services.setup }

  func noteBankRequestSent() { draft.bankRequestSent = true }

  var bankTexts: (any BankTextsConnecting)? { services.bankTexts }

  var offersBankTexts: Bool { bankTexts != nil && !offersSampleData && !mailConnected && bankTexts?.readsEmail != true }

  var readsBankEmailNote: String? { bankTexts?.readsEmail == true && source != .email ? BankTexts.setupReadsEmail : nil }

  var bankStepSubtitle: String {
    let reads = "Hasala reads your banks' alert emails on this iPhone."
    return bankTexts == nil ? "\(reads) Alerts must come by email, not only SMS." : reads
  }

  var connectBusy: Bool { connecting || coordinators.values.contains(where: \.busy) }

  var asksSource: Bool { offersBankTexts && draft.source != .email }

  var source: PaymentSource? { draft.source }

  private(set) var lastPickedSource: PaymentSource?

  func chooseSource(_ source: PaymentSource) {
    guard !busy, !connectBusy, bankTexts != nil else { return }
    didResume = true
    failure = nil
    lastPickedSource = source
    draft.source = source
    switch source {
    case .email:
      path = []
    case .texts:
      path = []
      go(.textsBanks)
    }
  }

  func backToSourceChoice() {
    guard !busy, !connectBusy else { return }
    failure = nil
    draft.source = nil
  }

  func skipSource() {
    guard !busy else { return }
    draft.source = nil
    skipBanks()
  }

  func continueWithTextBanks() async {
    guard path.last == .textsBanks, await saveBanks() else { return }
    go(.textsSetUp)
  }

  func sendTestText() {
    guard path.last != .textsTest else { return }
    bankTexts?.startTest()
    go(.textsTest)
  }

  func finishTexts() async {
    guard !busy, let lane = bankTexts else { return }
    didResume = true
    failure = nil
    busy = true
    defer { busy = false }
    do {
      try await lane.finishSetUp()
    } catch {
      failure = .failed(error.message)
      return
    }
    facts.textsChosen = true
    finish()
  }

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

  /// The connect attempt for `provider`'s screen, made once and kept.
  func coordinator(_ provider: MailProviderKind) -> MailConnectCoordinator {
    if let c = coordinators[provider] { return c }
    let c = MailConnectCoordinator(mailbox: mailLink, context: .setup(stepOf: nil))
    coordinators[provider] = c
    return c
  }

  /// How the last connect of `provider` failed, for its error screen.
  func connectFailure(_ provider: MailProviderKind) -> MailConnectFailure? {
    if case .failed(let f)? = coordinators[provider]?.outcome { return f }
    return nil
  }

  /// The provider's sign-in, then the first scan; once connected, on to the scan without
  /// a second sign-in. (The connect screen's button runs the same coordinator.)
  func connectMail(_ provider: MailProviderKind, replacing: Bool = false, removingOld: Bool = false) async {
    await runConnect(provider, again: false, replacing: replacing, removingOld: removingOld)
  }

  private func runConnect(_ provider: MailProviderKind, again: Bool, replacing: Bool = false,
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
    await runConnect(provider, again: true)
  }

  func continueConnected() {
    guard path.isEmpty else { return }
    emailConnected(provider)
  }

  private func emailConnected(_ provider: MailProviderKind, fresh: Bool = false) {
    if path.last == .connectError(provider) { path.removeLast() }
    if fresh {
      importStarted = false
      facts.mailbox = .unlinked
    }
    if facts.mailbox == .unlinked {
      draft.provider = provider
      facts.mailSkipped = false
      facts.mailbox = .scanning
      startImport(again: fresh)
    }
    if let line = coordinators[provider]?.takeRemovalFailure() {
      failure = .failed(line)
      return
    }
    finish()
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
    finish()
  }

  func useSampleData() async {
    guard !busy else { return }
    didResume = true
    busy = true
    defer { busy = false }
    do {
      try await services.mailbox.loadSampleData()
      facts.sampleLoaded = true
      finish()
    } catch {
      failure = error
    }
  }

  // MARK: The import

  private func startImport(again: Bool = false) {
    guard !importStarted else { return }
    importStarted = true
    firstScan.start(services.mailbox, again: again)
  }

  func finish() {
    guard !left else { return }
    left = true
    didResume = true
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
