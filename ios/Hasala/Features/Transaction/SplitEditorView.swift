import HasalaDesign
import HasalaModels
import SwiftUI

/// Split (Paper 6N5-0; page 16 · 08 Split editor): the total stays fixed at the top, a bar
/// shows each line in its bucket's hue, and one sentence says whether the lines add up. Each
/// line is a card with its category and an amount field; tapping the field focuses it (the 2
/// pt ring) and the inline amount keypad opens under the list. "Add a category", "Split
/// evenly" and "Put the rest in …" help; "Save split" works only when the lines add up.
/// Amounts show even with Hide amounts on: the editor was opened to change them.
struct SplitEditorView: View {
  let model: any TransactionModel
  let done: () -> Void

  struct Draft: Identifiable, Equatable {
    var id: Int
    var category: CategoryID
    var entry: AmountEntry
    var note: String
    /// The note row shows once there is a note or the person asked for one.
    var showsNote: Bool
  }

  @State private var lines: [Draft] = []
  /// The line whose amount the keypad types into.
  @State private var editing: Int?
  @FocusState private var noteFocus: Int?

  private var total: Int64 { model.detail?.amount.minor ?? 0 }
  private var currency: String { model.detail?.amount.currency ?? Money.home }
  private var amounts: [Int64?] { lines.map { $0.entry.minor } }
  private var verdict: SplitDraftVerdict { TransactionEngine.splitDraftVerdict(amounts, total: Money(minor: total, currency: currency)) }
  private var options: [CategoryOption] { model.categoryGroups.filter { $0.bucket != .other }.flatMap(\.options) }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        if let d = model.detail { header(d) }
        VStack(spacing: 12) {
          ForEach($lines) { $line in lineCard($line) }
          addCard
        }
        FlowLayout(spacing: 8) {
          FilterChip("Split evenly", selected: false) { splitEvenly() }
          if let first = lines.first, let name = name(first.category) {
            FilterChip("Put the rest in \(name)", selected: false) { putRest() }
          }
        }
        Text("Each line counts against its own budget. The bank email stays attached.")
          .hType(.footnote).foregroundStyle(HColor.textSecondary)
          .padding(.horizontal, 4)
        if !(model.detail?.splits.isEmpty ?? true) {
          Button("Remove the split") {
            model.removeSplit()
            done()
          }
          .buttonStyle(.pill(.destructiveText, size: .small))
        }
      }
      .padding(.horizontal, HSpacing.insetPage)
      .padding(.top, 8)
      .padding(.bottom, 24)
    }
    .background(HColor.sheetSurfaceLarge)
    .safeAreaInset(edge: .bottom, spacing: 0) { dock }
    .navigationTitle("Split")
    .navigationBarTitleDisplayMode(.inline)
    .onAppear(perform: seed)
  }

  // MARK: Header

  /// "Carrefour · Fri 9 Oct, 19:12", the fixed total, the split bar, the status.
  private func header(_ d: TransactionDetail) -> some View {
    VStack(spacing: 4) {
      Text("\(d.merchant) · \(d.meta.components(separatedBy: " · ").first ?? "")")
        .hType(.subheadline).foregroundStyle(HColor.textSecondary)
        .multilineTextAlignment(.center)
      MoneyText(d.amount, figure: .large, unit: .unit, color: HColor.moneyOut, unitColor: HColor.textPrimary,
                unitGap: 5)
      SplitBar(lines: lines.map { (hue: hue($0.category), minor: $0.entry.minor ?? 0) }, total: total,
               over: { if case .over = verdict { true } else { false } }())
        .frame(width: 220, height: 8)
        .padding(.top, 6)
        .padding(.bottom, 4)
      status
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 4)
  }

  /// "● Adds up exactly" (green), "12.00 left to place" (amber), "12.00 too much" (red).
  private var status: some View {
    let (words, spoken, tone): (String, String, StatusTone) = switch verdict {
    case .addsUp: ("Adds up exactly", "Adds up exactly", .success)
    case .leftToPlace(let m): ("\(MoneyFormat.string(m.minor)) left to place", "\(Self.dirhams(m)) left to place", .warning)
    case .over(let m): ("\(MoneyFormat.string(m.minor)) too much", "\(Self.dirhams(m)) too much", .error)
    case .emptyLine: ("Every line needs an amount", "Every line needs an amount", .warning)
    }
    return HStack(spacing: 6) {
      Circle().fill(tone == .warning ? HColor.paceFillOverPace : tone.foreground).frame(width: 7, height: 7)
      Text(words).hType(.subheadline.weight(.semibold)).foregroundStyle(tone.foreground)
    }
    // Words, not a control: without the trait the audit takes the element for a small target.
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(spoken)
    .accessibilityAddTraits(.isStaticText)
    .accessibilityIdentifier("split.verdict")
  }

  /// "12 dirhams" / "12 dirhams 50", as VoiceOver should say a figure (page 16 · 08).
  static func dirhams(_ m: Money) -> String {
    let whole = m.minor / 100, fils = m.minor % 100
    if m.currency != Money.home { return "\(m.currency) \(MoneyFormat.string(m.minor))" }
    return fils == 0 ? "\(MoneyFormat.grouped(UInt64(whole))) dirhams" : "\(MoneyFormat.grouped(UInt64(whole))) dirhams \(fils)"
  }

  // MARK: Lines

  /// A line: its category (a menu to change it, add a note, or remove the line), the bucket
  /// under the name, and the amount field; the note row under it when there is one.
  private func lineCard(_ line: Binding<Draft>) -> some View {
    let draft = line.wrappedValue
    let option = options.first { $0.id == draft.category }
    return VStack(spacing: 0) {
      HStack(spacing: 12) {
        Menu {
          Picker("Category", selection: line.category) {
            ForEach(options) { Text($0.name).tag($0.id) }
          }
          if !draft.showsNote {
            Button("Add a note") {
              line.wrappedValue.showsNote = true
              noteFocus = draft.id
            }
          }
          if lines.count > 2 {
            Button("Remove this line", role: .destructive) {
              if editing == draft.id { editing = nil }
              lines.removeAll { $0.id == draft.id }
            }
          }
        } label: {
          HStack(spacing: 12) {
            CategoryDisc(hue: option?.hue ?? .other, icon: (option?.glyph ?? .review).icon)
            VStack(alignment: .leading, spacing: 0) {
              Text(option?.name ?? "Choose").hType(.rowTitle).foregroundStyle(HColor.textPrimary)
              Text(option.map { $0.bucket.label } ?? "").hType(.footnote).foregroundStyle(HColor.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          .contentShape(Rectangle())
        }
        .accessibilityLabel("\(option?.name ?? "Category"), \(option?.bucket.label ?? "")")
        .accessibilityHint("Changes this line's category")
        .accessibilityIdentifier("split.category.\(draft.id)")
        amountField(draft, name: option?.name ?? "Line")
      }
      .padding(.horizontal, 16)
      .frame(minHeight: 72)
      if draft.showsNote {
        HDivider(inset: .disc68)
        HStack(spacing: 12) {
          PathGlyph(PathGlyph.noteLines, size: 20, color: HColor.iconSecondary, stroke: 1.9)
            .frame(width: 40)
          TextField("Add a note", text: line.note)
            .hType(.subheadline)
            .foregroundStyle(HColor.textPrimary)
            .focused($noteFocus, equals: draft.id)
            .accessibilityIdentifier("split.note.\(draft.id)")
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 48)
      }
    }
    .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.card, style: .continuous))
  }

  /// 112 × 44, radius 12, the field grey, the figure 17/22 600 on the right. Focused, it
  /// takes the 2 pt ring and shows a caret; the keypad types into it.
  private func amountField(_ line: Draft, name: String) -> some View {
    let focused = editing == line.id
    let shown = focused ? line.entry.display : (line.entry.minor.map { MoneyFormat.string($0) } ?? "")
    return Button {
      noteFocus = nil
      editing = focused ? nil : line.id
      if !focused { announceStatus() }
    } label: {
      HStack(spacing: 2) {
        Spacer(minLength: 0)
        Text(shown.isEmpty ? "0.00" : shown)
          .hFigure(HFigure(size: 17, leading: 22, weight: .semibold, textStyle: .body, tabular: true))
          .foregroundStyle(shown.isEmpty ? HColor.fieldHint : HColor.fieldText)
          .lineLimit(1)
          .minimumScaleFactor(0.6)
        if focused {
          RoundedRectangle(cornerRadius: 1).fill(HColor.actionAccent).frame(width: 2, height: 20)
        }
      }
      .padding(.horizontal, 14)
      .frame(width: 112)
      .frame(minHeight: 44)
      .background(HColor.fieldSurface, in: RoundedRectangle(cornerRadius: HRadius.control, style: .continuous))
      .overlay {
        if focused {
          RoundedRectangle(cornerRadius: HRadius.control + 2, style: .continuous)
            .strokeBorder(HColor.fieldFocus, lineWidth: 2).padding(-2)
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(name) amount")
    .accessibilityValue(line.entry.minor.map { MoneyFormat.string($0) } ?? "empty")
    .accessibilityHint(focused ? "Type with the keypad below" : "Opens the keypad")
    .accessibilityAddTraits(focused ? .isSelected : [])
    .accessibilityIdentifier("split.amount.\(line.id)")
  }

  /// "Add a category": a dashed card with a white 40 disc and the accent label.
  private var addCard: some View {
    Button(action: addLine) {
      HStack(spacing: 12) {
        Circle().fill(HColor.surfacePrimary).frame(width: 40, height: 40)
          .overlay { HIconView(.add, size: 18, color: HColor.textLink) }
        Text("Add a category").hType(.rowTitle).foregroundStyle(HColor.textLink)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(.horizontal, 16)
      .frame(minHeight: 60)
      .overlay {
        RoundedRectangle(cornerRadius: HRadius.card, style: .continuous)
          .strokeBorder(HColor.neutral300, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(HPressStyle(in: RoundedRectangle(cornerRadius: HRadius.card, style: .continuous), scales: false))
    .accessibilityIdentifier("split.add")
  }

  /// The keypad while a line's amount is being typed, then "Save split".
  private var dock: some View {
    VStack(spacing: 10) {
      if let editing, let i = lines.firstIndex(where: { $0.id == editing }) {
        AmountKeypad(entry: $lines[i].entry, layout: .inline)
          .transition(.opacity)
      }
      Button("Save split", action: save)
        .buttonStyle(.pill(.primary, fill: true))
        .disabled(verdict != .addsUp)
        .accessibilityIdentifier("split.save")
    }
    .padding(.horizontal, HSpacing.insetPage)
    .padding(.top, 12)
    .padding(.bottom, 8)
    .background(HColor.sheetSurfaceLarge.opacity(0.96).ignoresSafeArea(edges: .bottom))
  }

  // MARK: Edits

  private func name(_ id: CategoryID) -> String? { options.first { $0.id == id }?.name }
  private func hue(_ id: CategoryID) -> Hue { options.first { $0.id == id }?.hue ?? .other }

  private func seed() {
    guard lines.isEmpty, let d = model.detail else { return }
    if !d.splits.isEmpty {
      lines = d.splits.map {
        Draft(id: $0.id, category: $0.category.id, entry: AmountEntry(minor: $0.amount.minor), note: $0.note,
              showsNote: !$0.note.isEmpty)
      }
    } else {
      // The whole amount on line 1 in its category, line 2 empty in the first want.
      let first = d.category?.id ?? options.first?.id ?? ""
      let second = options.first { $0.id != first && $0.bucket == .wants }?.id ?? first
      lines = [Draft(id: 1, category: first, entry: AmountEntry(minor: d.amount.minor), note: "", showsNote: false),
               Draft(id: 2, category: second, entry: AmountEntry(), note: "", showsNote: false)]
    }
  }

  private func addLine() {
    let used = Set(lines.map(\.category))
    let category = options.first { !used.contains($0.id) && $0.bucket == .wants }?.id ?? options.first?.id ?? ""
    let id = (lines.map(\.id).max() ?? 0) + 1
    lines.append(Draft(id: id, category: category, entry: AmountEntry(), note: "", showsNote: false))
    editing = id
  }

  private func splitEvenly() {
    guard !lines.isEmpty else { return }
    let n = Int64(lines.count)
    let each = total / n
    for i in lines.indices {
      lines[i].entry = AmountEntry(minor: i == 0 ? total - each * (n - 1) : each)
    }
    editing = nil
    announceStatus()
  }

  private func putRest() {
    guard !lines.isEmpty else { return }
    let others = lines.dropFirst().reduce(Int64(0)) { $0 + ($1.entry.minor ?? 0) }
    lines[0].entry = AmountEntry(minor: max(0, total - others))
    editing = nil
    announceStatus()
  }

  private func save() {
    let parsed = lines.compactMap { l in
      l.entry.minor.map { SplitLine(id: l.id, categoryID: l.category, amount: Money(minor: $0, currency: currency), note: l.note) }
    }
    if model.saveSplit(parsed) { done() }
  }

  /// After an edit, VoiceOver hears where the split stands ("Adds up exactly").
  private func announceStatus() {
    let line: String = switch verdict {
    case .addsUp: "Adds up exactly"
    case .leftToPlace(let m): "\(Self.dirhams(m)) left to place"
    case .over(let m): "\(Self.dirhams(m)) too much"
    case .emptyLine: "Every line needs an amount"
    }
    AccessibilityNotification.Announcement(line).post()
  }
}

/// The split bar (220 × 8, gap 3, radius 4): one segment per line in its bucket's hue, as wide
/// as its share. Short, a grey gap stays at the end; over, the last segment turns red. Hidden
/// from VoiceOver: the status says it in words.
private struct SplitBar: View {
  let lines: [(hue: Hue, minor: Int64)]
  let total: Int64
  let over: Bool

  var body: some View {
    GeometryReader { geo in
      let placed = max(total, lines.reduce(0) { $0 + max(0, $1.minor) })
      let shown = lines.filter { $0.minor > 0 }
      let gaps = CGFloat(max(0, shown.count - 1)) * 3
      let width = max(0, geo.size.width - gaps)
      HStack(spacing: 3) {
        ForEach(Array(shown.enumerated()), id: \.offset) { i, line in
          let share = placed > 0 ? CGFloat(line.minor) / CGFloat(placed) : 0
          RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(over && i == shown.count - 1 ? AnyShapeStyle(HColor.paceOverBudget) : AnyShapeStyle(line.hue.dotGradient))
            .frame(width: max(4, width * share))
        }
        Spacer(minLength: 0)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(HColor.paceTrack, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
    .accessibilityHidden(true)
  }
}
