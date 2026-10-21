import HasalaDesign
import HasalaModels
import SwiftUI

enum InsightsSpeech {
  static func amount(_ m: Money, hidden: Bool, signed: Bool = false) -> String {
    if hidden { return "Amount hidden" }
    let sign = m.minor < 0 ? "minus " : (signed && m.minor > 0 ? "plus " : "")
    return sign + "AED " + MoneyFormat.string(m.minor)
  }

  static func row(_ title: String, _ money: Money, delta: InsightsDelta?, comparison: InsightsComparison?,
                  hidden: Bool, extra: String? = nil) -> String {
    var parts = [title, amount(money, hidden: hidden)]
    if let extra { parts.append(extra) }
    if let delta, let comparison { parts.append(delta.spoken(against: comparison.name)) }
    return parts.joined(separator: ", ")
  }
}

enum InsightsInk {
  static let needsBar = Color(HRGBA(214, 167, 112, 1))
  static let wantsBar = Color(HRGBA(172, 152, 217, 1))
  static let unsorted = Color(Hue.other.dotDeep)
  static let figure = HFigure(size: HFontSize.numericMedium, leading: HLeading.numericMedium, weight: .bold,
                              tracking: HTracking.numericMedium, textStyle: .title2,
                              maxDynamicTypeSize: .accessibility3, minimumScale: 0.75)

  static func bar(_ bucket: Bucket) -> Color {
    switch bucket {
    case .needs: needsBar
    case .wants: wantsBar
    case .savings: HColor.bucketSavingsFill
    case .income, .project, .other: HColor.neutral300
    }
  }

  static func legend(_ kind: InsightsLegendRow.Kind) -> Color {
    switch kind {
    case .needs: HColor.bucketNeedsFill
    case .wants: HColor.bucketWantsFill
    case .other, .unsorted: unsorted
    case .savings: HColor.bucketSavingsFill
    case .unspent: HColor.neutral300
    }
  }
}

struct InsightsSeparator: View {
  var inset: CGFloat = HSpacing.listRowInsetInline + HSpacing.listRowLeadingDisc + HSpacing.listRowGap

  var body: some View {
    Rectangle().fill(HColor.borderSubtle).frame(height: 1).padding(.leading, inset)
      .accessibilityHidden(true)
  }
}

struct InsightsDeltaBadge: View {
  let delta: InsightsDelta

  private var surface: Color {
    switch delta.tone {
    case .neutral: HColor.surfaceSecondary
    case .warning: HColor.statusWarningSurface
    case .success: HColor.statusSuccessSurface
    }
  }

  private var ink: Color {
    switch delta.tone {
    case .neutral: HColor.textSecondary
    case .warning: HColor.paceOverPace
    case .success: HColor.statusSuccessForeground
    }
  }

  var body: some View {
    Text(delta.text)
      .hFigure(HFigure(size: 12, leading: 16, weight: .bold, textStyle: .caption, tabular: true))
      .foregroundStyle(ink)
      .lineLimit(1)
      .fixedSize()
      .padding(.horizontal, 8)
      .frame(minHeight: 22)
      .background(surface, in: Capsule())
      .accessibilityHidden(true)
  }
}

struct InsightsBadgeSlot: View {
  let delta: InsightsDelta?

  var body: some View {
    HStack(spacing: 0) {
      Spacer(minLength: 0)
      if let delta { InsightsDeltaBadge(delta: delta) }
    }
    .frame(minWidth: 56)
    .fixedSize()
  }
}

// MARK: - Summary

