import HasalaDesign
import HasalaModels
import SwiftUI

/// One mailbox (Paper "Profile · Bank alerts · Mailbox", "Sign in again · 2 Mailbox
/// detail"): its address and state, what it reads, a new sign-in when its provider ended
/// access, and Disconnect behind the system alert.
///
/// The foundation's version (plan B7.3), on today's parts.
// TODO(plan P3): the identity block, the sign-in card with ProviderButton, KeyValueRow
// details and the provider's disconnect copy.
struct MailboxDetailPage: View {
  @Bindable var app: AppModel
  let mailboxID: String
  @State private var confirming = false
  @State private var busy = false
  @State private var failure: MailConnectFailure?

  init(app: AppModel, mailboxID: String) {
    self.app = app
    self.mailboxID = mailboxID
  }

  private var mailbox: MailboxSnapshot? { app.mailbox?.mailboxes.first { $0.id == mailboxID } }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        if let m = mailbox {
          ListCard {
            row("Address", m.address)
            row("Status", BankAlertsPage.state(m.state))
            if let kind = m.accountKind { row("Account", kind) }
            if !m.banks.isEmpty { row("Banks found here", m.banks.joined(separator: ", ")) }
            if let checked = m.lastChecked { row("Last checked", checked) }
            row("Access", m.provider.access)
            if let on = m.connectedOn { row("Connected", on) }
          }
          if let note = m.note { Text(note).hType(.footnote).foregroundStyle(HColor.textSecondary) }
          if m.state == .needsSignIn {
            Button(m.provider.continueTitle) { app.router.profile.append(.connectMail(m.provider)) }
              .buttonStyle(.pill(.primary, fill: true))
              .accessibilityIdentifier("mailbox.signInAgain")
          }
          if let f = failure?.message(for: m.provider) { FailureBanner(failure: .badPhrase(f)) }
          if m.state != .disconnected, app.mailbox?.capabilities.contains(.disconnect) == true {
            BusyButton(title: "Disconnect this mailbox", busy: busy, kind: .destructive, identifier: "mailbox.disconnect") {
              confirming = true
            }
            Text("Past transactions stay. No new alerts from this mailbox.")
              .hType(.footnote).foregroundStyle(HColor.textSecondary)
          }
        } else {
          EmptyNote(systemImage: "envelope", message: "This mailbox is no longer here.")
        }
      }
      .padding(HSpacing.insetPage)
    }
    .background(HColor.surfaceSecondary)
    .navigationTitle(mailbox?.provider.appName ?? "Mailbox")
    .navigationBarTitleDisplayMode(.inline)
    .alert("Disconnect \(mailbox?.address ?? "this mailbox")?", isPresented: $confirming) {
      Button("Disconnect", role: .destructive) { Task { await disconnect() } }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Hasala stops reading this mailbox and forgets its sign-in. Past transactions stay.")
    }
  }

  private func disconnect() async {
    guard let lane = app.mailbox, let m = mailbox else { return }
    busy = true
    defer { busy = false }
    do {
      try await lane.disconnect(mailboxID)
      failure = nil
      app.say("\(m.provider.appName) disconnected. Past transactions stay.")
      if let i = app.router.profile.lastIndex(of: .bankAlerts) { app.router.profile.removeSubrange((i + 1)...) }
    } catch {
      failure = error
    }
  }

  private func row(_ key: String, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Text(key).hType(.rowTitle).foregroundStyle(HColor.listRowTitle)
      Spacer(minLength: 8)
      Text(value).hType(.subheadline).foregroundStyle(HColor.textSecondary).multilineTextAlignment(.trailing)
    }
    .padding(.horizontal, HSpacing.listRowInsetInline)
    .frame(minHeight: HSpacing.listRowMinHeight)
    .accessibilityElement(children: .combine)
  }
}
