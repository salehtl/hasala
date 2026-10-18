import HasalaMocks
import HasalaModels
import HasalaWidgetData
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

@MainActor
@Suite("A held copy in Spent")
struct HeldCopySpentTests {
  let now = MayaLedger.now
  let october = MayaLedger.october

  func figures(_ s: LedgerState) -> (home: Money, insights: Money, widget: Money?) {
    let home = HomeEngine.snapshot(s, now: now)
    let insights = InsightsEngine.snapshot(s, months: october...october, now: now)
    let widget = GlanceEngine.snapshot(s, now: now, home: home, amountsHidden: false).spentSoFar
    return (home.hero.spent, insights.summary.spent, widget?.spent)
  }

  func pace(_ s: LedgerState) -> BudgetPaceWidget? {
    GlanceEngine.snapshot(s, now: now, home: HomeEngine.snapshot(s, now: now), amountsHidden: false).budgetPace
  }

  @Test func heldCopyIsLeftOutOfHomeInsightsAndTheWidget() throws {
    let base = figures(MayaLedger.state)
    let held = figures(Scenario.mayaCopy.state)
    #expect(held.home == base.home)
    #expect(held.insights == base.insights)
    #expect(held.widget == base.widget)
    #expect(held.widget == held.home)
    #expect(Spending.total(Scenario.mayaCopy.state, in: october) == Spending.total(MayaLedger.state, in: october))
    #expect(pace(Scenario.mayaCopy.state) == pace(MayaLedger.state))
  }

  @Test func keepBothCountsItInAllThree() throws {
    let base = figures(MayaLedger.state)
    let ledger = InMemoryLedger(state: Scenario.mayaCopy.state)
    _ = try ledger.apply(.resolveCopy("starbucks-copy", merge: false))
    let kept = figures(ledger.state)
    #expect(kept.home.minor == base.home.minor + 27_00)
    #expect(kept.insights.minor == base.insights.minor + 27_00)
    #expect(kept.widget?.minor == (base.widget?.minor).map { $0 + 27_00 })
    #expect(pace(ledger.state) != pace(MayaLedger.state))
  }
}
