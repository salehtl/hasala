import HasalaDesign
import HasalaModels
import SwiftUI

/// One mailbox, pushed from Bank alerts (Paper "Profile · Bank alerts · Mailbox (Outlook)"
/// 1NEG when it works, "Sign in again · 2 Mailbox detail" 1O3N when its provider ended
/// access): the mailbox and its details, the banks read from it, a new sign-in when it
/// needs one, and Disconnect behind the system alert (1O9X).
///
/// The sign-in runs from here, in place; done, the page turns into the working layout.
/// After Disconnect it goes back to Bank alerts, which says what happened.
struct MailboxDetailPage: View {
  @Bindable var app: AppModel
  let mailboxID: String
  @State private var confirming = false
  @State private var busy = false
  @State private var failure: MailConnectFailure?
  /// The sign-in again, made once for this page.
  @State private var signIn: MailConnectCoordinator?
  /// Each sign-in again that worked, counted once the page has turned (the success
  /// haptic's trigger).
  @State private var signedIn = 0
  @Environment(\.hMotion) private var motion

  init(app: AppModel, mailboxID: String) {
    self.app = app
    self.mailboxID = mailboxID
    _signIn = State(initialValue: app.mailbox.map {
      MailConnectCoordinator(mailbox: $0, context: .signInAgain(mailboxID: mailboxID))
    })
  }

  private var mailbox: MailboxSnapshot? { app.mailbox?.mailboxes.first { $0.id == mailboxID } }

  var body: some View {
    ScrollView {
      Group {
        if let m = mailbox {
          VStack(alignment: .leading, spacing: 24) {
            if m.state == .needsSignIn {
              needsSignIn(m)
            } else {
              working(m)
            }
            if let message = failure?.message(for: m.provider) {
              InlineStatus(tone: .error, text: message, size: .regular)
                .padding(.horizontal, 16)
                .hTransition(.rise)
            }
          }
          .hAnimation(.stateSwap, value: m.state)
        } else {
          EmptyStateCard(icon: .envelope, tone: .neutral, title: "This mailbox is no longer here",
                         message: "It was disconnected. Past transactions stay.")
        }
      }
      .padding(.horizontal, HSpacing.insetPage)
      .padding(.top, 8)
      .padding(.bottom, 48)
    }
    .background(HColor.surfaceSecondary)
    .navigationTitle(mailbox?.provider.appName ?? "Mailbox")
    .navigationBarTitleDisplayMode(.inline)
    .alert("Disconnect \(mailbox?.address ?? "this mailbox")?", isPresented: $confirming) {
      Button("Cancel", role: .cancel) {}
      Button("Disconnect", role: .destructive) { Task { await disconnect() } }
    } message: {
      if let m = mailbox { Text(MailCopy.disconnectMessage(m.provider)) }
    }
    // Signed in again: the motion policy's success, once.
    .hHaptic(.success, trigger: signedIn) { old, new in new > old }
    #if HASALA_MOCKS
      // A Debug screen id that stands for "Disconnect this mailbox" (`MailLaunch`).
      .task { if MailLaunch.takeDisconnect(mailboxID) { confirming = true } }
    #endif
  }

  // MARK: Working (1NEG)

  @ViewBuilder private func working(_ m: MailboxSnapshot) -> some View {
    HListCard {
      MailboxRow(m)
      ForEach(details(m, signInLayout: false), id: \.key) { row in
        HDivider(inset: .text16)
        MailboxFactRow(fact: row)
      }
    }
    .accessibilityIdentifier("mailbox.card")
    banksCard(m, title: "Banks in this mailbox")
    disconnect(m, footnote: m.state == .disconnected ? nil : Self.disconnectFootnote(m.provider))
    if m.state == .disconnected {
      Text("Hasala no longer reads this mailbox. Past transactions stay.")
        .hType(.footnote).foregroundStyle(HColor.textSecondary)
        .padding(.horizontal, 16)
    }
  }

  // MARK: Needs sign-in (1O3N)

