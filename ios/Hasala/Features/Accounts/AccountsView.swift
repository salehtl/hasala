import HasalaDesign
import HasalaModels
import Observation
import SwiftUI

/// Accounts · Net worth (Paper 1W6-0), pushed from Home's net worth widget and Profile ›
/// Accounts. Read only: the net worth with this month's change, the last 12 months, then the
/// accounts that count in your plan and the ones tracked for net worth only.
///
/// Live has no net worth history yet, so the change line and the chart show only when the
/// ledger has them. A row's check-in sheet and "Add an account" aren't built (Debug shows
/// "Add an account" as a placeholder).
struct AccountsView: View {
  @Bindable var app: AppModel
  @State private var model: AccountsViewModel

  init(app: AppModel) {
    self.app = app
    _model = State(initialValue: AccountsViewModel(app: app))
  }

  private var snap: AccountsSnapshot { model.snapshot }
  private var unfinished: Bool { BuildSurface.showsUnfinished }

  var body: some View {
    PushedPage(app: app, title: "Accounts", wash: .onTrack) {
      hero.padding(.horizontal, HSpacing.insetPage)
      if let chart = snap.chart {
        NetWorthChartCard(chart: chart).padding(.horizontal, HSpacing.insetPage)
      }
      if !snap.everyday.isEmpty {
        section("Everyday money", subtitle: "Counts in your plan", total: snap.everydayTotal, rows: snap.everyday)
          .padding(.horizontal, HSpacing.insetPage)
      }
      if !snap.tracking.isEmpty {
        section("Tracking", subtitle: "Counts in net worth, not in your plan", total: nil, rows: snap.tracking)
          .padding(.horizontal, HSpacing.insetPage)
      }
      if unfinished {
        // TODO(spec 13 B3): "Add an account" (not drawn past the button).
        Button("Add an account") { app.say("Adding an account comes in a later build", icon: .add) }
          .buttonStyle(.pill(.onGrouped, fill: true, leadingIcon: .add))
          .accessibilityIdentifier("accounts.add")
          .padding(.horizontal, HSpacing.insetPage)
      }
    }
    .toolbar {
      if unfinished {
        ToolbarItem(placement: .topBarTrailing) {
          Button { app.say("Adding an account comes in a later build", icon: .add) } label: {
            Image(systemName: "plus")
          }
          .accessibilityLabel("Add an account")
        }
      }
    }
  }

  /// "NET WORTH / AED 227,568.00 / ↑ +2,140.00 this month".
  private var hero: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Net worth").hType(.overline).foregroundStyle(HColor.textOnWashSecondary)
        .accessibilityAddTraits(.isHeader)
      MoneyText(snap.netWorth, figure: .hero, unit: .unit, hidden: model.hidden, hiddenGlyphs: 6,
                color: HColor.textPrimary, sign: snap.netWorth.isNegative ? .debt : .none)
        .accessibilityIdentifier("accounts.netWorth")
      if let change = snap.monthChange {
        let up = !change.isNegative
        let color = up ? HColor.moneyIn : HColor.moneyOut
        HStack(spacing: 6) {
          PathGlyph(d: up ? "M12 19V5M5.5 11.5 12 5l6.5 6.5" : "M12 5v14M5.5 12.5 12 19l6.5-6.5", color: color)
          MoneyText(change, figure: .compact, hidden: model.hidden, hiddenGlyphs: 3, color: color,
                    sign: up ? .income : .debt)
          Text("this month").hType(.subheadline).foregroundStyle(color)
        }
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("accounts.change")
      }
    }
    .padding(.top, 4)
  }

  /// "Everyday money / Counts in your plan ……… 38,163.00" over its list card.
  private func section(_ title: String, subtitle: String, total: Money?, rows: [AccountRowModel]) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      ReflowingRow(alignment: .bottom) {
        VStack(alignment: .leading, spacing: 2) {
          Text(title).hType(.section).foregroundStyle(HColor.textPrimary).accessibilityAddTraits(.isHeader)
          Text(subtitle).hType(.subheadline).foregroundStyle(HColor.textSecondary)
        }
      } trailing: {
        if let total {
          MoneyText(total, figure: .unit, hidden: model.hidden, hiddenGlyphs: 4, color: HColor.textSecondary,
                    sign: total.isNegative ? .debt : .none)
        }
      }
      HListCard {
        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
          if index > 0 { HDivider(inset: .disc68) }
          AccountRow(row: row, hidden: model.hidden)
            .accessibilityIdentifier("accounts.row.\(row.id)")
        }
      }
    }
  }
}

