import HasalaModels
import SwiftUI

// Pace bars (Paper page 16 §02): how much of a budget is spent against where spending should
// be today. The ink tick is today; the fill colour is the verdict, and a sentence beside the
// bar always says it in words. Geometry is the only place a fraction becomes a float.

// MARK: - The month bar (Home hero)

/// The Home hero's single bar: needs + wants spent against their combined plan (page 16 §02,
/// S1–S10). Blue up to the tick; in a live month, amber from the tick to the end of spent; past
/// the plan, the bar is full rose and a rose overflow runs past its end (2 pt gap, 8 tall, at
/// least 8 pt, capped at `overflow` with a square end and a fade). Savings is never on it.
///
/// Not focusable alone: the hero reads the figure, the plan and the verdict as one element.
/// Hidden amounts keep the bar's shape, fill and tick.
public struct MonthPaceBar: View {
  let spent: Money
  let plan: Money
  let tick: Money?
  let verdict: Verdict
  let overflow: CGFloat
  let hidden: Bool
  let live: Bool
  let onWash: Bool
  let phase: PaceFillPhase?

  /// `tick` is the planned spend by today (nil in a closed month or a range). `overflow` is
  /// the room past the track's end the overflow may use (18 in the hero: the card edge).
  /// `phase` is the reveal (`paceFillSequence`); nil shows the final state.
  public init(spent: Money, plan: Money, tick: Money?, verdict: Verdict, overflow: CGFloat = 18,
              hidden: Bool = false, live: Bool = true, onWash: Bool = true, phase: PaceFillPhase? = nil)
  {
    self.spent = spent
    self.plan = plan
    self.tick = tick
    self.verdict = verdict
    self.overflow = overflow
    self.hidden = hidden
    self.live = live
    self.onWash = onWash
    self.phase = phase
  }

  /// Spent as a share of the plan: geometry only.
  public var fraction: Double {
    plan.minor > 0 ? Double(max(0, spent.minor)) / Double(plan.minor) : 0
  }

  private var tickFraction: Double? {
    guard let tick, plan.minor > 0 else { return nil }
    return min(1, Double(max(0, tick.minor)) / Double(plan.minor))
  }

  public var body: some View {
    MonthBarCanvas(
      drawn: plan.minor > 0 ? (phase?.fill ?? fraction) : 0, tick: tickFraction,
      tickVisible: phase?.tickVisible ?? true, live: live, overflowRoom: overflow,
      track: onWash ? HColor.progressTrackOnHue : HColor.paceTrack,
      halo: onWash ? HColor.white.opacity(0.85) : HColor.surfacePrimary)
      .frame(height: HSpacing.paceMarkerHeight)
      .accessibilityHidden(true)
  }
}

/// The month bar drawn from one animatable value, so the colours follow the fill as it grows:
/// blue to the tick, amber past it, full rose once it passes the plan.
struct MonthBarCanvas: View, Animatable {
  var drawn: Double
  let tick: Double?
  let tickVisible: Bool
  let live: Bool
  let overflowRoom: CGFloat
  let track: Color
  let halo: Color

  nonisolated var animatableData: Double {
    get { drawn }
    set { drawn = newValue }
  }

  var body: some View {
    GeometryReader { geo in
      let w = geo.size.width
      let bar = HSpacing.paceBarHeight
      let shape = RoundedRectangle(cornerRadius: HRadius.paceBar, style: .continuous)
      ZStack(alignment: .leading) {
        shape.fill(track).frame(width: w, height: bar)
        if drawn > 1 {
          // Over the plan: full rose, then the overflow past the end.
          shape.fill(HColor.paceFillOverBudget).frame(width: w, height: bar)
          overflowPiece(width: w)
        } else if drawn > 0 {
          let spentX = max(bar, w * drawn)
          if live, let tick, drawn > tick {
            shape.fill(HColor.paceFillOverPace).frame(width: spentX, height: bar)
            shape.fill(HColor.paceFill).frame(width: max(bar, w * tick), height: bar)
          } else {
            shape.fill(HColor.paceFill).frame(width: spentX, height: bar)
          }
        }
        if let tick, live {
          TodayTick(height: HSpacing.paceMarkerHeight, halo: halo)
            .offset(x: w * tick - 1)
            .offset(y: tickVisible ? 0 : -HMotion.markerDrop)
            .opacity(tickVisible ? 1 : 0)
        }
      }
      .frame(height: HSpacing.paceMarkerHeight)
    }
  }

