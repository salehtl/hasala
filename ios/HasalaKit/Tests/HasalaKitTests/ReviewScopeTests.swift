import HasalaMocks
import HasalaModels
import Testing

@Suite("Review queue · uncategorized rows and the period")
struct ReviewScopeTests {
  let october = ReviewWindow.month(YearMonth(2026, 10))
  let september = ReviewWindow.month(YearMonth(2026, 9))

  func ledger(_ extra: [Txn]) -> LedgerState {
    var s = MayaLedger.state
    s.txns += extra
    return s
  }

  func unsorted(_ id: TxnID, _ at: LocalDateTime) -> Txn {
    Txn(id: id, merchant: "Corner Shop", amount: .aed(12_50), postedAt: at, accountID: "dib")
  }

  @Test func anOldUncategorizedRowIsInItsOwnMonth() {
    let s = ledger([unsorted("sep-shop", LocalDateTime(2026, 9, 30, 23, 50))])
    #expect(ReviewEngine.queue(s, in: september).map(\.id) == ["sep-shop"])
    #expect(!ReviewEngine.queue(s, in: october).map(\.id).contains("sep-shop"))
    #expect(ReviewEngine.queue(s, in: october).count == 6)
    #expect(ReviewEngine.queue(s).last?.id == "sep-shop")
    #expect(ReviewEngine.queue(s).count == 7)
  }

  @Test func aRangeTakesBothEnds() {
    let s = ledger([
      unsorted("aug-31", LocalDateTime(2026, 8, 31, 9, 0)),
      unsorted("sep-1", LocalDateTime(2026, 9, 1, 0, 0)),
      unsorted("oct-6", LocalDateTime(2026, 10, 6, 23, 59)),
    ])
    let range = ReviewWindow.range(LocalDate(2026, 10, 6), LocalDate(2026, 9, 1))
    let ids = ReviewEngine.queue(s, in: range).map(\.id)
    #expect(ids.last == "sep-1")
    #expect(ids.contains("oct-6") && ids.contains("atm"))
    #expect(!ids.contains("aug-31") && !ids.contains("transfer-in"))
  }

  @Test func aPeriodRunsFromItsFirstDayToItsLast() {
    let window = ReviewWindow(Period(YearMonth(2026, 10), YearMonth(2026, 8)))
    #expect(window == ReviewWindow(from: LocalDate(2026, 8, 1), to: LocalDate(2026, 10, 31)))
    #expect(ReviewWindow(.month(YearMonth(2026, 9))) == september)
    let s = ledger([
      unsorted("jul-31", LocalDateTime(2026, 7, 31, 23, 59)),
      unsorted("aug-1", LocalDateTime(2026, 8, 1, 0, 0)),
      unsorted("sep-30", LocalDateTime(2026, 9, 30, 23, 59)),
    ])
    let ids = ReviewEngine.queue(s, in: window).map(\.id)
    #expect(ids.suffix(2) == ["sep-30", "aug-1"])
    #expect(!ids.contains("jul-31") && ids.count == 8)
  }

  @MainActor @Test func sortingItTakesItOutOfTheQueue() throws {
    let store = InMemoryLedger(state: ledger([unsorted("sep-shop", LocalDateTime(2026, 9, 12, 10, 0))]))
    #expect(ReviewEngine.queue(store.state, in: september).count == 1)
    try store.apply(.categorize("sep-shop", "groceries", learnRule: false, project: nil))
    #expect(ReviewEngine.queue(store.state, in: september).isEmpty)
    #expect(ReviewEngine.queue(store.state).count == 6)
  }

