import SwiftUI

// Hasala's motion vocabulary in one place (spec 01 §4.8–4.11), so the values can move to
// `--motion-*` tokens later without hunting through screens. Paper names no motion tokens yet;
// the proposed names are in the comments.
//
// Durations follow the owner's motion policy of 15 Oct (hasala-v2-work/motion-policy.md), which
// overrides the longer "Proposed for app" values on page 04: micro-interactions 100–150 ms,
// standard UI 150–250 ms, and no UI animation of 300 ms or more except a first-time moment
// that celebrates (600 ms at most). Sheets, pushes, alerts, menus and the tab bar keep system
// timing; nothing here restyles them.

/// Named curves, springs, durations and distances. `MotionTests` pins every value.
public enum HMotion {
  // MARK: Curves

  /// `--motion-ease-out-soft`: cubic-bezier(.22, 1, .36, 1). Reveals, fades, toast in, release.
  public static func easeOutSoft(_ duration: Double) -> Animation {
    .timingCurve(0.22, 1, 0.36, 1, duration: duration)
  }

  /// `--motion-ease-in-out`: cubic-bezier(.65, 0, .35, 1). The pace bar fill; a figure counts on it.
  public static func easeInOut(_ duration: Double) -> Animation {
    .timingCurve(0.65, 0, 0.35, 1, duration: duration)
  }

  // MARK: Springs (owner values)

  /// Chips, the segmented thumb, the step indicator, checkmarks, pill state, the Welcome pager.
  public static let snappyResponse = 0.28
  public static let snappyDamping = 0.86
  public static let snappy = Animation.spring(response: snappyResponse, dampingFraction: snappyDamping)

  /// `--motion-spring-drop` (stiffness 420, damping 26; settles in about 250 ms): the next review
  /// card, the coin dropping into the slot.
  public static let dropStiffness = 420.0
  public static let dropDamping = 26.0
  public static let springDrop = Animation.interpolatingSpring(stiffness: dropStiffness, damping: dropDamping)

  /// A review card let go before the commit point springs back.
  public static let cardReturnResponse = 0.3
  public static let cardReturnDamping = 0.8
  public static let cardReturn = Animation.spring(response: cardReturnResponse, dampingFraction: cardReturnDamping)

  /// `--motion-spring-deal`: Welcome cards dealing in. Welcome stories only (delight).
  public static let dealResponse = 0.5
  public static let dealDamping = 0.78
  public static let springDeal = Animation.spring(response: dealResponse, dampingFraction: dealDamping)

  /// `--motion-spring-bouncy`: chips popping in last on a Welcome story. Welcome only.
  public static let bouncy = Animation.bouncy

  /// A first-time moment ("You're set", a mailbox connected, all caught up): a badge settles
  /// in about 400 ms, inside the 600 ms the policy allows a celebration.
  public static let celebrateResponse = 0.42
  public static let celebrateDamping = 0.72
  public static let celebrate = Animation.spring(response: celebrateResponse, dampingFraction: celebrateDamping)
  /// The longest a celebration may run, start to rest.
  public static let celebrateLimit = 0.6

  // MARK: Durations (seconds)

  /// `--motion-duration-press`: a button shows pressed at once and eases back over this.
  public static let pressBack = 0.12
  /// A pressed row or key fills for this long (rows highlight, never scale).
  public static let highlight = 0.10
  /// `--motion-duration-fade`: cross-fades, verdict and wash changes.
  public static let fade = 0.18
  /// Copy, banners and status lines rise into place.
  public static let rise = 0.22
  /// The glass toast rises in and fades out.
  public static let toastIn = 0.22
  public static let toastOut = 0.18
  /// `--motion-duration-count`: a changed figure rolls (numeric text).
  public static let count = 0.30
  /// `--motion-duration-fill`: a pace bar fills from 0 (Home hero first reveal, category bars).
  public static let fill = 0.30
  /// `--motion-duration-marker`: the today tick drops in once the fill ends.
  public static let marker = 0.12
  /// The verdict fades in after the tick.
  public static let verdict = 0.15
  /// A bar moves from its old width to a new one (a new transaction, a period change).
  public static let fillUpdate = 0.25
  /// A filed review card flies out.
  public static let cardCommit = 0.20
  /// Content changing size inside a sheet.
  public static let sheetContent = 0.25
  /// Hide amounts: figures swap to dots with at most this fade.
  public static let hideAmounts = 0.15
  /// The Reduce Motion substitute: travel, scale, rotation and springs become this cross-fade.
  public static let reduceMotionFade = 0.15
  /// `--motion-stagger`: the gap between cards entering together (80 ms in the app, page 00).
  public static let stagger = 0.08
  /// At most this many cards are staggered; later ones enter with the last.
  public static let staggerLimit = 4
  /// One Welcome story before it auto-advances.
  public static let storyDuration = 6.0
  /// How long a toast stays (Proposed on page 14); longer while VoiceOver runs.
  public static let toastDwell = 4.0
  public static let toastDwellVoiceOver = 8.0

