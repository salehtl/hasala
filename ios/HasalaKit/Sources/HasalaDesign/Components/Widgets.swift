import HasalaModels
import SwiftUI

// The Home canvas widgets (Paper "Widgets · launch set", "Home · Default"): r26, Small 175², Medium 362 wide.
// The same views will draw the WidgetKit extension's cards (spec 04 DV-8).

private let widgetShadowNear = Color(HRGBA(0, 0, 0, 0.0588))  // #0000000F
private let widgetShadowFar = Color(HRGBA(0, 0, 0, 0.0784))  // #00000014

extension View {
  func widgetChrome<S: ShapeStyle>(_ fill: S, padding: EdgeInsets) -> some View {
    self
      .padding(padding)
      .background(fill, in: RoundedRectangle(cornerRadius: HRadius.widget, style: .continuous))
      .clipShape(RoundedRectangle(cornerRadius: HRadius.widget, style: .continuous))
      .shadow(color: widgetShadowNear, radius: 1, x: 0, y: 1)
      .shadow(color: widgetShadowFar, radius: 12, x: 0, y: 8)
  }

  func smallWidget() -> some View {
    frame(maxWidth: .infinity, minHeight: HContainer.widgetUnit, maxHeight: HContainer.widgetUnit, alignment: .leading)
  }
}

/// The darker end of each bucket's legend dot (Paper draws hue-end → this, 160°).
private extension Bucket {
  var dotEnd: Color {
    switch self {
    case .needs: Color(HRGBA(233, 184, 119, 1))  // oklab(81.3% 0.028 0.096)
    case .wants: Color(HRGBA(187, 166, 230, 1))  // oklab(76.6% 0.045 -0.081)
    case .savings: Color(HRGBA(147, 211, 181, 1))  // oklab(81.5% -0.075 0.022)
    default: Color(tokens.ink)
    }
  }
}

/// Budget pace (Medium): one row per bucket with its bar; "✓ Done" when funded.
public struct BudgetPaceWidgetView: View {
  let model: BudgetPaceWidget
  let hidden: Bool

  public init(_ model: BudgetPaceWidget, hidden: Bool) {
    self.model = model
    self.hidden = hidden
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        HStack(spacing: 8) {
          Circle().fill(HColor.actionAccentSubtle).frame(width: 28, height: 28)
            .overlay {
              Image(systemName: Glyph.budgetPie.symbolName)
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(HColor.actionAccent)
            }
            .accessibilityHidden(true)
          Text("Budget pace").hType(.subheadline.weight(.semibold)).foregroundStyle(HColor.textPrimary)
        }
        Spacer(minLength: 8)
        Text(model.monthGone).hType(.footnote).foregroundStyle(HColor.textSecondary)
      }
      ForEach(model.rows) { row in
        VStack(spacing: 6) {
          HStack(spacing: 8) {
            Circle()
              .fill(LinearGradient(colors: [Color(row.bucket.tokens.end), row.bucket.dotEnd],
                                   startPoint: UnitPoint(x: 0.33, y: 0), endPoint: UnitPoint(x: 0.67, y: 1)))
              .frame(width: 10, height: 10)
            Text(row.bucket.title).hType(.subheadline.weight(.semibold)).foregroundStyle(HColor.textPrimary)
            Text(MoneyPhrase([.amount(row.spent, .compact), .text(" of "), .amount(row.budget, .compact)])
              .rendered(hidden: hidden))
              .hType(.footnote).foregroundStyle(HColor.textSecondary).lineLimit(1)
            Spacer(minLength: 4)
            if row.verdict == .done {
              HStack(spacing: 4) {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                Text("Done").hType(.subheadline.weight(.semibold))
              }
              .foregroundStyle(HColor.statusSuccessForeground)
            } else {
              Text(MoneyPhrase([.amount(row.left, .compact), .text(" left")]).rendered(hidden: hidden))
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(row.left.isNegative ? HColor.paceOverBudget : HColor.textPrimary)
                .lineLimit(1)
            }
          }
          ProgressLine(row.progress, fill: row.verdict.fill)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.bucket.title)
        .accessibilityValue(rowSummary(row))
      }
    }
    .widgetChrome(HColor.widgetSurface, padding: EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Budget pace, \(model.monthGone)")
  }

  private func rowSummary(_ row: BucketPaceRow) -> String {
    if hidden { return "Amounts hidden, \(row.verdict.label)" }
    let spent = MoneyFormat.string(row.spent.minor, style: .compact)
    let budget = MoneyFormat.string(row.budget.minor, style: .compact)
    if row.verdict == .done { return "\(spent) of \(budget), done" }
    return "\(spent) of \(budget), \(MoneyFormat.string(row.left.minor, style: .compact)) left"
  }
}

/// Next bill (Small): hue disc, due chip, amount and payee line.
public struct NextBillWidgetView: View {
  let model: NextBillWidget
  let hidden: Bool

