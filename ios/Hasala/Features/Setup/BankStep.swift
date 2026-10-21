import HasalaDesign
import HasalaModels
import SwiftUI

/// Setup · 1 of 4 · Connect your bank alerts (Paper X4 "Proposal · Step 4 · Bank alerts +
/// Gmail"): the banks the beta reads, all picked to start, how to turn on their email
/// alerts, a card for a bank that isn't listed, the mailbox they go to, what Google's own
/// screens will show, and the provider's sign-in, which runs from here.
struct BankStep: View {
  @Bindable var model: SetupModel
  @State private var telling = false
  @State private var helping = false
  @State private var asking: MailProviderKind?
  @Environment(\.dynamicTypeSize) private var typeSize

  var body: some View {
    let provider = model.provider
    let coordinator = model.coordinator(provider)
    let connected = model.connectedMailbox
    AccountScreen(
      title: "Connect your bank alerts",
      subtitle: "Hasala reads your banks' alert emails on this iPhone. Alerts must come by email, not only SMS.",
      steps: model.steps(1),
      trailing: ("Skip", model.skipBanks)
    ) {
      VStack(alignment: .leading, spacing: 12) {
        Text("Your banks")
          .hType(.overline)
          .foregroundStyle(HColor.textGroupedHeader)
          .padding(.horizontal, 16)
          .padding(.top, 4)
          .accessibilityAddTraits(.isHeader)
        BankList(chosen: model.chosenBanks, toggle: model.toggle)
        AlertsHowToLink { helping = true }
        AnotherBankCard(sent: model.bankRequestSent, sample: model.offersSampleData) { telling = true }
        MailboxChoiceCard(
          provider: provider, connected: connected,
          other: connected == nil ? model.connectable.first { $0 != provider } : nil,
          change: model.chooseEmail)
        if connected == nil, model.connectable.count <= 1 { TellUsWhichLink(small: true, leading: true) }
        if connected == nil, provider == .gmail, BuildSurface.showsGoogleBriefing { GoogleBriefingCard() }
        SetupFailureBanner(failure: model.failure)
        if typeSize.isAccessibilitySize { note(connected).padding(.top, 12) }
      }
      .padding(.top, -8)
    } footer: {
      if !typeSize.isAccessibilitySize { note(connected).padding(.bottom, 10) }
      if connected != nil {
        BusyButton(title: "Continue", busy: model.busy, enabled: !model.chosenBanks.isEmpty,
                   identifier: "bank.continue") { Task { await model.continueWithBanks() } }
          .dockPill()
      } else if model.offersSampleData {
        BusyButton(title: "Use sample data", busy: model.busy, enabled: !model.chosenBanks.isEmpty,
                   identifier: "mail.sample") { Task { await model.useSampleData() } }
          .dockPill()
        Button(provider.continueTitle) { connect(provider) }
          .buttonStyle(.pill(.tertiary, size: .medium, fill: true, loading: coordinator.busy))
          .disabled(model.chosenBanks.isEmpty)
          .dockPill()
          .accessibilityIdentifier("mail.connect.\(provider.rawValue)")
      } else {
        Button { connect(provider) } label: {
          Text(provider.continueTitle).fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(.pill(.primary, fill: true, loading: coordinator.busy || model.busy))
        .disabled(model.chosenBanks.isEmpty)
        .dockPill()
        .accessibilityIdentifier("mail.connect.\(provider.rawValue)")
      }
    }
    .sheet(isPresented: $telling) {
      RequestBankSheet(setup: model.bankRequests, prober: nil) { _ in model.noteBankRequestSent() }
    }
    .sheet(isPresented: $helping) {
      EmailAlertsHelpSheet(banks: SupportedBank.allCases)
    }
    .providerConnectQuestions(coordinator, provider: provider, request: $asking) { replacing, removingOld in
      Task { await model.connectMail(provider, replacing: replacing, removingOld: removingOld) }
    }
    .mailSwitchQuestion(coordinator)
  }

  private func connect(_ provider: MailProviderKind) {
    Task {
      guard await model.saveBanks() else { return }
      asking = provider
    }
  }

  private func note(_ connected: MailboxSnapshot?) -> some View {
    DockNote(text: model.chosenBanks.isEmpty
      ? "Pick at least one bank to continue."
      : connected != nil
        ? "Only alerts from the banks you pick are downloaded, straight to this iPhone."
        : "Read-only. Downloaded and read on this iPhone; our server never receives your emails. \(MailCopy.confirmNote)")
  }
}

private struct AlertsHowToLink: View {
  var action: () -> Void
  @ScaledMetric(relativeTo: .subheadline) private var lane: CGFloat = 20

