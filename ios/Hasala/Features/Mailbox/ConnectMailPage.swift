import HasalaDesign
import HasalaModels
import SwiftUI

/// The connect screen in the profile's context (Profile › Bank alerts › Add a mailbox, or
/// "Sign in again"), pushed inside the profile sheet so a password step-up can present
/// over it (no sheet over a sheet). A new mailbox's first scan starts here and goes on in
/// the background; Bank alerts shows it syncing.
///
/// An account that reads no bank yet (setup's bank step was skipped for manual entry)
/// picks its banks first, as setup does before its email step: the lane reads only the
/// banks' alert senders, so without them it would read nothing, and the provider's screen
/// would list no bank.
///
/// The foundation's version (plan B7.3).
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
    let context: MailConnectCoordinator.Context
    if case .signInAgain(let id, let p)? = app.mailOffer, p == provider {
      context = .signInAgain(mailboxID: id)
    } else {
      context = .addMailbox
    }
    _coordinator = State(initialValue: app.mailbox.map { MailConnectCoordinator(mailbox: $0, context: context) })
    _banks = State(initialValue: app.mailbox?.chosenBanks() ?? [])
  }

  var body: some View {
    if let coordinator, let mailbox = app.mailbox {
      if banks.isEmpty {
        MailBanksStep(provider: provider, setup: session?.services.setup) { banks = $0 }
      } else {
        ConnectProviderView(
          provider: provider, coordinator: coordinator, banks: banks,
          onConnected: { _ in connected(mailbox, coordinator.context) },
          onChooseDifferent: { app.router.profile.removeLast() })
      }
    }
  }

  /// Back to Bank alerts with a toast; a new mailbox's first import starts and outlives
  /// this screen.
  private func connected(_ mailbox: MailboxConnecting, _ context: MailConnectCoordinator.Context) {
    if context == .addMailbox {
      app.say("\(provider.appName) connected. Checking for alerts.")
      Task {
        guard await mailbox.linkState() == .scanning else { return }
        for await _ in mailbox.firstScan() {}
      }
    } else {
      app.say("\(provider.appName) reconnected")
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
            if i > 0 { Divider().padding(.leading, 68) }
            BankChoiceRow(bank: bank, on: chosen.contains(bank)) {
              if chosen.contains(bank) { chosen.remove(bank) } else { chosen.insert(bank) }
            }
          }
        }
        .listCard()
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
