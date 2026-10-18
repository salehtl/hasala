import HasalaMocks
import HasalaModels
import Testing

@MainActor
@Suite("A held probable copy")
struct HeldCopyTests {
  let october = MayaLedger.october

  @Test func isOutOfEveryTotalUntilKeptAndThenCounts() throws {
    let base = MayaLedger.state
    let ledger = InMemoryLedger(state: Scenario.mayaCopy.state)
    let s = ledger.state
    let copy = try #require(s.txn("starbucks-copy"))
    #expect(copy.isHeldCopy && !copy.countsInPlan)
    #expect(s.spent("dining", in: october) == base.spent("dining", in: october))
    #expect(HomeEngine.snapshot(s, now: MayaLedger.now).hero.spent == HomeEngine.snapshot(base, now: MayaLedger.now).hero.spent)
    #expect(ActivityEngine.reviewSummary(s, now: MayaLedger.now).unplanned == ActivityEngine.reviewSummary(base, now: MayaLedger.now).unplanned)
    #expect(ReviewEngine.queue(s).contains { $0.id == "starbucks-copy" })
    let card = ReviewEngine.card(copy, s)
    #expect(card.reviewReason == .probableCopy)
    #expect(card.copyLine == "Looks like a copy of Starbucks DIFC AED 27.00 from your other inbox")

    let token = try ledger.apply(.resolveCopy("starbucks-copy", merge: false))
    #expect(token?.title == "Kept both")
    #expect(ledger.state.txn("starbucks-copy")?.countsInPlan == true)
    #expect(ledger.state.spent("dining", in: october).minor == base.spent("dining", in: october).minor + 27_00)
    #expect(!ReviewEngine.queue(ledger.state).contains { $0.id == "starbucks-copy" })
  }

  @Test func mergeRemovesTheCopy() throws {
    let ledger = InMemoryLedger(state: Scenario.mayaCopy.state)
    #expect(try ledger.apply(.resolveCopy("starbucks-copy", merge: true))?.title == "Merged")
    #expect(ledger.state.txn("starbucks-copy") == nil)
    #expect(ledger.state.spent("dining", in: october) == MayaLedger.state.spent("dining", in: october))
    #expect(throws: ActionError.notFound) { try ledger.apply(.resolveCopy("starbucks", merge: true)) }
  }

  @Test func theSameInboxSaysSo() {
    var t = MayaLedger.state.txn("starbucks")!
    t.heldCopy = HeldCopy(of: "starbucks", fromOtherInbox: false)
    #expect(ReviewEngine.copyLine(t, MayaLedger.state) == "Looks like a copy of Starbucks DIFC AED 27.00 you already have")
  }
}