  /// The overspend on the plan's scale, at least 8 pt, starting 2 pt past the end; past the
  /// room it is capped with a square end that fades.
  @ViewBuilder private func overflowPiece(width w: CGFloat) -> some View {
    let length = max(8, w * (drawn - 1))
    let room = overflowRoom
    let capped = length > room
    let piece = UnevenRoundedRectangle(
      topLeadingRadius: HRadius.paceBar, bottomLeadingRadius: HRadius.paceBar,
      bottomTrailingRadius: capped ? 0 : HRadius.paceBar, topTrailingRadius: capped ? 0 : HRadius.paceBar,
      style: .continuous)
    Group {
      if capped {
        piece.fill(.linearGradient(
          Gradient(stops: [.init(color: HColor.paceFillOverBudget, location: 0),
                           .init(color: HColor.paceFillOverBudget, location: 0.45),
                           .init(color: HColor.paceFillOverBudget.opacity(0), location: 1)]).colorSpace(.perceptual),
          startPoint: .leading, endPoint: .trailing))
      } else {
        piece.fill(HColor.paceFillOverBudget)
      }
    }
    .frame(width: min(length, room), height: HSpacing.paceBarHeight)
    .offset(x: w + 2)
  }
}

/// The today tick: 2 pt wide, radius 1, `--color-pace-marker`, with a 1.5 pt halo in the colour
/// of what is under it so it stays visible on the fill. Twice the bar's height.
struct TodayTick: View {
  let height: CGFloat
  let halo: Color?

  var body: some View {
    RoundedRectangle(cornerRadius: 1)
      .fill(halo == nil ? HColor.white : HColor.paceMarker)
      .frame(width: 2, height: height)
      .background {
        if let halo {
          RoundedRectangle(cornerRadius: 2.5).fill(halo).frame(width: 5, height: height + 3)
        }
      }
  }
}

// MARK: - Card, slim and widget bars

/// A pace bar on a card or detail screen (page 16 §02, "Pace bar on cards"): an 8 bar on a 16
/// lane, the whole fill in the verdict's colour, the tick with a halo in the card colour. Over
/// budget, the fill is full and red. Read with its card ("Dining, 957 dirhams 25 left of
/// 1,600. Over pace").
public struct CategoryPaceBar: View {
  let spent: Permille
  let tick: Permille?
  let verdict: Verdict
  let onWash: Bool
  let phase: PaceFillPhase?

  public init(spent: Permille, tick: Permille?, verdict: Verdict, onWash: Bool = false,
              phase: PaceFillPhase? = nil)
  {
    self.spent = spent
    self.tick = tick
    self.verdict = verdict
    self.onWash = onWash
    self.phase = phase
  }

  public var body: some View {
    CategoryBarCanvas(
      drawn: min(1, phase?.fill ?? spent.fraction), tick: tick.map { min(1, $0.fraction) },
      tickVisible: phase?.tickVisible ?? true, fill: verdict.fill,
      track: onWash ? HColor.progressTrackOnHue : HColor.paceTrack,
      halo: onWash ? HColor.white.opacity(0.85) : HColor.surfacePrimary)
      .frame(height: HSpacing.paceMarkerHeight)
      .accessibilityHidden(true)
  }
}

struct CategoryBarCanvas: View, Animatable {
  var drawn: Double
  let tick: Double?
  let tickVisible: Bool
  let fill: Color
  let track: Color
  let halo: Color

  nonisolated var animatableData: Double {
    get { drawn }
    set { drawn = newValue }
  }