  @Test func elsewhereCountsTheQueueOutsideThePeriod() {
    let s = ledger([
      unsorted("aug-shop", LocalDateTime(2026, 8, 20, 9, 0)),
      unsorted("sep-shop", LocalDateTime(2026, 9, 12, 10, 0)),
    ])
    let oct = YearMonth(2026, 10), sep = YearMonth(2026, 9), aug = YearMonth(2026, 8)
    let inOctober = ReviewEngine.elsewhere(s, in: .month(oct), today: oct)
    #expect(inOctober == ReviewElsewhere(count: 2, side: .earlier, widened: Period(aug, oct)))
    #expect(inOctober?.line == "2 more in earlier months")
    let inAugust = ReviewEngine.elsewhere(s, in: .month(aug), today: oct)
    #expect(inAugust == ReviewElsewhere(count: 7, side: .later, widened: Period(aug, oct)))
    let inSeptember = ReviewEngine.elsewhere(s, in: .month(sep), today: oct)
    #expect(inSeptember?.side == .other && inSeptember?.widened == Period(aug, oct))
    #expect(inSeptember?.line == "7 more in other months")
    #expect(ReviewEngine.elsewhere(s, in: Period(aug, oct), today: oct) == nil)
    #expect(ReviewEngine.queue(s, in: september).count + (inSeptember?.count ?? 0) == ReviewEngine.queue(s).count)
    #expect(ReviewEngine.elsewhere(s, in: .month(YearMonth(2026, 6)), today: oct)?.widened == Period(YearMonth(2026, 6), oct))
  }

  @Test func aRowFromAFutureMonthCountsInThisMonth() {
    let s = ledger([unsorted("nov-shop", LocalDateTime(2026, 11, 2, 9, 0))])
    let oct = YearMonth(2026, 10)
    #expect(ReviewEngine.elsewhere(s, in: .month(oct), today: oct) == nil)
    let window = ReviewEngine.window(.month(oct), today: oct)
    #expect(window.to == nil && ReviewEngine.queue(s, in: window).contains { $0.id == "nov-shop" })
    let inSeptember = ReviewEngine.elsewhere(s, in: .month(YearMonth(2026, 9)), today: oct)
    #expect(inSeptember?.widened == Period(YearMonth(2026, 9), oct) && inSeptember?.count == 7)
    #expect(ReviewEngine.window(.month(YearMonth(2026, 9)), today: oct) == september)
  }

  @Test func elsewhereSaysOneMonthForOne() {
    let p = Period.month(YearMonth(2026, 10))
    #expect(ReviewElsewhere(count: 1, side: .earlier, widened: p).line == "1 more in an earlier month")
    #expect(ReviewElsewhere(count: 1, side: .later, widened: p).line == "1 more in a later month")
    #expect(ReviewElsewhere(count: 1, side: .other, widened: p).line == "1 more in another month")
  }

  @Test func elsewhereLeavesOutTodaysSkips() {
    var s = ledger([unsorted("sep-shop", LocalDateTime(2026, 9, 12, 10, 0))])
    s.skippedReview = ["sep-shop"]
    let oct = YearMonth(2026, 10)
    #expect(ReviewEngine.elsewhere(s, in: .month(oct), today: oct) == nil)
  }

  @Test func transfersArchivedAndSplitRowsStayOut() {
    let at = LocalDateTime(2026, 9, 12, 10, 0)
    var paired = unsorted("paired", at)
    paired.isTransfer = true
    var flaggedTransfer = unsorted("flagged-transfer", at)
    flaggedTransfer.isTransfer = true
    flaggedTransfer.needsReview = true
    var archived = unsorted("archived", at)
    archived.archived = true
    var split = unsorted("split", at)
    split.splits = [
      SplitLine(id: 0, categoryID: "groceries", amount: .aed(10_00)),
      SplitLine(id: 1, categoryID: "dining", amount: .aed(2_50)),
    ]
    var excluded = unsorted("cash", at)
    excluded.categoryID = "transfer"
    excluded.categorySource = .user
    let s = ledger([paired, flaggedTransfer, archived, split, excluded])
    #expect(ReviewEngine.queue(s, in: september).isEmpty)
  }

  @Test func aModelPickStandsUnlessItWasFlagged() {
    var picked = unsorted("picked", LocalDateTime(2026, 9, 12, 10, 0))
    picked.categoryID = "groceries"
    picked.categorySource = .model(tag: "apple-fm/1")
    var flagged = unsorted("flagged", LocalDateTime(2026, 9, 13, 10, 0))
    flagged.categoryID = "groceries"
    flagged.categorySource = .model(tag: "cf-clef/1")
    flagged.needsReview = true
    let s = ledger([picked, flagged])
    #expect(!picked.inReview && flagged.inReview)
    #expect(ReviewEngine.queue(s, in: september).map(\.id) == ["flagged"])
    #expect(ReviewEngine.cards(s, in: september).first?.suggestion?.name == "Groceries")
  }

