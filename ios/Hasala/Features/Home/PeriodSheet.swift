import HasalaDesign
import HasalaModels
import SwiftUI

struct PeriodSheet: View {
  @Bindable var app: AppModel
  @State private var picking: PeriodPicking
  @Environment(\.dismiss) private var dismiss

  init(app: AppModel) {
    self.app = app
    let today = app.store.now.date.yearMonth
    let earliest = app.store.state.txns.map(\.postedAt.date.yearMonth).min()
    _picking = State(initialValue: PeriodPicking(period: app.period, today: today, earliest: earliest))
  }

  var body: some View {
    ScrollView {
      VStack(spacing: HSpacing.sheetGap) {
        PlanSheetHeader(title: "Period", closeID: "period.close") { dismiss() }
        VStack(spacing: 16) {
          presets
          yearRow
          grid
          Text(picking.hint)
            .hType(.subheadline).foregroundStyle(HColor.textSecondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("period.hint")
          Button(picking.confirmTitle) {
            app.period = picking.period
            dismiss()
          }
          .buttonStyle(PillButtonStyle(.primary, size: .large, fill: true))
          .accessibilityIdentifier("period.show")
        }
      }
      .padding(.horizontal, HSpacing.insetPage)
      .padding(.top, 21)
      .padding(.bottom, 40)
    }
    .scrollBounceBehavior(.basedOnSize)
    .background(HColor.sheetSurfaceLarge)
    .accessibilityIdentifier("period.sheet")
    .planLargeSheet()
  }

  private var presets: some View {
    FlowLayout(spacing: 8) {
      ForEach(PeriodPreset.allCases) { preset in
        FilterChip(preset.title, selected: picking.preset == preset) { picking.choose(preset) }
          .accessibilityIdentifier("period.preset.\(preset.rawValue)")
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var yearRow: some View {
    HStack {
      stepButton(.back, label: "Previous year", enabled: picking.canGoBack, id: "period.previousYear") {
        picking.previousYear()
      }
      Spacer()
      Text(verbatim: "\(picking.year)").hType(.headline).foregroundStyle(HColor.textPrimary)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("period.year")
      Spacer()
      stepButton(.chevronRight, label: "Next year", enabled: picking.canGoForward, id: "period.nextYear") {
        picking.nextYear()
      }
    }
    .frame(minHeight: HSpacing.targetMinimum)
  }

  private func stepButton(_ icon: HIcon, label: String, enabled: Bool, id: String,
                          action: @escaping () -> Void) -> some View
  {
    Button(action: action) {
      HIconView(icon, size: 20,
                color: enabled ? HColor.iconPrimary : HColor.controlNavigationDisabledForeground, strokeWidth: 2.2)
        .frame(width: HSpacing.targetMinimum, height: HSpacing.targetMinimum)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(!enabled)
    .accessibilityLabel(label)
    .accessibilityIdentifier(id)
  }

  private var grid: some View {
    Grid(horizontalSpacing: 8, verticalSpacing: 8) {
      ForEach(0..<4, id: \.self) { row in
        GridRow {
          ForEach(0..<3, id: \.self) { col in
            monthCell(picking.months[row * 3 + col])
          }
        }
      }
    }
  }

  private func monthCell(_ m: YearMonth) -> some View {
    let cell = picking.cell(m)
    let shape = RoundedRectangle(cornerRadius: HRadius.control, style: .continuous)
    return Button { picking.tap(m) } label: {
      Text(m.shortName)
        .hType(.headline)
        .foregroundStyle(foreground(cell))
        .frame(maxWidth: .infinity, minHeight: 52)
        .background(background(cell), in: shape)
        .overlay {
          if cell == .future {
            shape.strokeBorder(HColor.borderSubtle, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
          }
        }
        .contentShape(shape)
    }
    .buttonStyle(HPressStyle(in: shape, scales: false))
    .disabled(cell == .future)
    .accessibilityLabel(m.title)
    .accessibilityAddTraits(cell == .end || cell == .between ? .isSelected : [])
    .accessibilityIdentifier("period.month.\(m)")
  }

  private func foreground(_ cell: PeriodPicking.Cell) -> Color {
    switch cell {
    case .end: HColor.chipTextSelected
    case .between: HColor.actionAccent
    case .future: HColor.controlNavigationDisabledForeground
    case .open: HColor.textPrimary
    }
  }

  private func background(_ cell: PeriodPicking.Cell) -> Color {
    switch cell {
    case .end: HColor.chipSurfaceSelected
    case .between: HColor.actionAccentSubtle
    case .future: .clear
    case .open: HColor.surfacePrimary
    }
  }
}
