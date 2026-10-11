import HasalaDesign
import HasalaModels
import SwiftUI

#if HASALA_MOCKS
  import HasalaMocks
#endif

/// Your profile (Paper board, and its page-14 variant with Sign-in & security): who you are, whether bank alerts are
/// working, your money things, and settings. A large sheet with its own stack.
struct ProfileSheet: View {
  @Bindable var app: AppModel
  @State private var model: ProfileViewModel
  @State private var path: [ProfileRoute] = []
  @State private var confirmSignOut = false
  @Environment(\.dismiss) private var dismiss

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
            Button("Sign out") { confirmSignOut = true }
              .buttonStyle(.pill(.tertiary, fill: true))
              .foregroundStyle(HColor.listRowDestructive)
              .accessibilityIdentifier("profile.signOut")
            Button("Delete your account") { model.deleteAccount() }
              .buttonStyle(.pill(.destructiveText, size: .small))
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
      .alert("Sign out of this iPhone?", isPresented: $confirmSignOut) {
        Button("Sign out", role: .destructive) { model.signOut() }
        Button("Cancel", role: .cancel) {}
      } message: {
        // TODO(01 §14 S-26): the sign-out copy, verbatim, with N-08's offline line.
        Text("You can sign back in with your passkey or password.")
      }
    }
    .overlay(alignment: .bottom) { ToastHost(app: app) }
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

  private var mailboxCard: some View {
    let m = snap.mailbox
    let (title, hue): (String, Hue) = switch m.status {
    case .working: ("Bank alerts are working", .mint)
    case .quiet: ("Bank alerts went quiet", .sand)
    case .reconnect: ("Reconnect Gmail", .rose)
    case .notConnected: ("Connect Gmail", .sky)
    }
    return Button { path.append(.bankAlerts) } label: {
      HStack(spacing: 12) {
        Circle().fill(HColor.posterGlyph).frame(width: 40, height: 40)
          .overlay { Image(systemName: m.status == .working ? "checkmark" : "envelope").foregroundStyle(hue.ink) }
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 0) {
          Text(title).hType(.headline).foregroundStyle(HColor.textPrimary)
          Text("Last email \(m.lastEmail)").hType(.footnote).foregroundStyle(HColor.textOnHueSecondary)
          Text(m.banks).hType(.footnote).foregroundStyle(HColor.textOnHueSecondary)
        }
        Spacer()
        Image(systemName: "chevron.right").foregroundStyle(HColor.textOnHueSecondary).accessibilityHidden(true)
      }
      .padding(16)
      .background(hue.gradient, in: RoundedRectangle(cornerRadius: HRadius.listGroup, style: .continuous))
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("profile.bankAlerts")
  }

  private var money: some View {
    VStack(alignment: .leading, spacing: 12) {
      SectionTitle(title: "Your money")
      ListCard {
        Button { path.append(.accounts) } label: {
          NavRow(title: "Accounts", detail: snap.accounts.rendered(hidden: model.hidden)) {
            HueDisc(hue: .sky, glyph: .bank)
          }
        }
        .buttonStyle(.plain)
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
          NavRow(title: "Projects", detail: projects.rendered(hidden: model.hidden)) {
            HueDisc(hue: .peach, glyph: .flag)
          }
          // TODO(spec 04 §16.1 "Project detail"): Project detail.
        }
      }
    }
  }

  private var settings: some View {
    VStack(alignment: .leading, spacing: 12) {
      SectionTitle(title: "Settings")
      ListCard {
        Button { path.append(.security) } label: {
          NavRow(title: "Sign-in & security") { RowIcon(systemName: "checkmark.shield") } trailing: {
            DetailLine(parts: [.status("Protected", .success)], hidden: false)
          }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("profile.security")
        // TODO(spec 04 §16.2 X1): Currency and exchange rates (PENDING PO-17).
        settingValue("Currency", "dollarsign.circle", "AED")
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
        Button { path.append(.privacy) } label: {
          NavRow(title: "Privacy and data") { RowIcon(systemName: "hand.raised") }
        }
        .buttonStyle(.plain)
        Button { path.append(.help) } label: {
          NavRow(title: "Get help") { RowIcon(systemName: "questionmark.circle") }
        }
        .buttonStyle(.plain)
      }
    }
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
      // TODO(spec 04 §16.2 X8): HelpView (FAQ, TestFlight feedback, Copy diagnostics).
      placeholder("Get help", "questionmark.circle",
                  "Send feedback from TestFlight: take a screenshot in Hasala and tap Share Beta Feedback.")
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