@MainActor
@Observable
final class AccountsViewModel {
  private let app: AppModel
  @ObservationIgnored private var memo = Memo<Int, AccountsSnapshot>()

  init(app: AppModel) { self.app = app }

  var snapshot: AccountsSnapshot {
    memo.value(for: app.store.revision) { AccountsEngine.snapshot(app.store.state, now: app.store.now) }
  }
  var hidden: Bool { app.amountsHidden }
}

/// One account (page 16 §14 AccountRow): the bank plate (radius 12, initials in the hue's ink,
/// or the cash glyph), the name and the balance on one baseline ("−" for card debt), and the
/// last four with when it was checked. Min 64. VoiceOver: "Emirates NBD Current, AED 41,823.50,
/// ···4412 · checked in 3 days ago · 6 since".
private struct AccountRow: View {
  let row: AccountRowModel
  let hidden: Bool
  @Environment(\.dynamicTypeSize) private var typeSize

  var body: some View {
    let layout = typeSize.isAccessibilitySize
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
      : AnyLayout(HStackLayout(spacing: HSpacing.listRowGap))
    layout {
      plate
      VStack(alignment: .leading, spacing: 2) {
        ReflowingRow(alignment: .firstTextBaseline) {
          Text(row.name).hType(.rowTitle).foregroundStyle(HColor.listRowTitle)
        } trailing: {
          MoneyText(row.balance, figure: .row, hidden: hidden, hiddenGlyphs: 3, color: HColor.moneyOut,
                    sign: row.balance.isNegative ? .debt : .none)
            .fixedSize()
        }
        if !row.detail.isEmpty {
          Text(row.detail).hType(.footnote).foregroundStyle(HColor.listRowSupporting).singleLineAtDefaultTextSize()
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, HSpacing.listRowInsetInline)
    .padding(.vertical, HSpacing.listRowInsetBlock)
    .frame(maxWidth: .infinity, minHeight: HSpacing.listRowMinHeightTwoLine, alignment: .leading)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(spoken)
  }

  @ViewBuilder private var plate: some View {
    switch row.plate {
    case .initials(let initials):
      // Paper sets the initials in Inter 800, 17/22 for a single letter ("S").
      if initials.count == 1 {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(row.hue.perceptualGradient)
          .frame(width: 40, height: 40)
          .overlay { Text(initials).font(.custom(HWeight.bold.interFace, size: 17)).foregroundStyle(row.hue.ink) }
          .accessibilityHidden(true)
      } else {
        BankPlate(initials: initials, hue: row.hue)
      }
    case .cash:
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(row.hue.perceptualGradient)
        .frame(width: 40, height: 40)
        .overlay { HIconView(.cash, size: 22, color: row.hue.ink) }
        .accessibilityHidden(true)
    }
  }

  private var spoken: String {
    let sign = row.balance.isNegative ? "minus " : ""
    let balance = hidden ? "Amount hidden" : "\(sign)\(row.balance.currency) \(MoneyFormat.string(row.balance.minor))"
    return [row.name, balance, row.detail].filter { !$0.isEmpty }.joined(separator: ", ")
  }
}

/// "Last 12 months" (1W6-0 · Chart card): a smooth line in the accent over a fading area, a
/// dashed baseline at the oldest month, the end dot on this month, and the month initials
/// under it, this month in bold. The points are the ledger's permille geometry, right-aligned
/// to the months, so a shorter history ends on this month too. One VoiceOver element.
private struct NetWorthChartCard: View {
  let chart: NetWorthChart

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Last 12 months").hType(.subheadline.weight(.semibold)).foregroundStyle(HColor.textPrimary)
      VStack(spacing: -6) {
        Canvas { context, size in draw(&context, size) }
          .frame(height: 120)
        HStack(spacing: 0) {
          ForEach(Array(chart.months.enumerated()), id: \.offset) { index, month in
            Text(month)
              .hType(HType(size: 12, leading: 16, weight: index == chart.months.count - 1 ? .bold : .medium,
                           textStyle: .caption))
              .foregroundStyle(index == chart.months.count - 1 ? HColor.textPrimary : HColor.textSecondary)
              // A column is 1/12 of the card: a large letter shrinks to fit it.
              .lineLimit(1)
              .minimumScaleFactor(0.5)
              .frame(maxWidth: .infinity)
          }
        }
      }
    }
    .padding(.top, 18)
    .padding(.horizontal, 20)
    .padding(.bottom, 16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.card, style: .continuous))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Net worth, last 12 months")
    .accessibilityValue(trend)
    .accessibilityIdentifier("accounts.chart")
  }

  /// Rising, falling or level, from the first point to the last.
  private var trend: String {
    guard let first = chart.points.first, let last = chart.points.last else { return "" }
    return last > first ? "Rising" : last < first ? "Falling" : "Level"
  }

  /// Paper's geometry on a 322 × 120 box: the line from y 102.44 (lowest) to 17.75 (highest),
  /// each point in the middle of its month's column.
  private func draw(_ context: inout GraphicsContext, _ size: CGSize) {
    let columns = CGFloat(max(chart.months.count, 1))
    let column = size.width / columns
    let low = CGFloat(chart.points.min() ?? 0)
    let high = CGFloat(chart.points.max() ?? 1)
    let bottom = size.height * 102.44 / 120
    let top = size.height * 17.75 / 120
    let offset = chart.months.count - chart.points.count
    let points: [CGPoint] = chart.points.enumerated().map { i, v in
      let x = column * (CGFloat(i + offset) + 0.5)
      let t = high > low ? (CGFloat(v) - low) / (high - low) : 0.5
      return CGPoint(x: x, y: bottom - t * (bottom - top))
    }
    var baseline = Path()
    baseline.move(to: CGPoint(x: 0, y: bottom))
    baseline.addLine(to: CGPoint(x: size.width, y: bottom))
    context.stroke(baseline, with: .color(HColor.borderSubtle), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
    guard let first = points.first, let last = points.last else { return }
    let line = Self.smooth(points)
    var area = line
    area.addLine(to: CGPoint(x: last.x, y: size.height))
    area.addLine(to: CGPoint(x: first.x, y: size.height))
    area.closeSubpath()
    context.fill(area, with: .linearGradient(
      Gradient(colors: [HColor.actionAccent.opacity(0.18), HColor.actionAccent.opacity(0)]),
      startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: size.height)))
    context.stroke(line, with: .color(HColor.actionAccent),
                   style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
    let dot = Path(ellipseIn: CGRect(x: last.x - 5.5, y: last.y - 5.5, width: 11, height: 11))
    context.fill(dot, with: .color(HColor.actionAccent))
    context.stroke(dot, with: .color(HColor.white), lineWidth: 2.5)
  }

  /// A Catmull-Rom curve through the points as cubic Béziers (control points a sixth of the
  /// way to the neighbours), as Paper's path is drawn.
  static func smooth(_ p: [CGPoint]) -> Path {
    var path = Path()
    guard let first = p.first else { return path }
    path.move(to: first)
    for i in 0..<(p.count - 1) {
      let p0 = p[max(i - 1, 0)], p1 = p[i], p2 = p[i + 1], p3 = p[min(i + 2, p.count - 1)]
      let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
      let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
      path.addCurve(to: p2, control1: c1, control2: c2)
    }
    return path
  }
}
