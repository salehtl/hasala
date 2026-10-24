import HasalaModels
import SwiftUI

// The Home canvas widgets (Paper "Home · Default" 14O7-0, page 18 "Widgets & Lock Screen"): one
// money fact each, r26, Small 175², Medium 362 wide. Widgets show whole dirhams ("AED 489",
// "3,309 left"; page 06 rule 5) and hide every amount with the eye (page 18 §18.7: percentages,
// counts, names and dates stay). The same views will draw the WidgetKit extension's cards
// (spec 04 DV-8).

private let widgetShadowNear = Color(HRGBA(0, 0, 0, 0.0588))  // #0000000F
private let widgetShadowFar = Color(HRGBA(0, 0, 0, 0.0784))  // #00000014

public enum WidgetHost: Sendable, Hashable {
  case canvas
  case system
}

public extension EnvironmentValues {
  @Entry var widgetHost: WidgetHost = .canvas
}

struct WidgetChrome<S: ShapeStyle, B: View>: ViewModifier {
  @Environment(\.widgetHost) private var host
  let fill: S
  let padding: EdgeInsets
  let minHeight: CGFloat?
  let backdrop: B

  func body(content: Content) -> some View {
    switch host {
    case .canvas:
      content
        .padding(padding)
        .frame(minHeight: minHeight)
        .background(alignment: .top) { backdrop }
        .background(fill, in: RoundedRectangle(cornerRadius: HRadius.widget, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: HRadius.widget, style: .continuous))
        .shadow(color: widgetShadowNear, radius: 1, x: 0, y: 1)
        .shadow(color: widgetShadowFar, radius: 12, x: 0, y: 8)
    case .system:
      content
        .padding(padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(alignment: .top) { backdrop }
    }
  }
}

extension View {
  func widgetChrome<S: ShapeStyle, B: View>(
    _ fill: S, padding: EdgeInsets, minHeight: CGFloat? = nil, @ViewBuilder backdrop: () -> B
  ) -> some View {
    modifier(WidgetChrome(fill: fill, padding: padding, minHeight: minHeight, backdrop: backdrop()))
  }

  func widgetChrome<S: ShapeStyle>(_ fill: S, padding: EdgeInsets, minHeight: CGFloat? = nil) -> some View {
    widgetChrome(fill, padding: padding, minHeight: minHeight) { EmptyView() }
  }

  /// A Small widget's content: it fills the height it is offered, so a canvas row that
  /// settles its height with `.fixedSize(horizontal: false, vertical: true)` gets two cards
  /// of equal height with their figures on the bottom edge. The card itself is the 175 pt
  /// unit, padding included (`smallWidgetChrome`), and taller when its text needs it.
  func smallWidget() -> some View {
    frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  /// A Small widget's card: Paper's 12 / 16 / 16 / `trailing` padding inside the 175 pt unit.
  func smallWidgetChrome<S: ShapeStyle, B: View>(
    _ fill: S, trailing: CGFloat, @ViewBuilder backdrop: () -> B
  ) -> some View {
    widgetChrome(fill, padding: EdgeInsets(top: 12, leading: 16, bottom: 16, trailing: trailing),
                 minHeight: HContainer.widgetUnit, backdrop: backdrop)
  }

  func smallWidgetChrome<S: ShapeStyle>(_ fill: S, trailing: CGFloat) -> some View {
    smallWidgetChrome(fill, trailing: trailing) { EmptyView() }
  }
}

extension HFigure {
  /// A widget's small heroes: 34/40 bold, −0.5 (Next bill, Project).
  static let widgetSmall = HFigure.large
  /// Net worth: 30/36 bold, −0.5.
  static let widgetNetWorth = HFigure(size: 30, leading: 36, weight: .bold, tracking: -0.5, textStyle: .title,
                                      minimumScale: 0.6)
  /// The unit and the word beside a widget figure ("AED", "left"): 15/20 semibold.
  static let widgetUnit = HFigure.compact.weight(.semibold)
}

/// A row's whole-dirham figure with what it means: "3,309 left", "770 over", "5,000 to save";
/// 3 dots when hidden.
private func wholeDirhams(_ m: Money, _ word: String) -> MoneyPhrase {
  MoneyPhrase([.amount(m, .rounded, hidden: 3), .text(" " + word)])
}

// MARK: - Budget pace (Medium)

/// Budget pace (Medium, page 16 §02 W1/W2): one row per bucket, the name, "spent of plan", what
/// is left on the right, and a 6 pt bar with no tick. Over: the bar is full rose and the right
/// says "x over" in rose. Savings: "saved of plan", "x to save", then a check and "Done" once the
/// plan is saved, with a full green bar. Widget bars stay blue (no amber).
public struct BudgetPaceWidgetView: View {
  let model: BudgetPaceWidget
  let hidden: Bool
  @Environment(\.widgetHost) private var host

