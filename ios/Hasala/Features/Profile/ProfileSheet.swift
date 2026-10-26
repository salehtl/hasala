import HasalaDesign
import HasalaModels
import SwiftUI

#if HASALA_MOCKS
  import HasalaMocks
#endif

/// Your profile (Paper "Profile · Your profile (sheet)" 5DE-0 and its page-14 variant with
/// Sign-in & security, HI3-0): who you are, whether bank alerts are working, your money
/// things, settings, sign out and delete. One large sheet from the avatar: every row pushes
/// inside its stack (`router.profile`), never a sheet over it, and Close returns to the tab
/// as it was.
///
/// A Release build shows only rows that work (`BuildSurface`): the settings with nothing
/// behind them yet (Notifications) are left out, Accounts shows once the
/// ledger has balances, and account actions follow `capabilities`.
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

  private func push(_ route: ProfileRoute) { app.router.profile.append(route) }

  var body: some View {
    NavigationStack(path: Bindable(app.router).profile) {
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          ProfileIdentity(name: snap.displayName, initial: snap.initial, email: app.avatarEmail, emailLine: snap.emailLine)
          TimelineView(.periodic(from: .now, by: 60)) { context in
            BankAlertsCard(summary: summary(now: context.date)) { push(.bankAlerts) }
          }
          money
          settings
          GravatarSection()
          if BuildSurface.showsCloudSuggestions { CloudSuggestionsSection(app: app) }
          footer
        }
        .padding(.horizontal, HSpacing.sheetPadding)
        // 18 under the header (Paper's sheet gap), with the identity's own 4.
        .padding(.top, 8)
        .padding(.bottom, 48)
      }
      .scrollEdgeEffectStyle(.soft, for: .bottom)
      .background(HColor.sheetSurfaceLarge)
      .navigationTitle("Your profile")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { SheetCloseButton(identifier: "profile.close") { dismiss() } }
      .navigationDestination(for: ProfileRoute.self) { route in
        ProfilePage(app: app, model: model, route: route)
      }
      // Read when the sheet opens and again each time it is back at its first page, so a
      // passkey added on Sign-in & security shows on the way back.
      .task(id: app.router.profile.isEmpty) {
        guard app.router.profile.isEmpty else { return }
        security = try? await session?.account.securityState()
      }
      .alert("Sign out of this iPhone?", isPresented: $confirmSignOut) {
        Button("Sign out", role: .destructive) { signOut() }
        Button("Cancel", role: .cancel) {}
      } message: {
        // The words Sign-in & security says for the same action, whichever page it starts from.
        Text(AccountCopy.signOutMessage)
      }
    }
    .environment(\.inProfileSheet, true)
    // Delete your account's "Keep a copy first" (Paper IAM), on Profile › Delete and on
    // Sign-in & security › Delete: the same CSV as "Export your data" (requests/p4.md 2).
    .environment(\.accountExport, CSVFile(rows: model.exportRows, name: CSVExport.fileName(model.today)))
    .overlay(alignment: .bottom) { ToastHost(app: app, placement: .bottom) }
    .sheet(item: Bindable(app.router).overProfile) { route in
      switch route {
      case .budget(let id):
        BudgetHost(app: app, category: id)
          .presentationDetents([.large])
      case .moveMoney(let id):
        MoveMoneyHost(app: app, category: id)
      default:
        EmptyView()
      }
    }
    .presentationDragIndicator(.visible)
    .presentationCornerRadius(HRadius.sheetLarge)
  }

  /// Signs out of this iPhone (S-26): the session ends, local data stays. The account gate
  /// then shows the welcome screens in place of the app, this sheet with it.
  private func signOut() {
    guard let session else { return }
    Task { await session.signOut() }
  }

  /// What the card says: `MailboxesSummary`, which Bank alerts' hero and the bell's mail
  /// row also draw from.
  private func summary(now: Date) -> MailboxesSummary {
    if let texts = app.bankTexts, texts.usesTexts { return .texts(texts.status, now: now) }
    return MailboxesSummary(
      app.mailbox?.mailboxes ?? [], health: snap.mailbox, offer: app.mailOffer, known: app.mailbox?.mailboxesKnown ?? true)
  }

  // MARK: Your money

  private var money: some View {
    VStack(alignment: .leading, spacing: 12) {
      HSectionHeader("Your money")
      ProfileListCard(inset: .disc68) {
        // Balances come from check-ins: with none, Accounts would say 0.00 for each.
        if unfinished || snap.accountsKnown {
          row(.accounts, id: "profile.accounts") {
            MoneyThingRow(plate: HuePlate(hue: .sky, icon: .bank, square: true), title: "Accounts",
                          detail: snap.accounts, hidden: model.hidden)
          }
        }
        row(.bills, id: "profile.bills") {
          MoneyThingRow(plate: HuePlate(hue: .sand, icon: .receipt), title: "Recurring",
                        detail: MoneyPhrase(stringLiteral: snap.bills), hidden: model.hidden, badge: snap.newBills,
                        badgeSpoken: "\(snap.newBills) \(snap.newBills == 1 ? "item needs" : "items need") a look")
        }
        row(.rules, id: "profile.rules") {
          MoneyThingRow(plate: HuePlate(hue: .lilac, icon: .tag), title: "Categories and rules",
                        detail: MoneyPhrase(stringLiteral: snap.categoriesAndRules), hidden: model.hidden)
        }
        if BuildSurface.showsPlanTab {
          row(.projects, id: "profile.projects") {
            MoneyThingRow(plate: HuePlate(hue: .peach, icon: .project), title: "Projects", detail: snap.projects,
                          hidden: model.hidden)
          }
        } else {
          row(.plan, id: "profile.plan") {
            MoneyThingRow(plate: HuePlate(hue: .sky, icon: .tabPlan), title: "Plan", detail: model.planLine,
                          hidden: model.hidden)
          }
        }
      }
    }
  }

  private func row(_ route: ProfileRoute, id: String, @ViewBuilder label: () -> some View) -> some View {
    Button { push(route) } label: { label() }
      .buttonStyle(HRowPressStyle())
      .accessibilityIdentifier(id)
  }

  // MARK: Settings

  private var settings: some View {
    VStack(alignment: .leading, spacing: 12) {
      HSectionHeader("Settings")
      ProfileListCard(inset: .icon52) {
        if session != nil, can(.changeName) {
          row(.editName, id: "profile.editName") {
            SettingRow(icon: .pencil, title: "Name", trailing: .value(snap.displayName))
          }
        }
        if session != nil || unfinished {
          row(.security, id: "profile.security") {
            SettingRow(icon: .shieldCheck, title: "Sign-in & security",
                       trailing: security.map { let status = Self.securityStatus($0); return .status(status.text, status.tone) }
                         ?? .none)
          }
        }
        // The mailbox, its sign-in and Disconnect, under Settings as well as behind the
        // card above: where a person looks to stop Hasala reading their email.
        if let lane = app.mailbox {
          let value = Self.mailboxesValue(lane.mailboxes, known: lane.mailboxesKnown)
          row(.bankAlerts, id: "profile.mailboxes") {
            SettingRow(icon: .envelope, title: "Mailboxes",
                       trailing: value.tone.map { .status(value.text, $0) } ?? .value(value.text))
          }
        }
        row(.exchangeRates, id: "profile.currency") {
          SettingRow(icon: .globe, title: "Currency", trailing: Self.currencyTrailing(app.store.state))
        }
        // TODO(spec 04 §9): local notifications are not in this build, so a Release build
        // doesn't offer their settings yet.
        if unfinished {
          row(.notifications, id: "profile.notifications") {
            SettingRow(icon: .bell, title: "Notifications", trailing: .value(snap.prefs.notifications.label))
          }
        }
        // Hasala is light only for now (spec 04 §14.9), so the row states it.
        SettingRow(icon: .appearance, title: "Appearance", trailing: .value("Light"), chevron: false)
        // TODO(spec 04 §16.2 X5): Swipe directions page.
        SettingRow(icon: .swipe, title: "Swipe directions",
                   trailing: .value(snap.swipeSummary, spoken: snap.swipeSpoken), chevron: false)
        ShareLink(item: CSVFile(rows: model.exportRows, name: CSVExport.fileName(model.today)),
                  preview: SharePreview(CSVExport.fileName(model.today))) {
          SettingRow(icon: .download, title: "Export your data", trailing: .value("CSV"))
        }
        .buttonStyle(HRowPressStyle())
        .accessibilityIdentifier("profile.export")
        Link(destination: URL(string: "https://hasala.app/privacy")!) {
          SettingRow(icon: .privacy, title: "Privacy and data")
        }
        .buttonStyle(HRowPressStyle())
        .accessibilityIdentifier("profile.privacy")
        row(.help, id: "profile.help") {
          SettingRow(icon: .help, title: "Get help")
        }
      }
    }
  }

  /// The Mailboxes row's value: "Checking" while the mailbox state is read, "Not
  /// connected" with none, "Sign in again" when one needs it, else the providers read
  /// ("Gmail").
  static func mailboxesValue(_ mailboxes: [MailboxSnapshot], known: Bool) -> (text: String, tone: StatusTone?) {
    guard known else { return ("Checking", nil) }
    let live = mailboxes.filter { $0.state != .disconnected }
    if live.isEmpty { return ("Not connected", nil) }
    if live.contains(where: { $0.state == .needsSignIn }) { return ("Sign in again", .warning) }
    return (live.map(\.provider.appName).formatted(.list(type: .and)), nil)
  }

  static func currencyTrailing(_ s: LedgerState) -> SettingRow.Trailing {
    let missing = ExchangeRates.page(s).missing.reduce(0) { $0 + $1.notCounted }
    return missing > 0 ? .status(ExchangeRatesPage.notCountedLine(missing), .warning) : .value(Money.home)
  }

  /// Sign-in & security's own status (its hero): frozen, a passkey, or a password only.
  static func securityStatus(_ s: SecurityState) -> (text: String, tone: StatusTone) {
    if s.frozen != nil { return ("Frozen", .accent) }
    return s.hasPasskey ? ("Protected", .success) : ("Password only", .warning)
  }

  // MARK: Sign out, delete, version

  /// Sign out (quiet, 54: Paper draws 52, off the pill ladder), "Delete your account" (a 44
  /// link), and the build line.
  private var footer: some View {
    VStack(spacing: 8) {
      if can(.signOut) {
        Button("Sign out") { confirmSignOut = true }
          .buttonStyle(.pill(.destructiveQuiet, fill: true))
          .pillHeight()
          .accessibilityIdentifier("profile.signOut")
      }
      if can(.deleteAccount) {
        Button { push(.deleteAccount) } label: {
          Text("Delete your account")
            .hType(.subheadline.weight(.medium))
            .foregroundStyle(HColor.actionDestructive)
            .frame(maxWidth: .infinity, minHeight: HSpacing.targetMinimum)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("profile.delete")
      }
      Text(Self.footer(BuildInfo.current))
        .hType(.footnote)
        .foregroundStyle(HColor.textSecondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("profile.buildFooter")
    }
    .padding(.top, 4)
  }

  /// "Hasala QA · 0.2.0 (1) · unset · End‑to‑end encrypted, never sold": the build first (the
  /// tests read its prefix), then Paper's promise. The hyphens don't break (U+2011).
  static func footer(_ build: BuildInfo) -> String {
    "\(build.footer) · End\u{2011}to\u{2011}end encrypted, never sold"
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
    case .projects:
      ProjectsListView(app: app)
    case .addToProject(let id):
      ProjectAddTransactionsView(app: app, project: id)
    case .editProject(let id):
      ProjectEditorView(app: app, project: id)
    case .newProject(let starter):
      ProjectEditorView(app: app, project: nil, starter: starter)
    case .plan:
      PlanPage(app: app)
    case .category(let id):
      CategoryDetailView(app: app, category: id)
    case .rules:
      RulesPage(app: app, model: model)
    case .categoryEditor(let id):
      CategoryEditorPage(app: app, category: id)
    case .categoryMove(let id):
      CategoryMovePage(app: app, category: id)
    case .notifications:
      NotificationSettingsPage(model: model)
    case .exchangeRates:
      ExchangeRatesPage(app: app)
    case .editRate(let currency):
      RateEditorPage(app: app, currency: currency)
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
      if let session { SecurityView(session: session, app: app) }
    case .editName:
      if let session { NameEditPage(app: app, session: session) }
    case .privacy, .help:
      HelpPage()
    case .deleteAccount:
      if let session { DeleteAccountView(session: session) }
    }
  }
}

#if HASALA_MOCKS
  #Preview("Profile") {
    ProfileSheet(app: AppModel(store: InMemoryLedger()))
  }
#endif
