import Foundation
import Observation

/// The setup screens after the account (spec 04 §6.6, Paper row 10).
enum SetupRoute: Hashable {
  case gmail
  case scan
  case income
  case plan
  case cards
  case result
  case notifications
  case done
}

/// Setup state. The steps' facts are what `OnboardingStep.derive` reads; this model keeps
/// them for the process (the live build reads them back from the projection and prefs).
///
/// The same model runs "Connect Gmail" after setup (`connecting`, from Home or Profile):
/// the bank step only when the account reads no bank yet, then Gmail, then the cards when
/// the first scan needs them, in a sheet that closes at the end.
@MainActor
@Observable
final class SetupModel {
  private let services: AccountServices
  private let onFinished: () -> Void
  /// "Close" on a connect after setup (nil in setup itself).
  @ObservationIgnored private var onClose: (() -> Void)?
  var path: [SetupRoute] = []
  private(set) var facts: OnboardingStep.Facts
  /// Set when this is a connect after setup rather than setup.
  let connecting: GmailOffer?
  /// A connect after setup starts at the bank step (the account reads no bank yet).
  private(set) var startsAtBank = false

  // Bank
  var chosenBanks: Set<SupportedBank> = Set(SupportedBank.allCases)
  var bankRequest = ""
  private(set) var bankRequestSent = false

  // Gmail and the scan
  private(set) var scan: ScanProgress?
  private var scanTask: Task<Void, Never>?

  // Income and plan
  var incomeText = ""
  var payday = 28
  var plan = StartingPlan()

  // Cards and result
  var cards: [DiscoveredCard] = []
  private(set) var summary: SortSummary?

  // Notifications
  var showDetails = false

  var busy = false
  var failure: SetupFailure?
  var displayName: String

  init(
    services: AccountServices, displayName: String, facts: OnboardingStep.Facts, connecting: GmailOffer? = nil,
    onFinished: @escaping () -> Void
  ) {
    self.services = services
    self.displayName = displayName
    self.facts = facts
    self.connecting = connecting
    self.onFinished = onFinished
  }

  /// "Connect Gmail" or "Reconnect Gmail" after setup. `onFinished` runs when it is done,
  /// `onClose` when the user closes it first.
  static func connectingGmail(
    _ offer: GmailOffer, services: AccountServices, onClose: @escaping () -> Void, onFinished: @escaping () -> Void
  ) -> SetupModel {
    let m = SetupModel(
      services: services, displayName: "", facts: OnboardingStep.Facts(hasSession: true, keysReady: true),
      connecting: offer, onFinished: onFinished)
    m.onClose = onClose
    let banks = services.mailbox.chosenBanks()
    if banks.isEmpty {
      m.startsAtBank = true
    } else {
      m.chosenBanks = Set(banks)
      m.facts.banksChosen = true
    }
    return m
  }

  var step: OnboardingStep { OnboardingStep.derive(facts) }

  /// Routes for the derived step, so a relaunch mid-setup resumes there. A scan cut short
  /// starts streaming again, so the cards it found reach the cards step.
  func resume() {
    switch step {
    case .bank, .passcode, .account, .keys: path = []
    case .gmail: path = [.gmail]
    case .scan:
      path = [.gmail, .scan]
      startScan()
    case .income: path = [.income]
    case .plan: path = [.income, .plan]
    case .cards:
      path = [.cards]
      startScan()
    case .notifications: path = [.notifications]
    case .done: path = [.done]
    case .finished: onFinished()
    }
  }

  /// A connect after setup opens where the lane is: a first scan whose cards are still to
  /// confirm goes straight to the cards.
  func openConnect() async {
    guard connecting != nil else { return }
    facts.mailbox = await services.mailbox.linkState()
    if facts.mailbox == .scanning || facts.mailbox == .awaitingCards {
      path = [.cards]
      startScan()
    }
  }

  /// Setup's step numbers ("2 of 5"); a connect after setup shows none.
  func steps(_ n: Int) -> (current: Int, of: Int)? { connecting == nil ? (n, 5) : nil }

  /// The Gmail step's button.
  var connectTitle: String { (connecting ?? .connect).action }

  /// The Gmail step is the first screen of a connect after setup: nothing to go back to.
  var gmailIsFirst: Bool { connecting != nil && !path.contains(.gmail) }

  /// The top bar's back button on the Gmail step and the cards: none where a connect after
  /// setup has nothing to go back to (its first screen, and the cards once connected).
  func backButton(on route: SetupRoute) -> (() -> Void)? {
    switch route {
    case .gmail where gmailIsFirst: nil
    case .cards where connecting != nil: nil
    default: { [weak self] in self?.back() }
    }
  }

