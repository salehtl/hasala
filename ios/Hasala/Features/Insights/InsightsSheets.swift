import HasalaDesign
import HasalaModels
import SwiftUI

struct InsightsPeriodSheet: View {
  let current: YearMonth
  let earliest: YearMonth
  let apply: (ClosedRange<YearMonth>) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var draft: ClosedRange<YearMonth>
  @State private var pending: YearMonth?
  @State private var year: Int

  init(selected: ClosedRange<YearMonth>, current: YearMonth, earliest: YearMonth,
       apply: @escaping (ClosedRange<YearMonth>) -> Void) {
    self.current = current
    self.earliest = earliest
    self.apply = apply
    _draft = State(initialValue: selected)
    _year = State(initialValue: selected.upperBound.year)
  }

  private var presets: [(String, ClosedRange<YearMonth>)] {
    let last = current.previous
    let threeBack = current.previous.previous
    return [
      ("This month", current...current), ("Last month", last...last), ("Last 3 months", threeBack...current),
      ("This year", YearMonth(current.year, 1)...current),
    ]
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          FlowLayout(spacing: 8) {
            ForEach(presets, id: \.0) { preset in
              FilterChip(preset.0, selected: draft == preset.1 && pending == nil) {
                draft = preset.1
                pending = nil
                year = preset.1.upperBound.year
              }
              .accessibilityIdentifier("period.preset.\(preset.0)")
            }
          }
          yearRow
          grid
          Text("Tap a month, or two for a range. Insights compares it with the month before.")
            .hType(.subheadline).foregroundStyle(HColor.textSecondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .fixedSize(horizontal: false, vertical: true)
          Button("Show \(InsightsEngine.title(of: draft))") {
            apply(draft)
            dismiss()
          }
          .buttonStyle(.pill(.primary, fill: true))
          .pillHeight()
          .accessibilityIdentifier("period.show")
        }
        .padding(.horizontal, HSpacing.insetPage)
        .padding(.top, 15)
        .padding(.bottom, 40)
      }
      .background(HColor.sheetSurfaceLarge)
      .navigationTitle("Period")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        SheetCloseButton(identifier: "period.close") { dismiss() }
        ToolbarItem(placement: .principal) {
          Text("Period").hType(.headline).foregroundStyle(HColor.textPrimary).accessibilityAddTraits(.isHeader)
        }
      }
    }
    .presentationDetents([.large])
    .presentationDragIndicator(.visible)
    .presentationCornerRadius(HRadius.sheetLarge)
    .presentationBackground(HColor.sheetSurfaceLarge)
  }

  private var yearRow: some View {
    HStack {
      stepper(.back, enabled: year > earliest.year, label: "Previous year") { year -= 1 }
      Spacer()
      Text(verbatim: "\(year)").hFigure(HFigure(size: 17, leading: 22, weight: .semibold, textStyle: .headline))
        .foregroundStyle(HColor.textPrimary)
        .accessibilityAddTraits(.isHeader)
      Spacer()
      stepper(.chevronRight, enabled: year < current.year, label: "Next year") { year += 1 }
    }
    .frame(minHeight: HSpacing.targetMinimum)
  }

  private func stepper(_ icon: HIcon, enabled: Bool, label: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HIconView(icon, size: 20, color: enabled ? HColor.iconPrimary : HColor.controlNavigationDisabledForeground,
                strokeWidth: 2.2)
        .frame(width: HSpacing.targetMinimum, height: HSpacing.targetMinimum)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(!enabled)
    .accessibilityLabel(label)
  }

  private var grid: some View {
    VStack(spacing: 8) {
      ForEach(0..<4, id: \.self) { row in
        HStack(spacing: 8) {
          ForEach(1...3, id: \.self) { col in
            cell(YearMonth(year, row * 3 + col))
          }
        }
      }
    }
  }

  private func cell(_ m: YearMonth) -> some View {
    let future = m > current
    let chosen = draft.contains(m)
    let shape = RoundedRectangle(cornerRadius: HRadius.control, style: .continuous)
    return Button { tap(m) } label: {
      Text(m.shortName)
        .hType(.headline)
        .foregroundStyle(future ? HColor.controlNavigationDisabledForeground
                         : (chosen ? HColor.chipTextSelected : HColor.textPrimary))
        .frame(maxWidth: .infinity, minHeight: 52)
        .background {
          if future {
            shape.strokeBorder(HColor.borderSubtle, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
          } else {
            shape.fill(chosen ? HColor.chipSurfaceSelected : HColor.surfacePrimary)
          }
        }
        .contentShape(shape)
    }
    .buttonStyle(HPressStyle())
    .disabled(future)
    .accessibilityLabel(m.title)
    .accessibilityValue(future ? "Not yet" : "")
    .accessibilityAddTraits(chosen ? .isSelected : [])
    .accessibilityIdentifier("period.month.\(m)")
  }

  private func tap(_ m: YearMonth) {
    if let start = pending, start != m {
      draft = min(start, m)...max(start, m)
      pending = nil
    } else {
      draft = m...m
      pending = pending == m ? nil : m
    }
  }
}

struct InsightsDrillSheet: View {
  let model: InsightsModel
  let target: InsightsTarget
  @Environment(\.dismiss) private var dismiss
  @State private var path: [InsightsTarget] = []

  var body: some View {
    NavigationStack(path: $path) {
      InsightsDrillPage(drill: model.drill(target), hidden: model.hidden) { path.append($0) }
        .toolbar { SheetCloseButton(identifier: "drill.close") { dismiss() } }
        .navigationDestination(for: InsightsTarget.self) { t in
          InsightsDrillPage(drill: model.drill(t), hidden: model.hidden) { path.append($0) }
        }
    }
    .presentationDetents([.large])
    .presentationDragIndicator(.visible)
    .presentationCornerRadius(HRadius.sheetLarge)
    .presentationBackground(HColor.sheetSurfaceLarge)
  }
}