struct InsightsSummaryCard: View {
  let summary: InsightsSummary
  let comparison: InsightsComparison?
  let hidden: Bool
  let open: (InsightsTarget) -> Void
  @Environment(\.dynamicTypeSize) private var typeSize

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      headline
      VStack(alignment: .leading, spacing: 8) {
        if let split = summary.split { InsightsSplitBar(split: split) }
        Text(summary.note.rendered(hidden: hidden)).hType(.footnote).foregroundStyle(HColor.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityLabel(summary.note.spoken(hidden: hidden))
      }
      VStack(spacing: 0) {
        ForEach(summary.legend) { row in
          if let target = row.target {
            Button { open(target) } label: { legend(row) }
              .buttonStyle(HRowPressStyle())
              .accessibilityHint("Shows its transactions")
              .accessibilityIdentifier("insights.legend.\(row.kind.rawValue)")
          } else {
            legend(row).accessibilityIdentifier("insights.legend.\(row.kind.rawValue)")
          }
        }
      }
    }
    .padding(HSpacing.insetCard)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.card, style: .continuous))
  }

  private var headline: some View {
    let layout = typeSize.isAccessibilitySize
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
      : AnyLayout(HStackLayout(alignment: .bottom, spacing: 12))
    return layout {
      VStack(alignment: .leading, spacing: 2) {
        Text(summary.label).hType(.footnote).foregroundStyle(HColor.textSecondary)
        figureLayout {
          Text("AED").hFigure(.unit).foregroundStyle(HColor.textPrimary)
          MoneyText(summary.figure, figure: InsightsInk.figure, hidden: hidden, hiddenGlyphs: 6,
                    color: summary.isNet && summary.figure.minor > 0 ? HColor.moneyIn : HColor.textPrimary,
                    sign: summary.isNet ? (summary.figure.minor > 0 ? .income : (summary.figure.minor < 0 ? .debt : .none))
                      : .none)
        }
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(summary.label)
      .accessibilityValue(InsightsSpeech.amount(summary.figure, hidden: hidden, signed: summary.isNet))
      .accessibilityIdentifier("insights.figure")
      if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
      VStack(alignment: typeSize.isAccessibilitySize ? .leading : .trailing, spacing: 2) {
        Text("Kept").hType(.footnote).foregroundStyle(HColor.textSecondary)
        Text(summary.kept ?? "\u{2014}").hFigure(.small).foregroundStyle(HColor.textPrimary)
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Kept")
      .accessibilityValue(summary.keptPercent.map { "\($0) percent of income" } ?? "No income yet")
      .accessibilityIdentifier("insights.kept")
    }
  }

  private var figureLayout: AnyLayout {
    typeSize.isAccessibilitySize
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
      : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 6))
  }

  private func legend(_ row: InsightsLegendRow) -> some View {
    let dot = RoundedRectangle(cornerRadius: 5).fill(InsightsInk.legend(row.kind)).frame(width: 10, height: 10)
    let title = Text(row.title).hType(.subheadline.weight(.semibold)).foregroundStyle(HColor.textPrimary)
      .fixedSize(horizontal: false, vertical: true)
    let amount = MoneyText(row.amount, figure: .compact, hidden: hidden, hiddenGlyphs: 4, color: HColor.textPrimary)
    let slot = InsightsBadgeSlot(delta: comparison == nil ? nil : row.delta)
    return Group {
      if typeSize.isAccessibilitySize {
        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 10) { dot; title }
          HStack(spacing: 10) { amount; slot }
        }
      } else {
        HStack(spacing: 10) {
          dot
          title.frame(maxWidth: .infinity, alignment: .leading)
          amount
          slot
        }
      }
    }
    .frame(maxWidth: .infinity, minHeight: HSpacing.targetMinimum, alignment: .leading)
    .contentShape(Rectangle())
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(InsightsSpeech.row(row.title, row.amount, delta: row.delta, comparison: comparison,
                                           hidden: hidden))
  }
}

struct InsightsSplitBar: View {
  let split: InsightsSplit

  var body: some View {
    let parts: [(Color, Int64)] = [
      (HColor.bucketNeedsFill, split.needs), (HColor.bucketWantsFill, split.wants),
      (InsightsInk.unsorted, split.unsorted), (HColor.bucketSavingsFill, split.savings), (HColor.neutral300, split.unspent),
    ].filter { $0.1 > 0 }
    let total = Fils.sum(parts.map(\.1))
    GeometryReader { geo in
      let gaps = CGFloat(max(0, parts.count - 1)) * 2
      let usable = max(0, geo.size.width - gaps)
      HStack(spacing: 2) {
        ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
          Rectangle().fill(part.0)
            .frame(width: total > 0 ? usable * CGFloat(Double(part.1) / Double(total)) : 0)
        }
      }
      .clipShape(Capsule())
    }
    .frame(height: 12)
    .accessibilityHidden(true)
  }
}

// MARK: - Rows

