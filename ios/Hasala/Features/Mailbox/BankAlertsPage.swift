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
/// once, with the success haptic (motion policy "celebrate").
struct BankAlertsPage: View {
  @Bindable var app: AppModel
  /// The rows this page has shown, to tell a new one when it comes back from Add a mailbox.
  @State private var known: Set<String>?
  /// A new row before it lands, then once it landed (the haptic's trigger).
  @State private var arriving: String?
  @State private var landed: String?
  /// The hero's sign-in again, while it runs or after it failed.
  @State private var signIn: MailConnectCoordinator?
  @Environment(\.hMotion) private var motion

  init(app: AppModel) {
    self.app = app
  }

  private var lane: (any MailboxConnecting)? { app.mailbox }
  private var mailboxes: [MailboxSnapshot] { lane?.mailboxes ?? [] }

  var body: some View {
    let health = app.store.state.mailbox
    let summary = MailboxesSummary(mailboxes, health: health, offer: app.mailOffer)
    let hero = Hero(summary: summary, health: health, mailboxes: mailboxes, offer: app.mailOffer)
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
    .onAppear { noteRows(mailboxes.map(\.id)) }
    .onChange(of: mailboxes.map(\.id)) { _, ids in noteRows(ids) }
    .hHaptic(.success, trigger: landed) { _, new in new != nil }
  }

  // MARK: Hero

  /// What the hero says, from the one summary the Profile card and the bell also draw.
  struct Hero: Equatable {
    enum Kind: Equatable {
      case working, importing, needsYou, notConnected
      case signInAgain(mailboxID: String, provider: MailProviderKind)
    }

    let kind: Kind
    let detail: String

    init(summary: MailboxesSummary, health: MailboxHealth, mailboxes: [MailboxSnapshot], offer: MailOffer?) {
      let live = mailboxes.filter { $0.state != .disconnected }
      if case .signInAgain(let id, let provider)? = offer {
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
      detail = kind == .notConnected ? "Add a mailbox so Hasala can read your bank alerts." : summary.detail
    }

    var title: String {
      switch kind {
      case .working: "Working"
      case .importing: "Importing"
      case .needsYou: "Needs you"
      case .notConnected: "Not connected"
      case .signInAgain: "Sign in again"
      }
    }

    var hue: Hue {
      switch kind {
      case .working, .importing: .mint
      case .needsYou, .signInAgain: .sand
      case .notConnected: .sky
      }
    }

    var glyph: [PaperGlyph.Part] {
      switch kind {
      case .working, .importing: PaperGlyph.check
      case .needsYou, .signInAgain: PaperGlyph.alert
      case .notConnected: PaperGlyph.envelope
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
    signIn = attempt
    Task {
      await attempt.connect(provider)
      if case .connected? = attempt.outcome {
        app.say(MailCopy.signedInAgain(provider))
        signIn = nil
      }
    }
  }

  // MARK: Mailboxes

  private var mailboxesSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      HSectionHeader("Mailboxes")
      if !mailboxes.isEmpty || offersAdd {
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
          }
        }
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
    guard let lane, lane.capabilities.contains(.connect), !lane.connectable.isEmpty else { return false }
    return lane.capabilities.contains(.addSecond) || !mailboxes.contains { $0.state != .disconnected }
  }

  /// Notes the rows on screen; one that wasn't here last time lands.
  private func noteRows(_ ids: [String]) {
    defer { known = Set(ids) }
    guard let known, let new = ids.first(where: { !known.contains($0) }) else { return }
    arriving = new
    Task {
      // After the pop back settles, so the person sees it land.
      try? await Task.sleep(for: .milliseconds(motion.settled ? 0 : 200))
      withHMotion(.celebrate, motion) { arriving = nil }
      landed = new
    }
  }

  // MARK: Banks

  @ViewBuilder private var banksSection: some View {
    let banks = lane?.chosenBanks() ?? []
    if !banks.isEmpty {
      VStack(alignment: .leading, spacing: 12) {
        HSectionHeader("Banks")
        HListCard {
          ForEach(Array(banks.enumerated()), id: \.element) { i, bank in
            if i > 0 { HDivider(inset: .disc68) }
            BankAlertsBankRow(bank: bank, detail: Self.bankDetail(bank, mailboxes))
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

  /// Where a bank's alerts are read: "In Gmail and Outlook · Arabic alerts". The lane keeps
  /// no per-bank freshness the app can show, so Paper's "Last email 4 min ago" is the hero's.
  static func bankDetail(_ bank: SupportedBank, _ mailboxes: [MailboxSnapshot]) -> String {
    let reading = mailboxes.filter { m in
      m.state != .disconnected && m.banks.contains { $0 == bank.name || $0 == bank.shortName }
    }
    var providers: [String] = []
    for m in reading where !providers.contains(m.provider.appName) { providers.append(m.provider.appName) }
    let place = providers.isEmpty ? "No alerts read yet" : "In \(providers.formatted(.list(type: .and)))"
    return bank == .dib ? "\(place) · Arabic alerts" : place
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
