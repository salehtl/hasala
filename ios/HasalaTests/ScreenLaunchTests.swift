import Foundation
import Testing

@testable import Hasala

/// The Debug launch hook (plan B6): every registered screen parses, starts from a known
/// scenario, belongs to exactly one area, and is reached through the real models.
@MainActor
@Suite("Screen launch")
struct ScreenLaunchTests {
  /// The ledger scenarios HasalaMocks knows besides the account ones.
  static let ledgerScenarios: Set<String> = ["maya", "mayaHidden", "mayaCaughtUp", "mayaSample", "firstDays", "mayaCopy"]

  @Test func everyRegisteredScreenParsesAndHasAScenario() {
    let screens = ScreenLaunch.registry
    #expect(!screens.isEmpty)
    #expect(Set(screens.map(\.id)).count == screens.count, "an id is registered twice")
    for s in screens {
      #expect(ScreenLaunch.from(["-HasalaScreen", s.id])?.id == s.id, "\(s.id) doesn't parse")
      #expect(AuthScenario(rawValue: s.scenario) != nil || Self.ledgerScenarios.contains(s.scenario),
              "\(s.id) starts from an unknown scenario \(s.scenario)")
    }
  }

  @Test func everyScreenBelongsToExactlyOneArea() {
    for area in ScreenLaunch.Area.allCases {
      for s in area.screens {
        #expect(ScreenLaunch.Area.of(s.id) == area, "\(s.id) is registered in \(area) but its prefix says otherwise")
        let others = ScreenLaunch.Area.allCases.filter { $0 != area && $0.screens.contains { $0.id == s.id } }
        #expect(others.isEmpty, "\(s.id) is in \(others) too")
      }
    }
    // The prefixes don't overlap.
    let prefixes = ScreenLaunch.Area.allCases.flatMap(\.prefixes)
    #expect(Set(prefixes).count == prefixes.count)
  }

  @Test func theArgumentsDecideTheGraph() {
    #expect(ScreenLaunch.from(["-HasalaScreen", "no.such.screen"]) == nil)
    #expect(ScreenLaunch.from(["-HasalaScreen"]) == nil)
    #expect(ScreenLaunch.isMockLaunch(["-HasalaScreen", "home"]))
    #expect(ScreenLaunch.isMockLaunch(["-HasalaScenario", "maya"]))
    #expect(!ScreenLaunch.isMockLaunch(["-HasalaReleaseSurface"]))
    // The screen's scenario, unless one was named.
    let launch = ScreenLaunch.from(["-HasalaScreen", "setup.bank"])
    #expect(launch?.arguments(["-HasalaScreen", "setup.bank"]).suffix(2) == ["-HasalaScenario", "setupBank"])
    let named = ["-HasalaScreen", "setup.bank", "-HasalaScenario", "reviewAccount"]
    #expect(launch?.arguments(named) == named)
    #expect(MotionLaunch.from(["-HasalaMotion", "off"]) == .off)
    #expect(MotionLaunch.from(["-HasalaMotion", "reduce"])?.reduceMotion == true)
    #expect(MotionLaunch.from(["-HasalaMotion", "slow"]) == nil && MotionLaunch.from([]) == nil)
  }

  /// A screen's graph on its scenario, with its router state and its steps done, at the
  /// mocks' full speed.
  func opened(_ id: String) async throws -> MockGraph {
    let screen = try #require(ScreenLaunch.registry.first { $0.id == id })
    let graph = try #require(MockGraph.fromLaunchArguments(["-HasalaScenario", screen.scenario]))
    if let account = graph.session.account as? MockAccountService { account.delay = .zero }
    if let mailbox = graph.session.services.mailbox as? MockMailbox { mailbox.connectDelay = .zero }
    screen.prepare(graph)
    await screen.drive(graph)
    return graph
  }

  @Test func everyScreenIsReachedThroughTheModels() async throws {
    for s in ScreenLaunch.registry { _ = try await opened(s.id) }
    let saved = try await opened("phrase.saved")
    #expect(saved.onboarding.signup.path.last == .accountReady && saved.onboarding.signup.phrase == nil)
    let wrong = try await opened("join.codeWrong")
    #expect(wrong.onboarding.signup.failure == .codeWrong(triesLeft: 4))
    let done = try await opened("setup.done")
    #expect(done.onboarding.setup?.path.last == .done)
    let connected = try await opened("mail.connectedGmail")
    #expect(connected.onboarding.setup?.path == [.connect(.gmail)] && connected.onboarding.setup?.mailConnected == true)
    let txn = try await opened("activity.txn")
    #expect(txn.app.router.tab == .activity && txn.app.router.pendingLaunch?.sheet == .transaction("carrefour"))
    let detail = try await opened("mail.detail")
    #expect(detail.app.router.pendingLaunch?.profile == [.bankAlerts, .mailbox("outlook-1")])
  }
}
