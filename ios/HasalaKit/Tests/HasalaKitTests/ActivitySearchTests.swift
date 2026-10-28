import HasalaMocks
import HasalaModels
import Testing

@Suite("Activity and search · matching, counts and edges")
struct ActivitySearchTests {
  let month = InsightsFixture.june
  let now = LocalDateTime(2026, 6, 20, 12, 0)

  @Test func searchFoldsAccentsWidthAndAlefForms() {
    #expect(SearchText.contains("Café Bateel", "cafe"))
    #expect(SearchText.contains("Cafe Bateel", "Café"))
    #expect(SearchText.contains("\u{0623}\u{062D}\u{0645}\u{062F} \u{0628}\u{0646} \u{0633}\u{0639}\u{064A}\u{062F}", "\u{0627}\u{062D}\u{0645}\u{062F}"))
    #expect(SearchText.contains("\u{0625}\u{0645}\u{0627}\u{0631}\u{0627}\u{062A}", "\u{0627}\u{0645}\u{0627}\u{0631}\u{0627}\u{062A}"))
    #expect(SearchText.contains("\u{0622}\u{0645}\u{0646}", "\u{0627}\u{0645}\u{0646}"))
    #expect(SearchText.contains("ＣＡＲＲＥＦＯＵＲ", "carrefour"))
    #expect(!SearchText.contains("Carrefour", "lulu"))
  }

  @Test func activityAndAskFindArabicAndAccentedMerchants() {
    let arabic = InsightsFixture.txn("2", 50_00, month, day: 12, merchant: "\u{0623}\u{062D}\u{0645}\u{062F} \u{0628}\u{0646} \u{0633}\u{0639}\u{064A}\u{062F} \u{0644}\u{0644}\u{062A}\u{062C}\u{0627}\u{0631}\u{0629}")
    let accented = InsightsFixture.txn("2", 30_00, month, day: 13, merchant: "Café Bateel")
    let s = InsightsFixture.ledger([arabic, accented])
    let q = "\u{0627}\u{062D}\u{0645}\u{062F}"
    #expect(ActivityEngine.snapshot(s, now: now, filter: TxnFilter(text: q)).days.flatMap(\.rows).map(\.id) == [arabic.id])
    #expect(ActivityEngine.snapshot(s, now: now, filter: TxnFilter(text: "cafe")).days.flatMap(\.rows).map(\.id) == [accented.id])
    #expect(AskEngine.answer(s, filter: AskFilter(merchants: [q])).rows.map(\.id) == [arabic.id])
    #expect(AskEngine.answer(s, filter: AskFilter(merchants: ["cafe"])).rows.map(\.id) == [accented.id])
  }

  @Test func monogramsUseTheFirstLetterOrFallBackToTheGlyph() {
    #expect(MerchantName.monogram("7-Eleven") == "E")
    #expect(MerchantName.monogram("(Rakuten) Viki") == "R")
    #expect(MerchantName.monogram("*Talabat") == "T")
    #expect(MerchantName.monogram("") == nil)
    #expect(MerchantName.monogram("123 *") == nil)
    #expect(MerchantName.display("  ") == "Unknown merchant")
    #expect(MerchantName.display("Zuma") == "Zuma")

    let s = InsightsFixture.ledger([
      InsightsFixture.txn(nil, 10_00, month, day: 12, merchant: "7-Eleven", needsReview: true),
      InsightsFixture.txn(nil, 10_00, month, day: 11, merchant: "", needsReview: true),
    ])
    let rows = ActivityEngine.snapshot(s, now: now, filter: .all).days.flatMap(\.rows)
    #expect(rows.map(\.monogram) == ["E", nil])
    #expect(rows.map(\.merchant) == ["7-Eleven", "Unknown merchant"])
  }

  @Test func theToReviewCardCountsThePeriodLikeItsChip() {
    let s = InsightsFixture.ledger([
      InsightsFixture.txn(nil, 10_00, month, day: 12, needsReview: true),
      InsightsFixture.txn(nil, 10_00, YearMonth(2026, 5), day: 12, needsReview: true),
      InsightsFixture.txn(nil, 10_00, YearMonth(2026, 4), day: 12, needsReview: true),
    ])
    let a = ActivityEngine.snapshot(s, now: now, filter: .all)
    #expect(a.chips.first { $0.kind == .toReview }?.count == 1)
    #expect(a.review?.count == 1)
  }

  @Test func countsAreGrouped() {
    let txns = (0..<1_284).map { i in InsightsFixture.txn("2", 1_00, month, day: 1 + i % 20) }
    let s = InsightsFixture.ledger(txns)
    #expect(ActivityEngine.snapshot(s, now: now, filter: .all).countLine == "1,284 transactions this month")
    #expect(AskEngine.answer(s, filter: AskFilter(category: "2")).countLine == "1,284 transactions")
  }

  @Test func aCategoryWithNoBudgetSaysSo() throws {
    let s = InsightsFixture.ledger([InsightsFixture.txn("2", 40_00, month, day: 12)])
    let summary = try #require(ActivityEngine.snapshot(s, now: now, filter: TxnFilter(category: "2")).summary)
    #expect(!summary.budgeted)
    #expect(summary.caption.rendered(hidden: false) == "No budget set")
    #expect(summary.total == .aed(40_00))
  }

  @Test func comingUpDropsBillsMoreThanAMonthLate() {
    var s = MayaLedger.state
    let now = MayaLedger.now
    let late = try! #require(s.bills.firstIndex { $0.state == .tracked && !$0.isIncome })
    s.bills[late].nextDue = now.date.adding(days: -31)
    #expect(ActivityEngine.comingUp(s, today: now.date, within: 7).contains { $0.id == s.bills[late].id })
    s.bills[late].nextDue = now.date.adding(days: -32)
    #expect(!ActivityEngine.comingUp(s, today: now.date, within: 7).contains { $0.id == s.bills[late].id })
  }

  @Test func datesFromAnotherYearSayTheYear() throws {
    let old = InsightsFixture.txn("2", 10_00, YearMonth(2025, 10), day: 8)
    let s = InsightsFixture.ledger([old])
    let d = try #require(TransactionEngine.detail(old.id, s, now: now))
    #expect(d.meta.hasPrefix("Wed 8 Oct 2025"))
    let a = AskEngine.answer(s, filter: AskFilter(category: "2"), today: now.date)
    #expect(a.rows.first?.detail == "Dining · Wed 8 Oct 2025")
  }
}
