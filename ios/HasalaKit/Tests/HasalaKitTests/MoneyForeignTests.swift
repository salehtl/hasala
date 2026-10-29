import HasalaMocks
import HasalaModels
import Testing

@Suite("Money · foreign amounts")
struct MoneyForeignTests {
  @Test func everyCurrencyIsShownInHundredths() {
    #expect(MoneyFormat.string(Money(minor: 150_000, currency: "JPY")) == "1,500.00")
    #expect(MoneyFormat.string(Money(minor: 750, currency: "KWD")) == "7.50")
    #expect(MoneyFormat.string(Money(minor: 4_599, currency: "USD")) == "45.99")
    #expect(MoneyFormat.string(Money(minor: 32_000, currency: "BHD"), style: .compact) == "320")
    #expect(MoneyFormat.string(Money(minor: 4_750, currency: "OMR"), style: .rounded) == "48")
    #expect(MoneyFormat.string(.aed(7_417_55)) == MoneyFormat.string(7_417_55))
  }

  @Test func phrasesShowForeignAmountsInHundredths() {
    let line = MoneyPhrase([.text("JPY "), .amount(Money(minor: 150_000, currency: "JPY")), .text(" and KWD "),
                            .signedMoney(Money(minor: -1_234, currency: "KWD"), style: .exact, hiddenGlyphs: 4)])
    #expect(line.rendered(hidden: false) == "JPY 1,500.00 and KWD \u{2212}12.34")
    #expect(line.rendered(hidden: true) == "JPY •••• and KWD ••••")
  }

  @Test func convertMatchesTheFoldForEveryCurrency() {
    #expect(ExchangeRates.convert(150_000, 24_500) == 36_75)
    #expect(ExchangeRates.convert(1_234, 11_942_000) == 147_36)
    #expect(ExchangeRates.convert(4_599, 3_672_500) == 168_90)
  }

  @Test func settingAJPYRateBackfillsInHundredths() {
    var s = Scenario.maya.state
    let id = s.txns[0].id
    s.txns[0].amount = Money(minor: 150_000, currency: "JPY")
    s.txns[0].homeMinor = nil
    s.txns[0].splits = []
    s.setRate("JPY", micro: 24_500)
    #expect(s.txn(id)?.homeMinor == 36_75)
  }

  @Test func csvWritesForeignAmountsInHundredths() {
    #expect(CSVExport.decimal(Money(minor: -150_000, currency: "JPY")) == "-1500.00")
    #expect(CSVExport.decimal(Money(minor: 1_234_567, currency: "KWD")) == "12345.67")
    #expect(CSVExport.decimal(Money(minor: -1_234_567, currency: "AED")) == "-12345.67")
  }

  @Test func reviewRowsNameAForeignCurrency() throws {
    let s = Scenario.maya.state
    var t = try #require(s.txns.first { $0.needsReview && $0.amount.currency == Money.home })
    let home = ReviewEngine.tabRow(ReviewEngine.card(t, s), s)
    #expect(!home.amount.rendered(hidden: false).hasPrefix("AED"))
    t.amount = Money(minor: 4_599, currency: "USD")
    t.homeMinor = nil
    let row = ReviewEngine.tabRow(ReviewEngine.card(t, s), s)
    #expect(row.amount.rendered(hidden: false) == "USD 45.99")
    #expect(row.amount.rendered(hidden: true) == "USD ••••")
    t.amount = Money(minor: 150_000, currency: "JPY")
    #expect(ReviewEngine.tabRow(ReviewEngine.card(t, s), s).amount.rendered(hidden: false) == "JPY 1,500.00")
  }

  @Test func countsAreGrouped() {
    #expect(MoneyFormat.count(1_284) == "1,284")
    #expect(MoneyFormat.count(12_840) == "12,840")
    #expect(MoneyFormat.count(999) == "999")
    #expect(MoneyFormat.count(0) == "0")
    #expect(MoneyFormat.count(-1_284) == "-1,284")
  }

  @Test func bidiIsolateWrapsInFirstStrongIsolate() {
    #expect(Bidi.isolate("مطعم") == "\u{2068}مطعم\u{2069}")
    #expect(Bidi.isolate("").unicodeScalars.map(\.value) == [0x2068, 0x2069])
  }

  @Test func shortDatesNameTheYearOnlyWhenItDiffers() {
    let today = LocalDate(2026, 10, 28)
    #expect(LocalDate(2026, 10, 9).short(today: today) == "Fri 9 Oct")
    #expect(LocalDate(2025, 12, 14).short(today: today) == "Sun 14 Dec 2025")
    #expect(LocalDate(2027, 1, 1).short(today: today) == "Fri 1 Jan 2027")
    #expect(LocalDate(2026, 1, 1).short(today: today) == LocalDate(2026, 1, 1).short)
  }
}
