import CoreDomain
import HasalaDesign
import HasalaModels
import HasalaText
import SwiftUI

// The pages that push inside the transaction sheet (Paper "Activity · Choose a category"
// 5PR-0, "Activity · Split" 6N5-0, and the note and rename editors the boards name). Each
// saves one edit and pops back to the sheet.

/// Choose a category (Paper 5PR-0): the transaction, a search field, the suggestion, "Always
/// use X for M" with its switch, every category as choice chips by bucket, and Save in a bar
/// that floats over the list.
struct CategoryPickerView: View {
  let model: any TransactionModel
  let done: () -> Void

  @State private var selected: CategoryID?
  @State private var alwaysUse = false

  private var direction: Direction { model.detail?.isIncome == true ? .in : .out }

  private var suggestion: CategoryOption? {
    model.detail?.suggestion.flatMap { CategoryGroup.offers($0.id, for: direction) ? $0 : nil }
  }

  var body: some View {
    ScrollView {
      CategoryChooser(groups: CategoryGroup.ordered(model.categoryGroups, for: direction), selected: selected,
                      suggestion: suggestion, idPrefix: "picker", choose: { selected = $0 }) {
        if let d = model.detail { transaction(d) }
      } accessory: {
        if model.detail?.canAlwaysUse == true { ruleCard }
      }
      .padding(.horizontal, HSpacing.insetPage)
      .padding(.top, 8)
      .padding(.bottom, 24)
    }
    .background(HColor.sheetSurfaceLarge)
    .safeAreaInset(edge: .bottom, spacing: 0) {
      Button("Save") {
        let rule = alwaysUse && model.detail?.canAlwaysUse == true
        if let selected, Self.changes(model.detail, to: selected, alwaysUse: rule) {
          model.choose(selected, alwaysUse: rule)
        }
        done()
      }
      .buttonStyle(.pill(.primary, fill: true))
      .disabled(selected == nil)
      .accessibilityIdentifier("picker.save")
      .padding(.horizontal, HSpacing.insetPage)
      .padding(.top, 36)
      .padding(.bottom, 8)
      .background {
        // Paper "Bottom bar · Save": the canvas, solid to 58%, then clear above.
        LinearGradient(stops: [.init(color: HColor.sheetSurfaceLarge.opacity(0), location: 0),
                               .init(color: HColor.sheetSurfaceLarge, location: 0.42)],
                       startPoint: .top, endPoint: .bottom)
          .ignoresSafeArea(edges: .bottom)
          .allowsHitTesting(false)
      }
    }
    .navigationTitle("Category")
    .navigationBarTitleDisplayMode(.inline)
    .onAppear {
      guard selected == nil else { return }
      selected = Self.initial(model.detail)
    }
  }

  /// The row being sorted, as Activity lists it.
  private func transaction(_ d: TransactionDetail) -> some View {
    let home = d.home ?? HomeAmount(shown: d.amount)
    return HListCard {
      HListRow(leading: d.monogram.map { .monogram($0) } ?? .disc(d.hue, d.glyph.icon), title: d.merchant,
               supporting: .wrapping(d.meta),
               trailing: home.notCounted ? .value("Not counted") : .amount(home.shown, in: d.isIncome, approx: home.estimate),
               hidden: model.hidden)
    }
  }

