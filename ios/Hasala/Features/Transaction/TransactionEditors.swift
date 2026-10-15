import HasalaDesign
import HasalaModels
import SwiftUI

/// Choose a category (Paper board): search, the suggestion, "Always use X for M",
/// "Add to a project", categories grouped by bucket, and Save.
struct CategoryPickerView: View {
  let model: any TransactionModel
  let done: () -> Void

  @State private var selected: CategoryID?
  @State private var alwaysUse = true
  @State private var project: ProjectID?
  @State private var query = ""

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        TextField("Search categories", text: $query)
          .hType(.body)
          .padding(.horizontal, 14)
          .frame(minHeight: 44)
          .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.field, style: .continuous))
          .accessibilityIdentifier("picker.search")

        VStack(spacing: 0) {
          Toggle(isOn: $alwaysUse) {
            VStack(alignment: .leading, spacing: 2) {
              Text("Always use \(selectedName ?? "this category") for \(model.merchantName)")
                .hType(.rowTitle).foregroundStyle(HColor.textPrimary)
              Text("Next time, \(model.merchantName) is sorted for you. Undo any time in Rules.")
                .hType(.footnote).foregroundStyle(HColor.textSecondary)
            }
          }
          .tint(HColor.actionAccent)
          .padding(16)
          .accessibilityIdentifier("picker.alwaysUse")
          if !model.projects.isEmpty {
            Divider().padding(.leading, 16)
            HStack {
              Text("Add to a project").hType(.callout).foregroundStyle(HColor.textPrimary)
              Spacer()
              Picker("Add to a project", selection: $project) {
                Text("None").tag(ProjectID?.none)
                ForEach(model.projects, id: \.id) { Text($0.name).tag(ProjectID?.some($0.id)) }
              }
              .labelsHidden()
              .tint(HColor.textSecondary)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: HSpacing.listRowMinHeight)
          }
        }
        .listCard()

        ForEach(groups) { group in
          VStack(alignment: .leading, spacing: 10) {
            Text(group.bucket.label).hType(.overline).foregroundStyle(HColor.textSecondary)
            FlowLayout(spacing: 8) {
              ForEach(group.options) { option in
                let isOn = selected == option.id
                Button { selected = option.id } label: {
                  HStack(spacing: 6) {
                    Circle().fill(isOn ? HColor.white : option.hue.end).frame(width: 8, height: 8)
                    Text(option.name).hType(.buttonSmall)
                  }
                  .foregroundStyle(isOn ? HColor.chipTextSelected : HColor.chipText)
                  .padding(.horizontal, 14)
                  .frame(minHeight: HSpacing.chipHeight)
                  .background(isOn ? HColor.chipSurfaceSelected : HColor.chipSurface, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn ? .isSelected : [])
                .accessibilityIdentifier("picker.\(option.id)")
              }
            }
          }
        }
      }
      .padding(HSpacing.insetPage)
      .padding(.bottom, 80)
    }
    .background(HColor.surfaceSecondary)
    .safeAreaInset(edge: .bottom) {
      Button("Save") {
        if let selected { model.choose(selected, alwaysUse: alwaysUse, project: project) }
        done()
      }
      .buttonStyle(.pill(.primary, fill: true))
      .disabled(selected == nil)
      .padding(.horizontal, HSpacing.insetPage)
      .padding(.bottom, 8)
      .accessibilityIdentifier("picker.save")
    }
    .navigationTitle("Category")
    .navigationBarTitleDisplayMode(.inline)
    .onAppear {
      selected = model.detail?.category?.id
      alwaysUse = model.detail?.needsReview ?? true
    }
  }

  private var selectedName: String? {
    groups.lazy.flatMap(\.options).first { $0.id == selected }?.name
      ?? model.categoryGroups.lazy.flatMap(\.options).first { $0.id == selected }?.name
  }

  private var groups: [CategoryGroup] {
    let q = query.trimmedSpaces.lowercased()
    guard !q.isEmpty else { return model.categoryGroups }
    return model.categoryGroups.map { g in
      CategoryGroup(bucket: g.bucket, options: g.options.filter { $0.name.lowercased().contains(q) })
    }.filter { !$0.options.isEmpty }
  }
}

