import HasalaMocks
import HasalaModels
import Testing

// The Home board read models: the canvas layout and the Maya hero (owned by P5 from Stage P).

@Suite("Home canvas")
struct CanvasTests {
  @Test func mediumsStandAloneAndSmallsPair() {
    let rows = Maya.home.widgets.canvasRows
    #expect(rows.map(\.count) == [1, 2, 2, 1])
    #expect(rows[1].map(\.id) == ["nextBill", "netWorth"])
  }

  @Test func anUnpairedSmallSitsAlone() {
    let w = Maya.home.widgets
    let rows = [w[1], w[0], w[2]].canvasRows
    #expect(rows.map(\.count) == [1, 1, 1])
  }
}

/// The mock reproduces the Paper Home board's figures exactly (spec 04 §15.3).
@Suite("Maya scenario")
struct MayaTests {
  @Test func heroMatchesTheBoard() {
    let hero = Maya.home.hero
    #expect(MoneyFormat.string(hero.left.minor) == "7,417.55")
    #expect(hero.verdictDetail.rendered(hidden: false) == "about AED 337 a day")
    #expect(hero.stats.map { MoneyFormat.string($0.value.minor) } == ["2,282.45", "8,005.89", "1,039.15"])
    #expect(hero.spent.value == 235)
    #expect(hero.today.value == 320)
    #expect(hero.verdict == .onTrack)
  }

  @Test func bucketRowsAddUp() throws {
    guard case .budgetPace(let pace) = Maya.home.widgets[0] else {
      Issue.record("first widget is not Budget pace")
      return
    }
    #expect(pace.rows.map { MoneyFormat.string($0.left.minor, style: .compact) } == ["3,309.20", "5,402.46", "0"])
    #expect(pace.rows.last?.verdict == .done)
  }

  @Test func scenarioFromLaunchArguments() {
    #expect(Scenario.fromLaunchArguments(["app"]) == .maya)
    #expect(Scenario.fromLaunchArguments(["app", "-HasalaScenario", "mayaHidden"]) == .mayaHidden)
    #expect(Scenario.fromLaunchArguments(["app", "-HasalaScenario", "nope"]) == .maya)
    #expect(Scenario.fromLaunchArguments(["app", "-HasalaScenario"]) == .maya)
  }

  @Test func goalPercentRoundsDown() {
    #expect(GoalWidget(name: "x", glyph: .flag, progress: Permille(999), caption: "").percentLabel == "99%")
  }
}
