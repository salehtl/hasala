import HasalaDesign
import HasalaModels
import SwiftUI

#if HASALA_MOCKS
  import HasalaMocks
#endif

/// Your profile (Paper board, and its page-14 variant with Sign-in & security): who you are, whether bank alerts are
/// working, your money things, and settings. A large sheet with its own stack.
///
/// A Release build shows only rows that work (`BuildSurface`): the pages still to come
/// (bank alerts, accounts, privacy) and the settings with nothing behind them yet (Face ID
/// lock, notifications) are left out, and account actions follow `capabilities`. The bank
/// alerts card offers "Connect Gmail" or "Reconnect Gmail" when Gmail needs it, in every build.
struct ProfileSheet: View {
  @Bindable var app: AppModel
  @State private var model: ProfileViewModel
  @State private var path: [ProfileRoute] = []
  @State private var confirmSignOut = false
  /// The Gmail connect sheet, over this one.
  @State private var connecting: GmailOffer?
  /// Sign-in & security's state, for its row's status; nil until read.
  @State private var security: SecurityState?
  @Environment(\.dismiss) private var dismiss
  /// Present once the account gate runs; sign out, delete and Sign-in & security need it.
  @Environment(AccountSession.self) private var session: AccountSession?

  private var unfinished: Bool { BuildSurface.showsUnfinished }

  private func can(_ action: AccountCapabilities) -> Bool {
    session?.capabilities.contains(action) ?? false
  }

  init(app: AppModel) {
    self.app = app
    _model = State(initialValue: ProfileViewModel(app: app))
  }

  private var snap: ProfileSnapshot { model.snapshot }

  var body: some View {
    NavigationStack(path: $path) {
      ScrollView {
        VStack(spacing: 24) {
          identity
          mailboxCard
          money
          settings
          VStack(spacing: 12) {
            if can(.signOut) {
              Button("Sign out") { confirmSignOut = true }
                .buttonStyle(.pill(.tertiary, fill: true))
                .foregroundStyle(HColor.listRowDestructive)
                .accessibilityIdentifier("profile.signOut")
            }
            if can(.deleteAccount) {
              Button("Delete your account") { path.append(.deleteAccount) }
                .buttonStyle(.pill(.destructiveText, size: .small))
                .accessibilityIdentifier("profile.delete")
            }
            Text(BuildInfo.current.footer)
              .hType(.footnote)
              .foregroundStyle(HColor.textSecondary)
              .multilineTextAlignment(.center)
              .accessibilityIdentifier("profile.buildFooter")
          }
        }
        .padding(.horizontal, HSpacing.insetPage)
        .padding(.bottom, 32)
      }
      .background(HColor.surfaceSecondary)
      .navigationTitle("Your profile")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { SheetCloseButton(identifier: "profile.close") { dismiss() } }
      .navigationDestination(for: ProfileRoute.self) { route in
        ProfilePage(app: app, model: model, route: route)
      }
      .sheet(item: $connecting) { GmailConnectSheet(app: app, offer: $0) }
      // Read again each time the profile shows, so a change on Sign-in & security shows.
      .task { security = try? await session?.account.securityState() }
      .alert("Sign out of this iPhone?", isPresented: $confirmSignOut) {
        Button("Sign out", role: .destructive) { signOut() }
        Button("Cancel", role: .cancel) {}
      } message: {
        // TODO(01 §14 S-26): the sign-out copy, verbatim, with N-08's offline line.
        Text("You can sign back in with your passkey or password.")
      }
    }
    .overlay(alignment: .bottom) { ToastHost(app: app) }
  }

  /// Signs out of this iPhone (S-26): the session ends, local data stays. The account gate
  /// then shows the welcome screens in place of the app, this sheet with it.
  private func signOut() {
    guard let session else { return }
    Task {
      await session.account.signOut()
      session.signedOut()
    }
  }

  private var identity: some View {
    VStack(spacing: 10) {
      AvatarDisc(initial: snap.initial, size: 96)
        .overlay(Circle().strokeBorder(HColor.white, lineWidth: 4))
        .elevation()
      Text(snap.displayName).hType(.title2).foregroundStyle(HColor.textPrimary)
        .accessibilityIdentifier("profile.name")
      HStack(spacing: 6) {
        Circle().fill(HColor.statusSuccessForeground).frame(width: 7, height: 7)
        Text(snap.emailLine).hType(.footnote.weight(.semibold))
      }
      .foregroundStyle(HColor.statusSuccessForeground)
      .padding(.horizontal, 10).padding(.vertical, 4)
      .background(HColor.statusSuccessSurface, in: Capsule())
      .accessibilityElement(children: .combine)
    }
    .padding(.top, 8)
  }

