import HasalaModels
import SwiftUI
import WidgetKit

public enum WidgetInk {
  public static func primary(_ showsBackground: Bool, _ ink: Color = HColor.textPrimary) -> Color {
    showsBackground ? ink : HColor.widgetOnInverse
  }

  public static func secondary(_ showsBackground: Bool, _ ink: Color = HColor.textSecondary) -> Color {
    showsBackground ? ink : HColor.widgetOnInverseSecondary
  }

  public static func trackOpacity(_ mode: WidgetRenderingMode) -> Double {
    mode == .fullColor ? 1 : 0.3
  }
}

struct WidgetBar<Full: View>: View {
  let progress: Permille
  let tick: Permille?
  @ViewBuilder let full: () -> Full
  @Environment(\.widgetRenderingMode) private var mode

  init(_ progress: Permille, tick: Permille? = nil, @ViewBuilder full: @escaping () -> Full) {
    self.progress = progress
    self.tick = tick
    self.full = full
  }

  var body: some View {
    if mode == .fullColor {
      full()
    } else {
      GeometryReader { geo in
        let w = geo.size.width
        ZStack(alignment: .leading) {
          Capsule().fill(Color.white).opacity(WidgetInk.trackOpacity(mode)).frame(height: 6)
          if progress.value > 0 {
            Capsule().fill(Color.white).frame(width: max(6, w * min(1, progress.fraction)), height: 6)
              .widgetAccentable()
          }
          if let tick {
            RoundedRectangle(cornerRadius: 1).fill(Color.white)
              .frame(width: 2, height: HSpacing.paceMarkerHeightWidget)
              .offset(x: w * min(1, tick.fraction) - 1)
          }
        }
        .frame(height: tick == nil ? 6 : HSpacing.paceMarkerHeightWidget)
      }
      .frame(height: tick == nil ? 6 : HSpacing.paceMarkerHeightWidget)
      .accessibilityHidden(true)
    }
  }
}