  // MARK: Distances, scales and angles

  /// `--motion-travel-rise`: copy and toasts rise this far into place.
  public static let travelRise: CGFloat = 12
  /// Welcome cards travel this far as they deal in.
  public static let travelDeal: CGFloat = 40
  /// Buttons scale to this while pressed (decision 1). Rows and list groups never scale.
  public static let pressScale: CGFloat = 0.97
  /// A Welcome card starts at this scale.
  public static let dealScale: CGFloat = 0.94
  /// A chip pops from this scale.
  public static let chipPopScale: CGFloat = 0.8
  /// The next review card grows from this scale and lifts this far.
  public static let nextCardScale: CGFloat = 0.96
  public static let nextCardLift: CGFloat = 8
  /// A filed card flies this far, as a share of its width, turning to this angle.
  public static let cardFlyOut: CGFloat = 1.4
  public static let cardFlyTilt = 16.0
  /// The live card's tilt at the commit point (component spec 16.6).
  public static let commitTilt = 3.0
  /// The today tick drops this far as it fades in.
  public static let markerDrop: CGFloat = 4
  /// The one loop in the app: Welcome cards float this far, over this period.
  public static let idleFloat: CGFloat = 4
  public static let idlePeriod = 4.0
}

public extension HMotion {
  /// What moves in the app. Each kind has a normal curve and a Reduce Motion substitute
  /// (B1.2); `MotionPolicy` picks between them once per transition.
  enum Kind: Sendable, Hashable {
    /// Buttons: scale 0.97 and the pressed colour, at once; 120 ms back. RM: colour only.
    case press
    /// Rows and keypad keys: the pressed fill, 100 ms. Never scales.
    case highlight
    /// A plain opacity change.
    case fade
    /// Copy blocks, banners, status lines: up 12 and in. RM: a fade.
    case rise
    case toastIn
    case toastOut
    /// A pace bar filling from 0. RM: the final width at once.
    case fill
    /// A bar moving to a new width. RM: at once.
    case fillUpdate
    /// The today tick dropping in. RM: at once.
    case marker
    /// The verdict fading in after the tick. RM: at once.
    case verdict
    /// A headline figure rolling to its value. RM: the value appears.
    case count
    /// A Welcome card dealing in, `index` places after the first (at most 4 staggered).
    case deal(index: Int)
    /// A Welcome chip popping in last.
    case chipPop
    /// The Welcome pager settling on a story.
    case pagerSettle
    /// A settle on spring-drop: the coin into the slot.
    case cardSettle
    /// A filed review card flying out.
    case cardCommit
    /// The next review card arriving.
    case cardNext
    /// A review card let go early springing back.
    case cardReturn
    /// The segmented thumb, split handles, the day strip. RM: jumps.
    case thumbSlide
    /// Wash and verdict changes, connected and not-connected states: a cross-fade.
    case stateSwap
    /// The Welcome idle float (the one loop). RM: off.
    case idleFloat
    /// Content changing size inside a sheet.
    case sheetContent
    /// A first-time moment: a badge popping into place. RM: a fade.
    case celebrate
    /// Hide amounts: figures to dots, a short fade at most.
    case hideAmounts

    /// Every kind once (`deal` at index 0), for tests and the catalogue.
    public static let allKinds: [Kind] = [
      .press, .highlight, .fade, .rise, .toastIn, .toastOut, .fill, .fillUpdate, .marker, .verdict, .count,
      .deal(index: 0), .chipPop, .pagerSettle, .cardSettle, .cardCommit, .cardNext, .cardReturn, .thumbSlide,
      .stateSwap, .idleFloat, .sheetContent, .celebrate, .hideAmounts,
    ]
  }

  /// A curve described by its numbers, so tests can read what an `Animation` cannot show.
  enum Curve: Sendable, Hashable {
    case easeOutSoft(duration: Double)
    case easeInOut(duration: Double)
    case linear(duration: Double)
    case spring(response: Double, damping: Double)
    case interpolatingSpring(stiffness: Double, damping: Double)
    /// The system `.bouncy` spring.
    case bouncy
    /// The idle float: an ease-in-out loop that reverses.
    case loop(period: Double)