  /// The bank alerts status. It opens Profile › Bank alerts where that page exists; a
  /// Release build shows the status alone. When Gmail needs connecting or reconnecting, the
  /// card says so and offers it (spec 04 §7.4).
  private var mailboxCard: some View {
    let offer = app.gmailOffer
    return VStack(alignment: .leading, spacing: 12) {
      if unfinished {
        Button { path.append(.bankAlerts) } label: { mailboxStatus(offer, chevron: true) }
          .buttonStyle(.plain)
          .accessibilityIdentifier("profile.bankAlerts")
      } else {
        mailboxStatus(offer, chevron: false)
          .accessibilityElement(children: .combine)
          .accessibilityIdentifier("profile.bankAlerts")
      }
      if let offer {
        Button(offer.action) { connecting = offer }
          .buttonStyle(.pill(.primary, size: .small))
          .accessibilityIdentifier("profile.connectGmail")
      }
    }
    .padding(16)
    .background(Self.hue(snap.mailbox.status, offer).gradient,
                in: RoundedRectangle(cornerRadius: HRadius.listGroup, style: .continuous))
  }

  static func hue(_ status: MailboxHealth.Status, _ offer: GmailOffer?) -> Hue {
    switch offer {
    case .connect: return .sky
    case .reconnect: return .rose
    case nil: break
    }
    switch status {
    case .working, .importing: return .mint
    case .quiet: return .sand
    case .reconnect: return .rose
    case .notConnected: return .sky
    }
  }

  /// The card's title: what Gmail needs, when it needs something, else the status.
  static func title(_ status: MailboxHealth.Status, _ offer: GmailOffer?) -> String {
    if let offer { return offer.status }
    switch status {
    case .working: return "Bank alerts are working"
    case .importing: return "Importing your bank alerts"
    case .quiet: return "Bank alerts went quiet"
    case .reconnect: return GmailOffer.reconnect.status
    case .notConnected: return GmailOffer.connect.status
    }
  }

