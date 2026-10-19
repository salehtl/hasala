import HasalaDesign
import HasalaModels
import SwiftUI

/// Profile › Bank alerts (Paper "Profile · Bank alerts" 64L, "Bank alerts · Outlook needs
/// sign-in" 1NAM, "Add a mailbox · 1 Bank alerts" 1NS8, "· 3 Two mailboxes" 1NYL): whether
/// bank alerts are working, the mailboxes they come from, the banks, what couldn't be read
/// (Debug), and how Hasala reads email.
///
/// The hero says it in a word ("Working", "Sign in again", "Needs you"); when a provider
/// ended Hasala's access it carries that provider's button, aimed at the first mailbox that
/// needs it (plan decision 10), and the sign-in runs from here. A mailbox just added lands
/// once, with the success haptic as it settles (motion policy "celebrate"); one read again
/// after a sign-in on another screen plays the haptic once this page shows
/// (`MailboxMoment`).
struct BankAlertsPage: View {
  @Bindable var app: AppModel
  /// The rows this page has shown, to tell a new one when it comes back from Add a mailbox.
  @State private var known: Set<String>?
  /// A new row before it lands.
  @State private var arriving: String?
  /// Whether this page is the one on screen (not under a pushed page).
  @State private var visible = false
  /// The hero's sign-in again, while it runs or after it failed.
  @State private var signIn: MailConnectCoordinator?
  /// Each mailbox connected or read again, counted once its motion settles (the success
  /// haptic's trigger: a count, so the same mailbox twice plays twice).
  @State private var successes = 0
  @Environment(\.hMotion) private var motion

  init(app: AppModel) {
    self.app = app
    // A page made in the place of the one that connected (the Profile card's "Connect your
    // email") holds the new row back from its first frame, so it lands rather than flashes.
    _arriving = State(initialValue: MailboxMoment.pendingAddition)
  }

  private var lane: (any MailboxConnecting)? { app.mailbox }
  private var mailboxes: [MailboxSnapshot] { lane?.mailboxes ?? [] }
  private var reporting: BankAlertsReporting? { lane as? BankAlertsReporting }
  /// Whether the mailboxes are known yet (live: the lane's first status was read).
  private var stateKnown: Bool { lane?.mailboxesKnown ?? true }