    public var animation: Animation {
      switch self {
      case .easeOutSoft(let d): HMotion.easeOutSoft(d)
      case .easeInOut(let d): HMotion.easeInOut(d)
      case .linear(let d): .linear(duration: d)
      case .spring(let r, let z): .spring(response: r, dampingFraction: z)
      case .interpolatingSpring(let k, let c): .interpolatingSpring(stiffness: k, damping: c)
      case .bouncy: .bouncy
      case .loop(let period): .easeInOut(duration: period / 2).repeatForever(autoreverses: true)
      }
    }

    /// The nominal length of a timed curve; springs report the time they take to settle
    /// closely enough that the next step of a sequence can start.
    public var nominalDuration: Double {
      switch self {
      case .easeOutSoft(let d), .easeInOut(let d), .linear(let d): d
      case .spring(let response, _): response
      case .interpolatingSpring: 0.25
      case .bouncy: 0.5
      case .loop(let period): period
      }
    }
  }

  /// The Reduce Motion cross-fade every travel, scale, rotation and spring becomes.
  static let reduceMotionCurve = Curve.easeOutSoft(duration: reduceMotionFade)

  /// The curve a kind plays with motion allowed.
  static func normal(_ kind: Kind) -> Curve {
    switch kind {
    case .press: .easeOutSoft(duration: pressBack)
    case .highlight: .easeOutSoft(duration: highlight)
    case .fade, .stateSwap: .easeOutSoft(duration: fade)
    case .rise: .easeOutSoft(duration: rise)
    case .toastIn: .easeOutSoft(duration: toastIn)
    case .toastOut: .easeOutSoft(duration: toastOut)
    case .fill: .easeInOut(duration: fill)
    case .fillUpdate: .easeInOut(duration: fillUpdate)
    case .marker: .easeOutSoft(duration: marker)
    case .verdict: .easeOutSoft(duration: verdict)
    case .count: .easeInOut(duration: count)
    case .deal: .spring(response: dealResponse, damping: dealDamping)
    case .chipPop: .bouncy
    case .pagerSettle, .thumbSlide: .spring(response: snappyResponse, damping: snappyDamping)
    case .cardSettle, .cardNext: .interpolatingSpring(stiffness: dropStiffness, damping: dropDamping)
    case .cardCommit: .easeOutSoft(duration: cardCommit)
    case .cardReturn: .spring(response: cardReturnResponse, damping: cardReturnDamping)
    case .idleFloat: .loop(period: idlePeriod)
    case .sheetContent: .easeOutSoft(duration: sheetContent)
    case .celebrate: .spring(response: celebrateResponse, damping: celebrateDamping)
    case .hideAmounts: .easeOutSoft(duration: hideAmounts)
    }
  }

  /// The substitute with Reduce Motion on; nil means the final state shows at once.
  static func reduced(_ kind: Kind) -> Curve? {
    switch kind {
    // Colour and opacity changes are not motion: they keep their own timing.
    case .press, .highlight, .fade, .stateSwap, .hideAmounts: normal(kind)
    // Travel, scale and springs become the short cross-fade.
    case .rise, .toastIn, .toastOut, .deal, .chipPop, .pagerSettle, .cardCommit, .cardNext, .celebrate,
         .sheetContent:
      reduceMotionCurve
    // Fills, ticks, counts, jumps and the loop: the final state at once.
    case .fill, .fillUpdate, .marker, .verdict, .count, .cardSettle, .cardReturn, .thumbSlide, .idleFloat: nil
    }
  }

  /// The delay before a dealt card starts: 80 ms per place, the first four staggered.
  static func dealDelay(index: Int) -> Double {
    stagger * Double(min(max(index, 0), staggerLimit - 1))
  }
}

/// How motion plays for this view tree: the person's Reduce Motion setting, and a Debug-only
/// `settled` switch (`-HasalaMotion off`) that shows every final state at once for screenshots
/// without silencing haptics (B1.2).
public struct MotionPolicy: Sendable, Equatable {
  public var reduceMotion: Bool
  public var settled: Bool

  public init(reduceMotion: Bool = false, settled: Bool = false) {
    self.reduceMotion = reduceMotion
    self.settled = settled
  }

  /// True when nothing travels: Reduce Motion is on or motion is settled.
  public var isStill: Bool { reduceMotion || settled }

  /// The curve this policy plays for `kind`; nil means no animation (final state at once).
  public func curve(_ kind: HMotion.Kind) -> HMotion.Curve? {
    if settled { return nil }
    return reduceMotion ? HMotion.reduced(kind) : HMotion.normal(kind)
  }

