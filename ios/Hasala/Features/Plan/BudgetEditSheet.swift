import HasalaDesign
import HasalaModels
import SwiftUI

/// Change a category's budget (Paper "Plan · Change Dining's budget (sheet)", 4B6-0): a white
/// medium sheet that fits its content. The math row (Budget, Spent, Left), the new budget
/// between − and +, quick chips, where the money comes from, what Ready to assign becomes,
/// and "Set Dining to AED 1,800". Saving happens only on that button; Close, a swipe down and
/// a tap on the scrim all cancel.
///
/// "Take it from" pushes the sources inside the sheet. A rise from Ready to assign sets the
/// budget; a rise from another category moves money from it; a cut gives the money back to
/// Ready to assign.
struct BudgetEditSheet: View {
  let model: any BudgetSheetModel
  @State private var draft = ""
  /// Ready to assign while it has money (Paper's default), else the first place that has some.
  @State private var source: CategoryID?
  @State private var picking = false
  @State private var fitted: CGFloat = 0
  /// Large at the accessibility sizes, decided when the sheet opens: a text size changed
  /// while it is up resizes the content, not the kind of sheet.
  @State private var opensLarge: Bool?
  @FocusState private var typing: Bool
  @Environment(\.dismiss) private var dismiss
  @Environment(\.dynamicTypeSize) private var typeSize

  init(model: any BudgetSheetModel) {
    self.model = model
    // The budget and where it comes from are there from the first frame, so the fitted
    // sheet is measured once, at its final height, and does not resize after it rises.
    if let row = model.row {
      _draft = State(initialValue: PlanAmountField.text(for: row.budget.minor))
      _source = State(initialValue: model.sources(to: row.id).first?.id)
    }
  }

  private var amount: Int64? { MoneyFormat.parseMinor(draft) }

