import HasalaDesign
import HasalaModels
import Observation
import SwiftUI

enum FinishSetupItem: String, CaseIterable, Identifiable {
  case phrase
  case connectEmail
  case bankAlerts
  case readingStopped
  case plan
  case notifications

  var id: String { rawValue }
}

@MainActor
final class ManualEntryChoice {
  static let key = "prefs.home.finish.byHand.v1"

  private let defaults: UserDefaults?
  private var chosenInMemory = false

  init(defaults: UserDefaults? = nil) {
    self.defaults = defaults
  }

  var chosen: Bool { defaults?.bool(forKey: Self.key) ?? chosenInMemory }

  func choose() {
    if let defaults { defaults.set(true, forKey: Self.key) } else { chosenInMemory = true }
  }

  static func forget(_ defaults: UserDefaults) {
    defaults.removeObject(forKey: key)
  }
}

@MainActor
@Observable
final class FinishSetupModel {
  @ObservationIgnored private let services: AccountServices
  @ObservationIgnored private let firstScan: FirstScanRun
  @ObservationIgnored private var importResumed = false
  @ObservationIgnored private let session: (() -> AccountSession)?
  private(set) var phraseTracked = false
  private(set) var phraseSecurity: SecurityModel?
  private(set) var phraseLoading = false
  private(set) var phraseFailure: AuthFailure?
  private(set) var planDone = false
  private(set) var notificationsDone = false
  private(set) var entersByHand = false
  var planFlow: MonthlyPlanModel?
  @ObservationIgnored private var draft: MonthlyPlanModel?
  var askingNotifications = false
  var showDetails = false
  private(set) var ledgerEmpty = false
  private var listed: Set<FinishSetupItem> = [.plan, .notifications]
  private(set) var alertsFound = false
  private(set) var checkingAgain = false
  var checkFailure: SetupFailure?
  private(set) var checkNote: String?
  var showingNoAlerts = false
  @ObservationIgnored private var bankAlertsAfterSheet = false

  init(services: AccountServices, firstScan: FirstScanRun = FirstScanRun(), session: (() -> AccountSession)? = nil) {
    self.services = services
    self.firstScan = firstScan
    self.session = session
    entersByHand = services.manualEntry.chosen
    refresh()
  }

  var items: [FinishSetupItem] {
    FinishSetupItem.allCases.filter {
      (listed.contains($0) || !isDone($0)) && !($0 == .connectEmail && (entersByHand || usesTexts))
    }
  }

  var noAlerts: Bool { ledgerEmpty && !alertsFound && (checkingAgain || services.mailbox.firstScanFinished) }

  var usesTexts: Bool { services.bankTexts?.usesTexts == true }

  var needsEmail: Bool {
    let mailbox = services.mailbox
    guard !usesTexts else { return false }
    return mailbox.mailboxesKnown && mailbox.heldElsewhere == nil && mailbox.offer == .connect
  }

  func enterByHand() {
    services.manualEntry.choose()
    entersByHand = true
  }

  var stoppedMailbox: MailboxSnapshot? {
    guard ledgerEmpty, !services.mailbox.firstScanFinished,
      let m = services.mailbox.mailboxes.first(where: { $0.state != .disconnected }),
      m.state == .needsSignIn || m.readElsewhere || m.note != nil
    else { return nil }
    return m
  }

  func refresh(hasTransactions: Bool? = nil) {
    if services.unseenPhrase.unseen {
      phraseTracked = true
      listed.insert(.phrase)
    }
    if let hasTransactions { ledgerEmpty = !hasTransactions }
    if needsEmail { listed.insert(.connectEmail) }
    if noAlerts { listed.insert(.bankAlerts) }
    if stoppedMailbox != nil { listed.insert(.readingStopped) }
    let saved = services.setup.readBack()
    if !planDone, saved.split != nil || saved.incomeMinor != nil { planDone = true }
    if !notificationsDone, services.notifications.answered { notificationsDone = true }
  }

  func resumeImport() async {
    guard !importResumed else { return }
    importResumed = true
    guard !firstScan.running, await services.mailbox.linkState() == .scanning else { return }
    firstScan.start(services.mailbox)
  }

  func isDone(_ item: FinishSetupItem) -> Bool {
    switch item {
    case .phrase: !services.unseenPhrase.unseen
    case .connectEmail: !needsEmail
    case .readingStopped: stoppedMailbox == nil
    case .bankAlerts: !noAlerts
    case .plan: planDone
    case .notifications: notificationsDone
    }
  }

  var phraseProblem: AuthFailure? {
    if let phraseFailure { return phraseFailure }
    guard let phraseSecurity, phraseSecurity.confirming == nil, phraseSecurity.viewedPhrase == nil else { return nil }
    return phraseSecurity.failure
  }

  func remindAboutPhrase() async {
    await services.unseenPhrase.remindIfAllowed()
  }

