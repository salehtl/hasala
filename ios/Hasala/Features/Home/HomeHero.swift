import HasalaDesign
import HasalaModels
import SwiftUI

/// Hero · Spent on needs + wants (Paper 14SX-0, page 16 §01–02): the period pill, "Day 10 of
/// 31", the figure, the caption, one bar for the month, the verdict in words and the Needs,
/// Wants and Savings tiles. 20 from the screen edges, 16 between its blocks.
///
/// Motion (owner's motion policy, B1.3; `HeroReveal`): the first time Home appears after
/// launch, the bar fills over 300 ms with the figure rolling on it, the tick drops in (120 ms)
/// as the bar lands, then the verdict fades in (150 ms): 0–300–420–570 ms. Home is seen many
/// times a day, so every later appearance, a tab switch or a return from a sheet shows the
/// final state at once. A change while Home is open (a new transaction) moves the bar on
/// `fillUpdate` (250 ms) and rolls the figure; the wash and the verdict cross-fade when the
/// verdict changes. Reduce Motion shows the final state.
struct HomeHero: View {
  let hero: SpendHero
  let hidden: Bool
  /// "October 2026", "Aug – Oct 2026".
  let period: String
  let isThisMonth: Bool
  let changePeriod: () -> Void
  let backToThisMonth: () -> Void
  /// "Insights": pushes Insights for Home's period.
  let insights: (() -> Void)?
  /// "Set your plan" with no plan yet: the Plan tab.
  let setPlan: () -> Void
  let openNotCounted: (SpendHero.NotCounted) -> Void