  var body: some View {
    NavigationStack {
      Group {
        if let row = model.row {
          ScrollView {
            content(row)
              .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fitted = $0 }
          }
          .scrollBounceBehavior(.basedOnSize)
          // The fitted detent leaves the bottom safe area out; the content's own 28 is the
          // margin under the button (page 14 §06). Large, it scrolls clear of the indicator.
          .ignoresSafeArea(.container, edges: (opensLarge ?? typeSize.isAccessibilitySize) ? [] : .bottom)
        } else {
          EmptyStateCard(icon: .tag, tone: .neutral, title: "This category is gone",
                         message: "It was archived or removed.")
        }
      }
      .background(HColor.sheetSurface)
      .toolbar(.hidden, for: .navigationBar)
      .navigationDestination(isPresented: $picking) {
        SourcePickerPage(title: "Take it from", sources: sources, selected: chosen?.id, hidden: model.hidden,
                         onCard: false) { id in
          source = id
          picking = false
        }
      }
    }
    // At the accessibility sizes the sheet is large and scrolls (page 14 §10).
    .planMediumSheet(height: fitted, large: opensLarge ?? typeSize.isAccessibilitySize)
    .onAppear { if opensLarge == nil { opensLarge = typeSize.isAccessibilitySize } }
  }

  // MARK: Content

  private func content(_ row: PlanRowModel) -> some View {
    VStack(spacing: 20) {
      PlanSheetHeader(title: "\(row.name) budget", closeID: "budget.close") { dismiss() }
      mathRow(row)
      VStack(alignment: .leading, spacing: 12) {
        PlanOverline("New budget")
        stepper
        chips(row)
      }
      sourceField(row)
      commit(row)
    }
    // The grabber sits 8 from the top; the header 20 under it (page 14 §05).
    .padding(.top, 33)
    .padding(.horizontal, HSpacing.sheetPadding)
    .padding(.bottom, 28)
    .toolbar {
      ToolbarItemGroup(placement: .keyboard) {
        Spacer()
        Button("Done") { typing = false }
      }
    }
  }

  /// "Budget 1,600 | Spent 642.75 | Left 957.25" on the grey strip. At the accessibility
  /// sizes the three go one under the other, each figure on its label's line, so none has to
  /// shrink into a third of the width.
  private func mathRow(_ row: PlanRowModel) -> some View {
    let left = row.budget.minor.minus(row.spent.minor)
    let cells: [(String, Money, MoneyStyle)] = [
      ("Budget", row.budget, .compact), ("Spent", row.spent, .exact),
      (left < 0 ? "Over" : "Left", .aed(abs(left)), .exact),
    ]
    let stacked = typeSize.isAccessibilitySize
    func figure(_ i: Int) -> some View {
      MoneyText(cells[i].1, figure: .stat, style: cells[i].2, hidden: model.hidden, hiddenGlyphs: 4,
                color: i == 2 && left < 0 ? HColor.statusErrorForeground : HColor.textPrimary)
    }
    let layout = stacked ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
    return layout {
      ForEach(Array(cells.enumerated()), id: \.offset) { i, cell in
        if i > 0 {
          Rectangle().fill(HColor.appleSeparatorsNonOpaque)
            .frame(width: stacked ? nil : 1, height: stacked ? 1 : 32)
        }
        Group {
          if stacked {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
              Text(cell.0).hType(.footnote).foregroundStyle(HColor.textSecondary)
              Spacer(minLength: 0)
              figure(i)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
          } else {
            VStack(spacing: 2) {
              Text(cell.0).hType(.footnote).foregroundStyle(HColor.textSecondary)
              figure(i)
            }
            .frame(maxWidth: .infinity)
          }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
      }
    }
    .padding(.vertical, stacked ? 4 : 14)
    .padding(.horizontal, 4)
    .background(HColor.surfaceSecondary, in: RoundedRectangle(cornerRadius: HRadius.tile, style: .continuous))
  }

  /// − AED 1,800 +: the figure is the field; each step is 100.
  private var stepper: some View {
    HStack(spacing: 8) {
      stepButton(.minus, label: "Less") { step(-100_00) }
      PlanAmountField(text: $draft, identifier: "budget.amount", label: "New budget", focus: $typing)
        .frame(maxWidth: .infinity)
      stepButton(.add, label: "More") { step(100_00) }
    }
  }

  private func stepButton(_ icon: HIcon, label: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HIconView(icon, size: HSpacing.iconGlass, color: HColor.textLink)
        .frame(width: HSpacing.glassButton, height: HSpacing.glassButton)
        .background(HColor.actionAccentSubtle, in: Circle())
    }
    .buttonStyle(HPressStyle(in: Circle()))
    .accessibilityLabel(label)
  }

  /// "+ 200", "Match September 1,486" (Debug only), "Cover the pace 1,992": each fills the
  /// field. Their figures hide with the amounts; the field they fill shows the real value.
  private func chips(_ row: PlanRowModel) -> some View {
    // 8 apart as drawn, 4 under the stepper (Paper "Quick chips", 4LX-0); each chip's target
    // reaches 3 past it, above and below, into the gaps rather than adding to them.
    GrowingChipRows(spacing: 8, lineSpacing: 8 - 2 * QuickChip.reach) {
      QuickChip(title: "+ 200", hidden: model.hidden, titleIsFigure: true) { step(200_00) }
        .accessibilityLabel("Add 200")
      // TODO(03a §6.12): "Match September" for live, once last month's spending is read there.
      if BuildSurface.showsUnfinished, let last = model.lastMonth {
        QuickChip(title: "Match \(last.name)", figure: MoneyPhrase([.amount(last.spent, .rounded, hidden: 3)]),
                  hidden: model.hidden) { set(last.spent.minor.plus(50) / 100 * 100) }
      }
      if let projected = model.projected, projected.minor != row.budget.minor {
        QuickChip(title: "Cover the pace", figure: MoneyPhrase([.amount(projected, .compact, hidden: 3)]),
                  hidden: model.hidden) { set(projected.minor) }
      }
    }
    .padding(.top, 4 - QuickChip.reach)
    .padding(.bottom, -QuickChip.reach)
  }

  // MARK: Where it comes from

  private var sources: [MoveSource] { model.sources(to: model.row?.id) }
  private var chosen: MoveSource? { sources.first { $0.id == source } }

  private func rise(_ row: PlanRowModel) -> Int64? { amount.map { $0 - row.budget.minor } }

  /// "Take it from ……… Ready to assign 1,000.00 ›" on the field fill; it pushes the sources.
  /// A cut gives the money back: "Goes back to ……… Ready to assign".
  @ViewBuilder private func sourceField(_ row: PlanRowModel) -> some View {
    let cut = (rise(row) ?? 0) < 0
    let label = Text(cut ? "Goes back to" : "Take it from").hType(.callout).foregroundStyle(HColor.textSecondary)
    let value = SideBySideOrStacked(spacing: 6, spreads: false) {
      Text(cut ? "Ready to assign" : (chosen?.name ?? "Ready to assign"))
        .hType(.rowTitle).foregroundStyle(HColor.textPrimary)
      if !cut, let chosen {
        MoneyText(chosen.available, figure: HFigure.row.weight(.semibold), hidden: model.hidden, hiddenGlyphs: 3,
                  color: HColor.textSecondary)
      }
    }
    let content = HStack(spacing: 6) {
      // Side by side while both fit; the value goes under the words when they don't (spec 04 §17).
      SideBySideOrStacked(spacing: 12) {
        label
        value
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      if !cut, sources.count > 1 {
        HIconView(.chevronRight, size: HSpacing.iconSmall, color: HColor.listRowChevron)
      }
    }
    .padding(.leading, 16)
    .padding(.trailing, 12)
    .padding(.vertical, 6)
    .frame(minHeight: HSpacing.fieldMinHeight)
    .background(HColor.fieldSurface, in: RoundedRectangle(cornerRadius: HRadius.field, style: .continuous))

    if cut || sources.count < 2 {
      content
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(cut ? "Goes back to Ready to assign" : "Take it from \(chosen?.name ?? "Ready to assign")")
        .accessibilityIdentifier("budget.source")
    } else {
      Button { picking = true } label: { content.contentShape(Rectangle()) }
        .buttonStyle(HPressStyle(in: RoundedRectangle(cornerRadius: HRadius.field, style: .continuous), scales: false))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Take it from")
        .accessibilityValue(chosen.map { "\($0.name), \($0.detail.spoken(hidden: model.hidden))" } ?? "")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("budget.source")
    }
  }

  // MARK: Commit

  /// "Ready to assign becomes AED 800.00" (or "Travel keeps AED 2,300.00"), then the button
  /// that repeats the result: "Set Dining to AED 1,800".
  private func commit(_ row: PlanRowModel) -> some View {
    VStack(spacing: 12) {
      if let refusal {
        InlineStatus(tone: .error, text: refusal, size: .regular)
          .frame(maxWidth: .infinity)
          .accessibilityIdentifier("budget.refusal")
      } else if let preview = preview(row) {
        preview
          .multilineTextAlignment(.center)
          .frame(maxWidth: .infinity)
          .accessibilityIdentifier("budget.consequence")
      }
      Button(amount.map { "Set \(row.name) to AED \(MoneyFormat.string($0, style: .compact))" } ?? "Enter a budget") {
        guard let amount else { return }
        typing = false
        _ = model.setBudget(.aed(amount), takingFrom: chosen?.id)
      }
      .buttonStyle(.pill(.primary, fill: true))
      .disabled(amount == nil || amount == row.budget.minor || refusal != nil)
      .accessibilityIdentifier("budget.save")
    }
  }

  /// Taking from a category that hasn't that much left is refused here, before anything is
  /// sent (no toast can show over a sheet). Ready to assign may go below zero: that is the
  /// plan asking for more than the income.
  private var refusal: String? {
    guard let row = model.row, let rise = rise(row), rise > 0, let from = chosen?.id else { return nil }
    return model.refusal(moving: .aed(rise), from: from)
  }

  private func preview(_ row: PlanRowModel) -> AnyView? {
    guard let rise = rise(row) else { return nil }
    let rta = model.plan.readyToAssign.minor
    let (words, after): (String, Int64)
    if rise > 0, let from = chosen, from.id != nil {
      (words, after) = ("\(from.name) keeps", from.available.minor - rise)
    } else {
      (words, after) = ("Ready to assign becomes", rta - rise)
    }
    // A shortfall leads with "−" (U+2212), as MoneyText draws debts; hidden, the figure and
    // its sign both go (spec 04 §12: only inputs show real values).
    let sign = after < 0 && !model.hidden ? "\u{2212}" : ""
    let figure = MoneyPhrase([.text("\(sign)AED "), .amount(.aed(abs(after)), hidden: 3)])
    return AnyView(
      // On one line, centred, while it fits; the figure goes under the words when it doesn't.
      SideBySideOrStacked(spacing: 4, spreads: false, stackedAlignment: .center) {
        Text(words).hType(.subheadline).foregroundStyle(HColor.textSecondary)
        Text(figure.rendered(hidden: model.hidden)).hFigure(.compact)
          .foregroundStyle(after < 0 ? HColor.statusErrorForeground : HColor.textPrimary)
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("\(words) \(figure.spoken(hidden: model.hidden))")
      .accessibilityAddTraits(.isStaticText)
    )
  }

  // MARK: Editing

  private func step(_ by: Int64) {
    set((amount ?? 0) + by)
  }

  private func set(_ minor: Int64) {
    draft = PlanAmountField.text(for: AmountEntry.clamped(minor))
  }
}
