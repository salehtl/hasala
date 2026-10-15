import HasalaDesign
import HasalaModels
import SwiftUI

/// The connect screen in the profile's context (Profile › Bank alerts › Add a mailbox, or
/// "Sign in again"), pushed inside the profile sheet so a password step-up can present
/// over it (no sheet over a sheet). A new mailbox's first scan starts here and goes on in
/// the background; Bank alerts shows it syncing.
///
/// The foundation's version (plan B7.3).
struct ConnectMailPage: View {
  @Bindable var app: AppModel
  let provider: MailProviderKind
  /// One attempt per push; nil without a mail lane (previews).
  @State private var coordinator: MailConnectCoordinator?

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
  }

  var body: some View {
    if let coordinator, let mailbox = app.mailbox {
      ConnectProviderView(
        provider: provider, coordinator: coordinator, banks: mailbox.chosenBanks(),
        onConnected: { _ in connected(mailbox, coordinator.context) },
        onChooseDifferent: { app.router.profile.removeLast() })
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
