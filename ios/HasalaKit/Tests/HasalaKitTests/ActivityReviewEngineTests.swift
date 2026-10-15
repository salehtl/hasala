import HasalaMocks
import HasalaModels
import Testing

/// Activity, the transaction sheet and the review deck over MayaLedger reproduce their boards.
/// Owned by P6 from Stage P, with the swipe physics and split draft rules below.
@Suite("Maya ledger · Activity, transaction and review parity")
struct ActivityReviewEngineParityTests {
  let s = MayaLedger.state
  let now = MayaLedger.now

  @Test func activityMatchesTheOverview() {
    let a = ActivityEngine.snapshot(s, now: now, filter: .all)
    #expect(a.countLine == "26 transactions this month")
    #expect(a.review?.count == 6)
    #expect(a.review?.unplanned == .aed(827_28))
    #expect(a.chips.first { $0.kind == .toReview }?.count == 6)
    #expect(a.comingUp.map(\.name) == ["DEWA", "AXA Insurance"])
    let days = a.days.prefix(4)
    #expect(days.map(\.title) == ["Today", "Yesterday, Fri 9 Oct", "Thu 8 Oct", "Wed 7 Oct"])
    #expect(days.map { MoneyFormat.string($0.total.minor) } == ["91.50", "388.15", "116.99", "601.00"])
    #expect(a.days[0].rows.map(\.merchant) == ["Talabat", "Starbucks DIFC"])
    #expect(a.days[0].rows.map(\.detail) == ["Dining · 13:20", "Dining · 09:05"])
    #expect(a.days[2].rows[1].detail == "Subscriptions · monthly bill")
  }

  /// Paper's Activity board draws "Bills 8", but its own data has six October payments
  /// linked to a bill (rent, the standing order, Sarwa, du, Netflix, Spotify); 03b §12 #1
  /// leaves that open and its §7 read counts linked payments, so the chip follows the
  /// data until the board or the definition changes.
  @Test func theBillsChipCountsPaymentsLinkedToABill() {
    let a = ActivityEngine.snapshot(s, now: now, filter: .all)
    #expect(a.chips.first { $0.kind == .bills }?.count == 6)
    let bills = ActivityEngine.snapshot(s, now: now, filter: TxnFilter(kind: .bills))
    #expect(bills.rowCount == 6)
    #expect(Set(bills.days.flatMap(\.rows).map(\.merchant)) == ["Al Habtoor", "Standing order", "Sarwa", "du", "Netflix", "Spotify"])
  }

  @Test func filteringByDiningMatchesTheFilteredBoard() {
    let a = ActivityEngine.snapshot(s, now: now, filter: TxnFilter(category: "dining"))
    #expect(a.rowCount == 5)
    #expect(a.summary?.total == .aed(642_75))
    #expect(a.summary?.caption.rendered(hidden: false) == "40% of Dining's 1,600")
    #expect(a.summary?.verdict == .overPace)
    #expect(a.review == nil)
    let groceries = ActivityEngine.snapshot(s, now: now, filter: TxnFilter(category: "groceries"))
    #expect(groceries.summary?.caption.rendered(hidden: false) == "36% of Groceries' 2,200")
  }

  @Test func searchingFindsAcrossMonthsAndRawMerchants() {
    let a = ActivityEngine.snapshot(s, now: now, filter: TxnFilter(text: "carre"))
    #expect(a.rowCount == 3)
    let raw = ActivityEngine.snapshot(s, now: now, filter: TxnFilter(text: "marina"))
    #expect(raw.days.flatMap(\.rows).map(\.merchant).contains("Lulu Hypermarket"))
  }

  @Test func transactionSheetMatchesCarrefour() throws {
    let d = try #require(TransactionEngine.detail("carrefour", s, now: now))
    #expect(d.meta == "Fri 9 Oct, 19:12 · Emirates NBD ···4412")
    #expect(d.pace?.left == .aed(1_387_60))
    #expect(d.pace?.verdict == .overPace)
    #expect(d.pace?.projection?.rendered(hidden: false) == "on course for 2,518")
    #expect(d.sortedBy == SortedBy(title: "Sorted by your rule", detail: "carrefour → Groceries"))
    #expect(d.provenance?.rawMerchant == "CARREFOUR MALL OF EMIRATES")
  }