  private func mailboxStatus(_ offer: GmailOffer?, chevron: Bool) -> some View {
    let m = snap.mailbox
    let hue = Self.hue(m.status, offer)
    return HStack(spacing: 12) {
      Circle().fill(HColor.posterGlyph).frame(width: 40, height: 40)
        .overlay {
          Image(systemName: m.status == .working && offer == nil ? "checkmark" : "envelope").foregroundStyle(hue.ink)
        }
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 0) {
        Text(Self.title(m.status, offer)).hType(.headline).foregroundStyle(HColor.textPrimary)
        if !m.lastEmail.isEmpty {
          Text("Last email \(m.lastEmail)").hType(.footnote).foregroundStyle(HColor.textOnHueSecondary)
        }
        if !m.banks.isEmpty {
          Text(m.banks).hType(.footnote).foregroundStyle(HColor.textOnHueSecondary)
        }
      }
      Spacer()
      if chevron {
        Image(systemName: "chevron.right").foregroundStyle(HColor.textOnHueSecondary).accessibilityHidden(true)
      }
    }
    .contentShape(Rectangle())
  }

  private var money: some View {
    VStack(alignment: .leading, spacing: 12) {
      SectionTitle(title: "Your money")
      ListCard {
        if unfinished {
          Button { path.append(.accounts) } label: {
            NavRow(title: "Accounts", detail: snap.accounts.rendered(hidden: model.hidden)) {
              HueDisc(hue: .sky, glyph: .bank)
            }
          }
          .buttonStyle(.plain)
        }
        Button { path.append(.bills) } label: {
          NavRow(title: "Bills", detail: snap.bills) {
            HueDisc(hue: .sand, glyph: .bill)
          } trailing: {
            if snap.newBills > 0 { CountBadge(snap.newBills, tone: .alert).accessibilityLabel("\(snap.newBills) new") }
          }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("profile.bills")
        Button { path.append(.rules) } label: {
          NavRow(title: "Categories and rules", detail: snap.categoriesAndRules) {
            HueDisc(hue: .lilac, glyph: .tag)
          }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("profile.rules")
        if let projects = snap.projects {
          // TODO(spec 04 §16.1 "Project detail"): Project detail; until then the row only reads.
          NavRow(title: "Projects", detail: projects.rendered(hidden: model.hidden), chevron: unfinished) {
            HueDisc(hue: .peach, glyph: .flag)
          }
          .accessibilityElement(children: .combine)
        }
      }
    }
  }

  private var settings: some View {
    VStack(alignment: .leading, spacing: 12) {
      SectionTitle(title: "Settings")
      ListCard {
        if session != nil || unfinished {
          Button { path.append(.security) } label: {
            NavRow(title: "Sign-in & security") { RowIcon(systemName: "checkmark.shield") } trailing: {
              if let status = security.map(Self.securityStatus) {
                DetailLine(parts: [.status(status.text, status.tone)], hidden: false)
              }
            }
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier("profile.security")
        }
        // TODO(spec 04 §16.2 X1): Currency and exchange rates (PENDING PO-17).
        settingValue("Currency", "dollarsign.circle", "AED")
        // TODO(spec 04 §9): local notifications and the Face ID lock (§11) are not in this
        // build, so a Release build doesn't offer their settings yet.
        if unfinished {
          Button { path.append(.notifications) } label: {
            NavRow(title: "Notifications") { RowIcon(systemName: "bell") } trailing: {
              Text(snap.prefs.notifications.label).hType(.subheadline).foregroundStyle(HColor.textSecondary)
            }
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier("profile.notifications")
          Toggle(isOn: Binding(get: { snap.prefs.faceIDLock }, set: { model.setFaceIDLock($0) })) {
            HStack(spacing: HSpacing.listRowGap) {
              RowIcon(systemName: "faceid")
              Text("Face ID lock").hType(.rowTitle).foregroundStyle(HColor.listRowTitle)
            }
          }
          .tint(HColor.actionAccent)
          .padding(.horizontal, HSpacing.listRowInsetInline)
          .frame(minHeight: HSpacing.listRowMinHeight)
          .accessibilityIdentifier("profile.faceID")
        }
        // Appearance is compiled but hidden (spec 04 §14.9, `Feature.appearance == false`).
        // TODO(spec 04 §16.2 X5): Swipe directions page.
        settingValue("Swipe directions", "arrow.left.and.right", snap.swipeSummary)
        ShareLink(item: CSVFile(rows: model.exportRows, name: CSVExport.fileName(model.today)),
                  preview: SharePreview(CSVExport.fileName(model.today))) {
          NavRow(title: "Export your data") { RowIcon(systemName: "square.and.arrow.down") } trailing: {
            Text("CSV").hType(.subheadline).foregroundStyle(HColor.textSecondary)
          }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("profile.export")
        if unfinished {
          Button { path.append(.privacy) } label: {
            NavRow(title: "Privacy and data") { RowIcon(systemName: "hand.raised") }
          }
          .buttonStyle(.plain)
        } else {
          Link(destination: URL(string: "https://hasala.app/privacy")!) {
            NavRow(title: "Privacy policy") { RowIcon(systemName: "hand.raised") }
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier("profile.privacy")
        }
        Button { path.append(.help) } label: {
          NavRow(title: "Get help") { RowIcon(systemName: "questionmark.circle") }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("profile.help")
      }
    }
  }

  /// Sign-in & security's own status (its hero): frozen, a passkey, or a password only.
  static func securityStatus(_ s: SecurityState) -> (text: String, tone: StatusTone) {
    if s.frozen != nil { return ("Frozen", .accent) }
    return s.hasPasskey ? ("Protected", .success) : ("Password only", .warning)
  }

  private func settingValue(_ title: String, _ icon: String, _ value: String) -> some View {
    HStack(spacing: HSpacing.listRowGap) {
      RowIcon(systemName: icon)
      Text(title).hType(.rowTitle).foregroundStyle(HColor.listRowTitle)
      Spacer()
      Text(value).hType(.subheadline).foregroundStyle(HColor.textSecondary)
    }
    .padding(.horizontal, HSpacing.listRowInsetInline)
    .frame(minHeight: HSpacing.listRowMinHeight)
    .accessibilityElement(children: .combine)
  }
}

/// A page pushed inside the profile sheet.
private struct ProfilePage: View {
  @Bindable var app: AppModel
  let model: any ProfileModel
  let route: ProfileRoute
  /// Present once the account gate runs; Sign-in & security needs it.
  @Environment(AccountSession.self) private var session: AccountSession?

  var body: some View {
    switch route {
    case .bills:
      BillsScreen(app: app, showsToast: false)
    case .rules:
      RulesPage(model: model)
    case .notifications:
      NotificationSettingsPage(model: model)
    case .bankAlerts:
      // TODO(spec 04 §16.1 "Profile · Bank alerts", §7.10): BankAlertsView (Gmail status, banks, Needs a look,
      // disconnect, read here instead) from the Gmail lane's MailboxSource.
      placeholder("Profile · Bank alerts", "envelope", "Your Gmail connection, banks and any email we couldn't read.")
    case .accounts:
      // TODO(spec 04 §16.1 "Accounts", "Accounts · Check in"): AccountsView and Check in.
      placeholder("Accounts", "building.columns", "Net worth, your accounts and check-ins.")
    case .security:
      if let session {
        SecurityView(session: session)
      } else {
        placeholder("Sign-in & security", "checkmark.shield", "Passkeys, password, this iPhone and your recovery phrase.")
      }
    case .privacy:
      // TODO(spec 04 §16.2 X7; 01 §14 S-02–S-06, S-18, S-42, S-43, PENDING PO-12).
      placeholder("Privacy and data", "hand.raised", "Who can see what, and how your data is kept.")
    case .help:
      HelpPage()
    case .deleteAccount:
      if let session { DeleteAccountPage(session: session) }
    }
  }

  private func placeholder(_ title: String, _ icon: String, _ message: String) -> some View {
    ScrollView {
      PlaceholderCard(systemImage: icon, title: "Coming in a later build", message: message)
        .padding(HSpacing.insetPage)
    }
    .background(HColor.surfaceSecondary)
    .navigationTitle(title)
    .navigationBarTitleDisplayMode(.inline)
  }
}

/// Categories and rules (Paper board, Rules tab): rules most used first; pausing one sends
/// its transactions back to review.
// TODO(spec 04 §16.2 P5, P6): the Categories tab, rule detail and "Add a rule".
private struct RulesPage: View {
  let model: any ProfileModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        Text("Hasala writes a rule when you sort a new merchant. Pause one to send its transactions back to review.")
          .hType(.subheadline).foregroundStyle(HColor.textSecondary)
        Text("Most used").hType(.overline).foregroundStyle(HColor.textSecondary)
        ListCard {
          ForEach(model.rules) { r in
            Toggle(isOn: Binding(get: { r.enabled }, set: { model.setRule(r.id, enabled: $0) })) {
              HStack(spacing: HSpacing.listRowGap) {
                HueDisc(hue: r.hue, glyph: r.glyph)
                VStack(alignment: .leading, spacing: 0) {
                  HStack(spacing: 6) {
                    Text(r.pattern).hType(.rowTitle).foregroundStyle(HColor.listRowTitle)
                    if r.learnedToday { InfoTag("Learned today", tone: .accent) }
                  }
                  Text(r.detail).hType(.footnote).foregroundStyle(HColor.listRowSupporting)
                }
              }
            }
            .tint(HColor.actionAccent)
            .padding(.horizontal, HSpacing.listRowInsetInline)
            .frame(minHeight: HSpacing.listRowMinHeightTwoLine)
            .accessibilityIdentifier("rule.\(r.id)")
          }
        }
      }
      .padding(HSpacing.insetPage)
    }
    .background(HColor.surfaceSecondary)
    .navigationTitle("Categories and rules")
    .navigationBarTitleDisplayMode(.inline)
  }
}

/// Settings › Notifications (spec 04 §16.2 X2).
private struct NotificationSettingsPage: View {
  let model: any ProfileModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        ListCard {
          ForEach(DevicePrefs.NotificationLevel.allCases, id: \.self) { level in
            Button { model.setNotifications(level) } label: {
              HStack {
                Text(level.label).hType(.rowTitle).foregroundStyle(HColor.listRowTitle)
                Spacer()
                if model.snapshot.prefs.notifications == level {
                  Image(systemName: "checkmark").font(.system(size: 15, weight: .bold))
                    .foregroundStyle(HColor.listRowCheck)
                }
              }
              .padding(.horizontal, HSpacing.listRowInsetInline)
              .frame(minHeight: HSpacing.listRowMinHeight)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(model.snapshot.prefs.notifications == level ? .isSelected : [])
            .accessibilityIdentifier("notifications.\(level.rawValue)")
          }
        }
        // TODO(01 §14 S-27): the Notifications settings sentence, verbatim.
        Text("Important only keeps everything except new transactions under AED 100 and the daily sorting nudge. Lock Screen notifications stay generic unless you choose otherwise.")
          .hType(.footnote).foregroundStyle(HColor.textSecondary)
      }
      .padding(HSpacing.insetPage)
    }
    .background(HColor.surfaceSecondary)
    .navigationTitle("Notifications")
    .navigationBarTitleDisplayMode(.inline)
  }
}

#if HASALA_MOCKS
  #Preview("Profile") {
    ProfileSheet(app: AppModel(store: InMemoryLedger()))
  }
#endif