  @ViewBuilder private func needsSignIn(_ m: MailboxSnapshot) -> some View {
    VStack(spacing: 10) {
      ProviderMark(m.provider, size: .large64)
      Text(m.address)
        .hType(HType(size: 22, leading: 28, weight: .bold, textStyle: .title2))
        .foregroundStyle(HColor.textPrimary)
        .multilineTextAlignment(.center)
      MailboxStatusChip(m.state)
    }
    .frame(maxWidth: .infinity)
    .padding(.top, 8)
    .accessibilityElement(children: .combine)
    VStack(alignment: .leading, spacing: 14) {
      VStack(alignment: .leading, spacing: 4) {
        Text(Self.signInHeading(m))
          .hType(.headline).foregroundStyle(HColor.textPrimary)
          .accessibilityAddTraits(.isHeader)
        Text(Self.signInBody(m))
          .hType(.subheadline).foregroundStyle(HColor.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      if app.mailbox?.capabilities.contains(.signInAgain) == true {
        ProviderButton(provider: m.provider, loading: signIn?.busy ?? false) { signInAgain(m.provider) }
          .accessibilityIdentifier("mailbox.signInAgain")
        if let line = signIn?.failureLine {
          InlineStatus(tone: .warning, text: line, size: .regular).hTransition(.rise)
        }
      }
    }
    .padding(20)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.card, style: .continuous))
    .accessibilityElement(children: .contain)
    HListCard {
      ForEach(Array(details(m, signInLayout: true).enumerated()), id: \.element.key) { i, row in
        if i > 0 { HDivider(inset: .text16) }
        MailboxFactRow(fact: row, style: .details)
      }
    }
    .accessibilityIdentifier("mailbox.details")
    disconnect(m, footnote: "Past transactions stay. No new alerts from this mailbox.")
  }

  /// "This happens after a password change, a long time signed out, or a work policy. No new
  /// Outlook alerts since Wed 7 Oct. Sign in again and the iPhone catches up. Nothing else
  /// changes."
  static func signInBody(_ m: MailboxSnapshot) -> String {
    // A sign-in that the provider didn't end (live: no Outlook mailbox on that account).
    if let note = m.note { return note }
    var lines = ["This happens after a password change, a long time signed out, or a work policy."]
    if let day = m.lastChecked?.split(separator: ",").first {
      lines.append("No new \(m.provider.appName) alerts since \(day).")
    }
    lines.append("Sign in again and the iPhone catches up. Nothing else changes.")
    return lines.joined(separator: " ")
  }

  /// "Microsoft ended Hasala's access", or, when a note says the provider didn't end it
  /// (no Outlook mailbox on that account), just what to do.
  static func signInHeading(_ m: MailboxSnapshot) -> String {
    m.note == nil ? "\(m.provider.company) ended Hasala's access" : "Sign in with another account"
  }

  // MARK: Parts

  /// The facts: account kind, banks, last check, access and since when. The working
  /// layout lists its banks in a card of their own.
  struct Fact: Hashable {
    let key: String
    let value: String
  }

  private func details(_ m: MailboxSnapshot, signInLayout: Bool) -> [Fact] {
    var rows: [Fact] = []
    if let kind = m.accountKind { rows.append(Fact(key: "Account", value: kind)) }
    if signInLayout, !m.banks.isEmpty {
      rows.append(Fact(key: "Banks found here", value: m.banks.formatted(.list(type: .and))))
    }
    if let checked = m.lastChecked { rows.append(Fact(key: "Last checked", value: checked)) }
    rows.append(Fact(key: "Access", value: m.provider.access))
    if !signInLayout, let on = m.connectedOn { rows.append(Fact(key: "Connected", value: on)) }
    return rows
  }

  @ViewBuilder private func banksCard(_ m: MailboxSnapshot, title: String) -> some View {
    let banks = SupportedBank.allCases.filter { bank in m.banks.contains { $0 == bank.name || $0 == bank.shortName } }
    if !banks.isEmpty {
      VStack(alignment: .leading, spacing: 12) {
        HSectionHeader(title)
        HListCard {
          ForEach(Array(banks.enumerated()), id: \.element) { i, bank in
            if i > 0 { HDivider(inset: .disc68) }
            BankAlertsBankRow(
              bank: bank,
              detail: BankAlertsPage.bankDetail(
                bank, lastEmail: (app.mailbox as? BankAlertsReporting)?.lastEmail(bank),
                checking: m.state == .syncing))
          }
        }
      }
    }
  }