/// Note (spec 04 §16.2 T1 `NoteEditorView`): `txn_annotated{note}`.
struct NoteEditorView: View {
  @State var note: String
  let save: (String) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      TextField("Add a note", text: $note, axis: .vertical)
        .hType(.body)
        .lineLimit(3...8)
        .padding(14)
        .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.field, style: .continuous))
        .accessibilityIdentifier("note.field")
      Text("Notes stay with the transaction and are encrypted like everything else.")
        .hType(.footnote).foregroundStyle(HColor.textSecondary)
      Spacer()
      Button("Save note") { save(note) }
        .buttonStyle(.pill(.primary, fill: true))
        .accessibilityIdentifier("note.save")
    }
    .padding(HSpacing.insetPage)
    .background(HColor.surfaceSecondary)
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
        .padding(.horizontal, 14)
        .frame(minHeight: 52)
        .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.field, style: .continuous))
        .accessibilityIdentifier("rename.field")
      Text("Every transaction from \(original) shows the new name. The bank email keeps its own.")
        .hType(.footnote).foregroundStyle(HColor.textSecondary)
      Spacer()
      Button("Rename") { save(name) }
        .buttonStyle(.pill(.primary, fill: true))
        .disabled(name.trimmedSpaces.isEmpty || name == original)
        .accessibilityIdentifier("rename.save")
    }
    .padding(HSpacing.insetPage)
    .background(HColor.surfaceSecondary)
    .navigationTitle("Rename merchant")
    .navigationBarTitleDisplayMode(.inline)
  }
}

/// Split (Paper board): lines that must add up to the transaction, each with its own
/// category; "Split evenly" and "Put the rest in X".
struct SplitEditorView: View {
  let model: any TransactionModel
  let done: () -> Void

  struct Draft: Identifiable, Equatable {
    var id: Int
    var category: CategoryID
    var amount: String
    var note: String
  }

  @State private var lines: [Draft] = []