struct InsightsLensRow: View {
  let row: InsightsRow
  let comparison: InsightsComparison?
  let hidden: Bool
  @Environment(\.dynamicTypeSize) private var typeSize

  var body: some View {
    HStack(alignment: typeSize.isAccessibilitySize ? .top : .center, spacing: HSpacing.listRowGap) {
      disc
      VStack(alignment: .leading, spacing: 6) {
        ReflowingRow(alignment: .firstTextBaseline) {
          Text(row.title).hType(.rowTitle).foregroundStyle(HColor.listRowTitle)
            .fixedSize(horizontal: false, vertical: true)
        } trailing: {
          MoneyText(row.amount, figure: .row, hidden: hidden, hiddenGlyphs: 4, color: HColor.textPrimary,
                    sign: row.amount.minor < 0 ? .income : .none)
        }
        HStack(spacing: 12) {
          GeometryReader { geo in
            RoundedRectangle(cornerRadius: 3)
              .fill(InsightsInk.bar(row.bucket))
              .frame(width: max(row.bar.value > 0 ? 6 : 0, geo.size.width * row.bar.fraction), height: 6)
          }
          .frame(height: 6)
          Text("\(row.sharePercent)%")
            .hFigure(HFigure(size: 13, leading: 18, weight: .semibold, textStyle: .footnote, tabular: true))
            .foregroundStyle(HColor.textSecondary)
            .frame(minWidth: 36, alignment: .trailing)
            .fixedSize()
          if case .merchant = row.target {} else { InsightsBadgeSlot(delta: row.delta) }
        }
      }
    }
    .padding(.horizontal, HSpacing.listRowInsetInline)
    .padding(.vertical, HSpacing.listRowInsetBlock)
    .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
    .contentShape(Rectangle())
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(InsightsSpeech.row(row.title, row.amount, delta: row.delta, comparison: comparison,
                                           hidden: hidden, extra: "\(row.sharePercent) percent of spending"))
    .accessibilityHint("Shows its transactions")
    .accessibilityAddTraits(.isButton)
  }

  @ViewBuilder private var disc: some View {
    if let letter = row.monogram, case .merchant = row.target {
      MonogramDisc(letter)
    } else {
      CategoryDisc(hue: row.hue, glyph: row.glyph)
    }
  }
}

struct InsightsChangeRow: View {
  let change: InsightsChange
  let comparison: InsightsComparison
  let hidden: Bool