  var body: some View {
    GeometryReader { geo in
      let w = geo.size.width
      let bar = HSpacing.paceBarHeight
      let shape = RoundedRectangle(cornerRadius: HRadius.paceBar, style: .continuous)
      ZStack(alignment: .leading) {
        shape.fill(track).frame(width: w, height: bar)
        if drawn > 0 {
          shape.fill(fill).frame(width: max(bar, w * drawn), height: bar)
        }
        if let tick {
          TodayTick(height: HSpacing.paceMarkerHeight, halo: halo)
            .offset(x: w * tick - 1)
            .offset(y: tickVisible ? 0 : -HMotion.markerDrop)
            .opacity(tickVisible ? 1 : 0)
        }
      }
      .frame(height: HSpacing.paceMarkerHeight)
    }
  }
}

/// A slim progress bar with no tick (budget rows, transaction detail, the project card): 6 tall,
/// radius 3 (8 and 4 on the project card). Slim progress, not pace.
public struct SlimProgressBar: View {
  let progress: Permille
  let fill: Color
  let track: Color
  let height: CGFloat

  public init(_ progress: Permille, fill: Color = HColor.paceFill, track: Color = HColor.paceTrack,
              height: CGFloat = HSpacing.progressHeight)
  {
    self.progress = progress
    self.fill = fill
    self.track = track
    self.height = height
  }

  public var body: some View {
    GeometryReader { geo in
      ZStack(alignment: .leading) {
        Capsule().fill(track)
        if progress.value > 0 {
          Capsule().fill(fill).frame(width: max(height, geo.size.width * min(1, progress.fraction)))
        }
      }
    }
    .frame(height: height)
    .accessibilityHidden(true)
  }
}

/// A widget's pace bar: 6 tall with a 2 × 12 tick (twice the bar). On a light widget the tick
/// is ink with a 1.5 white ring; on the ink widget (Spent so far) a plain white tick, the track
/// `widgetOnInverseTrack` and the fill blue-300.
public struct WidgetPaceBar: View {
  let spent: Permille
  let tick: Permille?
  let verdict: Verdict
  let inverse: Bool

  public init(spent: Permille, tick: Permille?, verdict: Verdict, inverse: Bool = false) {
    self.spent = spent
    self.tick = tick
    self.verdict = verdict
    self.inverse = inverse
  }

  public var body: some View {
    GeometryReader { geo in
      let w = geo.size.width
      ZStack(alignment: .leading) {
        Capsule().fill(inverse ? HColor.widgetOnInverseTrack : HColor.paceTrack).frame(height: 6)
        if spent.value > 0 {
          Capsule().fill(inverse ? HColor.blue300 : verdict.fill)
            .frame(width: max(6, w * min(1, spent.fraction)), height: 6)
        }
        if let tick {
          TodayTick(height: HSpacing.paceMarkerHeightWidget, halo: inverse ? nil : HColor.white)
            .offset(x: w * min(1, tick.fraction) - 1)
        }
      }
      .frame(height: HSpacing.paceMarkerHeightWidget)
    }
    .frame(height: HSpacing.paceMarkerHeightWidget)
    .accessibilityHidden(true)
  }
}

// MARK: - The verdict line

/// The verdict in words beside a bar (page 06 §6.4, page 16 §01): a dot, the verdict word in
/// its colour, then one fact ("· AED 8,711.66 left") and an optional link on the right ("See
/// month"). Hero size is a dot 8 and 15/20 on the wash's own colours; card size a dot 7 and
/// 13/18. The word carries the verdict; the colour only repeats it. At the accessibility sizes
/// the link moves under the line.
public struct VerdictLine: View {
  public enum Size: Sendable { case hero, card }

  /// What colours the dot and the word: a verdict, or neutral ("No plan yet").
  public enum Tone: Sendable, Hashable {
    case verdict(Verdict)
    case neutral
  }

  let tone: Tone
  let word: String
  let fact: MoneyPhrase?
  let hidden: Bool
  let size: Size
  let onWash: Bool
  let link: (title: String, action: () -> Void)?