  @Test func uncategorizedIncomeStaysInReview() {
    var salary = unsorted("salary-in", LocalDateTime(2026, 9, 28, 9, 0))
    salary.direction = .in
    let s = ledger([salary])
    #expect(salary.inReview)
    #expect(ReviewEngine.queue(s, in: september).map(\.id) == ["salary-in"])
  }

  @Test func activityCountsTheSameRows() {
    let s = ledger([unsorted("oct-shop", LocalDateTime(2026, 10, 9, 12, 0))])
    let snap = ActivityEngine.snapshot(s, now: MayaLedger.now, filter: TxnFilter(kind: .toReview))
    #expect(snap.chips.first { $0.kind == .toReview }?.count == 7)
    #expect(snap.days.flatMap(\.rows).contains { $0.id == "oct-shop" && $0.toReview })
    #expect(ActivityEngine.reviewSummary(s, now: MayaLedger.now).count == 7)
  }

  @Test func theQueueRunsNewestMonthFirstAndOldestFirstInAMonth() {
    let s = ledger([
      unsorted("dec-shop", LocalDateTime(2025, 12, 20, 9, 0)),
      unsorted("sep-late", LocalDateTime(2026, 9, 28, 9, 0)),
      unsorted("sep-early", LocalDateTime(2026, 9, 2, 9, 0)),
    ])
    let ids = ReviewEngine.queue(s).map(\.id)
    #expect(ids.count == 9)
    #expect(ids.prefix(6).allSatisfy { s.txn($0)?.postedAt.date.yearMonth == MayaLedger.october })
    #expect(ids.suffix(3) == ["sep-early", "sep-late", "dec-shop"])
    let months = ReviewEngine.months(ReviewEngine.cards(s), now: MayaLedger.now)
    #expect(months.map(\.title) == ["This month", "September", "December 2025"])
    #expect(months.map(\.cards.count) == [6, 2, 1])
    #expect(months.flatMap(\.cards).map(\.id) == ids)
  }

  @Test func everyCountOfWhatIsLeftToSortIsTheWholeQueueInAnyPeriod() {
    var s = ledger([
      unsorted("aug-shop", LocalDateTime(2026, 8, 12, 9, 0)),
      unsorted("sep-shop", LocalDateTime(2026, 9, 12, 9, 0)),
    ])
    s.skippedReview = ["atm"]
    let now = MayaLedger.now
    let queue = ReviewEngine.queue(s)
    #expect(queue.count == 7 && !queue.contains { $0.id == "atm" })
    let bell = NotificationsEngine.snapshot(s, now: now).needsALook.first { $0.id == "review" }
    #expect(bell?.title == "7 transactions to sort")
    #expect(bell?.when == "Today")
    #expect(GlanceEngine.snapshot(s, now: now, home: HomeEngine.snapshot(s, now: now), amountsHidden: false).toReview?.count == 7)
    #expect(ActivityEngine.reviewSummary(s, now: now).count == 7)
    for period in [Period.month(YearMonth(2026, 9)), .month(YearMonth(2026, 7)), Period(YearMonth(2026, 8), YearMonth(2026, 10))] {
      let home = HomeEngine.snapshot(s, now: now, period: period)
      #expect(home.aboutNow.first { $0.id == "review" }?.detail.rendered(hidden: false) == "7 waiting")
      #expect(home.notifications.needsALook.first { $0.id == "review" }?.title == "7 transactions to sort")
      #expect(ActivityEngine.snapshot(s, now: now, filter: .all, period: period).review?.count == 7)
    }
    s.skippedReview = Set(queue.map(\.id) + ["atm"])
    #expect(NotificationsEngine.snapshot(s, now: now).needsALook.first { $0.id == "review" } == nil)
    #expect(GlanceEngine.snapshot(s, now: now, home: HomeEngine.snapshot(s, now: now), amountsHidden: false).toReview?.count == 0)
    #expect(ActivityEngine.snapshot(s, now: now, filter: .all).review == nil)
  }