  var body: some View {
    HStack(spacing: HSpacing.listRowGap) {
      CategoryDisc(hue: change.hue, glyph: change.glyph)
      VStack(alignment: .leading, spacing: 2) {
        Text(change.title).hType(.rowTitle).foregroundStyle(HColor.listRowTitle)
        Text(change.before.rendered(hidden: hidden)).hType(.footnote).foregroundStyle(HColor.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 8)
      VStack(alignment: .trailing, spacing: 4) {
        MoneyText(change.change, figure: .row, hidden: hidden, hiddenGlyphs: 4, color: HColor.textPrimary,
                  sign: change.change.minor < 0 ? .debt : .income)
        InsightsDeltaBadge(delta: change.delta)
      }
      .fixedSize()
    }
    .padding(.horizontal, HSpacing.listRowInsetInline)
    .padding(.vertical, HSpacing.listRowInsetBlock)
    .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel([
      change.title, InsightsSpeech.amount(change.change, hidden: hidden, signed: true),
      change.delta.spoken(against: comparison.name), change.before.spoken(hidden: hidden),
    ].joined(separator: ", "))
    .accessibilityIdentifier("insights.change.\(change.categoryID)")
  }
}

// MARK: - Money in vs out

struct InsightsFlowCard: View {
  let flow: InsightsFlow
  let empty: String?
  let focus: YearMonth
  let hidden: Bool
  @Binding var showsTable: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      VStack(alignment: .leading, spacing: 6) {
        HStack(alignment: .firstTextBaseline) {
          Text("Money in vs out").hType(.headline).foregroundStyle(HColor.textPrimary)
            .accessibilityAddTraits(.isHeader)
          Spacer(minLength: 8)
          Text(flow.span).hType(.footnote).foregroundStyle(HColor.textSecondary)
        }
        if empty == nil, !showsTable {
          HStack(spacing: 14) {
            key("In", HColor.blue300)
            key("Out", HColor.textPrimary)
          }
          .accessibilityHidden(true)
        }
      }
      if let empty {
        Text(empty).hType(.footnote).foregroundStyle(HColor.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("insights.flow.empty")
      } else {
        if showsTable { table } else { chart }
        Text(flow.note.rendered(hidden: hidden)).hType(.footnote).foregroundStyle(HColor.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityLabel(flow.note.spoken(hidden: hidden))
        Button(showsTable ? "Show as a chart" : "Show as a table") { showsTable.toggle() }
          .buttonStyle(.plain)
          .hType(.subheadline.weight(.semibold))
          .foregroundStyle(HColor.textLink)
          .frame(minHeight: HSpacing.targetMinimum)
          .contentShape(Rectangle())
          .padding(.top, -10)
          .accessibilityIdentifier("insights.flow.toggle")
      }
    }
    .padding(HSpacing.insetCard)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.card, style: .continuous))
  }

  private func key(_ title: String, _ color: Color) -> some View {
    HStack(spacing: 6) {
      RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 10, height: 10)
      Text(title).hType(.footnote).foregroundStyle(HColor.textSecondary)
    }
  }

  private var largest: Int64 { flow.months.map { max($0.income.minor, $0.out.minor) }.max() ?? 0 }

  private var gridValue: Int64 {
    let top = largest
    var best: Int64 = 0
    var power: Int64 = 100
    while power <= top {
      for tenths in [Int64(10), 20, 25, 50] where power * tenths / 10 <= top {
        best = max(best, power * tenths / 10)
      }
      power *= 10
    }
    return best
  }

  private var chart: some View {
    let scaleTop = Double(largest) * 1.1
    let plot: CGFloat = 139
    func height(_ minor: Int64) -> CGFloat {
      scaleTop > 0 ? plot * CGFloat(Double(max(0, minor)) / scaleTop) : 0
    }
    let grid = gridValue
    return VStack(spacing: 6) {
      ZStack(alignment: .topLeading) {
        if grid > 0 {
          Rectangle().fill(HColor.borderSubtle).frame(height: 1).offset(y: plot - height(grid))
          Text(hidden ? MoneyFormat.hidden(count: 3) : MoneyFormat.string(grid, style: .rounded))
            .hFigure(HFigure(size: 12, leading: 16, weight: .medium, textStyle: .caption, tabular: true))
            .foregroundStyle(HColor.textSecondary)
            .offset(y: plot - height(grid) - 18)
        }
        Rectangle().fill(HColor.neutral300).frame(height: 1).offset(y: plot)
        HStack(alignment: .bottom, spacing: 0) {
          ForEach(flow.months) { m in
            HStack(alignment: .bottom, spacing: 4) {
              bar(height(m.income.minor), HColor.blue300)
              bar(height(m.out.minor), HColor.textPrimary)
            }
            .frame(maxWidth: .infinity, maxHeight: plot, alignment: .bottom)
          }
        }
        .frame(height: plot)
      }
      .frame(height: plot + 1, alignment: .top)
      HStack(spacing: 0) {
        ForEach(flow.months) { m in
          Text(m.month.shortName)
            .hType(HType(size: 12, leading: 16, weight: m.isFocus ? .bold : .medium, textStyle: .caption))
            .foregroundStyle(m.isFocus ? HColor.textPrimary : HColor.textSecondary)
            .frame(maxWidth: .infinity)
        }
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Money in vs out, \(flow.span)")
    .accessibilityValue(spokenSummary)
    .accessibilityIdentifier("insights.flow.chart")
  }

  private func bar(_ h: CGFloat, _ color: Color) -> some View {
    UnevenRoundedRectangle(topLeadingRadius: 4, bottomLeadingRadius: 2, bottomTrailingRadius: 2,
                           topTrailingRadius: 4)
      .fill(color)
      .frame(width: 14, height: max(0, h))
  }

  private var spokenSummary: String {
    var parts: [String] = []
    if let avg = flow.averageOut {
      parts.append("Out averaged \(InsightsSpeech.amount(avg, hidden: hidden)) a month")
    }
    for m in flow.months {
      parts.append("\(m.month.name)\(m.inProgress ? " so far" : ""): in \(InsightsSpeech.amount(m.income, hidden: hidden)), out \(InsightsSpeech.amount(m.out, hidden: hidden))")
    }
    return parts.joined(separator: ". ")
  }

  private var table: some View {
    VStack(spacing: 0) {
      tableRow(Text("Month"), Text("In"), Text("Out"), header: true)
      ForEach(flow.months) { m in
        InsightsSeparator(inset: 0)
        HStack {
          Text(m.month.name + (m.inProgress ? " so far" : ""))
            .hType(m.isFocus ? .subheadline.weight(.semibold) : .subheadline)
            .foregroundStyle(HColor.textPrimary)
          Spacer(minLength: 8)
          MoneyText(m.income, figure: .compact, hidden: hidden, hiddenGlyphs: 4, color: HColor.textPrimary)
            .frame(minWidth: 96, alignment: .trailing)
          MoneyText(m.out, figure: .compact, hidden: hidden, hiddenGlyphs: 4, color: HColor.textPrimary)
            .frame(minWidth: 96, alignment: .trailing)
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(m.month.name)\(m.inProgress ? " so far" : ""), in \(InsightsSpeech.amount(m.income, hidden: hidden)), out \(InsightsSpeech.amount(m.out, hidden: hidden))")
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("insights.flow.table")
  }

  private func tableRow(_ a: Text, _ b: Text, _ c: Text, header: Bool) -> some View {
    HStack {
      a
      Spacer(minLength: 8)
      b.frame(minWidth: 96, alignment: .trailing)
      c.frame(minWidth: 96, alignment: .trailing)
    }
    .hType(.footnote.weight(.semibold))
    .foregroundStyle(HColor.textSecondary)
    .frame(minHeight: 32)
    .accessibilityHidden(true)
  }
}

// MARK: - Reports

struct InsightsReportTile: View {
  let report: InsightsReport
  let hidden: Bool
  let chevron: Bool

  private static let figure = HFigure(size: 22, leading: 28, weight: .bold, tracking: -0.3, textStyle: .title3,
                                      minimumScale: 0.75)

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Text(report.title).hType(.subheadline.weight(.semibold)).foregroundStyle(HColor.textPrimary)
        Spacer(minLength: 4)
        if chevron { HIconView(.chevronRight, size: 14, color: HColor.listRowChevron) }
      }
      Spacer(minLength: 0)
      VStack(alignment: .leading, spacing: 2) {
        value
        Text(report.caption).hType(.footnote).foregroundStyle(HColor.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(HSpacing.insetCard)
    .frame(maxWidth: .infinity, minHeight: 128, alignment: .topLeading)
    .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.tile, style: .continuous))
    .contentShape(RoundedRectangle(cornerRadius: HRadius.tile, style: .continuous))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(report.title)
    .accessibilityValue("\(spokenValue), \(report.caption)")
    .accessibilityAddTraits(.isButton)
  }

  @ViewBuilder private var value: some View {
    switch report.value {
    case .missing:
      Text("\u{2014}").hFigure(Self.figure).foregroundStyle(HColor.textPrimary)
    case .money(let m):
      MoneyText(m, figure: Self.figure, hidden: hidden, hiddenGlyphs: 4, color: HColor.textPrimary,
                sign: m.minor < 0 ? .debt : .none)
    case .signedMoney(let m):
      MoneyText(m, figure: Self.figure, hidden: hidden, hiddenGlyphs: 4, color: HColor.textPrimary,
                sign: m.minor < 0 ? .debt : (m.minor > 0 ? .income : .none))
    case .delta(let d):
      Text(d.text).hFigure(Self.figure).foregroundStyle(HColor.textPrimary)
    }
  }

  private var spokenValue: String {
    switch report.value {
    case .missing: "Not available"
    case .money(let m): InsightsSpeech.amount(m, hidden: hidden)
    case .signedMoney(let m): InsightsSpeech.amount(m, hidden: hidden, signed: true)
    case .delta(let d):
      switch d.kind {
      case .up(let p): "up \(p) percent"
      case .down(let p): "down \(p) percent"
      case .new: "new"
      case .gone: "none"
      case .same: "the same"
      }
    }
  }
}