  /// `word` defaults to the verdict's label; Home passes its own ("Ahead of pace", "Over by
  /// AED 1,240.00"). `fact` is one fact, without the leading "·".
  public init(verdict: Verdict, word: String? = nil, fact: MoneyPhrase? = nil, hidden: Bool = false,
              size: Size = .hero, onWash: Bool = true, link: (title: String, action: () -> Void)? = nil)
  {
    self.init(tone: .verdict(verdict), word: word ?? verdict.label, fact: fact, hidden: hidden, size: size,
              onWash: onWash, link: link)
  }

  public init(tone: Tone, word: String, fact: MoneyPhrase? = nil, hidden: Bool = false, size: Size = .hero,
              onWash: Bool = true, link: (title: String, action: () -> Void)? = nil)
  {
    self.tone = tone
    self.word = word
    self.fact = fact
    self.hidden = hidden
    self.size = size
    self.onWash = onWash
    self.link = link
  }

  public var body: some View {
    ReflowingRow(spacing: 12) {
      // The dot sits centred in a lane one line tall, so it stays on the first line when the
      // words wrap (page 17 §03).
      HStack(alignment: .top, spacing: 6) {
        Circle().fill(dotColor).frame(width: size == .hero ? 8 : 7, height: size == .hero ? 8 : 7)
          .frame(height: lane)
        Text("\(Text(word).font(wordType.font).foregroundStyle(wordColor))\(factText)")
          .hType(size == .hero ? .subheadline : .footnote)
          .foregroundStyle(factColor)
          .fixedSize(horizontal: false, vertical: true)
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(spoken)
    } trailing: {
      if let link {
        Button(link.title, action: link.action)
          .buttonStyle(.plain)
          .hType(size == .hero ? .subheadline.weight(.medium) : .footnote.weight(.medium))
          .foregroundStyle(onWash ? HColor.textOnWashLink : HColor.textLink)
          .frame(minHeight: HSpacing.targetMinimum)
          .contentShape(Rectangle())
      }
    }
  }

  @ScaledMetric(relativeTo: .subheadline) private var heroLane: CGFloat = 20
  @ScaledMetric(relativeTo: .footnote) private var cardLane: CGFloat = 18
  private var lane: CGFloat { size == .hero ? heroLane : cardLane }

  private var wordType: HType { (size == .hero ? HType.subheadline : HType.footnote).weight(.semibold) }

  private var factText: Text {
    Text(verbatim: fact.map { " · " + $0.rendered(hidden: hidden) } ?? "")
  }

  private var spoken: String {
    [word, fact.map { $0.spoken(hidden: hidden) }].compactMap { $0 }.joined(separator: ", ")
  }

  private var dotColor: Color {
    switch tone {
    case .verdict(let v): v == .overPace ? HColor.paceFillOverPace : v.foreground
    case .neutral: onWash ? HColor.textOnWashSecondary : HColor.textSecondary
    }
  }

  private var wordColor: Color {
    switch tone {
    case .verdict(let v): v.foreground
    case .neutral: HColor.textPrimary
    }
  }

  private var factColor: Color { onWash ? HColor.textOnWashSecondary : HColor.textSecondary }
}

// MARK: - The fill sequence (B1.3)

/// Where a bar's reveal is: the drawn fill (spent as a share of the plan), then whether the
/// today tick and the verdict have landed.
public struct PaceFillPhase: Sendable, Hashable {
  public var fill: Double
  public var tickVisible: Bool
  public var verdictVisible: Bool

  public init(fill: Double = 0, tickVisible: Bool = false, verdictVisible: Bool = false) {
    self.fill = fill
    self.tickVisible = tickVisible
    self.verdictVisible = verdictVisible
  }

  /// The final state for a target: everything shown.
  public static func settled(_ target: Double) -> PaceFillPhase {
    PaceFillPhase(fill: target, tickVisible: true, verdictVisible: true)
  }