  /// The animation for `kind`, or nil for none. A dealt card carries its stagger delay.
  public func animation(_ kind: HMotion.Kind) -> Animation? {
    guard let curve = curve(kind) else { return nil }
    if case .deal(let index) = kind, !reduceMotion {
      return curve.animation.delay(HMotion.dealDelay(index: index))
    }
    return curve.animation
  }

  /// The insertion and removal for `kind`. With Reduce Motion every travel becomes opacity.
  public func transition(_ kind: HMotion.Kind) -> AnyTransition {
    if settled { return .identity }
    if reduceMotion { return .opacity }
    switch kind {
    case .rise:
      return .offset(y: HMotion.travelRise).combined(with: .opacity)
    case .toastIn, .toastOut:
      return .asymmetric(
        insertion: AnyTransition.offset(y: HMotion.travelRise).combined(with: .opacity)
          .animation(HMotion.normal(.toastIn).animation),
        removal: AnyTransition.opacity.animation(HMotion.normal(.toastOut).animation))
    case .deal:
      return AnyTransition.offset(y: HMotion.travelDeal)
        .combined(with: .scale(scale: HMotion.dealScale)).combined(with: .opacity)
    case .chipPop, .celebrate:
      return AnyTransition.scale(scale: HMotion.chipPopScale).combined(with: .opacity)
    case .cardNext:
      return AnyTransition.scale(scale: HMotion.nextCardScale)
        .combined(with: .offset(y: HMotion.nextCardLift)).combined(with: .opacity)
    case .marker:
      return AnyTransition.offset(y: -HMotion.markerDrop).combined(with: .opacity)
    default:
      return .opacity
    }
  }
}

public extension EnvironmentValues {
  /// The motion policy for this view tree. Set once at the root with `hMotionPolicy()`.
  @Entry var hMotion = MotionPolicy()
}

/// Reads the policy and the system's Reduce Motion together, so a tree whose root forgot
/// `hMotionPolicy()` still honours the person's setting.
@MainActor @propertyWrapper
struct ResolvedMotion: DynamicProperty {
  @Environment(\.hMotion) private var policy
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

  init() {}

  var wrappedValue: MotionPolicy {
    var p = policy
    p.reduceMotion = p.reduceMotion || systemReduceMotion
    return p
  }
}

struct MotionPolicyRoot: ViewModifier {
  let settled: Bool
  let forceReduceMotion: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func body(content: Content) -> some View {
    content.environment(\.hMotion, MotionPolicy(reduceMotion: reduceMotion || forceReduceMotion, settled: settled))
  }
}

struct HAnimationModifier<V: Equatable>: ViewModifier {
  let kind: HMotion.Kind
  let value: V
  @ResolvedMotion private var motion: MotionPolicy

  func body(content: Content) -> some View {
    content.animation(motion.animation(kind), value: value)
  }
}

struct HTransitionModifier: ViewModifier {
  let kind: HMotion.Kind
  @ResolvedMotion private var motion: MotionPolicy

  func body(content: Content) -> some View {
    content.transition(motion.transition(kind))
  }
}

struct NumberRollModifier: ViewModifier {
  let value: Double
  @ResolvedMotion private var motion: MotionPolicy

  func body(content: Content) -> some View {
    content.contentTransition(motion.isStill ? .identity : .numericText(value: value))
  }
}

public extension View {
  /// Sets the motion policy for the tree below from Reduce Motion, read here once. Call it at
  /// the root. `settled` and `forceReduceMotion` are the Debug `-HasalaMotion off|reduce` switches.
  func hMotionPolicy(settled: Bool = false, forceReduceMotion: Bool = false) -> some View {
    modifier(MotionPolicyRoot(settled: settled, forceReduceMotion: forceReduceMotion))
  }

  /// Animates changes to `value` with the policy's curve for `kind`.
  func hAnimation<V: Equatable>(_ kind: HMotion.Kind, value: V) -> some View {
    modifier(HAnimationModifier(kind: kind, value: value))
  }

  /// The policy's insertion and removal for `kind`.
  func hTransition(_ kind: HMotion.Kind) -> some View {
    modifier(HTransitionModifier(kind: kind))
  }

  /// A figure that rolls between values (numeric text); with Reduce Motion it just changes.
  func numberRoll(_ value: Double) -> some View {
    modifier(NumberRollModifier(value: value))
  }
}

/// Runs `body` inside the policy's animation for `kind` (none when still).
@MainActor
public func withHMotion<Result>(_ kind: HMotion.Kind, _ policy: MotionPolicy, _ body: () throws -> Result) rethrows
  -> Result
{
  try withAnimation(policy.animation(kind), body)
}
