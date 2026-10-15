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
/// alerts card offers to connect your email, or to sign in again, when mail needs it, in
/// every build; both open the provider's screen inside this sheet.
struct ProfileSheet: View {
  @Bindable var app: AppModel
  @State private var model: ProfileViewModel
  @State private var confirmSignOut = false
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

  /// The pages pushed inside the sheet (`ProfileRoute`), held by the router.
  private var path: [ProfileRoute] {
    get { app.router.profile }
    nonmutating set { app.router.profile = newValue }
  }

  var body: some View {
    NavigationStack(path: Bindable(app.router).profile) {
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

  /// What the card says: `MailboxesSummary`, which Bank alerts' hero and the bell's mail
  /// row also draw from.
  private var summary: MailboxesSummary {
    MailboxesSummary(app.mailbox?.mailboxes ?? [], health: snap.mailbox, offer: app.mailOffer)
  }

  /// The bank alerts status. It opens Profile › Bank alerts where that page exists; a
  /// Release build shows the status alone. When mail needs connecting or a new sign-in, the
  /// card says so and offers it (spec 04 §7.4), on the provider's screen inside this sheet.
  private var mailboxCard: some View {
    let summary = summary
    return VStack(alignment: .leading, spacing: 12) {
      if unfinished {
        Button { path.append(.bankAlerts) } label: { mailboxStatus(summary, chevron: true) }
          .buttonStyle(.plain)
          .accessibilityIdentifier("profile.bankAlerts")
      } else {
        mailboxStatus(summary, chevron: false)
          .accessibilityElement(children: .combine)
          .accessibilityIdentifier("profile.bankAlerts")
      }
      if let offer = app.mailOffer, let provider = Self.provider(offer, app.mailbox?.connectable ?? []) {
        Button(Self.action(offer)) { path.append(.connectMail(provider)) }
          .buttonStyle(.pill(.primary, size: .small))
          .accessibilityIdentifier("profile.connectGmail")
      }
    }
    .padding(16)
    .background(summary.hue.gradient, in: RoundedRectangle(cornerRadius: HRadius.listGroup, style: .continuous))
  }

  /// The offer's button: "Connect your email" or "Sign in again".
  static func action(_ offer: MailOffer) -> String {
    switch offer {
    case .connect: "Connect your email"
    case .signInAgain: "Sign in again"
    }
  }

  /// The provider an offer opens: the mailbox's for a new sign-in, else the first this
  /// build can connect.
  static func provider(_ offer: MailOffer, _ connectable: [MailProviderKind]) -> MailProviderKind? {
    switch offer {
    case .connect: connectable.first
    case .signInAgain(_, let provider): provider
    }
  }

  private func mailboxStatus(_ summary: MailboxesSummary, chevron: Bool) -> some View {
    HStack(spacing: 12) {
      Circle().fill(HColor.posterGlyph).frame(width: 40, height: 40)
        .overlay {
          Image(systemName: summary.needsYou ? "envelope" : "checkmark").foregroundStyle(summary.hue.ink)
        }
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 0) {
        Text(summary.title).hType(.headline).foregroundStyle(HColor.textPrimary)
        // One Text per line ("Last email 4 min ago", "Emirates NBD and DIB"), so each wraps
        // on its own at the accessibility sizes.
        ForEach(summary.detail.split(separator: "\n").map(String.init), id: \.self) { line in
          Text(line).hType(.footnote).foregroundStyle(HColor.textOnHueSecondary)
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
    case .bill(let id):
      BillDetailView(app: app, bill: id)
    case .project(let id):
      ProjectDetailView(app: app, project: id)
    case .rules:
      RulesPage(model: model)
    case .notifications:
      NotificationSettingsPage(model: model)
    case .bankAlerts:
      BankAlertsPage(app: app)
    case .mailbox(let id):
      MailboxDetailPage(app: app, mailboxID: id)
    case .addMailbox:
      AddMailboxPage(app: app)
    case .connectMail(let provider):
      ConnectMailPage(app: app, provider: provider)
    case .accounts:
      AccountsView(app: app)
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
      if let session { DeleteAccountView(session: session) }
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
