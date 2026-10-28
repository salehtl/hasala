import HasalaMocks
import HasalaModels
import Testing

@Suite("Review · copy at the edges")
struct ReviewCopyTests {
  @Test func countsAreGrouped() {
    #expect(ReviewEngine.unreadLine(1_284) == "1,284 bank emails we couldn't read")
    #expect(ReviewEngine.notDownloadedLine(12_840) == "12,840 more emails couldn't be downloaded.")
    #expect(ReviewEngine.unreadTextLine(1_284) == "1,284 bank texts we couldn't read")
    #expect(ReviewElsewhere(count: 1_243, side: .earlier, widened: .month(YearMonth(2026, 10))).line == "1,243 more in earlier months")
    #expect(ReviewElsewhere(count: 1, side: .later, widened: .month(YearMonth(2026, 10))).line == "1 more in a later month")
  }

  @Test func datesFromAnotherYearCarryTheYear() {
    let today = LocalDate(2026, 10, 10)
    let old = UnreadMail(id: "a", provider: .gmail, receivedOn: LocalDate(2025, 12, 14))
    #expect(ReviewEngine.unreadDetail(old, today: today) == "Received Sun 14 Dec 2025 · in Gmail")
    let thisYear = UnreadMail(id: "b", provider: nil, receivedOn: LocalDate(2026, 10, 8))
    #expect(ReviewEngine.unreadDetail(thisYear, today: today) == "Received Thu 8 Oct")
  }

  @Test func monogramsUseTheFirstLetter() {
    #expect(ReviewEngine.monogram("7-Eleven") == "E")
    #expect(ReviewEngine.monogram("(Rakuten) Viki") == "R")
    #expect(ReviewEngine.monogram("*Talabat") == "T")
    #expect(ReviewEngine.monogram("carrefour") == "C")
    #expect(ReviewEngine.monogram("كارفور") == "ك")
    #expect(ReviewEngine.monogram("") == "")
    #expect(ReviewEngine.monogram("1001") == "")
  }

  @Test func anEmptyMerchantReadsUnknown() throws {
    let s = Scenario.maya.state
    var t = try #require(s.txns.first { $0.needsReview })
    t.merchant = ""
    t.place = nil
    let card = ReviewEngine.card(t, s)
    #expect(card.merchant == "Unknown merchant")
    #expect(card.monogram == "")
    #expect(ReviewEngine.tabRow(card, s).title == "Unknown merchant")
  }

  @Test func theCardCarriesItsPostedDay() throws {
    let s = Scenario.maya.state
    let t = try #require(s.txns.first { $0.needsReview })
    let card = ReviewEngine.card(t, s)
    #expect(card.posted == t.postedAt.date)
    #expect(ReviewEngine.tabRow(card, s).detail == t.postedAt.date.short)
  }
}
