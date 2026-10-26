import HasalaDesign
import HasalaModels
import SwiftUI

struct BankTextsAlertsPage: View {
  @Bindable var app: AppModel
  let lane: any BankTextsConnecting
  @Binding var guiding: Bool
  @State private var pasting = false
  @State private var testing = false
  @State private var askingEmail = false
  @State private var requestingBank = false
  @Environment(AccountSession.self) private var session: AccountSession?
  @Environment(\.dynamicTypeSize) private var typeSize

  struct Hero: Equatable {
    let title: String
    let detail: String
    let hue: Hue
    let working: Bool

    init(_ status: BankTextsStatus, lastText: Date?, now: Date) {
      switch status {
      case .working(let lastRan):
        title = "Working"
        detail = ["Bank texts \u{00B7} ran \(RelativeTime.ago(lastRan, now: now))",
                  lastText.map { "Last bank text \(RelativeTime.ago($0, now: now))" }]
          .compactMap { $0 }.joined(separator: "\n")
        hue = .mint
        working = true
      case .waitingForFirstText:
        title = "Ready"
        detail = "Waiting for your first bank text.\nYour next payment shows up here."
        hue = .sky
        working = false
      case .notSetUp:
        title = "Not set up"
        detail = "Make the automation in the Shortcuts app."
        hue = .sand
        working = false
      }
    }
  }

  static func automationPill(_ status: BankTextsStatus, test: BankTextsTest, now: Date) -> StatusPill {
    switch status {
    case .working(let lastRan): StatusPill("Ran \(RelativeTime.ago(lastRan, now: now))", tone: .success, showsDot: false)
    case .waitingForFirstText:
      if case .received = test { StatusPill("Test passed", tone: .success, showsDot: false) }
      else { StatusPill("Not run yet", tone: .accent, showsDot: false) }
    case .notSetUp: StatusPill("Not set up", tone: .warning, showsDot: false)
    }
  }

  var body: some View {
    TimelineView(.periodic(from: .now, by: 60)) { context in
      let now = context.date
      let hero = Hero(lane.status, lastText: lane.lastTextAt, now: now)
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          heroCard(hero)
          automation(now)
          banks(now)
          howItReads
          switchSection
        }
        .padding(.horizontal, HSpacing.insetPage)
        .padding(.top, 8)
        .padding(.bottom, 48)
        .hAnimation(.stateSwap, value: hero)
      }
    }
    .background(HColor.surfaceSecondary)
    .navigationTitle("Bank alerts")
    .navigationBarTitleDisplayMode(.inline)
    .sheet(isPresented: $pasting) {
      PasteBankTextSheet(lane: lane) { app.say("Added to Review") }
    }
    .sheet(isPresented: $testing) {
      NavigationStack {
        BankTextsTestScreen(
          lane: lane, trailing: ("Done", { testing = false }), doneTitle: "Done", done: { testing = false })
      }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("textsTest")
    }
    .sheet(isPresented: $requestingBank) {
      RequestBankSheet(setup: session?.services.setup, prober: nil) { _ in app.say("Request sent") }
    }
    .alert("Switch to bank email?", isPresented: $askingEmail) {
      Button("Cancel", role: .cancel) {}
      Button("Connect email") { app.router.profile.append(.addMailbox) }
        .accessibilityIdentifier("bankAlerts.texts.switchConfirm")
    } message: {
      Text(BankTexts.switchToEmailMessage)
    }
  }

  private func heroCard(_ hero: Hero) -> some View {
    let layout = typeSize.isAccessibilitySize
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
      : AnyLayout(HStackLayout(alignment: .center, spacing: 16))
    return layout {
      Circle().fill(HColor.posterGlyph).frame(width: 56, height: 56)
        .overlay {
          if hero.working {
            PaperGlyph(PaperGlyph.check, size: 26, color: hero.hue.ink, lineWidth: 2.4)
          } else {
            HIconView(.clock, size: 26, color: hero.hue.ink, strokeWidth: 2)
          }
        }
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(hero.title).hType(.title1).foregroundStyle(hero.hue.ink)
        Text(hero.detail).hType(.subheadline).foregroundStyle(HColor.textOnHueSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Bank texts: \(hero.title). \(hero.detail.replacingOccurrences(of: "\n", with: ". "))")
      .accessibilityAddTraits(.isHeader)
      .accessibilityIdentifier("bankAlerts.status")
    }
    .padding(20)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(hero.hue.perceptualGradient, in: RoundedRectangle(cornerRadius: HRadius.card, style: .continuous))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("bankAlerts.hero")
  }

  private func automation(_ now: Date) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HSectionHeader("Automation")
      HListCard {
        HStack(alignment: .top, spacing: HSpacing.listRowGap) {
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(HColor.actionAccentSubtle)
            .frame(width: 40, height: 40)
            .overlay { HIconView(.chat, size: 20, color: HColor.actionAccent, strokeWidth: 1.8) }
            .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 2) {
            Text("Add bank text").hType(.rowTitle).foregroundStyle(HColor.textPrimary)
            Text("Runs on every text you get").hType(.footnote).foregroundStyle(HColor.listRowSupporting)
            StatusPillView(Self.automationPill(lane.status, test: lane.test, now: now), size: .s26, surface: .tinted)
              .padding(.top, 6)
          }
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, HSpacing.listRowInsetInline)
        .padding(.vertical, HSpacing.listRowInsetBlock)
        .frame(minHeight: HSpacing.listRowMinHeightTwoLine)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("bankAlerts.texts.automation")
        HDivider(inset: .disc68)
        TextsActionRow(title: "Test it again", icon: .chat, identifier: "bankAlerts.texts.test") {
          lane.startTest()
          testing = true
        }
        HDivider(inset: .disc68)
        TextsActionRow(
          title: "Paste a bank text", detail: "For texts from before you set this up", icon: .paper,
          identifier: "bankAlerts.texts.paste"
        ) { pasting = true }
        HDivider(inset: .disc68)
        TextsActionRow(title: "Show me how", icon: .help, identifier: "bankAlerts.texts.showMeHow") { guiding = true }
      }
      Text(BankTexts.automationFootnote)
        .hType(.footnote)
        .foregroundStyle(HColor.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 16)
    }
  }

  private func banks(_ now: Date) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HSectionHeader("Banks")
      HListCard {
        ForEach(Array(lane.banks.enumerated()), id: \.element.id) { i, bank in
          if i > 0 { HDivider(inset: .disc68) }
          BankAlertsBankRow(bank: bank.bank, detail: BankTexts.bankDetail(bank, now: now))
            .accessibilityIdentifier("bankAlerts.texts.bank.\(bank.bank.rawValue)")
        }
        if session != nil {
          HDivider(inset: .disc68)
          MailActionRow(title: "My bank isn't listed", identifier: "bankAlerts.requestBank") { requestingBank = true }
        }
      }
      Text(BankTexts.banksLine)
        .hType(.footnote)
        .foregroundStyle(HColor.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 16)
    }
  }

  private var howItReads: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("How Hasala reads your texts").hType(.body.weight(.semibold)).foregroundStyle(HColor.textPrimary)
        .accessibilityAddTraits(.isHeader)
      readsRow(.chat, "The automation hands Hasala each text you get, on this iPhone.")
      readsRow(.privacy, BankTexts.keepsPaymentShapedTexts)
      readsRow(.lock, "Only the payment Hasala read is kept. It syncs only end\u{2011}to\u{2011}end encrypted; the text itself never leaves this iPhone.")
    }
    .padding(.top, 18)
    .padding([.horizontal, .bottom], 20)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.tile, style: .continuous))
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("bankAlerts.texts.howItReads")
  }

  private func readsRow(_ icon: HIcon, _ text: String) -> some View {
    HStack(alignment: .top, spacing: 12) {
      HIconView(icon, size: 22, color: HColor.iconPrimary, strokeWidth: 1.8)
      Text(text).hType(.subheadline).foregroundStyle(HColor.textPrimary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var switchSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      HListCard {
        TextsActionRow(
          title: "Use bank email instead", detail: "Gmail or Outlook, read-only", icon: .envelope,
          identifier: "bankAlerts.texts.useEmail"
        ) { askingEmail = true }
      }
      Text(BankTexts.oneSourceNote)
        .hType(.footnote)
        .foregroundStyle(HColor.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 16)
    }
  }
}

