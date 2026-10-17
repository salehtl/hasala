import Foundation
import HasalaModels
import Observation

/// The mail lane as setup's email step sees it (plan B3.2 rule 2): a connect that already
/// happened answers at once with the mailbox it made, so Back to the email step and
/// Continue never open the provider's sign-in, the `mailbox.link` step-up or the server
/// link a second time. Everything else passes straight to the lane.
///
/// "Already happened" is a connect made through this link in this process, a mailbox of
/// that provider the account reads, or (the lane's status not read yet after a relaunch)
/// a link setup's facts already hold. The connect screens' `MailConnectCoordinator` runs
/// through it, so their connected state comes back without a second sign-in after a
/// relaunch too.
@MainActor
@Observable
final class SetupMailLink: MailboxConnecting {
  @ObservationIgnored let base: MailboxConnecting
  /// Whether setup's facts say the account's mail is linked (scanning, linked, or read on
  /// another iPhone).
  @ObservationIgnored var isLinked: () -> Bool = { false }
  /// The mailbox each provider's connect made here.
  @ObservationIgnored private var made: [MailProviderKind: String] = [:]

  init(base: MailboxConnecting) {
    self.base = base
  }

  /// The mailbox a connect of `provider` would only find again, if there is one.
  func existing(_ provider: MailProviderKind) -> String? {
    if let id = made[provider] { return id }
    let reading = base.mailboxes.filter { $0.state != .disconnected }
    if let mailbox = reading.first(where: { $0.provider == provider }) { return mailbox.id }
    // Linked, but the lane's status isn't read yet: the provider the link is to.
    if isLinked(), reading.isEmpty, provider == (base.linkedProvider ?? base.connectable.first ?? .gmail) {
      return provider.rawValue
    }
    return nil
  }

  var connectable: [MailProviderKind] { base.connectable }
  var capabilities: MailboxCapabilities { base.capabilities }
  var mailboxes: [MailboxSnapshot] { base.mailboxes }
  var offer: MailOffer? { base.offer }
  var linkedProvider: MailProviderKind? { base.linkedProvider }
  var offersSampleData: Bool { base.offersSampleData }
  var importing: MailImport? { base.importing }

  func chosenBanks() -> [SupportedBank] { base.chosenBanks() }
  func linkState() async -> OnboardingStep.Facts.Mailbox { await base.linkState() }

  @discardableResult
  func connect(_ provider: MailProviderKind, replacing: Bool) async throws(MailConnectFailure) -> String {
    if let id = existing(provider) { return id }
    let id = try await base.connect(provider, replacing: replacing)
    made[provider] = id
    return id
  }

  func signInAgain(_ mailboxID: String) async throws(MailConnectFailure) { try await base.signInAgain(mailboxID) }
  func disconnect(_ mailboxID: String) async throws(MailConnectFailure) { try await base.disconnect(mailboxID) }
  func firstScan() -> AsyncStream<ScanProgress> { base.firstScan() }
  func loadSampleData() async throws(SetupFailure) { try await base.loadSampleData() }
}