  func writeDownPhrase() async {
    guard !phraseLoading, let session else { return }
    let security = phraseSecurity ?? SecurityModel(session: session())
    phraseSecurity = security
    phraseFailure = nil
    phraseLoading = true
    defer { phraseLoading = false }
    if security.state == nil { await security.load() }
    if security.state?.hasPasskey == false {
      phraseFailure = .passkeyCantShowUnseenPhrase
      return
    }
    security.requestPhrase()
    if security.confirming == nil { phraseFailure = security.failure ?? .refused }
  }

  var noAlertsBanks: [SupportedBank] {
    let chosen = Set(services.mailbox.chosenBanks())
    return SupportedBank.allCases.filter { chosen.contains($0) }
  }

  var noAlertsMailbox: MailProviderKind {
    services.mailbox.mailboxes.first { $0.state != .disconnected }?.provider ?? services.mailbox.linkedProvider ?? .gmail
  }

  var alreadyChecking: Bool { !checkingAgain && services.mailbox.importing?.busy == true }

  func openNoAlerts() {
    checkFailure = nil
    checkNote = nil
    showingNoAlerts = true
  }

  func useDifferentEmail() {
    bankAlertsAfterSheet = true
    showingNoAlerts = false
  }

  func takeBankAlertsRequest() -> Bool {
    defer { bankAlertsAfterSheet = false }
    return bankAlertsAfterSheet
  }

  func checkAgain() async {
    guard !checkingAgain else { return }
    checkFailure = nil
    checkNote = nil
    guard !alreadyChecking else {
      checkNote = Self.alreadyCheckingLine(noAlertsMailbox)
      return
    }
    guard noAlerts else { return }
    checkingAgain = true
    defer { checkingAgain = false }
    var ended = false
    for await p in services.mailbox.firstScan() {
      switch p.phase {
      case .finished, .background:
        ended = true
        if let s = p.summary, s.total > 0 { alertsFound = true }
      case .failed(let message):
        ended = true
        checkFailure = .failed(message)
      default: break
      }
    }
    if !ended { checkNote = Self.alreadyCheckingLine(noAlertsMailbox) }
    if alertsFound { showingNoAlerts = false }
  }

  static func alreadyCheckingLine(_ provider: MailProviderKind) -> String {
    "Hasala is already reading \(provider.appName). New alerts show on Home as they're read."
  }

  var today: LocalDate { (services.setup as? SetupClock)?.today() ?? LedgerToday.device() }

  func setPlan() {
    let flow = draft ?? MonthlyPlanModel(setup: services.setup) { [weak self] held in
      if let held {
        self?.draft = nil
        if held.split != nil || held.incomeMinor != nil { self?.planDone = true }
      }
      self?.planFlow = nil
    }
    flow.path = []
    draft = flow
    planFlow = flow
  }

  func askNotifications() {
    showDetails = services.notifications.showsDetails
    askingNotifications = true
  }

  func allowNotifications() async {
    services.notifications.showsDetails = showDetails
    _ = await services.notifications.requestAuthorization()
    notificationsDone = true
    askingNotifications = false
    await services.unseenPhrase.remindIfAllowed()
  }

  func notificationsNotNow() {
    services.notifications.decline()
    notificationsDone = true
    askingNotifications = false
  }
}

struct FinishSetupSection: View {
  let model: FinishSetupModel
  let items: [FinishSetupItem]
  let importing: Bool
  var openBankAlerts: () -> Void = {}

  var body: some View {
    let open = items.filter { !model.isDone($0) }
    if !open.isEmpty {
      VStack(alignment: .leading, spacing: 12) {
        HSectionHeader("Finish setting up", trailing: .fact("\(items.count - open.count) of \(items.count)"))
        ForEach(open) { item in
          switch item {
          case .phrase:
            FinishSetupRow(
              icon: .paper, title: "Write down your 12 words",
              detail: "Your spare key if you lose this iPhone and your passkey. 2 minutes, pen and paper.",
              enabled: !model.phraseLoading, tone: .urgent, identifier: "home.finish.phrase") {
                Task { await model.writeDownPhrase() }
              }
            if let failure = model.phraseProblem {
              FailureBanner(failure: failure)
              if failure == .passkeyCantShowUnseenPhrase {
                WebLink(title: "Talk to a person", url: "https://hasala.app/support", identifier: "home.finish.phraseTalk")
              }
            }
          case .connectEmail:
            FinishSetupRow(
              icon: .envelope, title: "Connect your email",
              detail: "Where your banks send alerts. Hasala reads them on this iPhone.",
              enabled: true, identifier: "home.finish.connectEmail", action: openBankAlerts)
            TextLinkRow(lead: "Adding transactions by hand?", link: "Hide this.",
                        identifier: "home.finish.connectEmail.byHand", action: model.enterByHand)
          case .readingStopped:
            let stopped = Self.stopped(model.stoppedMailbox)
            FinishSetupRow(
              icon: .envelope, title: stopped.title, detail: stopped.detail,
              enabled: true, identifier: "home.finish.readingStopped", action: openBankAlerts)
          case .bankAlerts:
            FinishSetupRow(
              icon: .envelope, title: "No bank alerts yet",
              detail: "Turn on email alerts with your bank, then check again.",
              enabled: true, identifier: "home.finish.bankAlerts", action: model.openNoAlerts)
          case .plan:
            FinishSetupRow(
              icon: .clock, title: "Set your monthly plan",
              detail: "Your salary and a split, so Hasala can say what's left.",
              enabled: true, identifier: "home.finish.plan", action: model.setPlan)
          case .notifications:
            FinishSetupRow(
              icon: .bell, title: "A note when money moves",
              detail: importing
                ? "Offered once your alerts are read."
                : "Choose whether Hasala can send you a short note.",
              enabled: !importing, identifier: "home.finish.notifications", action: model.askNotifications)
          }
        }
      }
      .padding(.horizontal, HSpacing.insetPage)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("home.finish")
    }
  }
}