struct InsightsDrillPage: View {
  let drill: InsightsDrill
  let hidden: Bool
  let narrow: (InsightsTarget) -> Void
  @Environment(\.dynamicTypeSize) private var typeSize

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        header
        if !drill.categories.isEmpty {
          VStack(alignment: .leading, spacing: 8) {
            overline("Narrow to a category")
            VStack(spacing: 0) {
              ForEach(Array(drill.categories.enumerated()), id: \.element.id) { i, c in
                if i > 0 { InsightsSeparator(inset: HSpacing.listRowInsetInline) }
                Button { narrow(.category(c.id)) } label: { categoryRow(c) }
                  .buttonStyle(HRowPressStyle())
                  .accessibilityIdentifier("drill.category.\(c.id)")
              }
            }
            .listCard()
          }
        }
        VStack(alignment: .leading, spacing: 8) {
          overline(drill.rowsTitle)
          if drill.rows.isEmpty {
            EmptyNote(systemImage: "tray", message: "No transactions")
          } else {
            VStack(spacing: 0) {
              ForEach(Array(drill.rows.enumerated()), id: \.element.id) { i, r in
                if i > 0 { InsightsSeparator() }
                txnRow(r)
              }
            }
            .listCard()
          }
        }
      }
      .padding(.horizontal, HSpacing.insetPage)
      .padding(.top, 15)
      .padding(.bottom, 40)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("drill.sheet")
    }
    .background(HColor.sheetSurfaceLarge)
    .navigationTitle(drill.title)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .principal) {
        Text(drill.title).hType(.headline).foregroundStyle(HColor.textPrimary).accessibilityAddTraits(.isHeader)
      }
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text("AED").hFigure(.unit).foregroundStyle(HColor.textPrimary)
        MoneyText(drill.total, figure: InsightsInk.figure, hidden: hidden, hiddenGlyphs: 6,
                  color: HColor.textPrimary, sign: drill.total.minor < 0 ? .income : .none)
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Total")
      .accessibilityValue(InsightsSpeech.amount(drill.total, hidden: hidden))
      .accessibilityIdentifier("drill.total")
      Text(drill.line.rendered(hidden: hidden)).hType(.subheadline).foregroundStyle(HColor.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel(drill.line.spoken(hidden: hidden))
        .accessibilityIdentifier("drill.line")
    }
    .padding(.horizontal, 4)
  }

  private func overline(_ title: String) -> some View {
    Text(title.uppercased()).hType(.overline).foregroundStyle(HColor.textGroupedHeader)
      .padding(.horizontal, 4)
      .accessibilityAddTraits(.isHeader)
  }

  private func categoryRow(_ c: InsightsDrillCategory) -> some View {
    Group {
      if typeSize.isAccessibilitySize {
        HStack(spacing: 12) {
          VStack(alignment: .leading, spacing: 2) {
            Text(c.title).hType(.rowTitle).foregroundStyle(HColor.listRowTitle)
            Text(c.payments).hType(.footnote).foregroundStyle(HColor.textSecondary)
            MoneyText(c.amount, figure: .row, hidden: hidden, hiddenGlyphs: 4, color: HColor.textPrimary)
          }
          Spacer(minLength: 0)
          HIconView(.chevronRight, size: 14, color: HColor.listRowChevron)
        }
      } else {
        HStack(spacing: 12) {
          Text(c.title).hType(.rowTitle).foregroundStyle(HColor.listRowTitle)
          Spacer(minLength: 0)
          Text(c.payments).hType(.footnote).foregroundStyle(HColor.textSecondary)
          MoneyText(c.amount, figure: .row, hidden: hidden, hiddenGlyphs: 4, color: HColor.textPrimary)
            .frame(minWidth: 76, alignment: .trailing)
          HIconView(.chevronRight, size: 14, color: HColor.listRowChevron)
        }
      }
    }
    .padding(.horizontal, HSpacing.listRowInsetInline)
    .frame(maxWidth: .infinity, minHeight: HSpacing.listRowMinHeight)
    .padding(.vertical, 4)
    .contentShape(Rectangle())
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(c.title), \(InsightsSpeech.amount(c.amount, hidden: hidden)), \(c.payments)")
    .accessibilityAddTraits(.isButton)
  }

  private func txnRow(_ r: InsightsDrillRow) -> some View {
    HStack(spacing: HSpacing.listRowGap) {
      CategoryDisc(hue: r.hue, glyph: r.glyph)
      ReflowingRow(alignment: .center) {
        VStack(alignment: .leading, spacing: 2) {
          Text(r.merchant).hType(.rowTitle).foregroundStyle(HColor.listRowTitle)
          Text(r.detail).hType(.footnote).foregroundStyle(HColor.textSecondary)
        }
      } trailing: {
        MoneyText(r.amount, figure: .row, hidden: hidden, hiddenGlyphs: 3,
                  color: r.amount.minor < 0 ? HColor.moneyIn : HColor.moneyOut,
                  sign: r.amount.minor < 0 ? .income : .none)
      }
    }
    .padding(.horizontal, HSpacing.listRowInsetInline)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, minHeight: HSpacing.listRowMinHeightTwoLine, alignment: .leading)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(r.merchant), \(InsightsSpeech.amount(Money.aed(abs(r.amount.minor)), hidden: hidden))\(r.amount.minor < 0 ? " refunded" : ""), \(r.detail)")
    .accessibilityIdentifier("drill.row.\(r.id)")
  }
}
