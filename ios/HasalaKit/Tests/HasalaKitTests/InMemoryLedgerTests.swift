import HasalaMocks
import HasalaModels
import Testing

/// The Maya clock and calendar every engine reads (spec 04 §15.3). Frozen after Stage F.
@Suite("Maya ledger · clock")
struct MayaClockTests {
  let s = MayaLedger.state
  let now = MayaLedger.now

  @Test func theClockIsSaturdayTenOctober() {
    #expect(now.date.weekdayShort == "Sat")
    #expect(LocalDate(2026, 10, 14).short == "Wed 14 Oct")
    #expect(LocalDate(2026, 10, 9).short == "Fri 9 Oct")
    #expect(LocalDate(2026, 10, 28).short == "Wed 28 Oct")
    #expect(LocalDate(2026, 11, 1).short == "Sun 1 Nov")
    #expect(LocalDate(2026, 10, 10).adding(days: 65) == LocalDate(2026, 12, 14))
    #expect(YearMonth(2026, 10).days == 31)
    #expect(YearMonth(2028, 2).days == 29)
  }
}

@MainActor
@Suite("In-memory ledger edits")
struct InMemoryLedgerTests {
  @Test func sortingACardMovesItIntoThePlanAndUndoPutsItBack() throws {
    let ledger = InMemoryLedger()
    let token = try #require(try ledger.apply(.categorize("lulu", "groceries", learnRule: true, project: nil)))
    #expect(token.title == "Sorted into Groceries")
    #expect(ReviewEngine.queue(ledger.state).count == 5)
    #expect(ledger.state.spent("groceries", in: MayaLedger.october) == .aed(1_026_70))
    #expect(ledger.state.rules.contains { $0.patterns == ["lulu hypermarket dxb marina"] && $0.match == .exact && $0.learnedToday })
    ledger.undo(token)
    #expect(ReviewEngine.queue(ledger.state).count == 6)
    #expect(ledger.state.spent("groceries", in: MayaLedger.october) == .aed(812_40))
    #expect(!ledger.state.rules.contains { $0.learnedToday })
  }

  @Test func aSplitMustAddUp() throws {
    let ledger = InMemoryLedger()
    let bad = [SplitLine(id: 0, categoryID: "groceries", amount: .aed(300_00)),
               SplitLine(id: 1, categoryID: "shopping", amount: .aed(45_00))]
    #expect(throws: ActionError.splitDoesNotAddUp) { try ledger.apply(.split("carrefour", bad)) }
    let good = [SplitLine(id: 0, categoryID: "groceries", amount: .aed(297_00)),
                SplitLine(id: 1, categoryID: "shopping", amount: .aed(45_15), note: "Kitchen towels and batteries")]
    try ledger.apply(.split("carrefour", good))
    #expect(ledger.state.spent("shopping", in: MayaLedger.october) == .aed(476_95))
    #expect(ledger.state.spent("groceries", in: MayaLedger.october) == .aed(767_25))
  }

