import HasalaDesign
import SwiftUI

@main
struct HasalaApp: App {
  /// APNs token callbacks and silent pushes (spec 04 §2.3).
  @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate

  init() {
    HasalaFonts.register()
    // BGTaskScheduler handlers must be registered before launch finishes (spec 04 §7.9):
    // Info.plist lists both identifiers, and a task that fires without a handler crashes.
    // The work itself is installed once an account opens (`BootController`).
    BackgroundScheduler.shared.register()
  }

  var body: some Scene {
    WindowGroup {
      RootView()
        // English, light only (spec 04 §14.9; PO-10 decided).
        .preferredColorScheme(.light)
        .tint(HColor.actionAccent)
    }
  }
}
