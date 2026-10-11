import SwiftUI

#if HASALA_MOCKS
  import HasalaMocks
#endif

/// The root of the window.
///
/// Debug builds run the Maya mock scenario (`-HasalaScenario <name>`, spec 04 §15.3)
/// through the real tab shell. Release builds have no data source yet (no sync, no
/// account, no networking at Gate A0), so they show the A0 shell: the wordmark and
/// the build footer (spec 06 §15.2). No Release code path reaches HasalaMocks
/// (spec 04 §1.4, AT-REV-4).
struct RootView: View {
  var body: some View {
    #if HASALA_MOCKS
      let scenario = Scenario.fromLaunchArguments(ProcessInfo.processInfo.arguments)
      MainView(app: AppModel(snapshot: Maya.home, amountsHidden: scenario.startsWithAmountsHidden))
    #else
      ShellView(build: .current)
    #endif
  }
}