  public init(_ model: BudgetPaceWidget, hidden: Bool) {
    self.model = model
    self.hidden = hidden
  }

  public var body: some View {
    Group {
      if host == .system {
        ViewThatFits(in: .vertical) {
          content(model.rows, spacing: 6, rowSpacing: 4)
          content(model.rows.filter { $0.bucket != .savings }, spacing: 8, rowSpacing: 6)
        }
      } else {
        content(model.rows, spacing: 12, rowSpacing: 6)
      }
    }
    .widgetChrome(HColor.widgetSurface, padding: host == .system
      ? EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16)
      : EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Budget pace, \(model.monthGone)")
  }

  private func content(_ rows: [BucketPaceRow], spacing: CGFloat, rowSpacing: CGFloat) -> some View {
    VStack(alignment: .leading, spacing: spacing) {
      ReflowingRow {
        HStack(spacing: 8) {
          Circle().fill(HColor.actionAccentSubtle).frame(width: 28, height: 28)
            .overlay { HIconView(.tabPlan, size: 16, color: HColor.actionAccent) }
            .accessibilityHidden(true)
          Text("Budget pace").hType(.subheadline.weight(.semibold)).foregroundStyle(HColor.textPrimary)
        }
      } trailing: {
        Text(model.monthGone).hType(.footnote).foregroundStyle(HColor.textSecondary)
      }
      ForEach(rows) { row in
        VStack(spacing: rowSpacing) {
          ReflowingRow(spacing: 12) {
            HStack(spacing: 8) {
              Circle().fill(row.bucket.hue.dotGradient).frame(width: 10, height: 10)
              Text(row.bucket.title).hType(.subheadline.weight(.semibold)).foregroundStyle(HColor.textPrimary)
              Text(spentOfPlan(row)).privacySensitive().hType(.footnote).foregroundStyle(HColor.textSecondary)
                .singleLineAtDefaultTextSize()
            }
          } trailing: {
            trailing(row)
          }
          SlimProgressBar(row.verdict == .done || row.verdict == .overBudget ? Permille(1000) : row.progress,
                          fill: fill(row))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.bucket.title)
        .accessibilityValue(rowSummary(row))
      }
    }
  }

  @ViewBuilder private func trailing(_ row: BucketPaceRow) -> some View {
    switch row.verdict {
    case .done:
      HStack(spacing: 4) {
        HIconView(.check, size: 14, color: HColor.statusSuccessForeground, strokeWidth: 3)
        Text("Done").hType(.subheadline.weight(.semibold)).foregroundStyle(HColor.statusSuccessForeground)
      }
    case .overBudget:
      Text(leftPhrase(row).rendered(hidden: hidden)).privacySensitive()
        .hFigure(.compact).foregroundStyle(HColor.paceOverBudget).singleLineAtDefaultTextSize()
    case .onTrack, .overPace:
      Text(leftPhrase(row).rendered(hidden: hidden)).privacySensitive()
        .hFigure(.compact).foregroundStyle(HColor.textPrimary).singleLineAtDefaultTextSize()
    }
  }

  /// "9,041 of 12,350"; hidden "•••• of •••".
  private func spentOfPlan(_ row: BucketPaceRow) -> String {
    spentOfPlanPhrase(row).rendered(hidden: hidden)
  }

  private func spentOfPlanPhrase(_ row: BucketPaceRow) -> MoneyPhrase {
    MoneyPhrase([.amount(row.spent, .rounded), .text(" of "), .amount(row.budget, .rounded, hidden: 3)])
  }

