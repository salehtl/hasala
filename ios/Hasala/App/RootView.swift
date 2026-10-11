import SwiftUI

#if HASALA_MOCKS
  import HasalaMocks
#endif

/// The root of the window.
///
/// Debug builds run a mock scenario (`-HasalaScenario <name>`, spec 04 §15.3) through the
/// real tab shell, over an in-memory ledger the screens can change. Release builds have
/// no data source yet, so they show the A0 shell: the wordmark and the build footer
/// (spec 06 §15.2). No Release code path reaches HasalaMocks (spec 04 §1.4, AT-REV-4).
// TODO(spec 04 §15.2, §6.5): Release boots into BootWalls / OnboardingFlow / MainView over
// the live LedgerStore once accounts and sync land; MainView needs nothing else.
struct RootView: View {
  #if HASALA_MOCKS
    /// Made once for the window, not on every evaluation of `body`.
    @State private var app: AppModel = {
      let scenario = Scenario.fromLaunchArguments(ProcessInfo.processInfo.arguments)
      return AppModel(store: InMemoryLedger(state: scenario.state, now: MayaLedger.now),
                      amountsHidden: scenario.startsWithAmountsHidden)
    }()
    /// The account gate (onboarding, sign-in, walls) on the in-memory account mock; the
    /// page-14 scenarios pick its starting state (`AuthScenario`).
    @State private var session = AuthScenario.session(
      for: AuthScenario.fromLaunchArguments(ProcessInfo.processInfo.arguments))
  #endif

  var body: some View {
    #if HASALA_MOCKS
      AccountRootView(session: session) { MainView(app: app) }
    #else
      ShellView(build: .current)
    #endif
  }
}
