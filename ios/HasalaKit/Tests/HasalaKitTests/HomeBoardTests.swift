import HasalaMocks
import HasalaModels
import Testing

// The Home board read models: the canvas layout and the Maya hero (owned by P5).

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

/// The mock reproduces the Paper Home board's figures (14O7-0, page 06 §6.8) where the ledger
/// agrees with it.
@Suite("Maya scenario")
struct MayaTests {
  @Test func heroMatchesTheBoard() {
    let hero = Maya.home.hero
    #expect(hero.overline == "Day 10 of 31")
    #expect(MoneyFormat.string(hero.spent.minor) == "10,288.34")
    #expect(hero.caption.rendered(hidden: false) == "spent of 19,000 on needs and wants")
    #expect(hero.word.rendered(hidden: false) == "On track")
    #expect(hero.fact?.rendered(hidden: false) == "AED 8,711.66 left")
    #expect(hero.verdict == .onTrack)
    #expect(hero.wash == .sky)
    // The board's bar: fill 196 of 362 (54%), tick at 213 (59%).
    #expect(Permille.ratio(hero.spent.minor, of: hero.plan.minor).value == 541)
    #expect(hero.tick.map { Permille.ratio($0.minor, of: hero.plan.minor).value } == 590)
    // Needs and Wants as drawn; Savings follows the ledger (plan D.3 decision 5).
    #expect(hero.tiles.map { MoneyFormat.string($0.value.minor, style: $0.style) } == ["9,040.80", "1,247.54", "5,000.00"])
  }

  @Test func theBellCountsFour() {
    #expect(Maya.home.notifications.count == 4)
  }

  @Test func bucketRowsAddUp() throws {
    guard case .budgetPace(let pace) = Maya.home.widgets[0] else {
      Issue.record("first widget is not Budget pace")
      return
    }
    #expect(pace.rows.map { MoneyFormat.string($0.left.minor, style: .rounded) } == ["3,309", "5,402", "0"])
    #expect(pace.rows.map { MoneyFormat.string($0.spent.minor, style: .rounded) } == ["9,041", "1,248", "5,000"])
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