struct UseBankTextsSection: View {
  @Bindable var app: AppModel
  let lane: any BankTextsConnecting
  @Binding var guiding: Bool
  @State private var asking = false
  @State private var switching = false
  @State private var pasting = false

  static func footnote(_ mailbox: (any MailboxConnecting)?, lane: any BankTextsConnecting) -> String {
    if let blocker = SourceSwitch.textsBlocker(mailbox, texts: lane) { return blocker }
    let note = SourceSwitch.reading(mailbox).isEmpty
      ? BankTexts.oneSourceNote : "\(BankTexts.oneSourceNote) Switching disconnects your mailbox."
    return lane.isSetUp && lane.readsEmail ? "\(BankTexts.readsEmailNow) \(note)" : note
  }

  var body: some View {
    let blocked = SourceSwitch.textsBlocker(app.mailbox, texts: lane) != nil
    VStack(alignment: .leading, spacing: 8) {
      HListCard {
        TextsActionRow(
          title: "Use bank texts instead", detail: "No inbox access. Set up a Shortcut once.", icon: .chat,
          identifier: "bankAlerts.useTexts"
        ) { asking = true }
        .disabled(switching || blocked)
        if lane.offersPaste {
          HDivider(inset: .disc68)
          TextsActionRow(
            title: "Paste a bank text", detail: "It waits in Review for you to check", icon: .paper,
            identifier: "bankAlerts.useTexts.paste"
          ) { pasting = true }
        }
      }
      Text(Self.footnote(app.mailbox, lane: lane))
        .hType(.footnote)
        .foregroundStyle(HColor.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 16)
        .accessibilityIdentifier("bankAlerts.useTexts.note")
    }
    .sheet(isPresented: $pasting) {
      PasteBankTextSheet(lane: lane) { app.say("Added to Review") }
    }
    .alert("Switch to bank texts?", isPresented: $asking) {
      Button("Cancel", role: .cancel) {}
      Button("Switch to texts") { switchToTexts() }
    } message: {
      Text(BankTexts.switchToTextsMessage)
    }
  }

  private func switchToTexts() {
    guard !switching else { return }
    switching = true
    Task {
      defer { switching = false }
      switch await SourceSwitch.toTexts(mailbox: app.mailbox, texts: lane) {
      case .switched:
        guiding = true
      case .failed(let line):
        app.say(line, icon: .info)
      }
    }
  }
}
