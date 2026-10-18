import HasalaMocks
import HasalaModels
import Foundation
import Testing

@Suite("Review reason · sender not verified")
struct SenderUnverifiedTests {
  let s = MayaLedger.state
  let now = MayaLedger.now

  @Test func mayasSteamCardSaysTheSenderIsNotVerified() throws {
    let steam = try #require(ReviewEngine.cards(s).first { $0.id == "steam" })
    #expect(steam.senderUnverified && steam.reviewReason == .senderUnverified)
    #expect(TxnReviewReason.senderUnverified.label == "Couldn't verify sender")
    #expect(ReviewEngine.cards(s).filter(\.senderUnverified).map(\.id) == ["steam"])
  }

  @Test func theActivityRowNamesTheReasonInTheWarningTone() throws {
    let t = try #require(s.txn("steam"))
    let row = ActivityEngine.row(t, s)
    #expect(row.toReview && row.senderUnverified)
    #expect(row.detail == "Couldn't verify sender · 11:02")
    let lulu = ActivityEngine.row(try #require(s.txn("lulu")), s)
    #expect(!lulu.senderUnverified && lulu.detail == "To review · 18:42")
  }

  @Test func theTransactionSheetCarriesTheReason() {
    #expect(TransactionEngine.detail("steam", s, now: now)?.reviewReason == .senderUnverified)
    #expect(TransactionEngine.detail("lulu", s, now: now)?.senderUnverified == false)
  }

  @Test func aSortedRowNeverShowsTheReason() throws {
    var t = try #require(s.txn("steam"))
    t.needsReview = false
    t.categoryID = "entertainment"
    #expect(t.activeReviewReason == nil && t.reviewReason == .senderUnverified)
    #expect(ActivityEngine.row(t, s).reviewReason == nil)
  }

  @Test func noReasonMeansNoWarning() throws {
    var t = try #require(s.txn("steam"))
    t.reviewReason = nil
    #expect(!t.senderUnverified)
    #expect(ActivityEngine.row(t, s).detail == "To review · 11:02")
  }

  @Test func theReasonSurvivesCoding() throws {
    let t = try #require(s.txn("steam"))
    let back = try JSONDecoder().decode(Txn.self, from: JSONEncoder().encode(t))
    #expect(back.reviewReason == .senderUnverified)
    #expect(TxnReviewReason(rawValue: "sender_unverified") == .senderUnverified)
  }
}
