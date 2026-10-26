import HasalaDesign
import HasalaModels
import SwiftUI

@MainActor
@Observable
final class PasteBankTextModel {
  let lane: any BankTextsConnecting
  private(set) var text: String?
  private(set) var reading: BankTextReading?
  private(set) var isReading = false
  private(set) var adding = false
  private(set) var failure: String?
  private var generation = 0

  init(lane: any BankTextsConnecting) {
    self.lane = lane
  }

  var canAdd: Bool {
    guard text != nil, !isReading, !adding, let reading else { return false }
    return reading != .notAPayment
  }

  func paste(_ pasted: String?) async {
    let trimmed = pasted?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !trimmed.isEmpty else { return }
    generation += 1
    let mine = generation
    text = trimmed
    reading = nil
    failure = nil
    isReading = true
    let result = await lane.read(trimmed)
    guard mine == generation else { return }
    reading = result
    isReading = false
  }

  func add() async -> Bool {
    guard canAdd, let text else { return false }
    adding = true
    defer { adding = false }
    do {
      try await lane.addToReview(text)
      return true
    } catch {
      failure = error.message
      return false
    }
  }

  static func amountLine(_ p: BankTextPreview) -> String {
    let money = "\(p.amount.currency) \(MoneyFormat.string(p.amount.minor))"
    return p.direction == .out ? "\(money) out" : "\(money) in"
  }

  static func cardLine(_ p: BankTextPreview) -> String? {
    guard let ending = p.cardEnding else { return nil }
    let bank = p.bank.map { "\($0.shortName) card" } ?? "Card"
    return "\(bank) \u{00B7}\u{00B7}\u{00B7}\(ending)"
  }
}

struct PasteBankTextSheet: View {
  @State private var model: PasteBankTextModel
  var added: () -> Void
  @Environment(\.dismiss) private var dismiss

  init(lane: any BankTextsConnecting, added: @escaping () -> Void) {
    _model = State(initialValue: PasteBankTextModel(lane: lane))
    self.added = added
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          Text("For a text from before your automation. Copy it in Messages, then paste it here. Hasala reads it on this iPhone.")
            .hType(.subheadline)
            .foregroundStyle(HColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
          PasteButton(payloadType: String.self) { strings in
            let first = strings.first
            Task { @MainActor in await model.paste(first) }
          }
          .buttonBorderShape(.capsule)
          .tint(HColor.actionAccent)
          .frame(minHeight: HSpacing.targetMinimum)
          .accessibilityIdentifier("pasteText.paste")
          if let text = model.text {
            pasted(text)
            result
          }
          if let failure = model.failure {
            InlineStatus(tone: .warning, text: failure, size: .regular)
          }
          TextsNote(text: "Pasted texts always go to Review, so you check them before they count. The same text pasted twice is added once.")
        }
        .padding(.horizontal, HSpacing.insetPage)
        .padding(.top, 8)
        .padding(.bottom, 24)
      }
      .scrollEdgeEffectStyle(.soft, for: .bottom)
      .safeAreaBar(edge: .bottom) {
        Button {
          Task {
            if await model.add() {
              added()
              dismiss()
            }
          }
        } label: {
          Text("Add to Review").fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(.pill(.primary, fill: true, loading: model.adding))
        .disabled(!model.canAdd)
        .dockPill()
        .padding(.horizontal, HSpacing.insetPage)
        .padding(.bottom, 8)
        .accessibilityIdentifier("pasteText.add")
      }
      .background(HColor.surfaceSecondary)
      .navigationTitle("Paste a bank text")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { SheetCloseButton(identifier: "pasteText.close") { dismiss() } }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("pasteText")
    .task {
      #if HASALA_MOCKS
        if let text = BankTextsLaunch.takePasted() { await model.paste(text) }
      #endif
    }
  }

  private func pasted(_ text: String) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Pasted").hType(.overline).foregroundStyle(HColor.textGroupedHeader)
        .accessibilityAddTraits(.isHeader)
      Text(text)
        .hType(.subheadline)
        .foregroundStyle(HColor.textPrimary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.listGroup, style: .continuous))
        .accessibilityIdentifier("pasteText.text")
    }
  }

  @ViewBuilder private var result: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Hasala read").hType(.overline).foregroundStyle(HColor.textGroupedHeader)
        .accessibilityAddTraits(.isHeader)
      switch model.reading {
      case nil:
        HStack(spacing: 10) {
          Spinner(size: 18, track: HColor.feedbackProgressTrack)
          Text("Reading").hType(.subheadline).foregroundStyle(HColor.textSecondary)
        }
        .padding(16)
        .accessibilityElement(children: .combine)
      case .read(let preview)?:
        TextsCard {
          VStack(spacing: 0) {
            KeyValueRow("Amount", value: PasteBankTextModel.amountLine(preview))
            HDivider(inset: .none)
            KeyValueRow("Merchant", value: preview.merchant ?? "Not in the text", placeholder: preview.merchant == nil)
            HDivider(inset: .none)
            KeyValueRow(
              "Date", value: preview.date.map(BankTexts.dayAndTime) ?? "When it arrived", placeholder: preview.date == nil)
            if let card = PasteBankTextModel.cardLine(preview) {
              HDivider(inset: .none)
              KeyValueRow("Card", value: card)
            }
          }
          .padding(.horizontal, 16)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pasteText.read")
      case .unreadable?:
        InlineStatus(
          tone: .warning, text: "Hasala couldn't read this text. Add it to Review and fill in the payment yourself.",
          size: .regular)
          .accessibilityIdentifier("pasteText.unreadable")
      case .notAPayment?:
        InlineStatus(
          tone: .neutral, text: "This doesn't look like a bank payment, so Hasala won't keep it.", size: .regular)
          .accessibilityIdentifier("pasteText.notPayment")
      }
    }
  }
}
