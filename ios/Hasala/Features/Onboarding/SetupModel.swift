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
@MainActor
@Observable
final class SetupModel {
  private let services: AccountServices
  private let onFinished: () -> Void
  var path: [SetupRoute] = []
  private(set) var facts: OnboardingStep.Facts

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

  init(services: AccountServices, displayName: String, facts: OnboardingStep.Facts, onFinished: @escaping () -> Void) {
    self.services = services
    self.displayName = displayName
    self.facts = facts
    self.onFinished = onFinished
  }

  var step: OnboardingStep { OnboardingStep.derive(facts) }

  /// Routes for the derived step, so a relaunch mid-setup resumes there.
  func resume() {
    switch step {
    case .bank, .passcode, .account, .keys: path = []
    case .gmail: path = [.gmail]
    case .scan: path = [.gmail, .scan]
    case .income: path = [.income]
    case .plan: path = [.income, .plan]
    case .cards: path = [.cards]
    case .notifications: path = [.notifications]
    case .done: path = [.done]
    case .finished: onFinished()
    }
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
      facts.mailbox = .scanning
      startScan()
      go(.scan)
    } catch {
      failure = error
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
      go(.notifications)
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
