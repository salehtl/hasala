import Accessibility
import HasalaDesign
import HasalaModels
import SwiftUI

/// Day by day (Paper "Plan · Dining", chart card): one bar per day of the month so far, 132
/// tall. A spend day is a 12 wide bar in the hue's deeper step (rounded 4 at the top, 2 at the
/// foot), today in the hue's ink; a day with nothing is a 3 tall stub on the pace track. A
/// dashed line marks the daily budget with its label above it; the tallest day is named over
/// its bar ("Zuma · 412.00"). Day numbers run under the bars, today's in ink.
///
/// Heights are drawn against the tallest day (or the daily budget when that is higher), 108
/// at most, with one label line and 7 over it for the name (Paper: 23 at 12/16). The labels
/// are placed with their measured sizes, so they keep clear of the bars as the text grows. At
/// the accessibility sizes they are as wide as half the plot and as tall as its bars, so they
/// leave it for a key above it, each with its mark (spec 04 §17: layouts reflow). Geometry is
/// the only place a share becomes a float.
///
/// One VoiceOver element (`plan.chart`) with a summary, and an audio graph through
/// `accessibilityChartDescriptor`; with amounts hidden it says "Amount hidden".
struct DayByDayChart: View {
  let chart: DayByDay
  /// The category, for the audio graph's series ("Dining").
  let name: String
  /// The category's hue: bars in its deeper step (#BBA6E6 for lilac), today in its ink.
  let hue: Hue
  let hidden: Bool

  @Environment(\.dynamicTypeSize) private var typeSize
  /// One line of the chart's 12/16 labels, scaled with them.
  @ScaledMetric(relativeTo: .caption) private var labelLine: CGFloat = 16
  /// The labels' 12 pt, scaled: it sets where a key's mark sits on the first line.
  @ScaledMetric(relativeTo: .caption) private var labelSize: CGFloat = 12
  /// The widest day number ("30") in the day numbers' face, scaled with it.
  @ScaledMetric(relativeTo: .caption) private var dayLabelWidth: CGFloat = 15
  @ScaledMetric(relativeTo: .caption) private var dayLabelHeight: CGFloat = 16

  private let tallest: CGFloat = 108

