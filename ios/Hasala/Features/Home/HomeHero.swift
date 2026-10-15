import HasalaDesign
import HasalaModels
import SwiftUI

/// Hero · Spent on needs + wants (Paper 14SX-0, page 16 §01–02): the period pill, "Day 10 of
/// 31", the figure, the caption, one bar for the month, the verdict in words and the Needs,
/// Wants and Savings tiles. 20 from the screen edges, 16 between its blocks.
///
/// Motion (owner's motion policy, B1.3): the first time Home appears after launch, the bar
/// fills over 300 ms while the figure rolls with it, the tick drops in (120 ms), then the
/// verdict fades in (150 ms). Home is seen many times a day, so every later appearance, a tab
/// switch or a return from a sheet shows the final state at once. A change while Home is open
/// (a new transaction) moves the bar on `fillUpdate` (250 ms) and rolls the figure; the wash and
/// the verdict cross-fade when the verdict changes. Reduce Motion shows the final state.
struct HomeHero: View {
  let hero: SpendHero
  let hidden: Bool
  /// "October 2026".
  let month: String
  /// The pill's action: Debug only, until the period picker exists (plan D.2).
  let changePeriod: (() -> Void)?
  /// "See month" (Insights): Debug only.
  let seeMonth: (() -> Void)?
  /// "Set your plan" with no plan yet: the Plan tab.
  let setPlan: () -> Void

  @Environment(\.hMotion) private var policy
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dynamicTypeSize) private var typeSize
  @State private var phase = PaceFillPhase()

  /// The once-per-process key of the first reveal.
  static let revealKey = "home.hero"

  private var motion: MotionPolicy {
    MotionPolicy(reduceMotion: policy.reduceMotion || reduceMotion, settled: policy.settled)
  }

  private var isLive: Bool { hero.state == .live }

  /// Spent as a share of the plan, for the bar's geometry only.
  private var target: Double {
    isLive && hero.plan.minor > 0 ? Double(max(0, hero.spent.minor)) / Double(hero.plan.minor) : 0
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      PeriodPill(month, action: changePeriod)
      figureBlock
      VStack(alignment: .leading, spacing: 10) {
        MonthPaceBar(
          spent: hero.spent, plan: isLive ? hero.plan : .aed(0), tick: isLive ? hero.tick : nil,
          verdict: hero.verdict ?? .onTrack, overflow: 18, hidden: hidden, phase: phase)
        verdictLine
          .opacity(phase.verdictVisible ? 1 : 0)
      }
      tiles
    }
    .padding(.horizontal, HSpacing.insetPage)
    .paceFillSequence($phase, target: target, policy: motion, once: .perProcess(Self.revealKey))
  }

  // MARK: Figure

  private var figureBlock: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(hero.overline).hType(.overline).foregroundStyle(HColor.textOnWashSecondary)
      if hero.state == .syncing {
        HeroFigureSkeleton()
      } else {
        // 6 dots at Paper's 38 pt when hidden (page 06 §6.3). The figure is its own element
        // (`home.hero.left`, plan decision 8) and carries the caption as its value, so VoiceOver
        // reads "AED 10,288.34, spent of 19,000 on needs and wants".
        HeroFigure(amount: phase.figure(hero.spent), hidden: hidden)
          .hAnimation(.count, value: hero.spent)
          .accessibilityValue(hero.caption.spoken(hidden: hidden))
          .accessibilityIdentifier("home.hero.left")
        Text(hero.caption.rendered(hidden: hidden)).hType(.body).foregroundStyle(HColor.textOnWashSecondary)
          .accessibilityHidden(true)
      }
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
    case .live:
      HeroVerdictLine(verdict: hero.verdict, word: hero.word, fact: hero.fact, hidden: hidden,
                      link: seeMonth.map { .init("See month", identifier: "home.seeMonth", action: $0) })
    }
  }

  // MARK: Tiles

  /// Three tiles side by side; stacked at the accessibility sizes, or when they wouldn't fit.
  @ViewBuilder private var tiles: some View {
    let skeleton = hero.state == .syncing
    if typeSize.isAccessibilitySize {
      VStack(spacing: 8) {
        ForEach(hero.tiles) { StatTile($0, hidden: hidden, skeleton: skeleton) }
      }
    } else {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 8) {
          ForEach(hero.tiles) { StatTile($0, hidden: hidden, skeleton: skeleton) }
        }
        VStack(spacing: 8) {
          ForEach(hero.tiles) { StatTile($0, hidden: hidden, skeleton: skeleton) }
        }
      }
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

  var body: some View {
    HeroFigureLine(amount: amount, hidden: hidden)
      .dynamicTypeSize(...HFigure.display.maxDynamicTypeSize)
  }
}

private struct HeroFigureLine: View {
  let amount: Money
  let hidden: Bool
  /// Half of 56 × 1.19 − 58.
  @ScaledMetric(relativeTo: .largeTitle) private var trim: CGFloat = 4.32

  var body: some View {
    MoneyText(amount, figure: hidden ? HFigure.display.hiddenDots(38) : .display, unit: .displayUnit,
              hidden: hidden, hiddenGlyphs: 6, color: HColor.textPrimary)
      .padding(.vertical, hidden ? 0 : -trim)
  }
}