  @Test func windowsNameThemselves() {
    #expect(october.label == "October 2026")
    #expect(ReviewWindow.range(LocalDate(2026, 9, 1), LocalDate(2026, 10, 10)).label == "1 Sep – 10 Oct 2026")
    #expect(ReviewWindow.range(LocalDate(2025, 12, 20), LocalDate(2026, 1, 5)).label == "20 Dec 2025 – 5 Jan 2026")
    #expect(ReviewWindow.all.label == "All time")
    #expect(october.contains(LocalDate(2026, 10, 31)) && !october.contains(LocalDate(2026, 11, 1)))
  }
}

@MainActor
@Suite("Review queue · the copy lane and the sender reason in a period")
struct ReviewScopeReasonTests {
  let october = ReviewWindow.month(YearMonth(2026, 10))
  let september = ReviewWindow.month(YearMonth(2026, 9))
  let now = MayaLedger.now

  @Test func aHeldCopyIsInItsOwnPeriodAsACopyUntilKept() throws {
    let ledger = InMemoryLedger(state: Scenario.mayaCopy.state)
    let s = ledger.state
    #expect(ReviewEngine.queue(s, in: october).filter { $0.id == "starbucks-copy" }.count == 1)
    #expect(!ReviewEngine.queue(s, in: september).contains { $0.id == "starbucks-copy" })
    let card = try #require(ReviewEngine.cards(s, in: october).first { $0.id == "starbucks-copy" })
    #expect(card.reviewReason == .probableCopy && !card.senderUnverified)
    let row = ActivityEngine.row(try #require(s.txn("starbucks-copy")), s)
    #expect(row.toReview && row.reviewReason == .probableCopy)
    #expect(row.detail == "Looks like a copy · 09:09")
    let toReview = ActivityEngine.snapshot(s, now: now, filter: TxnFilter(kind: .toReview))
    #expect(toReview.days.flatMap(\.rows).contains { $0.id == "starbucks-copy" })
    let all = ActivityEngine.snapshot(s, now: now, filter: TxnFilter(kind: .all))
    #expect(all.days.flatMap(\.rows).contains { $0.id == "starbucks-copy" })
    let maya = ActivityEngine.snapshot(MayaLedger.state, now: now, filter: .all)
    #expect(all.days.map(\.total.minor) == maya.days.map(\.total.minor))

    _ = try ledger.apply(.resolveCopy("starbucks-copy", merge: false))
    #expect(!ReviewEngine.queue(ledger.state, in: october).contains { $0.id == "starbucks-copy" })
    #expect(ReviewEngine.queue(ledger.state, in: october).count == ReviewEngine.queue(s, in: october).count - 1)
  }

  @Test func theSenderReasonFollowsItsRowIntoThePeriod() throws {
    var s = MayaLedger.state
    var old = try #require(s.txn("steam"))
    old.id = "steam-sep"
    old.postedAt = LocalDateTime(2026, 9, 20, 11, 2)
    s.txns.append(old)
    let ledger = InMemoryLedger(state: s)
    #expect(ReviewEngine.cards(s, in: september).filter(\.senderUnverified).map(\.id) == ["steam-sep"])
    #expect(ReviewEngine.cards(s, in: october).filter(\.senderUnverified).map(\.id) == ["steam"])
    try ledger.apply(.categorize("steam-sep", "entertainment", learnRule: false, project: nil))
    #expect(ReviewEngine.cards(ledger.state, in: september).isEmpty)
    #expect(ledger.state.txn("steam-sep")?.activeReviewReason == nil)
    #expect(ReviewEngine.cards(ledger.state, in: october).filter(\.senderUnverified).map(\.id) == ["steam"])
  }

  @Test func aHeldCopyThatAlsoFailedTheSenderCheckShowsOnceAsACopy() throws {
    var s = Scenario.mayaCopy.state
    let i = try #require(s.txns.firstIndex { $0.id == "starbucks-copy" })
    s.txns[i].needsReview = true
    s.txns[i].reviewReason = .senderUnverified
    let ids = ReviewEngine.queue(s, in: october).map(\.id)
    #expect(ids.filter { $0 == "starbucks-copy" }.count == 1)
    let card = try #require(ReviewEngine.cards(s, in: october).first { $0.id == "starbucks-copy" })
    #expect(card.reviewReason == .probableCopy)
  }
}