  /// The labels sit in a key above the plot rather than over the bars.
  private var keyed: Bool { typeSize.isAccessibilitySize }
  /// Room over the tallest bar: its name and 7 (2 above it, 5 under it); 8 when the name is
  /// in the key.
  private var headroom: CGFloat { keyed ? 8 : labelLine + 7 }
  /// The plot over its 1 pt baseline: 131 at the default size.
  private var plotHeight: CGFloat { headroom + tallest }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if keyed { key.padding(.bottom, 6) }
      GeometryReader { geo in
        plot(width: geo.size.width)
      }
      .frame(height: plotHeight + 1)
      GeometryReader { geo in
        dayLabels(width: geo.size.width)
      }
      .frame(height: dayLabelHeight)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Day by day, \(chart.range)")
    .accessibilityValue(summary)
    .accessibilityChartDescriptor(DayByDayDescriptor(chart: chart, name: name, hidden: hidden))
    .accessibilityIdentifier("plan.chart")
  }

  // MARK: The plot

  private func plot(width: CGFloat) -> some View {
    let slot = width / CGFloat(max(1, chart.days.count))
    let bar = min(12, slot * 0.6)
    let top = CGFloat(max(1, chart.scaleTop.minor))
    let lineY = plotHeight - CGFloat(chart.dailyBudget.minor) / top * tallest
    let peak = chart.peak.flatMap { p in chart.days.firstIndex { $0.day == p.day }.map { (p, $0) } }
    return ZStack(alignment: .topLeading) {
      // The baseline.
      Rectangle().fill(HColor.borderSubtle).frame(width: width, height: 1).offset(y: plotHeight)
      // The bars, aligned on the baseline.
      HStack(alignment: .bottom, spacing: 0) {
        ForEach(chart.days) { day in
          dayBar(day, width: bar, height: CGFloat(day.spent.minor) / top * tallest)
            .frame(width: slot, alignment: .center)
        }
      }
      .frame(width: width, height: plotHeight, alignment: .bottomLeading)
      // The daily budget: a dashed line.
      if chart.dailyBudget.minor > 0 {
        Path { p in
          p.move(to: CGPoint(x: 0, y: 1))
          p.addLine(to: CGPoint(x: width, y: 1))
        }
        .stroke(HColor.neutral400, style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
        .frame(width: width, height: 2)
        .offset(y: lineY - 1)
      }
      // Its label and the tallest day's name, placed with their real sizes.
      if !keyed {
        DayByDayPlotLabels(
          hasPeak: peak != nil,
          peakCentre: peak.map { slot * (CGFloat($0.1) + 0.5) } ?? 0,
          peakTop: peak.map { plotHeight - CGFloat($0.0.total.minor) / top * tallest } ?? 0,
          lineY: chart.dailyBudget.minor > 0 ? lineY : nil
        ) {
          if let peak { PeakLabel(peak: peak.0, hidden: hidden, wraps: false) }
          if chart.dailyBudget.minor > 0 { DailyBudgetLabel(amount: chart.dailyBudget, hidden: hidden, wraps: false) }
        }
        .frame(width: width, height: plotHeight)
      }
    }
    .frame(width: width, height: plotHeight + 1, alignment: .topLeading)
  }

  @ViewBuilder private func dayBar(_ day: DaySpend, width: CGFloat, height: CGFloat) -> some View {
    if day.spent.minor > 0 {
      BarShape()
        .fill(barColour(day.day))
        .frame(width: width, height: max(4, height))
    } else {
      RoundedRectangle(cornerRadius: 1.5).fill(HColor.paceTrack).frame(width: width, height: 3)
    }
  }

  private func barColour(_ day: Int) -> Color {
    day == chart.today ? hue.ink : Color(hue.dotDeep)
  }

  // MARK: The key (accessibility sizes)

  /// "▮ Zuma · 412.00" and "- - Daily budget 51.61", one under the other, each wrapping
  /// beside its mark: the tallest day's bar and the dashed line.
  private var key: some View {
    // The marks grow with the words: the bar as tall as a capital (Inter's are 0.73 em),
    // the dashes a little longer, in one column.
    let cap = labelSize * 0.73
    let slot = cap * 1.2
    return VStack(alignment: .leading, spacing: 8) {
      if let peak = chart.peak {
        keyLine(PeakLabel(peak: peak, hidden: hidden, wraps: true), slot: slot) {
          BarShape().fill(barColour(peak.day)).frame(width: max(12, cap * 0.6), height: cap)
        }
      }
      if chart.dailyBudget.minor > 0 {
        keyLine(DailyBudgetLabel(amount: chart.dailyBudget, hidden: hidden, wraps: true), slot: slot) {
          Path { p in
            p.move(to: CGPoint(x: 0, y: 1))
            p.addLine(to: CGPoint(x: slot, y: 1))
          }
          .stroke(HColor.neutral400, style: StrokeStyle(lineWidth: 2, dash: [cap / 4, cap / 4]))
          .frame(width: slot, height: 2)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// A mark centred in a `slot` wide column, on the middle of its words' first line.
  private func keyLine<Words: View, Mark: View>(
    _ words: Words, slot: CGFloat, @ViewBuilder mark: () -> Mark
  ) -> some View {
    let halfCap = labelSize * 0.365
    return HStack(alignment: .firstTextBaseline, spacing: 8) {
      mark()
        .frame(width: slot)
        .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + halfCap }
      words
    }
  }

  // MARK: Day numbers

  /// The days whose numbers fit under the bars (`labelledDays`), today's in ink, each under
  /// its bar and kept inside the plot's ends (`labelCentre`).
  private func dayLabels(width: CGFloat) -> some View {
    let days = chart.days.map(\.day)
    let slot = width / CGFloat(max(1, days.count))
    let shown = Self.labelledDays(days, today: chart.today, slot: slot, labelWidth: dayLabelWidth)
    return HStack(spacing: 0) {
      ForEach(Array(chart.days.enumerated()), id: \.element.id) { i, day in
        let today = day.day == chart.today
        let centre = Self.labelCentre(i, day: day.day, count: days.count, slot: slot, labelWidth: dayLabelWidth)
        Text(shown.contains(day.day) ? "\(day.day)" : "")
          .font(.system(.caption, design: .rounded, weight: today ? .bold : .medium))
          .foregroundStyle(today ? HColor.textPrimary : HColor.textSecondary)
          .fixedSize()
          .frame(width: slot)
          .offset(x: centre - slot * (CGFloat(i) + 0.5))
      }
    }
  }

  /// Which day numbers to draw: today first, then every day while there are ten or fewer
  /// (the 1st and every fifth past that), each kept only when it stands clear of every
  /// number already drawn by 0.4 of a two-digit number (6 at the default size), so they
  /// never read as one long number. At the default size ten days all fit (Paper); at AX5
  /// they thin out, and a late month never puts "30" against "31". `labelWidth` is a
  /// two-digit number's width; one digit is taken as half of it.
  static func labelledDays(_ days: [Int], today: Int, slot: CGFloat, labelWidth: CGFloat) -> Set<Int> {
    func width(_ day: Int) -> CGFloat { day < 10 ? labelWidth / 2 : labelWidth }
    let gap = labelWidth * 0.4
    let candidates = days.count <= 10 ? days : days.filter { $0 == 1 || $0 % 5 == 0 }
    var shown: [(day: Int, centre: CGFloat)] = []
    for day in [today] + candidates {
      guard let i = days.firstIndex(of: day), !shown.contains(where: { $0.day == day }) else { continue }
      let centre = labelCentre(i, day: day, count: days.count, slot: slot, labelWidth: labelWidth)
      if shown.allSatisfy({ abs($0.centre - centre) >= (width($0.day) + width(day)) / 2 + gap }) {
        shown.append((day, centre))
      }
    }
    return Set(shown.map(\.day))
  }

  /// Where the number of the day at `index` is centred: under its bar, moved in from the
  /// plot's ends when it is wider than its slot, so it never runs past them.
  static func labelCentre(_ index: Int, day: Int, count: Int, slot: CGFloat, labelWidth: CGFloat) -> CGFloat {
    let half = (day < 10 ? labelWidth / 2 : labelWidth) / 2
    let end = slot * CGFloat(count)
    return min(max(half, slot * (CGFloat(index) + 0.5)), max(half, end - half))
  }

  // MARK: VoiceOver

  /// "Largest day Wed 7 Oct, Zuma, AED 412.00. Daily budget AED 51.61."
  private var summary: String {
    var parts: [String] = []
    if let peak = chart.peak, let day = chart.days.first(where: { $0.day == peak.day }) {
      parts.append("Largest day \(day.date.short), \(peak.label), \(spoken(peak.total))")
    } else {
      parts.append("Nothing spent yet")
    }
    // A category without a pace (a bill, savings) has no daily budget to say.
    if chart.dailyBudget.minor > 0 { parts.append("Daily budget \(spoken(chart.dailyBudget))") }
    return parts.joined(separator: ". ") + "."
  }

  private func spoken(_ m: Money) -> String {
    hidden ? "Amount hidden" : "AED \(MoneyFormat.string(m.minor))"
  }
}

/// A spend day's bar: rounded 4 at the top, 2 at the foot.
nonisolated private struct BarShape: Shape {
  func path(in rect: CGRect) -> Path {
    UnevenRoundedRectangle(topLeadingRadius: 4, bottomLeadingRadius: 2, bottomTrailingRadius: 2,
                           topTrailingRadius: 4, style: .continuous)
      .path(in: rect)
  }
}

/// Places the plot's labels at their measured sizes: the tallest day's name (the first
/// subview, when `hasPeak`) centred over its bar, 5 above it, inside the plot; the daily
/// budget's (the next) at the leading edge 4 above its line, or 4 under it when there is no
/// room above or the name is in the way.
struct DayByDayPlotLabels: Layout {
  let hasPeak: Bool
  let peakCentre: CGFloat
  /// The top of the tallest day's bar.
  let peakTop: CGFloat
  /// The daily budget line, or nil when it is not drawn.
  let lineY: CGFloat?

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    proposal.replacingUnspecifiedDimensions()
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var rest = subviews[...]
    let peak = hasPeak ? rest.popFirst() : nil
    let budget = lineY == nil ? nil : rest.popFirst()
    let frames = frames(
      peak: peak?.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)),
      budget: budget?.sizeThatFits(.unspecified), width: bounds.width)
    for (view, frame) in [(peak, frames.peak), (budget, frames.budget)] {
      guard let view, let frame else { continue }
      view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                 proposal: ProposedViewSize(frame.size))
    }
  }

  /// Where the labels of these sizes go in a plot `width` wide.
  func frames(peak: CGSize?, budget: CGSize?, width: CGFloat) -> (peak: CGRect?, budget: CGRect?) {
    let peakFrame = peak.map { size in
      let w = min(size.width, width)
      return CGRect(x: min(max(0, peakCentre - w / 2), width - w), y: max(0, peakTop - size.height - 5),
                    width: w, height: size.height)
    }
    let budgetFrame = budget.flatMap { size in
      lineY.map { lineY in
        var frame = CGRect(x: 0, y: lineY - size.height - 4, width: size.width, height: size.height)
        if frame.minY < 0 || peakFrame?.intersects(frame) == true { frame.origin.y = lineY + 4 }
        return frame
      }
    }
    return (peakFrame, budgetFrame)
  }
}