  /// The right of a row that is not done: "770 over", "5,000 to save" or "3,309 left".
  private func leftPhrase(_ row: BucketPaceRow) -> MoneyPhrase {
    row.verdict == .overBudget
      ? wholeDirhams(Money(minor: row.left.minor.negated), "over")
      : wholeDirhams(row.left, row.bucket == .savings ? "to save" : "left")
  }

  private func fill(_ row: BucketPaceRow) -> Color {
    switch row.verdict {
    case .done: HColor.statusSuccessForeground
    case .overBudget: HColor.paceFillOverBudget
    case .onTrack, .overPace: HColor.paceFill
    }
  }

  /// "Needs, 9,041 of 12,350, 3,309 left" (page 18 §15); hidden "Needs, amount hidden".
  private func rowSummary(_ row: BucketPaceRow) -> String {
    if hidden { return row.verdict == .done ? "Amount hidden, done" : "Amount hidden" }
    let spentOfPlan = spentOfPlanPhrase(row).spoken(hidden: false)
    return row.verdict == .done
      ? "\(spentOfPlan), done" : "\(spentOfPlan), \(leftPhrase(row).spoken(hidden: false))"
  }
}

// MARK: - Small widgets

/// Next bill (Small): the bill's hue disc and when it is due, "AED 489", the payee line.
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
        MoneyText(model.amount, figure: .widgetSmall, unit: .widgetUnit, style: .rounded, hidden: hidden,
                  hiddenGlyphs: 3, hiddenDots: 24, color: HColor.textPrimary, unitGap: 4)
        // Two lines: a 169 pt card (a 390 pt-wide phone) cannot always fit it in one.
        Text(model.caption).hType(.footnote).foregroundStyle(HColor.textSecondary).lineLimitAtDefaultTextSize(2)
      }
    }
    .smallWidget()
    .smallWidgetChrome(HColor.widgetSurface, trailing: 12)
    // "Next bill" first, then what the card shows (pill, amount, payee), so nothing drawn is
    // left out of what VoiceOver reads ("Next bill, In 4 days, AED 489, DEWA · expected Wed").
    .accessibilityElement(children: .combine)
    .accessibilityLabel { label in
      Text("Next bill")
      label
    }
  }
}

/// Net worth (Small, inverse): the sparkline behind the total and this month's change.
public struct NetWorthWidgetView: View {
  let model: NetWorthWidget
  let hidden: Bool
  @Environment(\.dynamicTypeSize) private var typeSize

  public init(_ model: NetWorthWidget, hidden: Bool) {
    self.model = model
    self.hidden = hidden
  }

  /// Up this month in green-300; down in the on-ink secondary (never red on a total).
  private var changeColor: Color {
    model.change.parts.contains { part in
      if case .signedMoney(let m, _, _) = part { return m.minor < 0 }
      return false
    } ? HColor.widgetOnInverseSecondary : HColor.green300
  }

  public var body: some View {
    VStack(alignment: .leading) {
      HStack(spacing: 8) {
        InkDisc(icon: .trendUp)
        Text("Net worth").hType(.footnote.weight(.semibold)).foregroundStyle(HColor.widgetOnInverseSecondary)
      }
      .frame(minHeight: 34)
      Spacer(minLength: 0)
      VStack(alignment: .leading, spacing: 2) {
        MoneyText(model.total, figure: .widgetNetWorth, unit: .widgetUnit, style: .rounded, hidden: hidden,
                  hiddenGlyphs: 6, hiddenDots: 22, color: HColor.widgetOnInverse, unitColor: HColor.widgetOnInverseSecondary, unitGap: 4,
                  sign: model.total.isNegative ? .debt : .none)
        HStack(spacing: 6) {
          Circle().fill(changeColor).frame(width: 7, height: 7)
          Text(model.change.rendered(hidden: hidden)).privacySensitive().hType(.footnote.weight(.semibold))
            .foregroundStyle(changeColor)
            .accessibilityLabel(model.change.spoken(hidden: hidden))
        }
        if let caption = model.mark?.caption {
          Text(caption).hType(.footnote).foregroundStyle(HColor.widgetOnInverseSecondary).lineLimit(1)
        }
      }
    }
    .smallWidget()
    // Paper: the 70 pt band from 44 down, across the whole card, behind the words. At the
    // accessibility sizes the title and the figure grow into the band, so the line would run
    // through the figure; it is decoration, and the change line says the trend in words.
    .smallWidgetChrome(HColor.widgetSurfaceInverse, trailing: 12) {
      if !typeSize.isAccessibilitySize {
        Sparkline(points: model.spark)
          .frame(height: 70)
          .padding(.top, 44)
      }
    }
    // Its own title, total and change, read together; a fixed label would drop the figures.
    .accessibilityElement(children: .combine)
  }
}