  public init(_ model: NextBillWidget, hidden: Bool) {
    self.model = model
    self.hidden = hidden
  }

  public var body: some View {
    VStack(alignment: .leading) {
      HStack {
        HueDisc(hue: model.hue, glyph: model.glyph, size: 34, iconSize: 18)
        Spacer(minLength: 4)
        StatusPillView(model.due, surface: .tinted)
      }
      Spacer(minLength: 0)
      VStack(alignment: .leading, spacing: 2) {
        MoneyText(model.amount, figure: .large, unit: HFigure.compact.weight(.semibold), hidden: hidden,
                  hiddenGlyphs: 3, color: HColor.textPrimary, unitGap: 4)
        Text(model.caption).hType(.footnote).foregroundStyle(HColor.textSecondary).lineLimit(1)
      }
    }
    .smallWidget()
    .widgetChrome(HColor.widgetSurface, padding: EdgeInsets(top: 12, leading: 16, bottom: 16, trailing: 12))
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Next bill")
  }
}

/// Net worth (Small, inverse): sparkline behind the total and this month's change.
public struct NetWorthWidgetView: View {
  let model: NetWorthWidget
  let hidden: Bool

  public init(_ model: NetWorthWidget, hidden: Bool) {
    self.model = model
    self.hidden = hidden
  }

  public var body: some View {
    VStack(alignment: .leading) {
      HStack(spacing: 8) {
        Circle().fill(Color(HRGBA(255, 255, 255, 0.12))).frame(width: 34, height: 34)
          .overlay {
            Image(systemName: Glyph.trendUp.symbolName)
              .font(.system(size: 14, weight: .semibold)).foregroundStyle(HColor.widgetOnInverse)
          }
          .accessibilityHidden(true)
        Text("Net worth").hType(.footnote.weight(.semibold)).foregroundStyle(HColor.widgetOnInverseSecondary)
      }
      Spacer(minLength: 0)
      VStack(alignment: .leading, spacing: 2) {
        MoneyText(model.total, figure: HFigure(size: 30, leading: 36, weight: .bold, tracking: -0.5, textStyle: .title),
                  unit: HFigure.compact.weight(.semibold), style: .rounded, hidden: hidden, hiddenGlyphs: 6,
                  color: HColor.widgetOnInverse, unitColor: HColor.widgetOnInverseSecondary, unitGap: 4)
        HStack(spacing: 6) {
          Circle().fill(HColor.green300).frame(width: 7, height: 7)
          Text(model.change.rendered(hidden: hidden)).hType(.footnote.weight(.semibold))
            .foregroundStyle(HColor.green300)
        }
      }
    }
    .smallWidget()
    .background(alignment: .top) {
      Sparkline(points: model.spark)
        .frame(height: 70)
        .padding(.top, 44)
    }
    .widgetChrome(HColor.widgetSurfaceInverse, padding: EdgeInsets(top: 12, leading: 16, bottom: 16, trailing: 12))
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Net worth")
  }
}

/// The net-worth sparkline: a soft line over a faint area (geometry only).
struct Sparkline: View {
  let points: [Permille]

  var body: some View {
    GeometryReader { geo in
      let line = path(in: geo.size)
      ZStack {
        line.closedArea(in: geo.size).fill(Color(HRGBA(255, 255, 255, 0.05)))
        line.stroke(Color(HRGBA(255, 255, 255, 0.22)),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
      }
    }
    .padding(.horizontal, -16)
    .accessibilityHidden(true)
  }

  private func path(in size: CGSize) -> Path {
    var p = Path()
    guard points.count > 1 else { return p }
    let step = (size.width + 32) / CGFloat(points.count - 1)
    for (i, pt) in points.enumerated() {
      let point = CGPoint(x: CGFloat(i) * step, y: size.height * (1 - pt.fraction))
      if i == 0 { p.move(to: point) } else { p.addLine(to: point) }
    }
    return p
  }
}

private extension Path {
  func closedArea(in size: CGSize) -> Path {
    var p = self
    guard let last = currentPoint else { return p }
    p.addLine(to: CGPoint(x: last.x, y: size.height))
    p.addLine(to: CGPoint(x: 0, y: size.height))
    p.closeSubpath()
    return p
  }
}

/// A project (Small): peach disc, what's left, target line and progress.
public struct ProjectWidgetView: View {
  let model: ProjectWidget
  let hidden: Bool

  public init(_ model: ProjectWidget, hidden: Bool) {
    self.model = model
    self.hidden = hidden
  }

