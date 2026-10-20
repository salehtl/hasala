import HasalaDesign
import HasalaModels
import SwiftUI

/// Setup · 1 of 4 · Your bank (Paper 66E-0): the banks the beta reads, both picked to
/// start, a card for a bank that isn't listed, and "Continue with N banks", which opens
/// "Choose your email" (or the one provider's screen).
struct BankStep: View {
  @Bindable var model: SetupModel
  @State private var telling = false
  @Environment(\.dynamicTypeSize) private var typeSize

  var body: some View {
    AccountScreen(
      title: "Which bank do you use?",
      subtitle: "Pick yours. Hasala reads only their transaction alerts, nothing else in your mail.",
      steps: model.steps(1),
      // Not on the board: Skip is the only way on for a bank that isn't listed yet
      // (manual entry), as before the rebuild.
      trailing: ("Skip", model.skipBanks)
    ) {
      VStack(alignment: .leading, spacing: 12) {
        Text("Available now")
          .hType(.overline)
          .foregroundStyle(HColor.textGroupedHeader)
          .padding(.horizontal, 16)
          .padding(.top, 4)
          .accessibilityAddTraits(.isHeader)
        BankList(chosen: model.chosenBanks, toggle: model.toggle)
        AnotherBankCard(sent: model.bankRequestSent) { telling = true }
        SetupFailureBanner(failure: model.failure)
        // At the accessibility sizes the note scrolls with the banks, so the dock keeps the
        // room the button's label needs.
        if typeSize.isAccessibilitySize { note.padding(.top, 12) }
      }
      // Paper's scroll area starts 16 under the question (the template's content, 24).
      .padding(.top, -8)
    } footer: {
      if !typeSize.isAccessibilitySize { note.padding(.bottom, 10) }
      Button {
        Task { await model.continueWithBanks() }
      } label: {
        // The count makes the label long: at the accessibility sizes it wraps, and the pill
        // takes the lines' full height.
        Text(model.chosenBanks.count == 1 ? "Continue with 1 bank" : "Continue with \(model.chosenBanks.count) banks")
          .fixedSize(horizontal: false, vertical: true)
      }
      .buttonStyle(.pill(.primary, fill: true, loading: model.busy))
      .disabled(model.chosenBanks.isEmpty)
      .accessibilityIdentifier("bank.continue")
    }
    .sheet(isPresented: $telling) {
      RequestBankSheet(setup: model.bankRequests, prober: nil) { _ in model.noteBankRequestSent() }
    }
  }

  /// The dock's lock note (Paper "Note row"), or why Continue is off.
  private var note: some View {
    DockNote(text: model.chosenBanks.isEmpty
      ? "Pick at least one bank to continue."
      : "Next you'll connect your email, read-only. Only alerts from the banks you pick are downloaded, straight to this iPhone.")
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

/// "Another bank?" (Paper "Card · Coming soon · tell us yours"): a ringed "+" plate, the
/// line, and the "Tell us" pill, which asks for the bank's name. A Release build never says
/// "coming soon" (plan 0.1 rule 7).
private struct AnotherBankCard: View {
  let sent: Bool
  var tellUs: () -> Void

  private var line: String {
    if sent { return "Thanks. We'll email you when it's ready." }
    return BuildSurface.showsUnfinished ? "Coming soon. Tell us yours." : "Not listed? Tell us yours."
  }

  var body: some View {
    HStack(spacing: 12) {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .strokeBorder(HColor.neutral300, lineWidth: 1.5)
        .frame(width: 40, height: 40)
        .overlay { HIconView(.add, size: 18, color: HColor.neutral500, strokeWidth: 2) }
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 0) {
        Text("Another bank?").hType(.rowTitle).foregroundStyle(HColor.textPrimary)
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
