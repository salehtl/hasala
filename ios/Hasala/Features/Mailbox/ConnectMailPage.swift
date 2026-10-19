import HasalaDesign
import HasalaModels
import SwiftUI

/// The connect screen in the profile's context (Profile › Bank alerts › Add a mailbox, the
/// Profile card's "Connect your email" or "Sign in again"), pushed inside the profile sheet
/// so a password step-up can present over it (no sheet over a sheet). No step indicator.
///
/// A sign-in that didn't finish, or a work account its admin hasn't approved, swaps in its
/// own screen ("Outlook isn't connected.", "Your organisation needs to approve Hasala.");
/// trying again runs the sign-in from the read-only screen. Connected, it goes back to Bank
/// alerts with a toast, where the new mailbox lands syncing; its first scan starts here and
/// goes on in the background.
///
/// An account that reads no bank yet (setup's bank step was skipped for manual entry)
/// picks its banks first, as setup does before its email step: the lane reads only the
/// banks' alert senders, so without them it would read nothing, and the provider's screen
/// would list no bank.
struct ConnectMailPage: View {
  @Bindable var app: AppModel
  let provider: MailProviderKind
  /// One attempt per push; nil without a mail lane (previews).
  @State private var coordinator: MailConnectCoordinator?
  /// The banks the account reads: read when the page is pushed, then the ones chosen here.
  @State private var banks: [SupportedBank]
  @Environment(AccountSession.self) private var session: AccountSession?

  init(app: AppModel, provider: MailProviderKind) {
    self.app = app
    self.provider = provider
    let context = Self.context(provider, offer: app.mailOffer)
    let handed = MailConnectCoordinator.handed(provider)
    _coordinator = State(initialValue: handed ?? app.mailbox.map { MailConnectCoordinator(mailbox: $0, context: context) })
    _banks = State(initialValue: app.mailbox?.chosenBanks() ?? [])
  }

  /// What a connect of `provider` from the profile does: while the offer (the Home bell's,
  /// the Profile card's) is a new sign-in for that provider's mailbox, it signs that one in
  /// again; otherwise it adds a mailbox. Add a mailbox's rows say the same
  /// (`ChooseEmailSheet.subtitle`).
  static func context(_ provider: MailProviderKind, offer: MailOffer?) -> MailConnectCoordinator.Context {
    if case .signInAgain(let id, let p)? = offer, p == provider { return .signInAgain(mailboxID: id) }
    return .addMailbox
  }

  var body: some View {
    if let coordinator, let mailbox = app.mailbox {
      Group {
        if banks.isEmpty {
          MailBanksStep(provider: provider, setup: session?.services.setup) { banks = $0 }
        } else if let failure = coordinator.errorScreen {
          MailConnectErrorView(
            failure: failure, provider: provider,
            onRetry: { retry(coordinator, mailbox) },
            onChooseDifferent: chooseDifferent)
        } else {
          ConnectProviderView(
            provider: provider, coordinator: coordinator, banks: banks,
            onConnected: { id in connected(id, mailbox, coordinator.context) },
            onChooseDifferent: chooseDifferent, choiceIsBack: choiceIsBack)
        }
      }
      .hAnimation(.stateSwap, value: coordinator.errorScreen)
      .onAppear { MailConnectCoordinator.release() }
      #if HASALA_MOCKS
        // A Debug screen id that stands for "Continue with <provider>" (`MailLaunch`).
        .task { if !banks.isEmpty, MailLaunch.takeConnect(provider) { await run(coordinator, mailbox) } }
      #endif
    }
  }

  /// "Continue with Microsoft" or "Try Microsoft again" on an error: back to the read-only
  /// screen, whose button shows the sign-in running.
  private func retry(_ coordinator: MailConnectCoordinator, _ mailbox: MailboxConnecting) {
    coordinator.reset()
    Task {
      await coordinator.retry(provider)
      if case .connected(let id)? = coordinator.outcome { connected(id, mailbox, coordinator.context) }
    }
  }

  private func run(_ coordinator: MailConnectCoordinator, _ mailbox: MailboxConnecting) async {
    await coordinator.connect(provider)
    if case .connected(let id)? = coordinator.outcome { connected(id, mailbox, coordinator.context) }
  }