extension FinishSetupSection {
  static func stopped(_ m: MailboxSnapshot?) -> (title: String, detail: String) {
    if let m, m.state == .needsSignIn {
      return ("Sign in to your email again", "Hasala can't read \(m.address) right now. Open Bank alerts to sign in.")
    }
    if m?.readElsewhere == true {
      return ("Read on your other iPhone", "Its transactions show here once that iPhone syncs them.")
    }
    return ("Reading your alerts stopped", "Open Bank alerts to try again.")
  }
}

private struct FinishSetupRow: View {
  enum Tone { case normal, urgent }

  let icon: HIcon
  let title: String
  let detail: String
  let enabled: Bool
  var tone: Tone = .normal
  let identifier: String
  var action: () -> Void

  private var urgent: Bool { tone == .urgent }

  var body: some View {
    Button(action: action) {
      HStack(spacing: 14) {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .fill(urgent ? HColor.surfacePrimary : enabled ? HColor.blue50 : HColor.neutral100)
          .frame(width: 44, height: 44)
          .overlay {
            HIconView(icon, size: 22, color: iconColor, strokeWidth: 1.6)
          }
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .hType(HType(size: 17, leading: 22, weight: .semibold, textStyle: .headline))
            .foregroundStyle(urgent ? HColor.amber950 : HColor.textPrimary)
          Text(detail)
            .hType(HType(size: 14, leading: 19, weight: .regular, textStyle: .subheadline))
            .foregroundStyle(urgent ? HColor.statusWarningForeground : HColor.textSecondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        if enabled || urgent {
          HIconView(.chevronRight, size: HSpacing.iconSmall,
                    color: urgent ? HColor.statusWarningForeground : HColor.neutral400)
        }
      }
      .padding(16)
      .background(urgent ? HColor.statusWarningSurface : HColor.widgetSurface,
                  in: RoundedRectangle(cornerRadius: 22, style: .continuous))
      .overlay {
        if urgent {
          RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(HColor.amber300, lineWidth: 1)
        }
      }
      .opacity(enabled || urgent ? 1 : 0.6)
      .contentShape(Rectangle())
    }
    .buttonStyle(HRowPressStyle())
    .disabled(!enabled)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isButton)
    .accessibilityIdentifier(identifier)
  }

  private var iconColor: Color {
    if urgent { return HColor.statusWarningForeground }
    return enabled ? HColor.actionAccent : HColor.neutral600
  }
}

struct PhraseOnHome: View {
  @Bindable var model: SecurityModel

  var body: some View {
    Color.clear
      .frame(width: 0, height: 0)
      .accessibilityHidden(true)
      .confirmSheet(model)
      .fullScreenCover(isPresented: Binding(get: { model.viewedPhrase != nil },
                                            set: { if !$0 { model.closePhrase() } })) {
        PhraseViewer(model: model)
      }
  }
}

struct MonthlyPlanSheet: View {
  @Bindable var model: MonthlyPlanModel
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack(path: $model.path) {
      IncomeStep(model: model)
        .toolbar {
          ToolbarItem(placement: .topBarLeading) {
            Button(role: .close) { dismiss() }
              .tint(HColor.iconGlass)
              .accessibilityIdentifier("plan.setup.close")
          }
        }
        .navigationDestination(for: MonthlyPlanModel.Route.self) { _ in
          PlanStep(model: model)
        }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("plan.setup")
  }
}

struct NotificationsAskSheet: View {
  @Bindable var model: FinishSetupModel

  var body: some View {
    NotificationsStep(
      today: model.today, showDetails: $model.showDetails,
      allow: { await model.allowNotifications() }, notNow: model.notificationsNotNow)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("notifications.ask")
  }
}
