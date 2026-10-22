#if HASALA_MOCKS
  import Foundation
  import HasalaModels

  /// Debug launch hook (plan B6): `-HasalaScreen <id>` opens one screen on the mocks, for
  /// screenshots (`ios/scripts/screens.sh`) and for tests that start deep in a flow.
  ///
  /// Each id names a screen that exists, starts from its own scenario (an explicit
  /// `-HasalaScenario` wins), and is reached the way a person reaches it: the area's
  /// function drives the real models with the mock services and sets the router. It never
  /// builds a view in a state the app can't reach. The ids live in one file per area
  /// (`ScreenLaunch+Join.swift` … `ScreenLaunch+Profile.swift`); each package adds its own.
  ///
  /// Compiled only with `HASALA_MOCKS`: no Release code path reaches it, and the Release
  /// .ipa check refuses the argument names (AT-REV-4).
  struct ScreenLaunch {
    /// One screen a launch can open.
    struct Screen {
      let id: String
      /// The scenario it starts from unless `-HasalaScenario` names another.
      let scenario: String
      /// Before the window shows: router state the shell applies as it appears (a tab, a
      /// path, a sheet or the cover).
      var prepare: @MainActor (MockGraph) -> Void = { _ in }
      /// After: the steps a person takes, through the real models (a signup's calls, a
      /// connect), at the mocks' speed.
      var drive: @MainActor (MockGraph) async -> Void = { _ in }

      /// A trailing closure is `drive`.
      init(
        _ id: String, scenario: String, drive: @escaping @MainActor (MockGraph) async -> Void = { _ in },
        prepare: @escaping @MainActor (MockGraph) -> Void = { _ in }
      ) {
        self.id = id
        self.scenario = scenario
        self.prepare = prepare
        self.drive = drive
      }
    }

    /// The area files, each owned by one package, and the id prefixes each owns.
    enum Area: String, CaseIterable {
      case join, setup, mail, signIn, home, activity, plan, profile

      /// The first part of an id ("join" in "join.invite") that belongs to this area.
      var prefixes: Set<String> {
        switch self {
        case .join: ["welcome", "join", "phrase", "resume"]
        case .setup: ["setup"]
        case .mail: ["mail", "bankAlerts"]
        case .signIn: ["signin", "unlock", "forgot", "recover", "approval", "security", "confirm", "frozen", "unfreeze"]
        case .home: ["home"]
        case .activity: ["activity", "review", "search"]
        case .plan: ["plan"]
        case .profile: ["profile", "bills", "accounts"]
        }
      }

      /// The area's registered screens.
      var screens: [Screen] {
        switch self {
        case .join: ScreenLaunch.joinScreens
        case .setup: ScreenLaunch.setupScreens
        case .mail: ScreenLaunch.mailScreens
        case .signIn: ScreenLaunch.signInScreens
        case .home: ScreenLaunch.homeScreens
        case .activity: ScreenLaunch.activityScreens
        case .plan: ScreenLaunch.planScreens
        case .profile: ScreenLaunch.profileScreens
        }
      }

      /// The area an id belongs to, by its first part.
      static func of(_ id: String) -> Area? {
        let prefix = String(id.split(separator: ".", maxSplits: 1).first ?? "")
        return allCases.first { $0.prefixes.contains(prefix) }
      }
    }

    let screen: Screen
    var id: String { screen.id }
    var scenario: String { screen.scenario }

    static let argument = "-HasalaScreen"

    /// Every registered screen, in area order.
    static var registry: [Screen] { Area.allCases.flatMap(\.screens) }

    /// `-HasalaScreen <id>`, when the id is registered.
    static func from(_ arguments: [String]) -> ScreenLaunch? {
      guard let i = arguments.firstIndex(of: argument), i + 1 < arguments.count else { return nil }
      let id = arguments[i + 1]
      guard let screen = Area.of(id)?.screens.first(where: { $0.id == id }) else { return nil }
      return ScreenLaunch(screen: screen)
    }

    /// The process runs a mock graph (and never the live one): a scenario or a screen was
    /// asked for.
    static func isMockLaunch(_ arguments: [String]) -> Bool {
      arguments.contains("-HasalaScenario") || arguments.contains(argument)
    }

    /// The arguments the mock graph reads: the screen's scenario unless one was given.
    func arguments(_ arguments: [String]) -> [String] {
      arguments.contains("-HasalaScenario") ? arguments : arguments + ["-HasalaScenario", scenario]
    }

    /// Opens the screen on `graph`: its router state now, its steps once the mocks answer
    /// at once (no simulated latency on a launched screen).
    func open(_ graph: MockGraph) {
      if let account = graph.session.account as? MockAccountService { account.delay = .zero }
      if let mailbox = graph.session.services.mailbox as? MockMailbox { mailbox.connectDelay = .zero }
      screen.prepare(graph)
      let drive = screen.drive
      Task { await drive(graph) }
    }

    // MARK: Helpers for the area files

    /// A tab with its push path, and a sheet or the cover over it, as the shell applies
    /// them when it appears.
    static func shell(
      _ tab: AppTab, home: [HomeRoute] = [], plan: [PlanRoute] = [], projects: [PlanRoute] = [],
      activity: [ActivityRoute] = [], sheet: SheetRoute? = nil, cover: CoverRoute? = nil,
      profile: [ProfileRoute] = [], overProfile: SheetRoute? = nil,
      transaction: [TransactionRoute] = [], review: [ReviewRoute] = []
    ) -> @MainActor (MockGraph) -> Void {
      { graph in
        let router = graph.app.router
        router.tab = tab
        router.home = home
        router.plan = plan
        router.projects = projects
        router.activity = activity
        router.review = review
        if sheet != nil || cover != nil {
          router.pendingLaunch = PendingLaunch(
            sheet: sheet, cover: cover, profile: profile, overProfile: overProfile, transaction: transaction)
        }
      }
    }

    /// The profile sheet with `path` pushed inside it.
    static func profile(_ path: [ProfileRoute]) -> @MainActor (MockGraph) -> Void {
      shell(.home, sheet: .profile, profile: path)
    }

    static func cloudSort(
      _ phase: CloudSortStatus.Phase, then next: @escaping @MainActor (MockGraph) -> Void
    ) -> @MainActor (MockGraph) -> Void {
      { graph in
        if graph.app.cloudSort == nil { graph.app.cloudSort = MockCloudSortController(MockCloudSortController.sample(phase)) }
        next(graph)
      }
    }
  }

  /// `-HasalaMotion off|reduce` (plan B6): screenshots with every animation at its end
  /// state, or the Reduce Motion substitutes without the system setting. Read once; the
  /// design system's motion policy applies it (its `settled` and `reduceMotion`).
  enum MotionLaunch: String, Sendable {
    /// Final states at once, haptics as usual.
    case off
    /// As if Reduce Motion were on.
    case reduce

    static let argument = "-HasalaMotion"

    static func from(_ arguments: [String]) -> MotionLaunch? {
      guard let i = arguments.firstIndex(of: argument), i + 1 < arguments.count else { return nil }
      return MotionLaunch(rawValue: arguments[i + 1])
    }

    /// This process's choice.
    static let current = from(ProcessInfo.processInfo.arguments)

    var settled: Bool { self == .off }
    var reduceMotion: Bool { self == .reduce }
  }
#endif
