import HasalaDesign
import HasalaModels
import SwiftUI

@MainActor
@Observable
final class PasteBankTextModel {
  let lane: any BankTextsConnecting
  let hidden: Bool
  private(set) var text: String?
  private(set) var reading: BankTextReading?
  private(set) var match: BankTextMatch?
  private(set) var isReading = false
  private(set) var adding = false
  private(set) var failure: String?
  private var generation = 0

  init(lane: any BankTextsConnecting, hidden: Bool = false) {
    self.lane = lane
    self.hidden = hidden
  }

  var refused: Bool { !lane.offersPaste }

  var canAdd: Bool {
    guard !refused, text != nil, !isReading, !adding, let reading else { return false }
    return reading != .notAPayment
  }

  var addTitle: String {
    switch match?.kind {
    case .payment?: "Add anyway"
    case .unreadText?: "Replace it"
    case nil: "Add to Review"
    }
  }

  func paste(_ pasted: String?) async {
    let trimmed = pasted?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !refused, !adding, !trimmed.isEmpty else { return }
    generation += 1
    let mine = generation
    text = trimmed
    reading = nil
    match = nil
    failure = nil
    isReading = true
    let result = await lane.read(trimmed)
    guard mine == generation else { return }
    let found = result == .notAPayment ? nil : await lane.match(trimmed)
    guard mine == generation else { return }
    reading = result
    match = found
    isReading = false
  }

  func add(replacing: Bool = true) async -> Bool {
    guard canAdd, let text else { return false }
    adding = true
    defer { adding = false }
    do {
      try await lane.addToReview(text, replacing: replacing && match?.kind == .unreadText ? match : nil)
      return true
    } catch {
      failure = error.message
      return false
    }
  }

  static func matchTitle(_ m: BankTextMatch) -> String {
    m.merchant ?? (m.kind == .unreadText ? "A bank text Hasala couldn't read" : "A payment")
  }

  static func matchDetail(_ m: BankTextMatch, hidden: Bool) -> String {
    let money = m.amount.map { hidden ? "Amount hidden" : "\($0.currency) \(MoneyFormat.string($0.minor))" }
    let from = m.fromText ? "From a bank text" : "From email"
    return [money, BankTexts.dayAndTime(m.postedAt), from].compactMap { $0 }.joined(separator: " \u{00B7} ")
  }

  static func matchQuestion(_ m: BankTextMatch) -> String {
    switch m.kind {
    case .payment: "A payment like this is already in Hasala. Add this text anyway?"
    case .unreadText: "This may be the bank text Hasala couldn't read. Replace it with this one?"
    }
  }

  static let undatedNote =
    "This text has no date, so Hasala dates it when you paste it. Change the date in Review if the payment was earlier."

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

  init(lane: any BankTextsConnecting, hidden: Bool, added: @escaping () -> Void) {
    _model = State(initialValue: PasteBankTextModel(lane: lane, hidden: hidden))
    self.added = added
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          Text(BankTexts.pasteIntro(usesTexts: model.lane.usesTexts))
            .hType(.subheadline)
            .foregroundStyle(HColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
          if model.refused {
            InlineStatus(tone: .neutral, text: BankTexts.pasteRefused, size: .regular)
              .accessibilityIdentifier("pasteText.refused")
          } else {
            PasteButton(payloadType: String.self) { strings in
              let first = strings.first
              Task { @MainActor in await model.paste(first) }
            }
            .buttonBorderShape(.capsule)
            .tint(HColor.actionAccent)
            .disabled(model.adding)
            .frame(minHeight: HSpacing.targetMinimum)
            .accessibilityIdentifier("pasteText.paste")
          }
          if let text = model.text {
            pasted(text)
            result
            if let match = model.match, model.reading != nil { matchCard(match) }
          }
          if let failure = model.failure {
            InlineStatus(tone: .warning, text: failure, size: .regular)
          }
          TextsNote(text: "Pasted texts always go to Review, so you check them before they count.")
        }
        .padding(.horizontal, HSpacing.insetPage)
        .padding(.top, 8)
        .padding(.bottom, 24)
      }
      .scrollEdgeEffectStyle(.soft, for: .bottom)
      .safeAreaBar(edge: .bottom) {
        VStack(spacing: 8) {
          Button { add(replacing: true) } label: {
            Text(model.addTitle).fixedSize(horizontal: false, vertical: true)
          }
          .buttonStyle(.pill(.primary, fill: true, loading: model.adding))
          .disabled(!model.canAdd)
          .dockPill()
          .accessibilityIdentifier("pasteText.add")
          if model.match?.kind == .unreadText {
            Button { add(replacing: false) } label: {
              Text("Add as a new payment").fixedSize(horizontal: false, vertical: true)
            }
            .buttonStyle(.pill(.tertiary, size: .medium, fill: true))
            .disabled(!model.canAdd)
            .dockPill()
            .accessibilityIdentifier("pasteText.addNew")
          }
        }
        .padding(.horizontal, HSpacing.insetPage)
        .padding(.bottom, 8)
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

  private func add(replacing: Bool) {
    Task {
      if await model.add(replacing: replacing) {
        added()
        dismiss()
      }
    }
  }

  private func matchCard(_ match: BankTextMatch) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Already in Hasala?").hType(.overline).foregroundStyle(HColor.textGroupedHeader)
        .accessibilityAddTraits(.isHeader)
      HListCard(alignment: .leading) {
        VStack(alignment: .leading, spacing: 2) {
          Text(PasteBankTextModel.matchTitle(match)).hType(.headline).foregroundStyle(HColor.textPrimary)
          Text(PasteBankTextModel.matchDetail(match, hidden: model.hidden)).hType(.footnote).foregroundStyle(HColor.textSecondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .accessibilityElement(children: .combine)
      }
      TextsNote(text: PasteBankTextModel.matchQuestion(match))
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("pasteText.match")
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
        HListCard(alignment: .leading) {
          VStack(spacing: 0) {
            KeyValueRow("Amount", value: PasteBankTextModel.amountLine(preview))
            HDivider(inset: .none)
            KeyValueRow("Merchant", value: preview.merchant ?? "Not in the text", placeholder: preview.merchant == nil)
            HDivider(inset: .none)
            KeyValueRow(
              "Date", value: preview.date.map(BankTexts.dayAndTime) ?? "When you paste it", placeholder: preview.date == nil)
            if let card = PasteBankTextModel.cardLine(preview) {
              HDivider(inset: .none)
              KeyValueRow("Card", value: card)
            }
          }
          .padding(.horizontal, 16)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pasteText.read")
        if preview.date == nil {
          TextsNote(text: PasteBankTextModel.undatedNote)
            .accessibilityIdentifier("pasteText.undated")
        }
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