  @Environment(\.hMotion) private var policy
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dynamicTypeSize) private var typeSize
  @State private var phase = PaceFillPhase()

  private var motion: MotionPolicy {
    MotionPolicy(reduceMotion: policy.reduceMotion || reduceMotion, settled: policy.settled)
  }

  private var isLive: Bool { hero.state == .live }

  /// Spent as a share of the plan, for the bar's geometry only.
  private var hasBar: Bool { hero.state == .live || hero.state == .ended }

  private var target: Double {
    hasBar && hero.plan.minor > 0 ? Double(max(0, hero.spent.minor)) / Double(hero.plan.minor) : 0
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      periodRow
      figureBlock
      VStack(alignment: .leading, spacing: 10) {
        if hero.state == .range {
          HeroMonthBars(bars: hero.bars, hidden: hidden)
        } else {
          MonthPaceBar(
            spent: hero.spent, plan: hasBar ? hero.plan : .aed(0), tick: isLive ? hero.tick : nil,
            verdict: hero.verdict ?? .onTrack, overflow: 18, hidden: hidden, live: isLive, phase: phase)
        }
        verdictLine
          .opacity(phase.verdictVisible ? 1 : 0)
      }
      VStack(alignment: .leading, spacing: typeSize.isAccessibilitySize ? 8 : 2) {
        tiles
        if let line = hero.notCounted {
          NotCountedLine(line: line, hidden: hidden) { openNotCounted(line) }
        }
      }
      if let note = hero.note {
        Text(note.rendered(hidden: hidden)).hType(.subheadline).foregroundStyle(HColor.textOnWashSecondary)
          .accessibilityLabel(note.spoken(hidden: hidden))
          .accessibilityIdentifier("home.hero.note")
      }
    }
    .padding(.horizontal, HSpacing.insetPage)
    .heroReveal($phase, target: target, policy: motion)
    #if HASALA_MOCKS
      .modifier(RevealTimingProbe(phase: phase, target: target))
    #endif
  }

  private var periodRow: some View {
    ReflowingRow(spacing: 12) {
      PeriodPill(period, tinted: !isThisMonth, action: changePeriod)
        .accessibilityIdentifier("home.period")
    } trailing: {
      if !isThisMonth {
        Button(action: backToThisMonth) {
          Text("Back to this month")
            .hType(.subheadline.weight(.medium))
            .foregroundStyle(HColor.textOnWashLink)
            .frame(minHeight: HSpacing.targetMinimum)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("home.backToThisMonth")
      }
    }
  }

  // MARK: Figure

  private var figureBlock: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(hero.overline).hType(.overline).foregroundStyle(HColor.textOnWashSecondary)
      // 6 dots at Paper's 38 pt when hidden (page 06 §6.3). The figure is its own element
      // (`home.hero.left`, plan decision 8) and carries the caption as its value, so VoiceOver
      // reads "AED 10,288.34, spent of 19,000 on needs and wants".
      // The figure is zero until the reveal's fill starts, so it rolls on the fill's curve. A
      // live change rolls it on the bar's own 250 ms curve, so both land together.
      HeroFigure(amount: phase.figure(hero.spent), hidden: hidden, approx: hero.approx)
        .hAnimation(.fillUpdate, value: hero.spent)
        .accessibilityValue(hero.caption.spoken(hidden: hidden))
        .accessibilityIdentifier("home.hero.left")
      Text(hero.caption.rendered(hidden: hidden)).hType(.body).foregroundStyle(HColor.textOnWashSecondary)
        .accessibilityHidden(true)
    }
  }

  // MARK: Verdict

  /// The verdict word changes only with the verdict; the line cross-fades when it does.
  private var verdictKey: String { hero.word.rendered(hidden: true) }

  private var verdictLine: some View {
    ZStack(alignment: .leading) {
      verdictContent
        .id(verdictKey)
        .transition(motion.transition(.stateSwap))
    }
    .animation(motion.animation(.stateSwap), value: verdictKey)
  }

  @ViewBuilder private var verdictContent: some View {
    switch hero.state {
    case .syncing:
      Text(hero.word.rendered(hidden: hidden)).hType(.subheadline).foregroundStyle(HColor.textOnWashSecondary)
    case .noPlan:
      HeroVerdictLine(verdict: nil, word: hero.word, fact: nil, hidden: hidden,
                      link: .init("Set your plan", identifier: "home.setPlan", action: setPlan))
    case .live, .ended:
      HeroVerdictLine(verdict: hero.verdict, word: hero.word, fact: hero.fact, hidden: hidden,
                      link: insights.map { .init("Insights", identifier: "home.insights", action: $0) })
    case .range:
      ReflowingRow(spacing: 12) {
        Text("\(Text(hero.word.rendered(hidden: hidden)).font(HType.subheadline.weight(.semibold).font).foregroundStyle(HColor.textPrimary))\(Text(verbatim: hero.fact.map { " · " + $0.rendered(hidden: hidden) } ?? ""))")
          .hType(.subheadline)
          .foregroundStyle(HColor.textOnWashSecondary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityLabel([hero.word.spoken(hidden: hidden), hero.fact?.spoken(hidden: hidden)].compactMap { $0 }
            .joined(separator: ", "))
      } trailing: {
        if let insights {
          Button(action: insights) {
            Text("Insights")
              .hType(.subheadline.weight(.medium))
              .foregroundStyle(HColor.textOnWashLink)
              .padding(.vertical, 12)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .padding(.vertical, -12)
          .accessibilityIdentifier("home.insights")
        }
      }
    }
  }

  // MARK: Tiles

  /// Three tiles side by side, their figures shrinking to fit; stacked at the accessibility sizes.
  @ViewBuilder private var tiles: some View {
    if typeSize.isAccessibilitySize {
      VStack(spacing: 8) { tileViews }
    } else {
      HStack(spacing: 8) { tileViews }
    }
  }

  /// Needs, Wants and Savings (`home.tile.needs`, `.wants`, `.savings`). Not controls.
  private var tileViews: some View {
    ForEach(hero.tiles) { tile in
      StatTile(tile, hidden: hidden)
        .accessibilityIdentifier("home.tile.\(tile.label.lowercased())")
    }
  }
}

/// The hero figure on Paper's 58 pt line: "AED" 20/24 and the figure 56/58 bold, −1.2, on one
/// baseline. SF Rounded's own line at 56 is about 66.6, so the line gives back the difference
/// (the design system adds leading but never takes it away). Hidden, six dots at 38 sit on the
/// 58 line already. Capped at AX3 with the figure, so the trim scales with it.
private struct HeroFigure: View {
  let amount: Money
  let hidden: Bool
  let approx: Bool

  var body: some View {
    HeroFigureLine(amount: amount, hidden: hidden, approx: approx)
      .dynamicTypeSize(...HFigure.display.maxDynamicTypeSize)
  }
}

private struct HeroFigureLine: View {
  let amount: Money
  let hidden: Bool
  let approx: Bool
  /// Half of 56 × 1.19 − 58.
  @ScaledMetric(relativeTo: .largeTitle) private var trim: CGFloat = 4.32

  var body: some View {
    // Paper's hidden hero: 38 pt dots, 3 pt apart, on the 58 line (page 18 §18.7).
    MoneyText(amount, figure: .display, unit: .displayUnit, hidden: hidden, hiddenGlyphs: 6, hiddenDots: 38,
              hiddenTracking: 3, color: HColor.textPrimary, sign: amount.isNegative ? .debt : .none, approx: approx)
      .padding(.vertical, hidden ? 0 : -trim)
  }
}

private struct NotCountedLine: View {
  let line: SpendHero.NotCounted
  let hidden: Bool
  let action: () -> Void

  @Environment(\.dynamicTypeSize) private var typeSize
  @ScaledMetric(relativeTo: .subheadline) private var lane: CGFloat = 20

  var body: some View {
    Button(action: action) {
      if typeSize.isAccessibilitySize {
        HStack(alignment: .top, spacing: 12) {
          mark(32, glyph: 18, stroke: 2.2)
            .frame(height: lane)
          text
        }
        .padding(.vertical, 10)
      } else {
        HStack(spacing: 8) {
          mark(20, glyph: 12, stroke: 2.4)
          text
          HIconView(.chevronRight, size: 14, color: HColor.iconTertiary, strokeWidth: 2.4)
        }
      }
    }
    .buttonStyle(.plain)
    .frame(maxWidth: .infinity, minHeight: HSpacing.targetMinimum, alignment: .leading)
    .contentShape(Rectangle())
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(line.line.spoken(hidden: hidden))
    .accessibilityAddTraits(.isButton)
    .accessibilityIdentifier("home.hero.notCounted")
  }

  private var text: some View {
    Text(line.line.rendered(hidden: hidden))
      .hType(.subheadline)
      .foregroundStyle(HColor.textOnWashSecondary)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func mark(_ side: CGFloat, glyph: CGFloat, stroke: CGFloat) -> some View {
    Circle()
      .fill(Hue.peach.perceptualGradient)
      .frame(width: side, height: side)
      .overlay { HIconView(.project, size: glyph, color: Hue.peach.ink, strokeWidth: stroke) }
      .accessibilityHidden(true)
  }
}

private struct HeroMonthBars: View {
  let bars: [HeroMonthBar]
  let hidden: Bool
  @ScaledMetric(relativeTo: .subheadline) private var labelWidth: CGFloat = 36

  var body: some View {
    Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
      ForEach(bars) { bar in
        GridRow {
          Text(bar.label).hType(.subheadline.weight(.semibold)).foregroundStyle(HColor.textPrimary)
            .frame(width: labelWidth, alignment: .leading)
          MonthPaceBar(spent: bar.spent, plan: bar.plan, tick: nil, verdict: bar.verdict, overflow: 10,
                       hidden: hidden, live: false)
            .padding(.trailing, 10)
            .frame(maxWidth: .infinity)
          MoneyText(bar.spent, figure: HFigure.compact, hidden: hidden, hiddenGlyphs: 3, color: HColor.textPrimary)
            .gridColumnAlignment(.trailing)
        }
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("By month")
    .accessibilityValue(bars.map { bar in
      "\(bar.month.title), " + (hidden ? "Amount hidden" : "\(bar.spent.isNegative ? "minus " : "")AED \(MoneyFormat.string(bar.spent.minor))")
    }.joined(separator: "; "))
    .accessibilityIdentifier("home.hero.months")
  }
}