  @Test func reviewDeckHasSixCards() {
    let cards = ReviewEngine.cards(s)
    #expect(cards.count == 6)
    let lulu = cards.first { $0.id == "lulu" }
    #expect(lulu?.meta == "Spent · Fri 9 Oct, 18:42 · DIB card ···8891")
    #expect(lulu?.suggestion?.name == "Groceries")
    #expect(lulu?.isNewMerchant == true)
    #expect(ReviewEngine.options(for: .need, s).map(\.name).prefix(3) == ["Rent", "Utilities", "Groceries"])
    let incoming = s.txn("transfer-in")
    #expect(ReviewEngine.options(for: .transfer, s, txn: incoming).map(\.name) ==
      ["Salary", "Freelance", "Transfer", "Refunds"])
  }
}

@Suite("Swipe physics")
struct SwipePhysicsTests {
  @Test func shortDragsDoNotCommit() {
    #expect(SwipePhysics.commit(dx: 60, dy: 10, vx: 100, vy: 0) == nil)
    #expect(SwipePhysics.detect(dx: 70, dy: 10) == nil)
  }

  @Test func farDragsCommitOnTheStrongerAxis() {
    #expect(SwipePhysics.commit(dx: 120, dy: 30, vx: 0, vy: 0) == .right)
    #expect(SwipePhysics.commit(dx: -101, dy: 0, vx: 0, vy: 0) == .left)
    #expect(SwipePhysics.commit(dx: 110, dy: 140, vx: 0, vy: 0) == .down)
    #expect(SwipePhysics.commit(dx: 0, dy: -100, vx: 0, vy: 0) == .up)
  }

  @Test func flicksCommitWithLittleTravel() {
    #expect(SwipePhysics.commit(dx: 30, dy: 0, vx: 600, vy: 0) == .right)
    // Too short to be intentional, or flung back against the drag.
    #expect(SwipePhysics.commit(dx: 20, dy: 0, vx: 900, vy: 0) == nil)
    #expect(SwipePhysics.commit(dx: 40, dy: 0, vx: -900, vy: 0) == nil)
  }

  @Test func previewIsQuantised() {
    #expect(SwipePhysics.progress(dx: 47, dy: 0) == 0.5)
    #expect(SwipePhysics.progress(dx: 250, dy: 0) == 1)
    #expect(SwipePhysics.preview(dx: 25, dy: 5) == .right)
  }

  @Test func directionsFollowThePreference() {
    #expect(SwipePhysics.choice(for: .right) == .need)
    #expect(SwipePhysics.choice(for: .left) == .want)
    #expect(SwipePhysics.choice(for: .right, needOnRight: false) == .want)
    #expect(SwipePhysics.choice(for: .down) == .save)
    #expect(SwipePhysics.choice(for: .up) == .transfer)
    #expect(SwipePhysics.edge(for: .need, needOnRight: false) == .left)
  }
}

@Suite("Split draft")
struct SplitDraftTests {
  let total = Money.aed(342_15)

  @Test func anEmptyLineNeverAddsUp() {
    // The editor's seed: the whole amount on line 1, line 2 not filled in yet.
    #expect(TransactionEngine.splitDraftVerdict([342_15, nil], total: total) == .emptyLine)
    #expect(TransactionEngine.splitDraftVerdict([342_15, 0], total: total) == .emptyLine)
    #expect(TransactionEngine.splitDraftVerdict([342_15], total: total) == .emptyLine)
  }

  @Test func leftAndOver() {
    #expect(TransactionEngine.splitDraftVerdict([300_00, nil], total: total) == .leftToPlace(.aed(42_15)))
    #expect(TransactionEngine.splitDraftVerdict([300_00, 45_00], total: total) == .over(.aed(2_85)))
  }

  @Test func addsUpMeansItCanBeSaved() {
    #expect(TransactionEngine.splitDraftVerdict([297_00, 45_15], total: total) == .addsUp)
    let lines = [SplitLine(id: 1, categoryID: "groceries", amount: .aed(297_00)),
                 SplitLine(id: 2, categoryID: "shopping", amount: .aed(45_15))]
    #expect(TransactionEngine.splitAddsUp(lines, total: total))
  }
}
