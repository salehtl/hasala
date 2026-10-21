import HasalaModels
import SwiftUI

// Materials (spec 01 §4.1–4.7, B1.5): native Liquid Glass for chrome that floats, solid
// cards for content, two shadows, and the ambient washes. Paper's five glass layers are its
// drawing of the iOS 26 material; the build uses the material itself (decision 2).

struct GlassModifier<S: Shape>: ViewModifier {
  let shape: S
  let prominent: Bool
  let interactive: Bool
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.hGlassPaired) private var paired

  func body(content: Content) -> some View {
    if paired {
      content
    } else if reduceTransparency {
      // Reduce Transparency: solid, with the 0.5 hairline so the edge still shows (page 04).
      content
        .background(prominent ? HColor.actionAccent : HColor.materialGlassReduced, in: shape)
        .overlay { shape.stroke(HColor.materialGlassOutline, lineWidth: HSpacing.strokeHairline) }
    } else {
      content.glassEffect(glass, in: shape)
    }
  }

  private var glass: Glass {
    let base: Glass = prominent ? .regular.tint(HColor.actionAccent) : .regular
    return interactive ? base.interactive() : base
  }
}

extension EnvironmentValues {
  @Entry var hGlassPaired = false
}

/// The two elevations (page 04 §4.4). List groups and rows are flat; only a card that
/// stands on its own lifts.
public enum HElevation: Sendable, Hashable {
  /// `0 1 2 --color-elevation-near`: the month pill, 56 discs, small plates.
  case near
  /// Near plus `0 8 24 --color-elevation-far`: free-standing cards (brief, answer, summary).
  case nearFar
}

public extension View {
  /// Native Liquid Glass in `shape` (tab bar, search, header buttons, sheet controls, toasts,
  /// review pills). `prominent` is the accent-tinted Done. With Reduce Transparency: a solid
  /// `materialGlassReduced` fill with the 0.5 `materialGlassOutline` hairline.
  func hGlass<S: Shape>(in shape: S, prominent: Bool = false, interactive: Bool = true) -> some View {
    modifier(GlassModifier(shape: shape, prominent: prominent, interactive: interactive))
  }

  /// One of the two shadow stacks. CSS blur is twice the SwiftUI radius.
  func hElevation(_ level: HElevation) -> some View {
    shadow(color: HColor.elevationNear, radius: 1, x: 0, y: 1)
      .shadow(color: level == .nearFar ? HColor.elevationFar : .clear, radius: 12, x: 0, y: 8)
  }
}

/// The soft tints at the top of a screen (page 04 §4.6). Each wash has its own colours and
/// height; the verdict washes follow the month in words, never alone.
public enum HWash: Sendable, Hashable {
  /// Home on track, and the neutral wash on every other tab (sky, 420).
  case onTrack
  /// Home ahead of pace; Bills when bills are due (sand, 420).
  case overPace
  /// Over budget, a late bill (rose, 420).
  case overBudget
  /// A category or project detail in its bucket's hue (420).
  case hue(Hue)
  /// Setup, account and sign-in screens (morning, 360).
  case setup
  /// Setup result and done ("It works": mint into sky, 480).
  case itWorks
  /// "Your account is ready" (mint into sky, 480).
  case ready
  /// The Welcome stories' join screen (morning into sky, 560).
  case welcome
  /// Setup · Notifications (morning into sky, 480).
  case notifications

  /// The wash for a Home or card verdict (`done` has no wash: it stays sky).
  public init(verdict: Verdict) {
    switch verdict {
    case .onTrack, .done: self = .onTrack
    case .overPace: self = .overPace
    case .overBudget: self = .overBudget
    }
  }

  /// The layer's height as Paper draws it.
  public var height: CGFloat {
    switch self {
    case .onTrack, .overPace, .overBudget, .hue: 420
    case .setup: 360
    case .itWorks, .ready, .notifications: 480
    case .welcome: 560
    }
  }

  /// The gradient stops, top to bottom, over `--color-surface-secondary`.
  ///
  /// The verdict and hue washes use page 04's recipe: the wash, the wash mixed half with clear
  /// at 38%, then clear. The two-hue washes are drawn with their own stops (spec 05, 07).
  public var stops: [(color: HRGBA, location: CGFloat)] {
    switch self {
    case .onTrack: Self.recipe(HPalette.washOnTrack)
    case .overPace: Self.recipe(HPalette.washOverPace)
    case .overBudget: Self.recipe(HPalette.washOverBudget)
    case .hue(let hue):
      switch hue {
      case .sky: Self.recipe(HPalette.washOnTrack)
      case .sand: Self.recipe(HPalette.washOverPace)
      case .rose: Self.recipe(HPalette.washOverBudget)
      default: Self.recipe(hue.tokens.start)
      }
    case .setup: Self.recipe(HPalette.washMorning)
    case .itWorks, .ready:
      [(HPalette.hueMintStart, 0), (HPalette.hueSkyStart, 0.46), (HPalette.hueSkyStart.clear, 1)]
    case .welcome:
      [(HPalette.washMorning, 0), (HPalette.hueSkyStart, 0.45), (HPalette.hueSkyStart.clear, 1)]
    case .notifications:
      [(HPalette.washMorning, 0), (HPalette.hueSkyStart, 0.46), (HPalette.hueSkyStart.clear, 1)]
    }
  }

  /// The colour at the top, which text on the wash is checked against (ContrastTests).
  public var top: HRGBA { stops[0].color }

  static func recipe(_ wash: HRGBA) -> [(color: HRGBA, location: CGFloat)] {
    [(wash, 0), (wash.withOpacity(0.5), 0.38), (wash.clear, 1)]
  }
}

extension HRGBA {
  /// The same colour at another opacity (gradients fade a colour to clear, not to black).
  func withOpacity(_ opacity: Double) -> HRGBA { HRGBA(red, green, blue, opacity) }
  var clear: HRGBA { withOpacity(0) }
}
