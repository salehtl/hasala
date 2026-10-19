import HasalaDesign
import HasalaModels
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
  @State private var alwaysUse = true
  @State private var query = ""

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        if let d = model.detail { transaction(d) }
        searchField
        if let s = model.detail?.suggestion, matches(s) {
          group("Suggested", [s])
        }
        ruleCard
        ForEach(groups) { g in group(g.bucket.label, g.options) }
      }
      .padding(.horizontal, HSpacing.insetPage)
      .padding(.top, 8)
      .padding(.bottom, 24)
    }
    .background(HColor.sheetSurfaceLarge)
    .safeAreaInset(edge: .bottom, spacing: 0) {
      Button("Save") {
        if let selected { model.choose(selected, alwaysUse: alwaysUse) }
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
      selected = model.detail?.category?.id ?? model.detail?.suggestion?.id
      // A merchant still in review is new to the plan: teaching a rule is the likely wish.
      alwaysUse = model.detail?.needsReview ?? true
    }
  }

  /// The row being sorted, as Activity lists it.
  private func transaction(_ d: TransactionDetail) -> some View {
    HListCard {
      HListRow(leading: d.monogram.map { .monogram($0) } ?? .disc(d.hue, d.glyph.icon), title: d.merchant,
               supporting: .text(d.meta), trailing: .amount(d.amount, in: d.isIncome), hidden: model.hidden)
    }
  }

  /// "Search categories": white on the grey sheet, 52 tall, radius 14.
  private var searchField: some View {
    HStack(spacing: 10) {
      HIconView(.magnifier, size: 20, color: HColor.fieldIcon)
      TextField("Search categories", text: $query)
        .hType(.body)
        .foregroundStyle(HColor.fieldText)
        .submitLabel(.search)
        .autocorrectionDisabled()
        .accessibilityIdentifier("picker.search")
    }
    .padding(.horizontal, 16)
    .frame(minHeight: 52)
    .background(HColor.fieldSurfaceOnGrouped, in: RoundedRectangle(cornerRadius: HRadius.field, style: .continuous))
  }

  /// "Always use Groceries for Lulu Hypermarket" with the switch.
  private var ruleCard: some View {
    let merchant = model.merchantName
    return VStack(spacing: 0) {
      Toggle(isOn: $alwaysUse) {
        HStack(alignment: .top, spacing: 14) {
          HIconView(.rule, size: 22, color: HColor.iconPrimary)
          VStack(alignment: .leading, spacing: 4) {
            Text("Always use \(selectedName ?? "this category") for \(merchant)")
              .hType(.rowTitle).foregroundStyle(HColor.textPrimary)
              .fixedSize(horizontal: false, vertical: true)
            Text("Next time, \(merchant) is sorted for you. Undo any time in Rules.")
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

  /// An overline and its chips, wrapping (never scrolling sideways). Picking one selects it
  /// at once and clears the old one; the dot keeps its hue.
  private func group(_ title: String, _ options: [CategoryOption]) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title).hType(.overline).foregroundStyle(HColor.textGroupedHeader)
        .padding(.leading, 4).padding(.top, 2)
        .accessibilityAddTraits(.isHeader)
      FlowLayout(spacing: 8) {
        ForEach(options) { o in
          ChoiceChip(o.name, dot: o.hue, selected: selected == o.id) { selected = o.id }
            .accessibilityIdentifier(title == "Suggested" ? "picker.suggested.\(o.id)" : "picker.\(o.id)")
        }
      }
    }
  }

  private var selectedName: String? {
    model.categoryGroups.lazy.flatMap(\.options).first { $0.id == selected }?.name
  }

  private func matches(_ o: CategoryOption) -> Bool {
    let q = query.trimmedSpaces.lowercased()
    return q.isEmpty || o.name.lowercased().contains(q)
  }

  private var groups: [CategoryGroup] {
    model.categoryGroups.map { g in CategoryGroup(bucket: g.bucket, options: g.options.filter(matches)) }
      .filter { !$0.options.isEmpty }
  }
}

/// Note (spec 04 §16.2 T1 `NoteEditorView`): `txn_annotated{note}`.
struct NoteEditorView: View {
  @State var note: String
  let save: (String) -> Void
  @FocusState private var focused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      TextField("Add a note", text: $note, axis: .vertical)
        .hType(.body)
        .foregroundStyle(HColor.fieldText)
        .lineLimit(3...8)
        .focused($focused)
        .padding(16)
        .background(HColor.fieldSurfaceOnGrouped, in: RoundedRectangle(cornerRadius: HRadius.field, style: .continuous))
        .accessibilityIdentifier("note.field")
      Text("Notes stay with the transaction and are encrypted like everything else.")
        .hType(.footnote).foregroundStyle(HColor.textSecondary)
        .padding(.horizontal, 4)
      Spacer()
      Button("Save note") { save(note) }
        .buttonStyle(.pill(.primary, fill: true))
        .accessibilityIdentifier("note.save")
    }
    .padding(HSpacing.insetPage)
    .background(HColor.sheetSurfaceLarge)
    .navigationTitle("Note")
    .navigationBarTitleDisplayMode(.inline)
  }
}

/// Rename merchant (spec 04 §16.2 T1 `RenameMerchantView`): `merchant_named{key, name}`.
struct RenameMerchantView: View {
  @State var name: String
  let save: (String) -> Void
  private let original: String

  init(name: String, save: @escaping (String) -> Void) {
    _name = State(initialValue: name)
    original = name
    self.save = save
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      TextField("Merchant name", text: $name)
        .hType(.body)
        .foregroundStyle(HColor.fieldText)
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
        .background(HColor.fieldSurfaceOnGrouped, in: RoundedRectangle(cornerRadius: HRadius.field, style: .continuous))
        .accessibilityIdentifier("rename.field")
      Text("Every transaction from \(original) shows the new name. The bank email keeps its own.")
        .hType(.footnote).foregroundStyle(HColor.textSecondary)
        .padding(.horizontal, 4)
      Spacer()
      Button("Rename") { save(name) }
        .buttonStyle(.pill(.primary, fill: true))
        .disabled(name.trimmedSpaces.isEmpty || name == original)
        .accessibilityIdentifier("rename.save")
    }
    .padding(HSpacing.insetPage)
    .background(HColor.sheetSurfaceLarge)
    .navigationTitle("Rename merchant")
    .navigationBarTitleDisplayMode(.inline)
  }
}
