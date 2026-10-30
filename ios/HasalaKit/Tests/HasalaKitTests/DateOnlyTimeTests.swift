import HasalaMocks
import HasalaModels
import Testing

@Suite("Rows with a date and no time")
struct DateOnlyTimeTests {
  let s = MayaLedger.state
  let now = MayaLedger.now

  @Test func rowsLeaveOutTheTime() throws {
    var lulu = try #require(s.txn("lulu"))
    lulu.postedTimeKnown = false
    #expect(ActivityEngine.row(lulu, s).detail == "To review")
    #expect(ActivityEngine.dated(lulu, s).detail == "To review")

    var steam = try #require(s.txn("steam"))
    steam.postedTimeKnown = false
    #expect(ActivityEngine.row(steam, s).detail == "To review")
    steam.needsReview = false
    steam.categoryID = "entertainment"
    let name = try #require(s.category("entertainment")).name
    #expect(ActivityEngine.row(steam, s).detail == name)
    #expect(ActivityEngine.dated(steam, s).detail == steam.postedAt.date.short)
  }

  @Test func theCardsLeaveOutTheTime() throws {
    var t = try #require(s.txn("lulu"))
    t.postedTimeKnown = false
    var state = s
    state.txns = state.txns.map { $0.id == t.id ? t : $0 }
    let meta = try #require(TransactionEngine.detail(t.id, state, now: now)).meta
    #expect(meta.hasPrefix(t.postedAt.date.short) && !meta.contains(t.postedAt.time))
    let card = ReviewEngine.card(t, state)
    #expect(!card.meta.contains(t.postedAt.time))
  }
}