  /// "Always use Groceries for Lulu Hypermarket" with the switch.
  private var ruleCard: some View {
    let merchant = model.merchantName
    return VStack(spacing: 0) {
      Toggle(isOn: $alwaysUse) {
        HStack(alignment: .top, spacing: 14) {
          HIconView(.rule, size: 22, color: HColor.iconPrimary)
          VStack(alignment: .leading, spacing: 4) {
            Text(Self.alwaysUseTitle(category: selectedName, merchant: merchant))
              .hType(.rowTitle).foregroundStyle(HColor.textPrimary)
              .fixedSize(horizontal: false, vertical: true)
            Text(Self.alwaysUseFootnote(merchant: merchant))
              .hType(.footnote).foregroundStyle(HColor.textSecondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
      .tint(HColor.controlSwitchTrackOn)
      .padding(.vertical, 14)
      .padding(.horizontal, 16)
      .accessibilityIdentifier("picker.alwaysUse")
    }
    .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.card, style: .continuous))
  }

  private var selectedName: String? {
    model.categoryGroups.lazy.flatMap(\.options).first { $0.id == selected }?.name
  }

  static func alwaysUseTitle(category: String?, merchant: String) -> String {
    "Always use \(category.map(Bidi.isolate) ?? "this category") for \(Bidi.isolate(merchant))"
  }

  static func alwaysUseFootnote(merchant: String) -> String {
    "Also re-files \(Bidi.isolate(merchant))\u{2019}s other transactions, except ones you sorted. Undo puts them back."
  }

  static func initial(_ detail: TransactionDetail?) -> CategoryID? {
    guard let detail else { return nil }
    let direction: Direction = detail.isIncome ? .in : .out
    let suggestion = detail.suggestion.flatMap { CategoryGroup.offers($0.id, for: direction) ? $0.id : nil }
    if detail.needsReview, let suggestion { return suggestion }
    return detail.category?.id ?? suggestion
  }

  static func changes(_ detail: TransactionDetail?, to selected: CategoryID, alwaysUse: Bool) -> Bool {
    guard let detail, detail.category?.id == selected, !detail.needsReview else { return true }
    return alwaysUse && !detail.sortedByRule
  }
}

struct CategoryChooser<Leading: View, Accessory: View>: View {
  let groups: [CategoryGroup]
  let selected: CategoryID?
  var suggestion: CategoryOption?
  let idPrefix: String
  let choose: (CategoryID) -> Void
  let leading: () -> Leading
  let accessory: () -> Accessory
  @State private var query = ""

  init(groups: [CategoryGroup], selected: CategoryID?, suggestion: CategoryOption? = nil, idPrefix: String,
       choose: @escaping (CategoryID) -> Void,
       @ViewBuilder leading: @escaping () -> Leading,
       @ViewBuilder accessory: @escaping () -> Accessory) {
    self.groups = groups
    self.selected = selected
    self.suggestion = suggestion
    self.idPrefix = idPrefix
    self.choose = choose
    self.leading = leading
    self.accessory = accessory
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      leading()
      searchField
      if let s = suggestion, !CategoryGroup.matching([CategoryGroup(bucket: s.bucket, options: [s])], query).isEmpty {
        group("Suggested", [s], suggested: true)
      }
      accessory()
      let shown = CategoryGroup.matching(groups, query)
      ForEach(shown) { g in group(g.bucket.label, g.options, suggested: false) }
      if shown.isEmpty {
        Text("No category matches \u{201C}\(query.trimmedSpaces)\u{201D}.")
          .hType(.subheadline).foregroundStyle(HColor.textSecondary)
          .padding(.horizontal, 4)
          .accessibilityIdentifier("\(idPrefix).noMatch")
      }
    }
  }

  private var searchField: some View {
    HStack(spacing: 10) {
      HIconView(.magnifier, size: 20, color: HColor.fieldIcon)
      TextField("Search categories", text: $query, prompt: .fieldPrompt("Search categories"))
        .hType(.body)
        .foregroundStyle(HColor.fieldText)
        .submitLabel(.search)
        .autocorrectionDisabled()
        .accessibilityIdentifier("\(idPrefix).search")
    }
    .padding(.horizontal, 16)
    .frame(minHeight: 52)
    .background(HColor.fieldSurfaceOnGrouped, in: RoundedRectangle(cornerRadius: HRadius.field, style: .continuous))
  }

  private func group(_ title: String, _ options: [CategoryOption], suggested: Bool) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title).hType(.overline).foregroundStyle(HColor.textGroupedHeader)
        .padding(.leading, 4).padding(.top, 2)
        .accessibilityAddTraits(.isHeader)
      FlowLayout(spacing: 8) {
        ForEach(options) { o in
          ChoiceChip(o.name, dot: o.hue, selected: selected == o.id) { choose(o.id) }
            .accessibilityIdentifier(suggested ? "\(idPrefix).suggested.\(o.id)" : "\(idPrefix).\(o.id)")
        }
      }
    }
  }
}

/// Note (spec 04 §16.2 T1 `NoteEditorView`): `txn_annotated{note}`.
struct NoteEditorView: View {
  @State var note: String
  let save: (String) -> Void
  private let original: String
  @FocusState private var focused: Bool