  var body: some View {
    Button(action: action) {
      HStack(alignment: .top, spacing: 8) {
        HIconView(.info, size: 16, color: HColor.actionAccent, strokeWidth: 1.6).frame(height: lane)
        Text("How to turn on email alerts in your bank's app")
          .hType(HType.subheadline.weight(.medium))
          .foregroundStyle(HColor.textLink)
          .multilineTextAlignment(.leading)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(.horizontal, 4)
      .frame(minHeight: HSpacing.targetMinimum)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("bank.howTo")
  }
}

private struct MailboxChoiceCard: View {
  let provider: MailProviderKind
  let connected: MailboxSnapshot?
  let other: MailProviderKind?
  var change: () -> Void

  private var detail: String {
    if let connected { return "\(connected.provider.appName) · connected" }
    return provider == .outlook ? ConnectProviderView.outlookAccountLine : "Where your banks send alerts"
  }

  var body: some View {
    HStack(spacing: 12) {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(HColor.neutral100)
        .frame(width: 40, height: 40)
        .overlay { HIconView(.envelope, size: 22, color: HColor.textPrimary, strokeWidth: 1.6) }
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 1) {
        Text(connected?.address ?? provider.appName).hType(.headline).foregroundStyle(HColor.textPrimary)
        Text(detail).hType(.footnote).foregroundStyle(HColor.textSecondary)
      }
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityElement(children: .combine)
      .accessibilityIdentifier(connected == nil ? "mail.provider" : "mail.connected")
      if let other {
        Button("Use \(other.appName)", action: change)
          .buttonStyle(.plain)
          .hType(HType.subheadline.weight(.medium))
          .foregroundStyle(HColor.textLink)
          .frame(minHeight: HSpacing.targetMinimum)
          .contentShape(Rectangle())
          .accessibilityIdentifier("mail.change")
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 14)
    .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.listGroup, style: .continuous))
  }
}

private struct GoogleBriefingCard: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("What Google will show")
        .hType(.overline)
        .foregroundStyle(HColor.statusWarningForeground)
        .accessibilityAddTraits(.isHeader)
      item(1, "\u{201C}Google hasn\u{2019}t verified this app.\u{201D} Hasala is in beta; tap Advanced, then Go to Hasala.")
      item(2, "Tick \u{201C}Read your email\u{201D}. Without it, Hasala can\u{2019}t see your alerts.")
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(HColor.statusWarningSurface, in: RoundedRectangle(cornerRadius: HRadius.listGroup, style: .continuous))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("mail.googleBriefing")
  }

  private func item(_ n: Int, _ text: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Text(verbatim: "\(n)")
        .hType(HType.subheadline.weight(.bold))
        .foregroundStyle(HColor.statusWarningForeground)
        .frame(minWidth: 20, alignment: .leading)
      Text(text)
        .hType(.subheadline)
        .foregroundStyle(HColor.textPrimary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .accessibilityElement(children: .combine)
  }
}

struct EmailAlertsHelpSheet: View {
  let banks: [SupportedBank]
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          Text("Hasala reads the alert emails your bank sends. Many banks send alerts by SMS only until you turn on email.")
            .hType(.subheadline)
            .foregroundStyle(HColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
          ForEach(banks) { bank in
            BankAlertsSteps(bank: bank)
          }
          Text("Can\u{2019}t find it? Your bank\u{2019}s support team can turn on email alerts for you.")
            .hType(.footnote)
            .foregroundStyle(HColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
        }
        .padding(.horizontal, HSpacing.insetPage)
        .padding(.top, 8)
        .padding(.bottom, 32)
      }
      .background(HColor.surfaceSecondary)
      .navigationTitle("Turn on email alerts")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
            .accessibilityIdentifier("alertsHelp.done")
        }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("alertsHelp")
  }
}

private struct BankAlertsSteps: View {
  let bank: SupportedBank

  private var steps: [String] {
    [
      "Open the \(bank.name) app and sign in.",
      "Find the alert or notification settings. They\u{2019}re often under Settings or Profile.",
      "Turn on email alerts for card and account transactions.",
      "Check the alerts go to the email you connect to Hasala.",
    ]
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 12) {
        BankMonogram(bank: bank)
        Text(bank.name).hType(.rowTitle).foregroundStyle(HColor.textPrimary)
          .accessibilityAddTraits(.isHeader)
      }
      ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
        HStack(alignment: .firstTextBaseline, spacing: 10) {
          Text(verbatim: "\(i + 1)")
            .hType(HType.subheadline.weight(.bold))
            .foregroundStyle(HColor.textSecondary)
            .frame(minWidth: 20, alignment: .leading)
          Text(step)
            .hType(.subheadline)
            .foregroundStyle(HColor.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.listGroup, style: .continuous))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("alertsHelp.\(bank.rawValue)")
  }
}

/// The banks in one list card (Paper "ListGroup · Banks"): rows 56 tall, the divider
/// inset to the text.
struct BankList: View {
  let chosen: Set<SupportedBank>
  var toggle: (SupportedBank) -> Void

