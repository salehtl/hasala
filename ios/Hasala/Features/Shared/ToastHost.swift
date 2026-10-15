import HasalaDesign
import SwiftUI

/// Floats the app's toast above the tab bar. Every tab root, sheet and pushed screen that
/// can show a toast hosts one (`toast`, with its action as a button inside).
// TODO(plan B7.1): the toast motion of HMotion (rise 12 and fade in over 220 ms, fade out
// over 180 ms), the VoiceOver announcement and the 4 s dwell (8 s with VoiceOver).
struct ToastHost: View {
  let app: AppModel

  var body: some View {
    if let toast = app.toast {
      GlassToast(systemImage: toast.systemImage, title: toast.title, subtitle: toast.subtitle,
                 actionTitle: toast.actionTitle) { app.toastAction() }
        .padding(.horizontal, HSpacing.insetPage)
        .padding(.bottom, 12)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .accessibilityIdentifier("toast")
    }
  }
}
