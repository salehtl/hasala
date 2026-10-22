import Foundation
import HasalaDesign
import SwiftUI
import Testing

@testable import Hasala

@Suite("Header mark coin taps")
struct HeaderMarkTests {
  let start: TimeInterval = 100

  @Test func aSingleTapDeposits() {
    var taps = CoinTaps()
    #expect(taps.tap(at: start) == .deposit)
    #expect(taps.streak == 1)
  }

  @Test func fiveQuickTapsHitTheJackpotAndStartOver() {
    var taps = CoinTaps()
    let tricks = (0..<6).map { taps.tap(at: start + Double($0) * 0.3) }
    #expect(tricks == [.deposit, .deposit, .deposit, .deposit, .jackpot, .deposit])
    #expect(taps.streak == 1)
  }

  @Test func aPauseBreaksTheStreak() {
    var taps = CoinTaps()
    for index in 0..<4 { _ = taps.tap(at: start + Double(index) * 0.3) }
    #expect(taps.tap(at: start + 0.9 + CoinTaps.gap + 0.1) == .deposit)
    #expect(taps.streak == 1)
  }
}

@Suite("Header mark coin show")
struct CoinShowTests {
  let start: TimeInterval = 100

  @Test func theDepositStaysUnderTheUILimit() {
    #expect(CoinShow.total(.deposit) < 0.3)
    #expect(CoinShow.beats(.deposit) == [CoinShow.Beat(at: CoinShow.sink, haptic: .impactLight)])
  }

  @Test func theJackpotRunsLongerButStaysARareMoment() {
    let total = CoinShow.total(.jackpot)
    #expect(total >= 0.9)
    #expect(total <= 1.6)
    #expect(CoinShow.firstImpact + CoinShow.burst <= total)
  }

  @Test func theJackpotHitsLandInOrderInsideTheShow() {
    let hits = CoinShow.impacts(.jackpot)
    #expect(hits.count == CoinShow.showerCoins + 1)
    #expect(hits == hits.sorted())
    #expect(hits.first == CoinShow.firstImpact)
    #expect(hits.allSatisfy { $0 > CoinShow.crouch + CoinShow.spinTime && $0 < CoinShow.total(.jackpot) })
    #expect(CoinShow.bumps.count == hits.count)
  }

  @Test func theJackpotHapticsFollowTheHits() {
    let beats = CoinShow.beats(.jackpot)
    #expect(beats.map(\.haptic) == [.impactRigid, .impactLight, .impactLight, .success])
    #expect(Array(beats.map(\.at).prefix(3)) == CoinShow.impacts(.jackpot))
    #expect(beats.map(\.at) == beats.map(\.at).sorted())
    #expect(beats.last!.at < CoinShow.total(.jackpot))
  }

  @Test func aTapWhileIdlePlaysAtOnce() {
    var stage = CoinStage()
    #expect(stage.step(.deposit, at: start) == .play(after: 0))
    #expect(stage.busyUntil == start + CoinShow.total(.deposit))
  }

  @Test func depositsDuringAShowAreSkipped() {
    var stage = CoinStage()
    _ = stage.step(.jackpot, at: start)
    #expect(stage.step(.deposit, at: start + 0.2) == .skip)
    #expect(stage.busyUntil == start + CoinShow.total(.jackpot))
  }

  @Test func aJackpotDuringADepositQueuesOnce() {
    var stage = CoinStage()
    _ = stage.step(.deposit, at: start)
    guard case .play(let wait) = stage.step(.jackpot, at: start + 0.1) else {
      Issue.record("the jackpot was not queued")
      return
    }
    #expect(abs(wait - (CoinShow.total(.deposit) - 0.1)) < 1e-9)
    #expect(stage.jackpotQueued)
    #expect(stage.step(.jackpot, at: start + 0.15) == .skip)
    #expect(stage.busyUntil == start + CoinShow.total(.deposit) + CoinShow.total(.jackpot))
    stage.started(.jackpot)
    #expect(!stage.jackpotQueued)
  }

  @Test func theStageIsFreeOnceTheShowEnds() {
    var stage = CoinStage()
    _ = stage.step(.jackpot, at: start)
    #expect(stage.step(.deposit, at: start + CoinShow.total(.jackpot)) == .play(after: 0))
  }

  @Test func resetFreesTheStage() {
    var stage = CoinStage()
    _ = stage.step(.deposit, at: start)
    _ = stage.step(.jackpot, at: start + 0.1)
    stage.reset()
    #expect(stage == CoinStage())
    #expect(stage.step(.deposit, at: start + 0.12) == .play(after: 0))
  }

  func timeline(_ trick: CoinTaps.Trick) -> KeyframeTimeline<HeaderMark.Coin> {
    KeyframeTimeline(initialValue: HeaderMark.Coin()) { HeaderMark.keyframes(trick) }
  }

  @Test(arguments: [CoinTaps.Trick.deposit, .jackpot])
  func theKeyframesLastAsLongAsTheShow(_ trick: CoinTaps.Trick) {
    #expect(abs(timeline(trick).duration - CoinShow.total(trick)) < 1e-9)
  }

  @Test func everyJackpotHitIsACoinReachingTheSlot() {
    let drawn = timeline(.jackpot)
    for hit in CoinShow.impacts(.jackpot) {
      #expect(abs(drawn.value(time: hit).drop) < 1e-6)
      #expect(drawn.value(time: hit + CoinShow.sinkAway / 2).drop < 0)
    }
  }

  @Test func theJackpotBumpsPeakAfterEachHit() {
    let drawn = timeline(.jackpot)
    for (hit, bump) in zip(CoinShow.impacts(.jackpot), CoinShow.bumps) {
      #expect(abs(drawn.value(time: hit + CoinShow.bumpUp).bump - bump) < 1e-6)
    }
  }

  @Test(arguments: [CoinTaps.Trick.deposit, .jackpot])
  func theShowEndsAtRest(_ trick: CoinTaps.Trick) {
    let end = timeline(trick).value(time: CoinShow.total(trick))
    #expect(abs(end.drop) < 1)
    #expect(end.spin == 0)
    #expect(end.squash == 0)
    #expect(abs(end.bump) < 0.01)
    #expect(end.burst == 0)
  }
}

@Suite("Header mark jackpot launch")
struct JackpotLaunchTests {
  @Test func theArgumentParses() {
    #expect(JackpotLaunch.from([]) == nil)
    #expect(JackpotLaunch.from(["-HasalaJackpot"]) == 0)
    #expect(JackpotLaunch.from(["-HasalaJackpot", "-HasalaScenario"]) == 0)
    #expect(JackpotLaunch.from(["-HasalaJackpot", "2.5"]) == 2.5)
    #expect(JackpotLaunch.from(["-HasalaJackpot", "-3"]) == 0)
    #expect(JackpotLaunch.from(["-HasalaJackpot", "nan"]) == 0)
    #expect(JackpotLaunch.from(["-HasalaJackpot", "inf"]) == 0)
  }
}
