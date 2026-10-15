import HasalaDesign
import HasalaModels
import SwiftUI

/// The read-only connect screen for one provider (Paper "Setup · 2 of 4 · Connect Gmail,
/// read-only", "Outlook, read-only"), in setup and in the profile: what Hasala reads and
/// never reads, then the provider's sign-in. Once connected it shows the mailbox and
/// "Continue", never a second sign-in.
///
/// The foundation's version (plan B7.3), on today's parts: setup still draws `GmailView`.
// TODO(plan P3): the flow strip, ProviderButton, MailboxRow, the per-provider footers and
// the "Use a different email? Tell us which." link.
struct ConnectProviderView: View {
  let provider: MailProviderKind
  @Bindable var coordinator: MailConnectCoordinator
  let banks: [SupportedBank]
  /// Review accounts: "Use sample data" (`mail.sample`) instead of mail.
  var sample: (() -> Void)?
  var onConnected: (String) -> Void
  var onChooseDifferent: () -> Void
  @Environment(\.dismiss) private var dismiss

  init(
    provider: MailProviderKind, coordinator: MailConnectCoordinator, banks: [SupportedBank],
    sample: (() -> Void)? = nil, onConnected: @escaping (String) -> Void, onChooseDifferent: @escaping () -> Void
  ) {
    self.provider = provider
    self.coordinator = coordinator
    self.banks = banks
    self.sample = sample
    self.onConnected = onConnected
    self.onChooseDifferent = onChooseDifferent
  }

  private var steps: (current: Int, of: Int)? {
    if case .setup(let steps) = coordinator.context { return steps.map { ($0.0, $0.1) } }
    return nil
  }

  private var connectedID: String? {
    if case .connected(let id) = coordinator.outcome { return id }
    return nil
  }

  private var failure: MailConnectFailure? {
    if case .failed(let f) = coordinator.outcome { return f }
    return nil
  }

  var body: some View {
    AccountScreen(
      title: connectedID == nil ? "Read-only \(provider.appName), on your iPhone." : "\(provider.appName) is connected.",
      subtitle: "Your bank alerts are fetched from \(provider.appName) by this iPhone. Our server never receives your emails.",
      steps: steps,
      back: .system
    ) {
      VStack(alignment: .leading, spacing: 12) {
        VStack(alignment: .leading, spacing: 10) {
          Text("Hasala reads").hType(.overline).foregroundStyle(HColor.statusSuccessForeground)
          check("Alerts from \(banks.map(\.shortName).formatted(.list(type: .and))), and nothing else", ok: true)
          check("Downloaded and read here, on this iPhone", ok: true)
          Divider()
          Text("Never").hType(.overline).foregroundStyle(HColor.textSecondary)
          check("The rest of your inbox. It's never downloaded.", ok: false)
          check("Sending, deleting or changing your email", ok: false)
          check("Passing your emails to our server or an AI service", ok: false)
        }
        .padding(18)
        .listCard()
        Text(Self.note(provider))
          .hType(.footnote)
          .foregroundStyle(HColor.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
        if let message = failure?.message(for: provider) {
          FailureBanner(failure: .badPhrase(message))
        }
      }
    } footer: {
      if let id = connectedID {
        BusyButton(title: "Continue", busy: false, identifier: "mail.continue") { onConnected(id) }
      } else {
        if let sample {
          BusyButton(title: "Use sample data", busy: false, identifier: "mail.sample", action: sample)
        }
        BusyButton(title: provider.continueTitle, busy: coordinator.busy, kind: sample == nil ? .primary : .tertiary,
                   identifier: "mail.connect.\(provider.rawValue)") {
          Task {
            await coordinator.connect(provider)
            if let id = connectedID { onConnected(id) }
          }
        }
        LinkButton(title: "Not your email? Choose a different one.", identifier: "mail.notYours", action: onChooseDifferent)
      }
    }
  }

  /// Why the provider's own screen asks for more than Hasala reads, and how new alerts
  /// arrive: a Release build checks when the app opens (no push promise).
  static func note(_ provider: MailProviderKind) -> String {
    let scope = "\(provider.company)'s permission screen still asks to let Hasala read your email, because \(provider.appName) offers nothing narrower."
    return BuildSurface.showsUnfinished
      ? scope + " To catch new alerts quickly, our server is told when new mail arrives, never what it says."
      : scope + " This iPhone checks for new alerts when you open Hasala, and from time to time in the background."
  }

  private func check(_ text: String, ok: Bool) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: ok ? "checkmark.circle.fill" : "minus.circle.fill")
        .foregroundStyle(ok ? HColor.statusSuccessForeground : HColor.iconTertiary)
        .accessibilityHidden(true)
      Text(text).hType(.callout).foregroundStyle(HColor.textPrimary).fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityElement(children: .combine)
  }
}
