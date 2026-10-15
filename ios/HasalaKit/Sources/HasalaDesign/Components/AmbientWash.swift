import HasalaModels
import SwiftUI

/// The ambient wash at the top of tab, pushed and flow screens (Paper `4.6`): a tint that
/// fades into the grouped canvas, interpolated in a perceptual space as Paper draws it
/// (`in oklab`). A change of wash cross-fades (`.stateSwap`); the colour is set before any
/// other motion starts.
public struct AmbientWash: View {
  let wash: HWash
  let height: CGFloat
  @ResolvedMotion private var motion: MotionPolicy

  public init(_ wash: HWash, height: CGFloat? = nil) {
    self.wash = wash
    self.height = height ?? wash.height
  }

  /// The hue form: sky, sand and rose are the three verdict washes (on track, over pace,
  /// over budget); lilac, peach and mint tint a category or project detail.
  public init(_ hue: Hue, height: CGFloat = 420) {
    switch hue {
    case .sky: self.init(.onTrack, height: height)
    case .sand: self.init(.overPace, height: height)
    case .rose: self.init(.overBudget, height: height)
    default: self.init(.hue(hue), height: height)
    }
  }

  public var body: some View {
    ZStack {
      WashLayer(wash: wash)
        .id(wash)
        .transition(.opacity)
    }
    .frame(height: height)
    .frame(maxWidth: .infinity)
    .animation(motion.animation(.stateSwap), value: wash)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

struct WashLayer: View {
  let wash: HWash

  var body: some View {
    let gradient = Gradient(stops: wash.stops.map { Gradient.Stop(color: Color($0.color), location: $0.location) })
    Rectangle().fill(.linearGradient(gradient.colorSpace(.perceptual), startPoint: .top, endPoint: .bottom))
  }
}