/// "Zuma · 412.00" over the tallest bar: 12/16, the name 600, the figure rounded 700. In the
/// plot it is one line and a long name gives way to the figure; in the key it wraps.
private struct PeakLabel: View {
  let peak: DayByDay.Peak
  let hidden: Bool
  let wraps: Bool

  var body: some View {
    Group {
      if wraps {
        Text("\(name) \(figure)").fixedSize(horizontal: false, vertical: true)
      } else {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
          name.lineLimit(1)
          figure.fixedSize().layoutPriority(1)
        }
      }
    }
    .foregroundStyle(HColor.textPrimary)
  }

  private var name: Text { Text("\(peak.label) ·").font(HType.caption1.weight(.semibold).font) }

  private var figure: Text {
    Text(hidden ? MoneyFormat.hidden(count: 3) : MoneyFormat.string(peak.total.minor))
      .font(.system(.caption, design: .rounded, weight: .bold))
  }
}

/// "Daily budget 51.61" by its line: the words 400, the figure rounded 600, both secondary.
private struct DailyBudgetLabel: View {
  let amount: Money
  let hidden: Bool
  let wraps: Bool

  var body: some View {
    Group {
      if wraps {
        Text("\(words) \(figure)").fixedSize(horizontal: false, vertical: true)
      } else {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
          words
          figure
        }
        .fixedSize()
      }
    }
    .foregroundStyle(HColor.textSecondary)
  }

  private var words: Text { Text("Daily budget").font(HType.caption1.weight(.regular).font) }

  private var figure: Text {
    Text(hidden ? MoneyFormat.hidden(count: 3) : MoneyFormat.string(amount.minor))
      .font(.system(.caption, design: .rounded, weight: .semibold))
  }
}

/// The audio graph behind the chart: one bar per day, heights as a share of the tallest day
/// (the pitch only), each point labelled with its exact amount, or "Amount hidden".
struct DayByDayDescriptor: AXChartDescriptorRepresentable {
  let chart: DayByDay
  let name: String
  let hidden: Bool

  func makeChartDescriptor() -> AXChartDescriptor {
    let top = max(1, chart.scaleTop.minor)
    let days = AXCategoricalDataAxisDescriptor(title: "Day", categoryOrder: chart.days.map { "\($0.day)" })
    let height = AXNumericDataAxisDescriptor(title: "Share of the tallest day", range: 0...100, gridlinePositions: []) {
      "\(Int($0)) percent"
    }
    let points = chart.days.map { day in
      AXDataPoint(
        x: "\(day.day)", y: Double(day.spent.minor * 100 / top),
        label: "\(day.date.short), " + (hidden ? "Amount hidden" : "AED \(MoneyFormat.string(day.spent.minor))"))
    }
    return AXChartDescriptor(
      title: "Day by day, \(chart.range)", summary: chart.caption, xAxis: days, yAxis: height,
      additionalAxes: [], series: [AXDataSeriesDescriptor(name: name, isContinuous: false, dataPoints: points)])
  }
}