  @Test func movingMoneyFromReadyToAssign() throws {
    let ledger = InMemoryLedger()
    let token = try #require(try ledger.apply(.moveMoney(from: nil, to: "groceries", MayaLedger.october, .aed(318_00))))
    let plan = PlanEngine.snapshot(ledger.state, now: ledger.now)
    #expect(plan.readyToAssign == .aed(682_00))
    #expect(ledger.state.plan.budget("groceries", MayaLedger.october) == .aed(2_518_00))
    #expect(throws: ActionError.insufficientFunds) {
      try ledger.apply(.moveMoney(from: nil, to: "dining", MayaLedger.october, .aed(5_000_00)))
    }
    #expect(throws: ActionError.insufficientFunds) {
      try ledger.apply(.moveMoney(from: "entertainment", to: "dining", MayaLedger.october, .aed(506_00)))
    }
    ledger.undo(token)
    #expect(PlanEngine.snapshot(ledger.state, now: ledger.now).readyToAssign == .aed(1_000_00))
  }

  @Test func renamingRenamesEveryTransactionOfTheMerchant() throws {
    let ledger = InMemoryLedger()
    try ledger.apply(.renameMerchant("talabat", "Talabat Food"))
    #expect(ledger.state.txns.filter { $0.merchant == "Talabat Food" }.count == 2)
  }

  @Test func billsCanBeTrackedPaidAndDismissed() throws {
    let ledger = InMemoryLedger()
    try ledger.apply(.trackCandidate("apple-bill"))
    #expect(BillsEngine.snapshot(ledger.state, now: ledger.now).tracked == 10)
    #expect(ledger.state.billCandidates.isEmpty)
    try ledger.apply(.markBillPaid("axa"))
    #expect(ledger.state.bill("axa")?.nextDue == LocalDate(2026, 11, 7))
    #expect(BillsEngine.snapshot(ledger.state, now: ledger.now).needsALook.map(\.name) == ["du"])
    try ledger.apply(.acceptBillAmount("du"))
    #expect(BillsEngine.snapshot(ledger.state, now: ledger.now).needsALook.isEmpty)
  }

  @Test func undoKeepsALaterEditToAnotherField() throws {
    let ledger = InMemoryLedger()
    let sorted = try #require(try ledger.apply(.categorize("lulu", "groceries", learnRule: true, project: nil)))
    // A note shows no toast, so the categorise's Undo is still on screen.
    #expect(try ledger.apply(.setNote("lulu", "Weekly shop")) == nil)
    try ledger.apply(.setRuleEnabled("r-zuma", false))
    ledger.undo(sorted)
    let lulu = try #require(ledger.state.txn("lulu"))
    #expect(lulu.needsReview)
    #expect(lulu.note == "Weekly shop")
    #expect(!ledger.state.rules.contains { $0.learnedToday })
    #expect(ledger.state.rules.first { $0.id == "r-zuma" }?.enabled == false)
  }

  @Test func undoLeavesAFieldChangedAgainSince() throws {
    let ledger = InMemoryLedger()
    let first = try #require(try ledger.apply(.categorize("lulu", "groceries", learnRule: false, project: nil)))
    try ledger.apply(.categorize("lulu", "shopping", learnRule: false, project: nil))
    ledger.undo(first)
    #expect(ledger.state.txn("lulu")?.categoryID == "shopping")
  }

  @Test func undoingADismissPutsTheCandidateBackInPlace() throws {
    let ledger = InMemoryLedger()
    let before = ledger.state.billCandidates
    let token = try #require(try ledger.apply(.dismissCandidate("apple-bill")))
    #expect(ledger.state.billCandidates.isEmpty)
    ledger.undo(token)
    #expect(ledger.state.billCandidates == before)
    let tracked = try #require(try ledger.apply(.trackCandidate("apple-bill")))
    ledger.undo(tracked)
    #expect(ledger.state.billCandidates == before)
    #expect(BillsEngine.snapshot(ledger.state, now: ledger.now).tracked == 9)
  }

  @Test func everyChangeMovesTheRevision() throws {
    let ledger = InMemoryLedger()
    let r0 = ledger.revision
    let token = try #require(try ledger.apply(.archive("zuma", true)))
    #expect(ledger.revision > r0)
    let r1 = ledger.revision
    ledger.undo(token)
    #expect(ledger.revision > r1)
    let r2 = ledger.revision
    ledger.setNow(ledger.now)
    #expect(ledger.revision > r2)
  }

  @Test func archivingTakesATransactionOutOfThePlan() throws {
    let ledger = InMemoryLedger()
    try ledger.apply(.archive("zuma", true))
    #expect(ledger.state.spent("dining", in: MayaLedger.october) == .aed(230_75))
    let archived = ActivityEngine.snapshot(ledger.state, now: ledger.now, filter: TxnFilter(kind: .archived))
    #expect(archived.rowCount == 1)
  }
}