  var body: some View {
    VStack(spacing: 0) {
      ForEach(Array(SupportedBank.allCases.enumerated()), id: \.element) { i, bank in
        if i > 0 { HDivider(inset: .disc68) }
        BankChoiceRow(bank: bank, on: chosen.contains(bank)) { toggle(bank) }
      }
    }
    .padding(.vertical, 4)
    .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.listGroup, style: .continuous))
  }
}

/// One bank in a pick list (`bank.<bank>`, Paper "Row · Emirates NBD · Selected"): the
/// bank's monogram plate, its name and note, and the filled check circle (page 12 "Pick
/// several"), empty with a grey ring when not picked. The whole row is the target; it
/// highlights, never scales. Setup's bank step, and the banks asked for before a connect
/// from the profile when the account reads none (`ConnectMailPage`).
struct BankChoiceRow: View {
  let bank: SupportedBank
  let on: Bool
  var toggle: () -> Void

  var body: some View {
    Button(action: toggle) {
      HStack(spacing: 12) {
        BankMonogram(bank: bank)
        VStack(alignment: .leading, spacing: 0) {
          Text(bank.name).hType(.rowTitle).foregroundStyle(HColor.textPrimary)
          if let note = bank.note { Text(note).hType(.footnote).foregroundStyle(HColor.textSecondary) }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        CheckCircle(on: on)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 8)
      .frame(minHeight: 56)
      .contentShape(Rectangle())
    }
    .buttonStyle(HRowPressStyle())
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    .accessibilityIdentifier("bank.\(bank.rawValue)")
  }
}

/// The bank's monogram on its hue plate (Paper 40, radius 12, gradient 160°): "ENBD" on
/// sky, "DIB" on mint. The plate never grows, so its letters keep their size: it is a
/// picture of the bank's mark, drawn in a canvas (no text for VoiceOver or Dynamic Type to
/// reach), and the row beside it says the bank's name in text that grows.
struct BankMonogram: View {
  let bank: SupportedBank

  private var hue: Hue {
    switch bank {
    case .enbd: .sky
    case .dib: .mint
    case .adib: .lilac
    }
  }

  private var wide: Bool { bank.monogram.count > 3 }

  var body: some View {
    let ink = hue.ink
    let monogram = Text(verbatim: bank.monogram)
      .font(.custom(HWeight.bold.interFace, fixedSize: wide ? 11 : 12))
      .tracking(wide ? -0.22 : -0.12)
      .foregroundStyle(ink)
    RoundedRectangle(cornerRadius: 12, style: .continuous)
      .fill(hue.perceptualGradient)
      .frame(width: 40, height: 40)
      .overlay {
        Canvas { context, size in
          context.draw(context.resolve(monogram), at: CGPoint(x: size.width / 2, y: size.height / 2))
        }
      }
      .accessibilityHidden(true)
  }
}

/// The pick-several mark (page 12 "Checks" 2): a 24 accent circle with a white 14 tick when
/// picked; a 2 pt `control-check-unselected` ring when not. Colour never says it alone: the
/// tick does, and the row reads "Selected".
struct CheckCircle: View {
  let on: Bool

  var body: some View {
    ZStack {
      Circle().strokeBorder(HColor.controlCheckUnselected, lineWidth: 2).opacity(on ? 0 : 1)
      Circle().fill(HColor.actionAccent).opacity(on ? 1 : 0)
      HIconView(.check, size: 14, color: HColor.white, strokeWidth: 3).opacity(on ? 1 : 0)
    }
    .frame(width: 24, height: 24)
    .hAnimation(.thumbSlide, value: on)
    .accessibilityHidden(true)
  }
}

/// "Bank not listed?" (Paper X4 "Bank not listed?"): a ringed "+" plate, the line, and the
/// "Tell us" pill, which asks for the bank's name. Where the account offers sample data it
/// says so; otherwise Skip is the way on, by hand.
private struct AnotherBankCard: View {
  let sent: Bool
  let sample: Bool
  var tellUs: () -> Void

  private var line: String {
    if sent { return "Thanks. We'll email you when it's ready." }
    return sample
      ? "Tell us, and look around with sample data meanwhile."
      : "Tell us yours. Meanwhile, Skip lets you add spending by hand."
  }

  var body: some View {
    HStack(spacing: 12) {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .strokeBorder(HColor.neutral300, lineWidth: 1.5)
        .frame(width: 40, height: 40)
        .overlay { HIconView(.add, size: 18, color: HColor.neutral500, strokeWidth: 2) }
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 0) {
        Text("Bank not listed?").hType(.rowTitle).foregroundStyle(HColor.textPrimary)
        Text(line).hType(.footnote).foregroundStyle(HColor.textSecondary)
      }
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityElement(children: .combine)
      Button("Tell us", action: tellUs)
        .buttonStyle(.pill(.secondary, size: .small))
        .accessibilityIdentifier("bank.tellUs")
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .frame(minHeight: 64)
    .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.listGroup, style: .continuous))
  }
}
