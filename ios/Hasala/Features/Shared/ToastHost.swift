import HasalaDesign
import SwiftUI

/// Floats the app's toast (Paper page 14 §03 "Toast"): the glass strip 20 from the sides,
/// 14 above the tab bar, or on the home indicator's safe area (34 from the bottom) where
/// there is no bar. Every tab root, sheet and pushed screen that can show a toast hosts one
/// (`toast`, with its action as a button inside).
///
/// It rises 12 and fades in over 220 ms, and fades out in place over 180 ms (`HMotion`
/// `.toastIn` / `.toastOut`); with Reduce Motion it only fades. A touch holds it, a swipe
/// down sends it away, and Magic Tap runs its action. How long it stays and what VoiceOver
/// hears are `AppModel`'s.
struct ToastHost: View {
  enum Placement {
    /// Over a tab: 14 above the bar.
    case tabBar
    /// Over a sheet, a cover or a flow with no bar: on the bottom safe area.
    case bottom
  }

  let app: AppModel
  var placement: Placement = .tabBar

  @Environment(\.hMotion) private var policy
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var pull: CGFloat = 0
  @State private var held = false

  var body: some View {
    let motion = MotionPolicy(reduceMotion: policy.reduceMotion || reduceMotion, settled: policy.settled)
    ZStack(alignment: .bottom) {
      if let toast = app.toast {
        GlassToast(disc(toast.disc), title: toast.title, subtitle: toast.subtitle, actionTitle: toast.actionTitle,
                   action: toast.actionTitle == nil ? nil : { app.toastAction() })
          .padding(.horizontal, HSpacing.insetPage)
          .padding(.bottom, placement == .tabBar ? 14 : 0)
          .offset(y: pull)
          .simultaneousGesture(touch)
          .accessibilityAction(.magicTap) { app.toastAction() }
          .accessibilityIdentifier("toast")
          .transition(motion.transition(.toastIn))
      }
    }
    .animation(motion.animation(app.toast == nil ? .toastOut : .toastIn), value: app.toast)
  }

  /// Down holds the toast; a pull down past 24 pt sends it away; a shorter one lets it go
  /// back and stay its full time.
  private var touch: some Gesture {
    DragGesture(minimumDistance: 0)
      .onChanged { value in
        if !held {
          held = true
          app.holdToast(true)
        }
        pull = max(0, value.translation.height)
      }
      .onEnded { value in
        held = false
        if value.translation.height > 24 {
          app.dismissToast()
        } else {
          app.holdToast(false)
        }
        pull = 0
      }
  }

  private func disc(_ d: AppModel.Toast.Disc) -> GlassToast.Disc {
    switch d {
    case .done: .accent(.check)
    case .note(let icon): .ink(icon)
    }
  }
}