  @ViewBuilder private func disconnect(_ m: MailboxSnapshot, footnote: String?) -> some View {
    // Not for a mailbox read on another iPhone: the server's delete would end its reading there.
    if m.readElsewhere {
      // Where Disconnect is for this one: the iPhone that holds its sign-in, or the
      // provider's own settings.
      Text(Self.readElsewhereFootnote(m.provider))
        .hType(.footnote).foregroundStyle(HColor.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 16)
        .accessibilityIdentifier("mailbox.readElsewhere")
    } else if m.state != .disconnected, app.mailbox?.capabilities.contains(.disconnect) == true {
      VStack(alignment: .leading, spacing: 10) {
        Button("Disconnect this mailbox") { confirming = true }
          .buttonStyle(.pill(.destructiveQuiet, size: .large, fill: true, loading: busy))
          .accessibilityIdentifier("mailbox.disconnect")
        if let footnote {
          Text(footnote).hType(.footnote).foregroundStyle(HColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
        }
      }
    }
  }

  /// Paper 1NEG's footnote, naming the provider's own settings.
  static func disconnectFootnote(_ provider: MailProviderKind) -> String {
    "New alerts from this mailbox stop, and its sign-in is deleted from this iPhone. Transactions already read stay. You can also remove Hasala in your \(provider.company) account settings."
  }

  /// A mailbox read on another iPhone: this iPhone holds no sign-in to end, so it says
  /// where to disconnect it.
  static func readElsewhereFootnote(_ provider: MailProviderKind) -> String {
    "Your other iPhone reads this mailbox and holds its sign-in. Disconnect it there, or remove Hasala at \(MailCopy.consentPage(provider))."
  }

  private func signInAgain(_ provider: MailProviderKind) {
    guard let signIn else { return }
    failure = nil
    let policy = motion
    Task {
      await signIn.connect(provider)
      if case .connected? = signIn.outcome {
        app.say(MailCopy.signedInAgain(provider))
        signIn.reset()
        // The page turns into the working layout; the haptic once it has.
        try? await Task.sleep(for: policy.settleDelay(.stateSwap))
        signedIn += 1
      }
    }
  }

  /// Disconnect, then back to Bank alerts. The mock keeps a grey row there; the live lane
  /// keeps none, so the toast says what happened in both.
  private func disconnect() async {
    guard let lane = app.mailbox, let m = mailbox else { return }
    busy = true
    defer { busy = false }
    do {
      try await lane.disconnect(mailboxID)
      failure = nil
      app.say("\(m.provider.appName) disconnected. Past transactions stay.")
      if let i = app.router.profile.lastIndex(of: .bankAlerts) {
        app.router.profile.removeSubrange((i + 1)...)
      } else {
        app.router.profile = [.bankAlerts]
      }
    } catch {
      failure = error
    }
  }
}

/// A key and its value in a mailbox's card, wrapping under the key when it can't fit.
private struct MailboxFactRow: View {
  enum Style {
    /// Under the mailbox row (Paper 1NEG): 15/20, the key in secondary, the value in
    /// primary, 14 above and below.
    case mailbox
    /// The details card of a mailbox that needs a sign-in (Paper 1O3N "Card · Details"):
    /// the key 16/22 in primary, the value 15/20 in secondary, rows at least 52 tall.
    case details
  }

  let fact: MailboxDetailPage.Fact
  var style = Style.mailbox

  var body: some View {
    ReflowingRow(spacing: 12) {
      Text(fact.key)
        .hType(style == .details ? .callout : .subheadline)
        .foregroundStyle(style == .details ? HColor.textPrimary : HColor.textSecondary)
    } trailing: {
      Text(fact.value).hType(.subheadline)
        .foregroundStyle(style == .details ? HColor.textSecondary : HColor.textPrimary)
        .multilineTextAlignment(.trailing)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, style == .details ? 10 : 14)
    .frame(minHeight: style == .details ? 52 : nil)
    // One line of text for VoiceOver ("Account, Personal Microsoft"), not a control: a
    // label with a value reads as one to the accessibility audit, which then finds its
    // 20 pt text too small to tap.
    .accessibilityElement(children: .combine)
  }
}