  init(note: String, save: @escaping (String) -> Void) {
    _note = State(initialValue: note)
    original = note
    self.save = save
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      TextField("Add a note", text: $note, prompt: .fieldPrompt("Add a note"), axis: .vertical)
        .hType(.body)
        .foregroundStyle(HColor.fieldText)
        .lineLimit(3...8)
        .focused($focused)
        .padding(16)
        .background(HColor.fieldSurfaceOnGrouped, in: RoundedRectangle(cornerRadius: HRadius.field, style: .continuous))
        .accessibilityIdentifier("note.field")
      TextLimitLine("Notes stay with the transaction and are encrypted like everything else.",
                    limit: .note, text: note, id: "note.count")
      Spacer()
      Button("Save note") { save(note) }
        .buttonStyle(.pill(.primary, fill: true))
        .disabled(note == original || TextLimit.note.isOver(note))
        .accessibilityIdentifier("note.save")
    }
    .padding(HSpacing.insetPage)
    .background(HColor.sheetSurfaceLarge)
    .navigationTitle("Note")
    .navigationBarTitleDisplayMode(.inline)
    .task { focused = true }
  }
}

/// Rename merchant (spec 04 §16.2 T1 `RenameMerchantView`): `merchant_named{key, name}`.
struct RenameMerchantView: View {
  @State var name: String
  let save: (String) -> Void
  private let original: String
  @FocusState private var focused: Bool

  init(name: String, save: @escaping (String) -> Void) {
    _name = State(initialValue: name)
    original = name
    self.save = save
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      TextField("Merchant name", text: $name, prompt: .fieldPrompt("Merchant name"))
        .hType(.body)
        .foregroundStyle(HColor.fieldText)
        .focused($focused)
        .submitLabel(.done)
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
        .background(HColor.fieldSurfaceOnGrouped, in: RoundedRectangle(cornerRadius: HRadius.field, style: .continuous))
        .accessibilityIdentifier("rename.field")
      TextLimitLine(Self.hint(original), limit: .label, text: name, id: "rename.count")
      Spacer()
      Button("Rename") { save(name) }
        .buttonStyle(.pill(.primary, fill: true))
        .disabled(name.trimmedSpaces.isEmpty || name == original || TextLimit.label.isOver(name))
        .accessibilityIdentifier("rename.save")
    }
    .padding(HSpacing.insetPage)
    .background(HColor.sheetSurfaceLarge)
    .navigationTitle("Rename merchant")
    .navigationBarTitleDisplayMode(.inline)
    .task { focused = true }
  }

  static func hint(_ original: String) -> String {
    "Every transaction from \(Bidi.isolate(original)) shows the new name. The bank email keeps its own."
  }
}

struct TextLimit: Equatable {
  let scalars: Int
  let bytes: Int

  static let label = TextLimit(scalars: TextRules.labelMaxScalars, bytes: TextRules.labelMaxBytes)
  static let note = TextLimit(scalars: TextRules.noteMaxScalars, bytes: TextRules.noteMaxBytes)

  static func stored(_ typed: String) -> String {
    UserText.normalize(typed)
  }

  func count(_ typed: String) -> Int { Self.stored(typed).unicodeScalars.count }

  func isOver(_ typed: String) -> Bool {
    let s = Self.stored(typed)
    return s.unicodeScalars.count > scalars || s.utf8.count > bytes
  }

  func nearsLimit(_ typed: String) -> Bool { isOver(typed) || count(typed) * 5 >= scalars * 4 }
}

struct TextLimitCounter: View {
  let limit: TextLimit
  let text: String
  let id: String

  var body: some View {
    let over = limit.isOver(text)
    Text("\(limit.count(text)) of \(limit.scalars)")
      .hType(.footnote.weight(over ? .semibold : .regular))
      .monospacedDigit()
      .foregroundStyle(over ? HColor.statusErrorForeground : HColor.textSecondary)
      .accessibilityLabel(over ? "Too long. \(limit.count(text)) of \(limit.scalars) characters" : "\(limit.count(text)) of \(limit.scalars) characters")
      .accessibilityIdentifier(id)
  }
}

private struct TextLimitLine: View {
  let hint: String
  let limit: TextLimit
  let text: String
  let id: String
  @Environment(\.dynamicTypeSize) private var typeSize

  init(_ hint: String, limit: TextLimit, text: String, id: String) {
    self.hint = hint
    self.limit = limit
    self.text = text
    self.id = id
  }

  var body: some View {
    let layout = typeSize.isAccessibilitySize
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
      : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))
    layout {
      Text(hint).hType(.footnote).foregroundStyle(HColor.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
      TextLimitCounter(limit: limit, text: text, id: id).fixedSize()
    }
    .padding(.horizontal, 4)
  }
}