/// The net-worth sparkline: a soft line over a faint area, edge to edge of the card, the
/// points evenly apart (Paper: 11 points, 18 apart, the last at the edge). Geometry only.
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
    .accessibilityHidden(true)
  }

  private func path(in size: CGSize) -> Path {
    var p = Path()
    guard points.count > 1 else { return p }
    let step = size.width / CGFloat(points.count - 1)
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

/// A project (Small): the peach disc and its name, what's left, the target line and progress.
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
        Text(model.name).hType(.footnote.weight(.semibold)).foregroundStyle(HColor.textPrimary)
          .singleLineAtDefaultTextSize()
      }
      .frame(minHeight: 34)
      Spacer(minLength: 0)
      VStack(alignment: .leading, spacing: 8) {
        VStack(alignment: .leading, spacing: 0) {
          HStack(alignment: .firstTextBaseline, spacing: 5) {
            MoneyText(model.left, figure: .widgetSmall, style: .rounded, hidden: hidden, hiddenGlyphs: 4,
                      hiddenDots: 24, color: figureColor)
            Text(model.unit.rawValue).hFigure(.widgetUnit).foregroundStyle(figureColor)
          }
          if !model.caption.parts.isEmpty {
            Text(model.caption.rendered(hidden: hidden)).privacySensitive().hType(.footnote)
              .foregroundStyle(HColor.textSecondary)
              .lineLimitAtDefaultTextSize(2)
              .accessibilityLabel(model.caption.spoken(hidden: hidden))
          }
        }
        if let progress = model.progress {
          SlimProgressBar(progress, fill: model.unit == .over ? HColor.paceFillOverBudget : HColor.paceFill)
        }
      }
    }
    .smallWidget()
    .smallWidgetChrome(HColor.widgetSurface, trailing: 16)
    .accessibilityElement(children: .combine)
  }

  private var figureColor: Color { model.unit == .over ? HColor.paceOverBudget : HColor.textPrimary }
}

/// A savings goal (Small, the mint wash): the jar and its name, the percent funded, the
/// amounts and the progress. The percent stays when amounts hide.
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
        HIconView(model.glyph.icon, size: 18, color: Hue.mint.ink, strokeWidth: 2)
        Text(model.name).hType(.footnote.weight(.semibold)).foregroundStyle(Hue.mint.ink)
          .singleLineAtDefaultTextSize()
      }
      .frame(minHeight: 34)
      Spacer(minLength: 0)
      VStack(alignment: .leading, spacing: 8) {
        VStack(alignment: .leading, spacing: 0) {
          Text(model.percentLabel).hFigure(.hero).foregroundStyle(Hue.mint.ink)
          Text(model.caption.rendered(hidden: hidden)).privacySensitive().hType(.footnote).foregroundStyle(HColor.textOnHueSecondary)
            .lineLimitAtDefaultTextSize(2)
            .accessibilityLabel(model.caption.spoken(hidden: hidden))
        }
        SlimProgressBar(model.progress, fill: Hue.mint.ink, track: HColor.progressTrackOnHue)
      }
    }
    .smallWidget()
    .smallWidgetChrome(Hue.mint.perceptualGradient, trailing: 16)
    .accessibilityElement(children: .combine)
  }
}

// MARK: - Today (Medium)

/// Today (Medium): the day's transactions as they arrive, 48 pt rows with a 32 disc, the name
/// 15/20 600 over "Dining · 13:20", and the whole-dirham amount on the right.
public struct TodayWidgetView: View {
  let model: TodayWidget
  let hidden: Bool
  @Environment(\.widgetHost) private var host

