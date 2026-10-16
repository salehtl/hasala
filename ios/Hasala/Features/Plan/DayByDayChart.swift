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
/// at most, so the name fits above. Geometry is the only place a share becomes a float.
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

  /// The plot: 131 for the bars over the 1 pt baseline.
  private let plotHeight: CGFloat = 131
  private let tallest: CGFloat = 108

  var body: some View {
    VStack(spacing: 6) {
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

  @ScaledMetric(relativeTo: .caption) private var dayLabelHeight: CGFloat = 16

  // MARK: The plot

  private func plot(width: CGFloat) -> some View {
    let slot = width / CGFloat(max(1, chart.days.count))
    let bar = min(12, slot * 0.6)
    let top = CGFloat(max(1, chart.scaleTop.minor))
    let lineY = plotHeight - CGFloat(chart.dailyBudget.minor) / top * tallest
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
      // The daily budget: a dashed line, its label just above it (or under it near the top).
      if chart.dailyBudget.minor > 0 {
        Path { p in
          p.move(to: CGPoint(x: 0, y: 1))
          p.addLine(to: CGPoint(x: width, y: 1))
        }
        .stroke(HColor.neutral400, style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
        .frame(width: width, height: 2)
        .offset(y: lineY - 1)
        dailyBudgetLabel
          .offset(y: lineY > 24 ? lineY - 20 : lineY + 4)
      }
      // The tallest day, named over its bar.
      if let peak = chart.peak, let i = chart.days.firstIndex(where: { $0.day == peak.day }) {
        let barTop = plotHeight - CGFloat(peak.total.minor) / top * tallest
        PeakLabel(peak: peak, hidden: hidden)
          .fixedSize()
          .alignmentGuide(.leading) { d in
            // Centred on the bar, kept inside the plot.
            let centre = slot * (CGFloat(i) + 0.5)
            return -min(max(0, centre - d.width / 2), max(0, width - d.width))
          }
          .alignmentGuide(.top) { d in -max(0, barTop - d.height - 5) }
      }
    }
    .frame(width: width, height: plotHeight + 1, alignment: .topLeading)
  }

  @ViewBuilder private func dayBar(_ day: DaySpend, width: CGFloat, height: CGFloat) -> some View {
    if day.spent.minor > 0 {
      UnevenRoundedRectangle(topLeadingRadius: 4, bottomLeadingRadius: 2, bottomTrailingRadius: 2,
                             topTrailingRadius: 4, style: .continuous)
        .fill(day.day == chart.today ? hue.ink : Color(hue.dotDeep))
        .frame(width: width, height: max(4, height))
    } else {
      RoundedRectangle(cornerRadius: 1.5).fill(HColor.paceTrack).frame(width: width, height: 3)
    }
  }

  private var dailyBudgetLabel: some View {
    HStack(alignment: .firstTextBaseline, spacing: 3) {
      Text("Daily budget").font(HType.caption1.weight(.regular).font)
      Text(hidden ? MoneyFormat.hidden(count: 3) : MoneyFormat.string(chart.dailyBudget.minor))
        .font(.system(.caption, design: .rounded, weight: .semibold))
    }
    .foregroundStyle(HColor.textSecondary)
    .fixedSize()
  }

  // MARK: Day numbers

  /// Every day while they fit (up to 10); past that, the first, every fifth and today.
  private func dayLabels(width: CGFloat) -> some View {
    let slot = width / CGFloat(max(1, chart.days.count))
    let every = chart.days.count <= 10
    return HStack(spacing: 0) {
      ForEach(chart.days) { day in
        let shown = every || day.day == 1 || day.day % 5 == 0 || day.day == chart.today
        let today = day.day == chart.today
        Text(shown ? "\(day.day)" : "")
          .font(.system(.caption, design: .rounded, weight: today ? .bold : .medium))
          .foregroundStyle(today ? HColor.textPrimary : HColor.textSecondary)
          .fixedSize()
          .frame(width: slot)
      }
    }
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
    parts.append("Daily budget \(spoken(chart.dailyBudget))")
    return parts.joined(separator: ". ") + "."
  }

  private func spoken(_ m: Money) -> String {
    hidden ? "Amount hidden" : "AED \(MoneyFormat.string(m.minor))"
  }
}

/// "Zuma · 412.00" over the tallest bar: 12/16, the name 600, the figure rounded 700.
private struct PeakLabel: View {
  let peak: DayByDay.Peak
  let hidden: Bool

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 4) {
      Text("\(peak.label) ·").font(HType.caption1.weight(.semibold).font)
      Text(hidden ? MoneyFormat.hidden(count: 3) : MoneyFormat.string(peak.total.minor))
        .font(.system(.caption, design: .rounded, weight: .bold))
    }
    .foregroundStyle(HColor.textPrimary)
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