  /// True once the fill has started: the headline figure switches from 0 to its value inside
  /// the same animation, so it rolls on the fill's curve. (Integer money only: the figure is
  /// either 0 or the real amount, never a computed in-between.)
  public var started: Bool { fill > 0 || tickVisible }

  /// The figure to show during the reveal: zero before the fill starts, the amount after.
  public func figure(_ money: Money) -> Money {
    started ? money : Money(minor: 0, currency: money.currency)
  }
}

/// When a reveal plays.
public enum PaceFillOnce: Sendable, Hashable {
  /// Each time the host view appears (a category detail, per push). A tab switch keeps the
  /// host alive, so it does not replay; neither does returning from a sheet.
  case perAppearance
  /// Once per process under a key (the Home hero's first reveal after launch); later
  /// appearances show the final state at once.
  case perProcess(String)
}

/// The keys that have played this process (the Home hero plays its reveal once per launch).
@MainActor
final class PaceFillMemory {
  static let shared = PaceFillMemory()
  private var played: Set<String> = []

  func hasPlayed(_ key: String) -> Bool { played.contains(key) }
  func markPlayed(_ key: String) { played.insert(key) }
  /// Tests start each case clean.
  func reset() { played.removeAll() }
}

struct PaceFillSequence: ViewModifier {
  @Binding var phase: PaceFillPhase
  let target: Double
  let given: MotionPolicy
  let once: PaceFillOnce
  @State private var played = false
  @ResolvedMotion private var resolved: MotionPolicy

  /// The caller's policy, still honouring the system's Reduce Motion if the root forgot to.
  private var policy: MotionPolicy {
    MotionPolicy(reduceMotion: given.reduceMotion || resolved.reduceMotion, settled: given.settled || resolved.settled)
  }

  func body(content: Content) -> some View {
    content
      .onAppear(perform: start)
      .onChange(of: target) { _, new in
        // A value change after the reveal: the bar moves to its new width; tick and verdict
        // stay (the verdict cross-fades if its word changes, through `.stateSwap`).
        guard played else { return }
        withAnimation(policy.animation(.fillUpdate)) { phase = .settled(new) }
      }
  }

  private func start() {
    guard !played else { return }
    played = true
    let shouldPlay: Bool
    switch once {
    case .perAppearance: shouldPlay = true
    case .perProcess(let key):
      shouldPlay = !PaceFillMemory.shared.hasPlayed(key)
      PaceFillMemory.shared.markPlayed(key)
    }
    guard shouldPlay, !policy.isStill, target > 0 else {
      // Reduce Motion, settled, nothing spent, or already played: the final state at once.
      phase = .settled(target)
      return
    }
    // Track, then fill (300 ms ease-in-out, the figure counting with it), then the tick drops
    // (120 ms), then the verdict fades in (150 ms). Nothing moves after this. The three start
    // together, the tick and the verdict on delays, so the render clock keeps their spacing:
    // started from each step's completion, every step landed two or three frames late (a
    // frame trace put the tick at 375 ms and the verdict at 540 instead of 300 and 420;
    // requests/p5.md 4).
    phase = PaceFillPhase()
    withAnimation(policy.animation(.fill)) { phase.fill = target }
    withAnimation(policy.animation(.marker)?.delay(HMotion.fill)) { phase.tickVisible = true }
    withAnimation(policy.animation(.verdict)?.delay(HMotion.fill + HMotion.marker)) {
      phase.verdictVisible = true
    }
  }
}

public extension View {
  /// Runs a bar's reveal into `phase` (B1.3): fill, then tick, then verdict, once per `once`.
  /// With Reduce Motion or settled motion the final state shows at once. A later change of
  /// `target` moves the bar on `.fillUpdate`.
  func paceFillSequence(_ phase: Binding<PaceFillPhase>, target: Double, policy: MotionPolicy,
                        once: PaceFillOnce = .perAppearance) -> some View
  {
    modifier(PaceFillSequence(phase: phase, target: target, given: policy, once: once))
  }
}
