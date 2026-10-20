import HasalaDesign
import SwiftUI

#if HASALA_MOCKS
  import HasalaMocks
#endif

/// The root of the window.
///
/// Every build runs the live graph (spec 04 §15.2): the account gate (`BootController`)
/// in front of the tab shell over the account's projection. Debug builds run a mock
/// scenario instead only when launched with `-HasalaScenario <name>` or a Debug screen
/// launch (`ScreenLaunch`; spec 04 §15.3: the UI tests, previews and screenshots); no
/// Release code path reaches HasalaMocks (spec 04 §1.4, AT-REV-4).
struct RootView: View {
  #if HASALA_MOCKS
    /// The mock scenario, when one was asked for.
    @State private var mock: MockGraph? = MockGraph.fromLaunchArguments(ProcessInfo.processInfo.arguments)
  #endif

  /// The motion policy (plan B1.2) is set here once, above the gate, the shell and their
  /// sheets, so every part of the design system reads the same Reduce Motion answer.
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    content
      .overlay {
        if SnapshotCover.covers(scenePhase) { SnapshotCover() }
      }
  }

  @ViewBuilder private var content: some View {
    #if HASALA_MOCKS
      Group {
        if let mock {
          AccountRootView(session: mock.session, onboarding: mock.onboarding, setupFacts: mock.setupFacts) {
            MainView(app: mock.app)
          }
        } else {
          LiveRootView()
        }
      }
      // `-HasalaMotion off|reduce` (plan B6): end states at once for screenshots, or the
      // Reduce Motion substitutes without the system setting.
      .hMotionPolicy(
        settled: MotionLaunch.current?.settled ?? false,
        forceReduceMotion: MotionLaunch.current?.reduceMotion ?? false
      )
    #else
      LiveRootView()
        .hMotionPolicy()
    #endif
  }
}

/// The live graph: the account gate, setup, and the app over the open account.
struct LiveRootView: View {
  /// One live graph per process (`@State`'s initial value is evaluated on every init).
  @State private var boot = AppGraph.live()
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    Group {
      if boot.state == .waiting || boot.waitingForRuntime && !isReady {
        LaunchView()
      } else {
        AccountRootView(session: boot.session, onboarding: boot.onboarding, setupFacts: boot.setupFacts) {
          if let app = boot.app {
            MainView(app: app).id(boot.generation)
          } else {
            LaunchView()
          }
        }
        .id(ObjectIdentifier(boot.session))
        // Under a wall the gate keeps its place (a sign-in screen stays where it was).
        .accessibilityHidden(boot.wall != nil)
      }
    }
    .overlay {
      if let wall = boot.wall {
        BootWallView(boot: boot, wall: wall)
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

struct SnapshotCover: View {
  static func covers(_ phase: ScenePhase) -> Bool { phase == .background }

  var body: some View {
    Image("HasalaWordmark")
      .resizable()
      .scaledToFit()
      .frame(maxWidth: 200)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(HColor.surfaceSecondary)
      .ignoresSafeArea()
      .accessibilityHidden(true)
  }
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
  /// A Debug mock scenario (`-HasalaScenario <name>`, or a screen's own with
  /// `-HasalaScreen <id>`): the Maya ledger in memory, the account mock's starting state,
  /// and the process's one onboarding store (`RootView` keeps this graph for the process).
  @MainActor
  final class MockGraph {
    let app: AppModel
    let session: AccountSession
    let onboarding: OnboardingStore
    /// Where setup resumes in this scenario.
    let setupFacts: OnboardingStep.Facts
    let widgets: WidgetPublisher

    init(app: AppModel, session: AccountSession, setupFacts: OnboardingStep.Facts) {
      self.app = app
      self.session = session
      self.setupFacts = setupFacts
      widgets = WidgetPublisher(app: app)
      onboarding = OnboardingStore(services: session.services, session: { [session] in session })
    }

    /// The graph for a mock launch, nil for the live one. A launched screen picks its
    /// scenario (an explicit `-HasalaScenario` wins), then opens over it (`ScreenLaunch`).
    static func fromLaunchArguments(_ given: [String]) -> MockGraph? {
      guard ScreenLaunch.isMockLaunch(given) else { return nil }
      let launch = ScreenLaunch.from(given)
      let arguments = launch?.arguments(given) ?? given
      let scenario = Scenario.fromLaunchArguments(arguments)
      let auth = AuthScenario.fromLaunchArguments(arguments)
      let session = AuthScenario.session(for: auth)
      let graph = MockGraph(
        app: AppModel(
          store: InMemoryLedger(state: scenario.state, now: scenario.now),
          amountsHidden: scenario.startsWithAmountsHidden, mailbox: session.services.mailbox,
          layouts: mockLayouts(arguments)),
        session: session, setupFacts: AuthScenario.setupFacts(for: auth))
      launch?.open(graph)
      return graph
    }

    static let keepLayoutArgument = "-HasalaKeepHomeLayout"
    static let layoutSuite = "app.hasala.mock.homeLayout"

    static func mockLayouts(_ arguments: [String]) -> HomeLayoutStore? {
      guard let defaults = UserDefaults(suiteName: layoutSuite) else { return nil }
      if !arguments.contains(keepLayoutArgument) { HomeLayoutStore.forgetAll(defaults) }
      return HomeLayoutStore(defaults: defaults, account: "maya")
    }
  }
#endif