  /// Add a mailbox's providers are the screen behind this one: Back picks another.
  private var choiceIsBack: Bool {
    let path = app.router.profile
    guard let i = path.lastIndex(of: .connectMail(provider)), i > 0 else { return false }
    return path[i - 1] == .addMailbox
  }

  /// The providers: back to Add a mailbox when it led here, else in this screen's place (the
  /// Profile card's "Connect your email" pushes this screen straight away).
  private func chooseDifferent() {
    var path = app.router.profile
    if path.last == .connectMail(provider) { path.removeLast() }
    if path.last != .addMailbox { path.append(.addMailbox) }
    app.router.profile = path
  }

  /// Back to Bank alerts with a toast; a new mailbox's first import starts and outlives
  /// this screen. This screen goes as it ends, so Bank alerts plays the success moment
  /// once it shows (`MailboxMoment`): the new row lands, or the haptic plays for a mailbox
  /// read again. That holds when Bank alerts is made new in this screen's place, too.
  private func connected(_ id: String, _ mailbox: MailboxConnecting, _ context: MailConnectCoordinator.Context) {
    if context == .addMailbox {
      app.say(MailCopy.added(provider))
      MailboxMoment.hand(.added(mailboxID: id))
      Task {
        guard await mailbox.linkState() == .scanning else { return }
        for await _ in mailbox.firstScan() {}
      }
    } else {
      app.say(MailCopy.signedInAgain(provider))
      MailboxMoment.hand(.signedInAgain(mailboxID: id))
    }
    if let i = app.router.profile.lastIndex(of: .bankAlerts) {
      app.router.profile.removeSubrange((i + 1)...)
    } else {
      app.router.profile = [.bankAlerts]
    }
  }
}

/// "Which bank do you use?" before a connect from the profile (Paper "Setup · 1 of 4 ·
/// Bank", without the step, Skip or a bank request): Continue sends the same bank ops as
/// setup's step (`SetupAuthoring.chooseBanks`), then the provider's screen lists them.
private struct MailBanksStep: View {
  let provider: MailProviderKind
  /// Nil outside the account gate (previews): nothing can be sent, so Continue is off.
  let setup: SetupAuthoring?
  var onChosen: ([SupportedBank]) -> Void

  /// Both picked, as setup's step starts.
  @State private var chosen = Set(SupportedBank.allCases)
  @State private var busy = false
  @State private var failure: SetupFailure?

  private var ordered: [SupportedBank] { SupportedBank.allCases.filter { chosen.contains($0) } }

  var body: some View {
    AccountScreen(
      title: "Which bank do you use?",
      subtitle: "Pick yours. Hasala reads only their transaction alerts, nothing else in your mail.",
      back: .system
    ) {
      VStack(alignment: .leading, spacing: 12) {
        Text("Available now").hType(.overline).foregroundStyle(HColor.textSecondary).padding(.leading, 16)
        VStack(spacing: 0) {
          ForEach(Array(SupportedBank.allCases.enumerated()), id: \.element) { i, bank in
            if i > 0 { HDivider(inset: .disc68) }
            BankChoiceRow(bank: bank, on: chosen.contains(bank)) {
              if chosen.contains(bank) { chosen.remove(bank) } else { chosen.insert(bank) }
            }
          }
        }
        .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.listGroup, style: .continuous))
        if let message = failure?.message {
          FailureBanner(failure: .badPhrase(message))
        }
      }
    } footer: {
      LockNote(text: "Next you'll connect \(provider.appName), read-only. Only alerts from the banks you pick are downloaded, straight to this iPhone.")
        .padding(.bottom, 8)
      BusyButton(title: chosen.count == 1 ? "Continue with 1 bank" : "Continue with \(chosen.count) banks",
                 busy: busy, enabled: !chosen.isEmpty && setup != nil, identifier: "bank.continue") {
        Task { await choose() }
      }
      .dockPill()
    }
  }

  private func choose() async {
    guard let setup, !chosen.isEmpty, !busy else { return }
    busy = true
    defer { busy = false }
    let banks = ordered
    do {
      try await setup.chooseBanks(banks)
      failure = nil
      onChosen(banks)
    } catch {
      failure = error
    }
  }
}
