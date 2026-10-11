import HasalaDesign
import SwiftUI

#if HASALA_MOCKS
  import HasalaMocks
#endif

/// The root of the window.
///
/// Every build runs the live graph (spec 04 §15.2): the account gate (`BootController`)
/// in front of the tab shell over the account's projection. Debug builds run a mock
/// scenario instead only when launched with `-HasalaScenario <name>` (spec 04 §15.3; the
/// UI tests and previews); no Release code path reaches HasalaMocks (spec 04 §1.4,
/// AT-REV-4).
struct RootView: View {
  #if HASALA_MOCKS
    /// The mock scenario, when one was asked for.
    @State private var mock: MockGraph? = MockGraph.fromLaunchArguments(ProcessInfo.processInfo.arguments)
  #endif

  var body: some View {
    #if HASALA_MOCKS
      if let mock {
        AccountRootView(session: mock.session) { MainView(app: mock.app) }
      } else {
        LiveRootView()
      }
    #else
      LiveRootView()
    #endif
  }
}

/// The live graph: the account gate, setup, and the app over the open account.
struct LiveRootView: View {
  @State private var boot: BootController = {
    let boot = BootController(env: .live())
    AppGraph.boot = boot
    return boot
  }()
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    Group {
      if boot.state == .waiting || boot.waitingForRuntime && !isReady {
        LaunchView()
      } else {
        AccountRootView(session: boot.session, setupFacts: boot.setupFacts) {
          if let app = boot.app {
            MainView(app: app).id(boot.generation)
          } else {
            LaunchView()
          }
        }
        .id(ObjectIdentifier(boot.session))
      }
    }
    .onAppear { boot.start() }
    .onChange(of: boot.session.phase) { _, phase in boot.phaseChanged(phase) }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active { boot.foreground() }
    }
  }

  /// The app shows its own placeholder while the runtime opens; only setup waits here.
  private var isReady: Bool { boot.session.phase == .ready }
}

/// The wordmark on the launch background while the account opens.
struct LaunchView: View {
  var body: some View {
    VStack(spacing: 24) {
      Image("HasalaWordmark")
        .resizable()
        .scaledToFit()
        .frame(maxWidth: 200)
        .accessibilityLabel("Hasala")
      ProgressView()
        .accessibilityLabel("Opening Hasala")
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(HColor.surfaceSecondary)
    .accessibilityIdentifier("launch.opening")
  }
}

#if HASALA_MOCKS
  /// A Debug mock scenario (`-HasalaScenario <name>`): the Maya ledger in memory and the
  /// account mock's starting state.
  @MainActor
  final class MockGraph {
    let app: AppModel
    let session: AccountSession

    init(app: AppModel, session: AccountSession) {
      self.app = app
      self.session = session
    }

    static func fromLaunchArguments(_ arguments: [String]) -> MockGraph? {
      guard arguments.contains("-HasalaScenario") else { return nil }
      let scenario = Scenario.fromLaunchArguments(arguments)
      return MockGraph(
        app: AppModel(
          store: InMemoryLedger(state: scenario.state, now: MayaLedger.now),
          amountsHidden: scenario.startsWithAmountsHidden),
        session: AuthScenario.session(for: AuthScenario.fromLaunchArguments(arguments)))
    }
  }
#endif