  public var body: some View {
    VStack(alignment: .leading) {
      HStack(spacing: 8) {
        HueDisc(hue: .peach, glyph: model.glyph, size: 34, iconSize: 18)
        Text(model.name).hType(.footnote.weight(.semibold)).foregroundStyle(HColor.textPrimary).lineLimit(1)
      }
      Spacer(minLength: 0)
      VStack(alignment: .leading, spacing: 8) {
        VStack(alignment: .leading, spacing: 0) {
          HStack(alignment: .firstTextBaseline, spacing: 5) {
            MoneyText(model.left, figure: .large, style: .compact, hidden: hidden, color: HColor.textPrimary)
            Text("left").hFigure(HFigure.compact.weight(.semibold)).foregroundStyle(HColor.textPrimary)
          }
          Text(model.caption.rendered(hidden: hidden)).hType(.footnote).foregroundStyle(HColor.textSecondary)
            .lineLimit(1)
        }
        ProgressLine(model.progress)
      }
    }
    .smallWidget()
    .widgetChrome(HColor.widgetSurface, padding: EdgeInsets(top: 12, leading: 16, bottom: 16, trailing: 16))
    .accessibilityElement(children: .combine)
  }
}

/// A savings goal (Small, mint): percent funded, amounts and progress.
public struct GoalWidgetView: View {
  let model: GoalWidget
  let hidden: Bool

  public init(_ model: GoalWidget, hidden: Bool) {
    self.model = model
    self.hidden = hidden
  }

  public var body: some View {
    VStack(alignment: .leading) {
      HStack(spacing: 6) {
        Image(systemName: model.glyph.symbolName).font(.system(size: 14, weight: .semibold))
          .accessibilityHidden(true)
        Text(model.name).hType(.footnote.weight(.semibold)).lineLimit(1)
      }
      .foregroundStyle(Hue.mint.ink)
      .frame(height: 34)
      Spacer(minLength: 0)
      VStack(alignment: .leading, spacing: 8) {
        VStack(alignment: .leading, spacing: 0) {
          Text(model.percentLabel).hFigure(.hero).foregroundStyle(Hue.mint.ink)
          Text(model.caption.rendered(hidden: hidden)).hType(.footnote).foregroundStyle(HColor.textOnHueSecondary)
            .lineLimit(1)
        }
        ProgressLine(model.progress, fill: Hue.mint.ink, track: HColor.progressTrackOnHue)
      }
    }
    .smallWidget()
    .widgetChrome(Hue.mint.gradient, padding: EdgeInsets(top: 12, leading: 16, bottom: 16, trailing: 16))
    .accessibilityElement(children: .combine)
  }
}

/// Today (Medium): the day's transactions as compact rows.
public struct TodayWidgetView: View {
  let model: TodayWidget
  let hidden: Bool

  public init(_ model: TodayWidget, hidden: Bool) {
    self.model = model
    self.hidden = hidden
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text("Today").hType(.subheadline.weight(.semibold)).foregroundStyle(HColor.textPrimary)
          .accessibilityAddTraits(.isHeader)
        Spacer()
        Text(model.summary.rendered(hidden: hidden)).hType(.footnote).foregroundStyle(HColor.textSecondary)
          .accessibilityLabel(model.summary.spoken(hidden: hidden))
      }
      .padding(.bottom, 4)
      ForEach(model.rows) { TxnRow($0, hidden: hidden, compact: true) }
    }
    .widgetChrome(HColor.widgetSurface, padding: EdgeInsets(top: 14, leading: 16, bottom: 8, trailing: 16))
    .accessibilityElement(children: .contain)
  }
}

/// The dashed "Add widget" slot at the end of the canvas.
public struct AddWidgetTile: View {
  let action: () -> Void

  public init(action: @escaping () -> Void) { self.action = action }

  public var body: some View {
    Button(action: action) {
      HStack(spacing: 12) {
        Circle().fill(HColor.surfacePrimary).frame(width: 44, height: 44)
          .overlay {
            Image(systemName: "plus").font(.system(size: 17, weight: .semibold)).foregroundStyle(HColor.actionAccent)
          }
          .elevation()
        Text("Add widget").hType(.headline).foregroundStyle(HColor.textLink)
      }
      .frame(maxWidth: .infinity, minHeight: 96)
      .overlay {
        RoundedRectangle(cornerRadius: HRadius.widget, style: .continuous)
          .strokeBorder(HColor.neutral300, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
      }
      .contentShape(RoundedRectangle(cornerRadius: HRadius.widget))
    }
    .buttonStyle(.plain)
  }
}

/// Draws any Home widget model with its view.
public struct HomeWidgetView: View {
  let widget: HomeWidget
  let hidden: Bool

  public init(_ widget: HomeWidget, hidden: Bool) {
    self.widget = widget
    self.hidden = hidden
  }

  public var body: some View {
    switch widget {
    case .budgetPace(let m): BudgetPaceWidgetView(m, hidden: hidden)
    case .nextBill(let m): NextBillWidgetView(m, hidden: hidden)
    case .netWorth(let m): NetWorthWidgetView(m, hidden: hidden)
    case .project(let m): ProjectWidgetView(m, hidden: hidden)
    case .goal(let m): GoalWidgetView(m, hidden: hidden)
    case .today(let m): TodayWidgetView(m, hidden: hidden)
    }
  }
}