  var body: some View {
    let health = app.store.state.mailbox
    let summary = MailboxesSummary(mailboxes, health: health, offer: app.mailOffer, known: stateKnown)
    let hero = Hero(
      summary: summary, health: health, mailboxes: mailboxes, offer: app.mailOffer, read: reporting?.readThisMonth,
      known: stateKnown)
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        heroCard(hero)
        mailboxesSection
        banksSection
        if BuildSurface.showsUnfinished { needsALook }
        howItReads
      }
      .padding(.horizontal, HSpacing.insetPage)
      .padding(.top, 8)
      .padding(.bottom, 48)
      .hAnimation(.stateSwap, value: hero)
    }
    .background(HColor.surfaceSecondary)
    .navigationTitle("Bank alerts")
    .navigationBarTitleDisplayMode(.inline)
    .onAppear {
      visible = true
      noteRows(mailboxes.map(\.id))
      takeMoment()
      if let arriving { land(arriving) }
    }
    .onDisappear { visible = false }
    .onChange(of: mailboxes.map(\.id)) { _, ids in noteRows(ids) }
    // A mailbox connected or signed in again: the motion policy's success, once each.
    .hHaptic(.success, trigger: successes) { old, new in new > old }
  }

  // MARK: Hero

  /// What the hero says, from the one summary the Profile card and the bell also draw.
  struct Hero: Equatable {
    enum Kind: Equatable {
      case working, importing, needsYou, notConnected
      /// The mailbox state is still being read.
      case checking
      case signInAgain(mailboxID: String, provider: MailProviderKind)
    }

    let kind: Kind
    let detail: String

    init(
      summary: MailboxesSummary, health: MailboxHealth, mailboxes: [MailboxSnapshot], offer: MailOffer?,
      read: MonthRead? = nil, known: Bool = true
    ) {
      let live = mailboxes.filter { $0.state != .disconnected }
      if !known {
        kind = .checking
      } else if case .signInAgain(let id, let provider)? = offer {
        kind = .signInAgain(mailboxID: id, provider: provider)
      } else if let broken = live.first(where: { $0.state == .needsSignIn }) {
        kind = .signInAgain(mailboxID: broken.id, provider: broken.provider)
      } else if live.isEmpty {
        kind = .notConnected
      } else if summary.needsYou {
        kind = .needsYou
      } else if live.allSatisfy({ $0.state == .syncing }) || health.status == .importing {
        // Every mailbox on its first import (one still syncing beside a working one keeps
        // the hero "Working", Paper 1NYL).
        kind = .importing
      } else {
        kind = .working
      }
      switch kind {
      case .notConnected:
        detail = "Add a mailbox so Hasala can read your bank alerts."
      case .checking:
        detail = summary.detail
      case .signInAgain(let id, _):
        detail = Self.signInDetail(live.first { $0.id == id }, live: live) ?? summary.detail
      case .working where !health.lastEmail.isEmpty:
        // "Last email 4 min ago" over "214 read in October" (Paper 1NS8); the banks when
        // the month's count isn't known.
        detail = ["Last email \(health.lastEmail)", read?.line ?? (health.banks.isEmpty ? nil : health.banks)]
          .compactMap { $0 }.joined(separator: "\n")
      default:
        detail = summary.detail
      }
    }

    /// "Microsoft ended access to maya.k@example.com on Wed 7 Oct. Your Gmail still works."
    /// (Paper 1NAM): the provider, the mailbox, the day it was last read, and the mailbox
    /// that still works.
    static func signInDetail(_ broken: MailboxSnapshot?, live: [MailboxSnapshot]) -> String? {
      guard let broken else { return nil }
      // A sign-in that the provider didn't end (live: no Outlook mailbox on that account).
      if let note = broken.note { return note }
      var detail = "\(broken.provider.company) ended access to \(broken.address)"
      // The date stays on one line ("Wed 7 Oct").
      if let day = broken.lastChecked?.split(separator: ",").first {
        detail += " on " + day.replacingOccurrences(of: " ", with: "\u{00A0}")
      }
      detail += "."
      let working = live.first { $0.id != broken.id && ($0.state == .connected || $0.state == .syncing) }
      if let working { detail += " Your \(working.provider.appName) still works." }
      return detail
    }

    var title: String {
      switch kind {
      case .working: "Working"
      case .importing: "Importing"
      case .needsYou: "Needs you"
      case .notConnected: "Not connected"
      case .checking: "Checking"
      case .signInAgain: "Sign in again"
      }
    }

    var hue: Hue {
      switch kind {
      case .working, .importing: .mint
      case .needsYou, .signInAgain: .sand
      case .notConnected, .checking: .sky
      }
    }

    var glyph: [PaperGlyph.Part] {
      switch kind {
      case .working, .importing: PaperGlyph.check
      case .needsYou, .signInAgain: PaperGlyph.alert
      case .notConnected, .checking: PaperGlyph.envelope
      }
    }
  }

  @Environment(\.dynamicTypeSize) private var typeSize

  private func heroCard(_ hero: Hero) -> some View {
    let layout = typeSize.isAccessibilitySize
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
      : AnyLayout(HStackLayout(alignment: .center, spacing: 16))
    return VStack(alignment: .leading, spacing: 16) {
      layout {
        Circle().fill(HColor.posterGlyph).frame(width: 56, height: 56)
          .overlay { PaperGlyph(hero.glyph, size: 26, color: hero.hue.ink, lineWidth: 2.4) }
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text(hero.title).hType(.title1).foregroundStyle(hero.hue.ink)
          Text(hero.detail).hType(.subheadline).foregroundStyle(HColor.textOnHueSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Bank alerts: \(hero.title). \(hero.detail.replacingOccurrences(of: "\n", with: ". "))")
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("bankAlerts.status")
      }
      if case .signInAgain(let id, let provider) = hero.kind, lane?.capabilities.contains(.signInAgain) == true {
        ProviderButton(provider: provider, loading: signIn?.busy ?? false) { signInAgain(id, provider) }
          .accessibilityIdentifier("bankAlerts.signInAgain")
        if let message = signIn?.failureLine {
          InlineStatus(tone: .warning, text: message, size: .regular)
            .hTransition(.rise)
        }
      }
    }
    .padding(20)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(hero.hue.perceptualGradient, in: RoundedRectangle(cornerRadius: HRadius.card, style: .continuous))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("bankAlerts.hero")
  }

  /// The provider's sign-in for that mailbox, from here (no read-only screen: the person
  /// read it when they connected). Done, the hero says it works again.
  private func signInAgain(_ id: String, _ provider: MailProviderKind) {
    guard let lane else { return }
    let attempt = MailConnectCoordinator(mailbox: lane, context: .signInAgain(mailboxID: id))
    let policy = motion
    signIn = attempt
    Task {
      await attempt.connect(provider)
      if attempt.failedWithNoMailbox {
        signIn = nil
        MailConnectCoordinator.hand(attempt, to: app.router)
      } else if let line = attempt.signedInAgainLine {
        app.say(line)
        signIn = nil
        // The hero turns to Working; the haptic once it has.
        try? await Task.sleep(for: policy.settleDelay(.stateSwap))
        successes += 1
      }
    }
  }

  // MARK: Mailboxes

  private var mailboxesSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      HSectionHeader("Mailboxes")
      if !stateKnown {
        // Not "no mailbox" before the lane's state is read: a row that says it is checking.
        HListCard {
          HStack(spacing: HSpacing.listRowGap) {
            ProgressView()
              .frame(width: 40, height: 40)
            Text("Checking your mailbox")
              .hType(.rowTitle).foregroundStyle(HColor.textSecondary)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .padding(.horizontal, HSpacing.listRowInsetInline)
          .padding(.vertical, HSpacing.listRowInsetBlock)
          .frame(minHeight: HSpacing.listRowMinHeightTwoLine)
          .accessibilityElement(children: .combine)
          .accessibilityIdentifier("bankAlerts.mailboxes.checking")
        }
      } else if !mailboxes.isEmpty || offersAdd || offersChange {
        HListCard {
          ForEach(Array(mailboxes.enumerated()), id: \.element.id) { i, m in
            if i > 0 { HDivider(inset: .disc68) }
            Button { app.router.profile.append(.mailbox(m.id)) } label: { landing(m) }
              .buttonStyle(HRowPressStyle())
              .accessibilityIdentifier("bankAlerts.mailbox.\(m.id)")
          }
          if offersAdd {
            if !mailboxes.isEmpty { HDivider(inset: .disc68) }
            MailActionRow(title: "Add a mailbox", identifier: "bankAlerts.addMailbox") {
              app.router.profile.append(.addMailbox)
            }
          } else if offersChange {
            HDivider(inset: .disc68)
            MailActionRow(title: "Use another email", identifier: "bankAlerts.changeMailbox", glyph: PaperGlyph.envelope) {
              app.router.profile.append(.addMailbox)
            }
          }
        }
        // A chip that changes (Syncing to Connected, Sign in again to Connected) cross-fades.
        .hAnimation(.stateSwap, value: mailboxes.map(\.state))
      }
      Text(MailCopy.mailboxesFootnote)
        .hType(.footnote)
        .foregroundStyle(HColor.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 16)
    }
  }

  /// A row; the one just added rises into place once (motion policy "celebrate": under
  /// 600 ms; a fade under Reduce Motion, nothing when motion is settled).
  private func landing(_ m: MailboxSnapshot) -> some View {
    let pending = arriving == m.id
    return MailboxRow(m)
      .opacity(pending ? 0 : 1)
      .offset(y: pending && !motion.isStill ? HMotion.travelRise : 0)
      .scaleEffect(pending && !motion.isStill ? HMotion.dealScale : 1)
  }

  /// "Add a mailbox" shows with a second mailbox allowed, or when none is read (B4.6 rule 3).
  private var offersAdd: Bool {
    guard let lane, stateKnown, lane.capabilities.contains(.connect), !lane.connectable.isEmpty else { return false }
    return lane.capabilities.contains(.addSecond) || !mailboxes.contains { $0.state != .disconnected }
  }

  /// "Use another email" shows where the build holds one mailbox, the account has it, and
  /// another provider can replace it (the provider's screen confirms the switch).
  private var offersChange: Bool {
    guard let lane, !offersAdd, lane.holdsOneLink, lane.capabilities.contains(.connect) else { return false }
    // Not while another iPhone reads it: this iPhone can't switch it.
    guard !mailboxes.contains(where: \.readElsewhere) else { return false }
    let linked = Set(mailboxes.filter { $0.state != .disconnected }.map(\.provider))
    return !linked.isEmpty && lane.connectable.contains { !linked.contains($0) }
  }

  /// Notes the rows on screen; one that wasn't here last time lands, once this page shows
  /// again (the connect that added it ran on a page pushed over this one).
  private func noteRows(_ ids: [String]) {
    defer { known = Set(ids) }
    guard let known, let new = ids.first(where: { !known.contains($0) }) else { return }
    arriving = new
    if visible { land(new) }
  }

  private func land(_ id: String) {
    let policy = motion
    Task {
      // After the pop back settles, so the person sees it land.
      try? await Task.sleep(for: Self.popSettle(policy))
      guard arriving == id else { return }
      withHMotion(.celebrate, policy) { arriving = nil }
      // The haptic as the row comes to rest, not as it starts (spec 01 §4.11).
      try? await Task.sleep(for: policy.settleDelay(.celebrate))
      successes += 1
    }
  }

  /// A moment a screen that went handed over (`ConnectMailPage`): a new row lands; a mailbox
  /// read again plays the haptic once the way back has settled (its chip changed while
  /// this page was out of sight).
  private func takeMoment() {
    switch MailboxMoment.take() {
    case .added(let id)?:
      // A row this page already saw arrive is the same one; a mailbox gone since lands nothing.
      if mailboxes.contains(where: { $0.id == id }) {
        arriving = id
      } else if arriving == id {
        arriving = nil
      }
    case .signedInAgain?:
      let policy = motion
      Task {
        try? await Task.sleep(for: Self.popSettle(policy))
        successes += 1
      }
    case nil:
      break
    }
  }

  /// The system push or pop back to this page, near enough (none when motion is settled).
  static func popSettle(_ policy: MotionPolicy) -> Duration {
    .milliseconds(policy.settled ? 0 : 200)
  }

  // MARK: Banks

  @ViewBuilder private var banksSection: some View {
    let banks = lane?.chosenBanks() ?? []
    if !banks.isEmpty {
      VStack(alignment: .leading, spacing: 12) {
        HSectionHeader("Banks")
        HListCard {
          let checking = mailboxes.contains { $0.state == .syncing }
          ForEach(Array(banks.enumerated()), id: \.element) { i, bank in
            if i > 0 { HDivider(inset: .disc68) }
            BankAlertsBankRow(
              bank: bank, detail: Self.bankDetail(bank, lastEmail: reporting?.lastEmail(bank), checking: checking))
              .accessibilityIdentifier("bankAlerts.bank.\(bank.rawValue)")
          }
          // Adding a bank has no screen yet (plan P3 work 5): Debug only.
          if BuildSurface.showsUnfinished {
            HDivider(inset: .disc68)
            MailActionRow(title: "Add a bank", identifier: "bankAlerts.addBank") {
              app.say("Adding a bank here isn't built yet", icon: .info)
            }
          }
        }
      }
    }
  }

  /// When a bank's alerts last arrived (Paper 1NS8: "Last email 4 min ago", "Last email 2 h
  /// ago · Arabic alerts"); before the first, "Checking now" while a mailbox's first import
  /// runs, else that none were read yet.
  static func bankDetail(_ bank: SupportedBank, lastEmail: String?, checking: Bool) -> String {
    let when = lastEmail.map { "Last email \($0)" } ?? (checking ? "Checking now" : "No alerts read yet")
    return bank == .dib ? "\(when) · Arabic alerts" : when
  }

  // MARK: Needs a look (Debug)

  /// "1 email we couldn't read" (Paper 64L): the alerts a mailbox fetched but couldn't read.
  /// Their review has no screen yet, so this is Debug's (plan P3 work 5).
  @ViewBuilder private var needsALook: some View {
    let unreadable = (lane as? UnreadableMailReporting)?.unreadableMail ?? []
    let count = max(unreadable.count, app.store.state.mailbox.unreadable)
    if count > 0 {
      VStack(alignment: .leading, spacing: 12) {
        HSectionHeader("Needs a look")
        HListCard {
          Button {
            app.say("Reading these here isn't built yet", icon: .info)
          } label: {
            HStack(spacing: HSpacing.listRowGap) {
              Circle().fill(HColor.statusWarningSurface).frame(width: 40, height: 40)
                .overlay { HIconView(.envelope, size: 20, color: HColor.statusWarningForeground, strokeWidth: 1.9) }
              VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                  Circle().fill(HColor.paceFillOverPace).frame(width: 8, height: 8)
                  Text(count == 1 ? "1 email we couldn't read" : "\(count) emails we couldn't read")
                    .hType(.rowTitle).foregroundStyle(HColor.textPrimary)
                }
                Text(unreadable.first.map { "\($0.kind) · \($0.provider.appName) · \($0.day)" }
                  ?? "Kept for you to sort by hand")
                  .hType(.footnote).foregroundStyle(HColor.listRowSupporting)
              }
              .frame(maxWidth: .infinity, alignment: .leading)
              HIconView(.chevronRight, size: HSpacing.iconSmall, color: HColor.listRowChevron)
            }
            .padding(.horizontal, HSpacing.listRowInsetInline)
            .padding(.vertical, HSpacing.listRowInsetBlock)
            .frame(minHeight: HSpacing.listRowMinHeightTwoLine)
            .contentShape(Rectangle())
          }
          .buttonStyle(HRowPressStyle())
          .accessibilityIdentifier("bankAlerts.unreadable")
        }
      }
    }
  }

  // MARK: How Hasala reads your email

  private var howItReads: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("How Hasala reads your email").hType(.body.weight(.semibold)).foregroundStyle(HColor.textPrimary)
        .accessibilityAddTraits(.isHeader)
      readsRow(PaperGlyph.envelope, "Your iPhone asks your mail provider only for emails from your banks' alert addresses.")
      readsRow(PaperGlyph.eyeOff, "The rest of your inbox, headers included, is never downloaded.")
      readsRow(PaperGlyph.link,
               "The alert text is kept on your iPhone, so every transaction shows where it came from. It syncs only end\u{2011}to\u{2011}end encrypted.")
    }
    .padding(.top, 18)
    .padding([.horizontal, .bottom], 20)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.tile, style: .continuous))
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("bankAlerts.howItReads")
  }

  private func readsRow(_ glyph: [PaperGlyph.Part], _ text: String) -> some View {
    HStack(alignment: .top, spacing: 12) {
      PaperGlyph(glyph, size: 22, color: HColor.iconPrimary, lineWidth: 1.8)
      Text(text).hType(.subheadline).foregroundStyle(HColor.textPrimary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

/// A mail lane that can say which alerts it fetched but couldn't read ("Needs a look").
/// The mock does; the live lane's count is in `MailboxHealth.unreadable`.
@MainActor
protocol UnreadableMailReporting {
  var unreadableMail: [UnreadableMail] { get }
}

/// A mail lane that can say, bank by bank, when its alerts last arrived, and how many it
/// read this month (Paper 1NS8: "Last email 4 min ago", "214 read in October"). The live
/// lane reads its bank health rows; the mock has Paper's numbers. It stays on the iPhone.
@MainActor
protocol BankAlertsReporting {
  /// How long ago the newest alert from `bank` arrived ("4 min ago"); nil before any.
  func lastEmail(_ bank: SupportedBank) -> String?
  /// The alerts read this month; nil before any.
  var readThisMonth: MonthRead? { get }
}

/// "214 read in October": the alerts read in the current month.
struct MonthRead: Hashable, Sendable {
  var count: Int
  /// "October".
  var month: String

  var line: String { "\(count) read in \(month)" }
}

/// One alert a mailbox fetched but couldn't read: "Debit card alert · Gmail · Thu 8 Oct".
struct UnreadableMail: Hashable, Sendable {
  var kind: String
  var provider: MailProviderKind
  var day: String
}

extension MailConnectCoordinator {
  /// What a sign-in again that didn't finish says on the hero or the mailbox: there is no
  /// screen for it (nothing changed), only a line.
  var failureLine: String? {
    guard case .failed(let failure)? = outcome, let provider else { return nil }
    if case .cancelled = failure { return "\(provider.company) sign-in didn't finish. Nothing changed." }
    return failure.message(for: provider)
  }
}