  public init(_ model: TodayWidget, hidden: Bool) {
    self.model = model
    self.hidden = hidden
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      ReflowingRow {
        Text("Today").hType(.subheadline.weight(.semibold)).foregroundStyle(HColor.textPrimary)
          .accessibilityAddTraits(.isHeader)
      } trailing: {
        Text(model.summary.rendered(hidden: hidden)).privacySensitive().hType(.footnote).foregroundStyle(HColor.textSecondary)
          .accessibilityLabel(model.summary.spoken(hidden: hidden))
      }
      .padding(.bottom, 4)
      ForEach(host == .system ? Array(model.rows.prefix(2)) : model.rows) { TodayRow(row: $0, hidden: hidden) }
    }
    .widgetChrome(HColor.widgetSurface, padding: EdgeInsets(top: 14, leading: 16, bottom: 8, trailing: 16))
    .accessibilityElement(children: .contain)
  }
}

/// One Today row (Paper "Mini row"): at the accessibility sizes the amount moves under the words.
struct TodayRow: View {
  let row: MiniTxnRow
  let hidden: Bool
  @Environment(\.dynamicTypeSize) private var typeSize

  var body: some View {
    Group {
      if typeSize.isAccessibilitySize {
        VStack(alignment: .leading, spacing: 6) {
          disc
          words
          amount
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        HStack(spacing: 12) {
          disc
          words.frame(maxWidth: .infinity, alignment: .leading)
          amount
        }
        .frame(minHeight: 48)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(row.merchant), \(row.detail)")
    .accessibilityValue(MoneyText.spoken(row.amount, style: .rounded, sign: row.isIncome ? .income : .none,
                                         hidden: hidden))
  }

  @ViewBuilder private var disc: some View {
    if let monogram = row.monogram {
      MonogramDisc(monogram, size: 32)
    } else {
      CategoryDisc(hue: row.hue, glyph: row.glyph, size: .s32)
    }
  }

  private var words: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(row.merchant).privacySensitive().hType(.subheadline.weight(.semibold)).foregroundStyle(HColor.textPrimary)
        .singleLineAtDefaultTextSize()
      Text(row.detail).privacySensitive().hType(.footnote).foregroundStyle(HColor.textSecondary).singleLineAtDefaultTextSize()
    }
  }

  private var amount: some View {
    MoneyText(row.amount, figure: .compact, style: .rounded, hidden: hidden, hiddenGlyphs: 3,
              color: row.isIncome ? HColor.moneyIn : HColor.moneyOut, sign: row.isIncome ? .income : .none)
      .fixedSize()
  }
}

// MARK: - Canvas end

/// The dashed "Add widget" slot at the end of the canvas: 96 tall, r26, 1.5 dashed neutral-300,
/// a white 44 disc with an accent plus and "Add widget" 17 600 in the link blue.
public struct AddWidgetTile: View {
  let action: () -> Void

  public init(action: @escaping () -> Void) { self.action = action }

  public var body: some View {
    Button(action: action) {
      HStack(spacing: 12) {
        Circle().fill(HColor.surfacePrimary).frame(width: 44, height: 44)
          .overlay { HIconView(.add, size: 18, color: HColor.actionAccent, strokeWidth: 2.4) }
          .hElevation(.nearFar)
          .accessibilityHidden(true)
        Text("Add widget").hType(.headline).foregroundStyle(HColor.textLink)
      }
      .frame(maxWidth: .infinity, minHeight: 96)
      .overlay {
        RoundedRectangle(cornerRadius: HRadius.widget, style: .continuous)
          .strokeBorder(HColor.neutral300, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
      }
      .contentShape(RoundedRectangle(cornerRadius: HRadius.widget))
    }
    .buttonStyle(HPressStyle(in: RoundedRectangle(cornerRadius: HRadius.widget, style: .continuous)))
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
    case .spentSoFar(let m): SpentSoFarWidgetView(m, hidden: hidden)
    case .categoryWatch(let m): CategoryWatchWidgetView(m, hidden: hidden)
    case .comingUp(let m): ComingUpWidgetView(m, hidden: hidden)
    case .toReview(let m): ToReviewWidgetView(m, hidden: hidden)
    }
  }
}

public struct HomeCanvasItemView: View {
  let item: HomeCanvasItem
  let hidden: Bool

  public init(_ item: HomeCanvasItem, hidden: Bool) {
    self.item = item
    self.hidden = hidden
  }

  public var body: some View {
    if let widget = item.widget {
      HomeWidgetView(widget, hidden: hidden)
    } else {
      WaitingWidgetView(title: item.kind.title, sentence: item.kind.waitingSentence)
    }
  }
}
