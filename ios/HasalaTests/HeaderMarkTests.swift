import Foundation
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