  /// The top bar's text button: setup's "Skip" (when the step has one), or "Close" on a
  /// connect after setup.
  func topAction(skip: (() -> Void)?) -> (title: String, action: () -> Void)? {
    if connecting != nil { return ("Close", { [weak self] in self?.close() }) }
    return skip.map { ("Skip", $0) }
  }

  /// "Close" on a connect after setup: the sheet goes, and a scan carries on in the
  /// background (the Home card brings the cards back).
  func close() {
    scanTask?.cancel()
    (onClose ?? onFinished)()
  }

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
    if chosenBanks.contains(bank) { chosenBanks.remove(bank) } else { chosenBanks.insert(bank) }
  }

  func continueWithBanks() async {
    guard !chosenBanks.isEmpty else { return }
    busy = true
    defer { busy = false }
    do {
      try await services.setup.chooseBanks(orderedBanks)
      facts.banksChosen = true
      go(.gmail)
    } catch {
      failure = error
    }
  }

  /// "Skip": manual-entry mode; Gmail, the scan and the cards are skipped too.
  func skipBanks() {
    facts.bankSkipped = true
    go(.income)
  }

  func sendBankRequest() async {
    let name = bankRequest.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return }
    do {
      try await services.setup.requestBank(String(name.prefix(80)))
      bankRequestSent = true
      bankRequest = ""
    } catch {
      failure = error
    }
  }

  // MARK: Gmail (step 4) and the scan (step 5)

  var offersSampleData: Bool { services.mailbox.offersSampleData }

  func connectGmail() async {
    busy = true
    defer { busy = false }
    do {
      try await services.mailbox.connectGmail(banks: orderedBanks)
    } catch {
      failure = error
      return
    }
    guard connecting != nil else {
      facts.mailbox = .scanning
      startScan()
      go(.scan)
      return
    }
    // After setup: a first connect (or a reconnect cut short mid-scan) goes on to the
    // cards; a reconnect resumes where it stopped and is done.
    facts.mailbox = await services.mailbox.linkState()
    if facts.mailbox == .scanning || facts.mailbox == .awaitingCards {
      startScan()
      go(.cards)
    } else {
      finish()
    }
  }

  func skipGmail() {
    facts.gmailSkipped = true
    go(.income)
  }

  func useSampleData() async {
    busy = true
    defer { busy = false }
    do {
      try await services.mailbox.loadSampleData()
      facts.sampleLoaded = true
      if connecting != nil { finish() } else { go(.notifications) }
    } catch {
      failure = error
    }
  }

  private func startScan() {
    scanTask?.cancel()
    let stream = services.mailbox.firstScan()
    scanTask = Task { [weak self] in
      for await p in stream {
        guard let self else { return }
        self.scan = p
        switch p.phase {
        case .awaitingCards:
          self.facts.mailbox = .awaitingCards
          self.cards = await self.services.mailbox.discoveredCards()
        case .failed(let message):
          self.failure = .failed(message)
        default: break
        }
      }
    }
  }

  var scanRunning: Bool { scan?.isRunning ?? false }

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

  /// "Use this plan" (or Skip): one enqueue of the income and plan ops.
  func savePlan(skip: Bool = false) async {
    busy = true
    defer { busy = false }
    do {
      try await services.setup.savePlan(income: incomeMinor, payday: incomeMinor == nil ? nil : payday,
                                        plan: skip ? nil : plan)
      facts.planSet = !skip
      facts.planSkipped = skip
      afterPlan()
    } catch {
      failure = error
    }
  }

  private func afterPlan() {
    if facts.mailbox == .scanning || facts.mailbox == .awaitingCards {
      go(.cards)
    } else {
      go(.notifications)
    }
  }

  // MARK: Cards (step 8)

  var keptCards: Int { cards.filter(\.keep).count }

  func toggleCard(_ id: String) {
    guard let i = cards.firstIndex(where: { $0.id == id }) else { return }
    cards[i].keep.toggle()
  }

  func confirmCards() async {
    busy = true
    defer { busy = false }
    do {
      summary = try await services.mailbox.confirmCards(cards)
      facts.mailbox = .linked
      go(.result)
    } catch {
      failure = error
    }
  }

  /// "Continue" on the result: setup goes on to notifications; a connect after setup is done.
  func afterResult() {
    if connecting != nil { finish() } else { path.append(.notifications) }
  }

  // MARK: Notifications (step 9) and done (step 10)

  func allowNotifications() async {
    services.notifications.showsDetails = showDetails
    _ = await services.notifications.requestAuthorization()
    facts.notificationsAsked = true
    go(.done)
  }

  func notNow() {
    facts.notificationsAsked = true
    go(.done)
  }

  func finish() {
    facts.finished = true
    scanTask?.cancel()
    onFinished()
  }
}
