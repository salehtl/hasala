import HasalaMocks
import HasalaModels
import Foundation
import Testing

@Suite("Sender not verified · no warning shown")
struct SenderUnverifiedTests {
  let s = MayaLedger.state
  let now = MayaLedger.now

  @Test func mayasSteamCardIsAnOrdinaryReviewCard() throws {
    let steam = try #require(ReviewEngine.cards(s).first { $0.id == "steam" })
    #expect(steam.reviewReason == nil)
    #expect(try #require(s.txn("steam")).senderUnverified)
  }

  @Test func theActivityRowSaysToReview() throws {
    let row = ActivityEngine.row(try #require(s.txn("steam")), s)
    #expect(row.toReview && row.reviewReason == nil)
    #expect(row.detail == "To review · 11:02")
  }

  @Test func theTransactionSheetCarriesNoReason() {
    #expect(TransactionEngine.detail("steam", s, now: now)?.reviewReason == nil)
  }

  @Test func theFlagSurvivesCoding() throws {
    let t = try #require(s.txn("steam"))
    let back = try JSONDecoder().decode(Txn.self, from: JSONEncoder().encode(t))
    #expect(back.senderUnverified)
    #expect(TxnReviewReason(rawValue: "sender_unverified") == nil)
  }

  @Test func aRuleNeverReachesAnUnverifiedRow() throws {
    var t = try #require(s.txn("steam"))
    t.categorySource = .dictionary
    #expect(!MockReach.ruled(t, pairs: []))
    t.senderUnverified = false
    #expect(MockReach.ruled(t, pairs: []))
  }
}
