import HasalaModels
import SwiftUI

/// The ambient wash at the top of tab and pushed screens (Paper `4.8`): 420 pt tall,
/// fading into the grouped canvas. Sky on track or neutral, sand over pace, rose
/// over budget or a late bill, lilac a category, peach projects and bills, mint done.
public struct AmbientWash: View {
  let hue: Hue
  let height: CGFloat

  public init(_ hue: Hue, height: CGFloat = 420) {
    self.hue = hue
    self.height = height
  }

  public var body: some View {
    LinearGradient(
      stops: [
        .init(color: Color(top), location: 0),
        .init(color: Color(middle), location: 0.38),
        .init(color: HColor.surfaceSecondary.opacity(0), location: 1),
      ],
      startPoint: .top, endPoint: .bottom
    )
    .frame(height: height)
    .accessibilityHidden(true)
  }

  /// The wash's first stop. On-track sky is `--color-wash-on-track`; the others start
  /// at their hue's start token (`--color-wash-over-pace` / `-over-budget` are sand/rose).
  var top: HRGBA {
    switch hue {
    case .sky: HPalette.washOnTrack
    case .sand: HPalette.washOverPace
    case .rose: HPalette.washOverBudget
    default: hue.tokens.start
    }
  }

  /// The 38% stop. Paper's on-track board draws oklab(94.1% −0.003 −0.021) = #E4ECFA;
  /// the other washes blend their start halfway into the canvas.
  var middle: HRGBA {
    if hue == .sky { return HRGBA(228, 236, 250, 1) }
    let a = top, b = HPalette.surfaceSecondary
    return HRGBA(UInt8((Int(a.red) + Int(b.red)) / 2), UInt8((Int(a.green) + Int(b.green)) / 2),
                 UInt8((Int(a.blue) + Int(b.blue)) / 2), 1)
  }
}
