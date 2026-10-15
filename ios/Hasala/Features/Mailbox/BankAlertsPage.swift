import HasalaDesign
import HasalaModels
import SwiftUI

/// Profile › Bank alerts (Paper "Profile · Bank alerts", "Add a mailbox · 1 Bank alerts"):
/// whether bank alerts are working, the mailboxes they come from, and the banks.
///
/// The foundation's version (plan B7.3), on today's parts.
// TODO(plan P3): StatusHero with the provider button (decision 10), MailboxRow and its
// chips, the Banks card, "Needs a look" (Debug) and "How Hasala reads your email".
struct BankAlertsPage: View {
  @Bindable var app: AppModel

  init(app: AppModel) {
    self.app = app
  }

  private var mailboxes: [MailboxSnapshot] { app.mailbox?.mailboxes ?? [] }

  var body: some View {
    let summary = MailboxesSummary(mailboxes, health: app.store.state.mailbox, offer: app.mailOffer)
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        VStack(alignment: .leading, spacing: 12) {
          Text(summary.title).hType(.headline).foregroundStyle(HColor.textPrimary)
          ForEach(summary.detail.split(separator: "\n").map(String.init), id: \.self) { line in
            Text(line).hType(.footnote).foregroundStyle(HColor.textOnHueSecondary)
          }
          if let provider = offeredProvider {
            Button(provider.continueTitle) { app.router.profile.append(.connectMail(provider)) }
              .buttonStyle(.pill(.primary, size: .small))
              .accessibilityIdentifier("bankAlerts.signInAgain")
          }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(summary.hue.gradient, in: RoundedRectangle(cornerRadius: HRadius.listGroup, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bankAlerts.hero")

        VStack(alignment: .leading, spacing: 12) {
          SectionTitle(title: "Mailboxes")
          ListCard {
            ForEach(mailboxes) { m in
              Button { app.router.profile.append(.mailbox(m.id)) } label: {
                NavRow(title: m.address, detail: "\(m.provider.appName) · \(m.meta) · \(Self.state(m.state))") {
                  RowIcon(systemName: "envelope")
                }
              }
              .buttonStyle(.plain)
              .accessibilityIdentifier("bankAlerts.mailbox.\(m.id)")
            }
            if offersAdd {
              Button { app.router.profile.append(.addMailbox) } label: {
                NavRow(title: "Add a mailbox", chevron: false) { RowIcon(systemName: "plus") }
              }
              .buttonStyle(.plain)
              .accessibilityIdentifier("bankAlerts.addMailbox")
            }
          }
          Text("Read on this iPhone, read-only. Only alerts from your banks are downloaded. Our server sees a keyed hash of each address and when new mail arrives, never the mail.")
            .hType(.footnote).foregroundStyle(HColor.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
      }
      .padding(HSpacing.insetPage)
    }
    .background(HColor.surfaceSecondary)
    .navigationTitle("Bank alerts")
    .navigationBarTitleDisplayMode(.inline)
  }

  /// "Add a mailbox" shows with a second mailbox allowed, or when none is read (B4.6 rule 3).
  private var offersAdd: Bool {
    guard let mailbox = app.mailbox, mailbox.capabilities.contains(.connect) else { return false }
    return mailbox.capabilities.contains(.addSecond) || !mailboxes.contains { $0.state != .disconnected }
  }

  /// The hero's sign-in button aims at the first mailbox that needs one.
  private var offeredProvider: MailProviderKind? {
    if case .signInAgain(_, let p)? = app.mailOffer { return p }
    return nil
  }

  static func state(_ s: MailboxState) -> String {
    switch s {
    case .syncing: "Syncing"
    case .connected: "Connected"
    case .needsSignIn: "Sign in again"
    case .disconnected: "Disconnected"
    }
  }
}
