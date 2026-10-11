import HasalaDesign
import SwiftUI

@main
struct HasalaApp: App {
  init() {
    HasalaFonts.register()
    // BGTaskScheduler handlers must be registered before launch finishes (spec 04 §7.9).
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