  private var total: Int64 { model.detail?.amount.minor ?? 0 }
  private var check: SplitDraftVerdict {
    TransactionEngine.splitDraftVerdict(lines.map { MoneyFormat.parseMinor($0.amount) }, total: .aed(total))
  }
  private var options: [CategoryOption] { model.categoryGroups.filter { $0.bucket != .other }.flatMap(\.options) }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        if let d = model.detail {
          VStack(alignment: .leading, spacing: 6) {
            Text("\(d.merchant) · \(d.meta.components(separatedBy: " · ").first ?? "")")
              .hType(.subheadline).foregroundStyle(HColor.textSecondary)
            MoneyText(d.amount, figure: .large, unit: .unit, hidden: model.hidden, color: HColor.textPrimary, unitGap: 5)
            verdict
          }
        }
        ForEach($lines) { $line in
          VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
              let option = options.first { $0.id == line.category }
              HueDisc(hue: option?.hue ?? .other, glyph: option?.glyph ?? .review)
              Picker("Category", selection: $line.category) {
                ForEach(options) { Text($0.name).tag($0.id) }
              }
              .labelsHidden()
              .tint(HColor.textPrimary)
              Spacer(minLength: 8)
              // Inputs show real values while editing (spec 04 §12).
              TextField("0.00", text: $line.amount)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .font(.system(.callout, design: .rounded, weight: .bold).monospacedDigit())
                .frame(width: 110, height: 44)
                .padding(.horizontal, 10)
                .background(HColor.surfaceSecondary, in: RoundedRectangle(cornerRadius: HRadius.control))
                .accessibilityIdentifier("split.amount.\(line.id)")
            }
            TextField("Add a note", text: $line.note)
              .hType(.footnote)
              .foregroundStyle(HColor.textSecondary)
          }
          .padding(16)
          .listCard()
          .overlay(alignment: .topTrailing) {
            if lines.count > 2 {
              Button { lines.removeAll { $0.id == line.id } } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 20))
                  .foregroundStyle(HColor.iconTertiary)
                  .frame(width: 44, height: 44)
              }
              .accessibilityLabel("Remove this line")
              .offset(x: 14, y: -14)
            }
          }
        }
        Button {
          lines.append(Draft(id: (lines.map(\.id).max() ?? 0) + 1, category: options.first?.id ?? "", amount: "",
                             note: ""))
        } label: {
          Label("Add a category", systemImage: "plus")
            .hType(.rowTitle)
            .frame(maxWidth: .infinity, minHeight: 52)
            .overlay(RoundedRectangle(cornerRadius: HRadius.listGroup)
              .strokeBorder(HColor.textSecondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
        }
        .buttonStyle(.plain)
        .foregroundStyle(HColor.textLink)
        .accessibilityIdentifier("split.add")

        HStack(spacing: 8) {
          FilterChip("Split evenly", selected: false) { splitEvenly() }
          if let first = lines.first, let name = options.first(where: { $0.id == first.category })?.name {
            FilterChip("Put the rest in \(name)", selected: false) { putRest() }
          }
        }
        Text("Each line counts against its own budget. The bank email stays attached.")
          .hType(.footnote).foregroundStyle(HColor.textSecondary)
        if !(model.detail?.splits.isEmpty ?? true) {
          Button("Remove the split") { model.removeSplit(); done() }
            .buttonStyle(.pill(.destructiveText, size: .small))
        }
      }
      .padding(HSpacing.insetPage)
      .padding(.bottom, 80)
    }
    .background(HColor.surfaceSecondary)
    .safeAreaInset(edge: .bottom) {
      Button("Save split") {
        let parsed = lines.compactMap { l in
          MoneyFormat.parseMinor(l.amount).map { SplitLine(id: l.id, categoryID: l.category, amount: .aed($0), note: l.note) }
        }
        if model.saveSplit(parsed) { done() }
      }
      .buttonStyle(.pill(.primary, fill: true))
      .disabled(check != .addsUp)
      .padding(.horizontal, HSpacing.insetPage)
      .padding(.bottom, 8)
      .accessibilityIdentifier("split.save")
    }
    .navigationTitle("Split")
    .navigationBarTitleDisplayMode(.inline)
    .onAppear(perform: seed)
  }

  /// "● Adds up exactly", what is left to place or over, or that a line is empty.
  private var verdict: some View {
    let parts: [PlanDetailPart] = switch check {
    case .addsUp: [.status("Adds up exactly", .success)]
    case .leftToPlace(let m): [.status("Left to place", .warning), .text(MoneyPhrase([.amount(m)]))]
    case .over(let m): [.status("Over by", .warning), .text(MoneyPhrase([.amount(m)]))]
    case .emptyLine: [.status("Every line needs an amount", .warning)]
    }
    return DetailLine(parts: parts, hidden: model.hidden).accessibilityIdentifier("split.verdict")
  }

  private func seed() {
    guard lines.isEmpty, let d = model.detail else { return }
    if !d.splits.isEmpty {
      lines = d.splits.map { Draft(id: $0.id, category: $0.category.id, amount: MoneyFormat.draft($0.amount.minor),
                                   note: $0.note) }
    } else {
      let first = d.category?.id ?? options.first?.id ?? ""
      let second = options.first { $0.id != first && $0.bucket == .wants }?.id ?? first
      lines = [Draft(id: 1, category: first, amount: MoneyFormat.draft(d.amount.minor), note: ""),
               Draft(id: 2, category: second, amount: "", note: "")]
    }
  }

  private func splitEvenly() {
    guard !lines.isEmpty else { return }
    let n = Int64(lines.count)
    let each = total / n
    for i in lines.indices {
      let share = i == 0 ? total - each * (n - 1) : each
      lines[i].amount = MoneyFormat.draft(share)
    }
  }

  private func putRest() {
    guard !lines.isEmpty else { return }
    let others = lines.dropFirst().reduce(Int64(0)) { $0 + (MoneyFormat.parseMinor($1.amount) ?? 0) }
    lines[0].amount = MoneyFormat.draft(max(0, total - others))
  }
}
