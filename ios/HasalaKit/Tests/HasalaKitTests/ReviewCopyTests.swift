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

  @Test func anEmptyMerchantWithAPlaceReadsUnknown() throws {
    let s = Scenario.maya.state
    var t = try #require(s.txns.first { $0.needsReview })
    t.merchant = " "
    t.place = "Dubai"
    let card = ReviewEngine.card(t, s)
    #expect(card.merchant == "Unknown merchant")
    #expect(card.monogram == "")
  }

  @Test func aSamePurchaseFromAnotherYearCarriesTheYear() throws {
    var s = Scenario.mayaSamePurchase.state
    let aed = try #require(s.txn("amazon-aed"))
    let i = try #require(s.txns.firstIndex { $0.id == aed.samePurchase?.of })
    s.txns[i].postedAt = LocalDateTime(2025, 12, 14, 10, 0)
    let old = try #require(ReviewEngine.samePurchaseLine(aed, s, today: LocalDate(2026, 10, 10)))
    #expect(old.hasSuffix("on Sun 14 Dec 2025?"))
    let card = ReviewEngine.card(aed, s, today: LocalDate(2026, 10, 10))
    #expect(card.copyLine == old)
    let same = try #require(ReviewEngine.samePurchaseLine(aed, s, today: LocalDate(2025, 12, 20)))
    #expect(same.hasSuffix("on Sun 14 Dec?"))
  }

  @Test func copyLinesShortenALongMerchant() throws {
    var s = Scenario.mayaSamePurchase.state
    let aed = try #require(s.txn("amazon-aed"))
    let i = try #require(s.txns.firstIndex { $0.id == aed.samePurchase?.of })
    s.txns[i].merchant = "International Duty Free Shopping Centre Terminal 3"
    s.txns[i].place = "Dubai"
    let line = try #require(ReviewEngine.samePurchaseLine(aed, s))
    #expect(line.contains(" at International Duty Free… on "))
    #expect(ReviewEngine.copyName(s.txns[i]).count == ReviewEngine.copyNameLimit)
    var copy = aed
    copy.heldCopy = HeldCopy(of: s.txns[i].id, fromOtherInbox: false)
    #expect(ReviewEngine.copyLine(copy, s)?.hasPrefix("Looks like a copy of International Duty Free… ") == true)
  }

  @Test func theCardCarriesItsPostedDay() throws {
    let s = Scenario.maya.state
    let t = try #require(s.txns.first { $0.needsReview })
    let card = ReviewEngine.card(t, s)
    #expect(card.posted == t.postedAt.date)
    #expect(ReviewEngine.tabRow(card, s).detail == t.postedAt.date.short)
  }
}
