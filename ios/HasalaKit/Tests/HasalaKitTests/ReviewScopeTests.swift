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
    #expect(ReviewEngine.queue(s).first?.id == "sep-shop")
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
    #expect(ids.first == "sep-1")
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
    #expect(ids.prefix(2) == ["aug-1", "sep-30"])
    #expect(!ids.contains("jul-31") && ids.count == 8)
  }

  @MainActor @Test func sortingItTakesItOutOfTheQueue() throws {
    let store = InMemoryLedger(state: ledger([unsorted("sep-shop", LocalDateTime(2026, 9, 12, 10, 0))]))
    #expect(ReviewEngine.queue(store.state, in: september).count == 1)
    try store.apply(.categorize("sep-shop", "groceries", learnRule: false, project: nil))
    #expect(ReviewEngine.queue(store.state, in: september).isEmpty)
    #expect(ReviewEngine.queue(store.state).count == 6)
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

  @Test func aModelGuessWaitsForAPerson() {
    var guessed = unsorted("guessed", LocalDateTime(2026, 9, 12, 10, 0))
    guessed.categoryID = "groceries"
    guessed.categorySource = .model
    let s = ledger([guessed])
    #expect(ReviewEngine.queue(s, in: september).map(\.id) == ["guessed"])
    #expect(ReviewEngine.cards(s, in: september).first?.suggestion?.name == "Groceries")
  }

  @Test func activityCountsTheSameRows() {
    let s = ledger([unsorted("oct-shop", LocalDateTime(2026, 10, 9, 12, 0))])
    let snap = ActivityEngine.snapshot(s, now: MayaLedger.now, filter: TxnFilter(kind: .toReview))
    #expect(snap.chips.first { $0.kind == .toReview }?.count == 7)
    #expect(snap.days.flatMap(\.rows).contains { $0.id == "oct-shop" && $0.toReview })
    #expect(ActivityEngine.reviewSummary(s, now: MayaLedger.now).count == 7)
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
    #expect(!all.days.flatMap(\.rows).contains { $0.id == "starbucks-copy" })

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
