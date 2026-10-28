import HasalaMocks
import HasalaModels
import Testing

@Suite("Money · minor digits")
struct MoneyMinorDigitsTests {
  @Test func eachCurrencyUsesItsOwnMinorDigits() {
    #expect(MoneyFormat.minorDigits("AED") == 2)
    #expect(MoneyFormat.minorDigits("USD") == 2)
    #expect(MoneyFormat.minorDigits("JPY") == 0)
    #expect(MoneyFormat.minorDigits("KRW") == 0)
    #expect(MoneyFormat.minorDigits("KWD") == 3)
    #expect(MoneyFormat.minorDigits("BHD") == 3)
    #expect(MoneyFormat.minorDigits("OMR") == 3)
  }

  @Test func exactShowsEveryMinorDigit() {
    #expect(MoneyFormat.string(Money(minor: 1_500, currency: "JPY")) == "1,500")
    #expect(MoneyFormat.string(Money(minor: 12_345, currency: "KWD")) == "12.345")
    #expect(MoneyFormat.string(Money(minor: 32_500, currency: "BHD")) == "32.500")
    #expect(MoneyFormat.string(Money(minor: 4_750, currency: "OMR")) == "4.750")
    #expect(MoneyFormat.string(Money(minor: 4_599, currency: "USD")) == "45.99")
    #expect(MoneyFormat.string(Money(minor: -45, currency: "KWD")) == "0.045")
    #expect(MoneyFormat.string(Money(minor: 1_234_567_890, currency: "JPY")) == "1,234,567,890")
  }

  @Test func compactDropsAZeroFractionOnly() {
    #expect(MoneyFormat.string(Money(minor: 1_500, currency: "JPY"), style: .compact) == "1,500")
    #expect(MoneyFormat.string(Money(minor: 12_345, currency: "KWD"), style: .compact) == "12.345")
    #expect(MoneyFormat.string(Money(minor: 32_000, currency: "BHD"), style: .compact) == "32")
    #expect(MoneyFormat.string(Money(minor: 4_750, currency: "OMR"), style: .compact) == "4.750")
    #expect(MoneyFormat.string(Money(minor: 4_599, currency: "USD"), style: .compact) == "45.99")
    #expect(MoneyFormat.string(Money(minor: 2_500, currency: "USD"), style: .compact) == "25")
  }

  @Test func roundedRoundsHalfAwayFromZeroInWholeUnits() {
    #expect(MoneyFormat.string(Money(minor: 1_500, currency: "JPY"), style: .rounded) == "1,500")
    #expect(MoneyFormat.string(Money(minor: 12_345, currency: "KWD"), style: .rounded) == "12")
    #expect(MoneyFormat.string(Money(minor: 32_500, currency: "BHD"), style: .rounded) == "33")
    #expect(MoneyFormat.string(Money(minor: 4_750, currency: "OMR"), style: .rounded) == "5")
    #expect(MoneyFormat.string(Money(minor: 4_599, currency: "USD"), style: .rounded) == "46")
  }

  @Test func aedCallersKeepTheirFormat() {
    #expect(MoneyFormat.string(.aed(7_417_55)) == MoneyFormat.string(7_417_55))
    #expect(MoneyFormat.string(.aed(12_350_00), style: .compact) == "12,350")
    #expect(MoneyFormat.string(.aed(337_49), style: .rounded) == "337")
  }

  @Test func phrasesUseTheAmountsCurrency() {
    let line = MoneyPhrase([.text("JPY "), .amount(Money(minor: 1_500, currency: "JPY")), .text(" and KWD "),
                            .signedMoney(Money(minor: -12_345, currency: "KWD"), style: .exact, hiddenGlyphs: 4)])
    #expect(line.rendered(hidden: false) == "JPY 1,500 and KWD \u{2212}12.345")
    #expect(line.rendered(hidden: true) == "JPY •••• and KWD ••••")
  }

  @Test func convertScalesToTheHomeCurrencysMinorUnits() {
    #expect(ExchangeRates.convert(1_500, 24_500, currency: "JPY") == 36_75)
    #expect(ExchangeRates.convert(12_345, 11_942_000, currency: "KWD") == 147_42)
    #expect(ExchangeRates.convert(32_500, 9_767_287, currency: "BHD") == 317_44)
    #expect(ExchangeRates.convert(4_750, 9_551_365, currency: "OMR") == 45_37)
    #expect(ExchangeRates.convert(4_599, 3_672_500, currency: "USD") == 168_90)
    #expect(ExchangeRates.convert(4_599, 3_672_500) == 168_90)
    #expect(ExchangeRates.convert(-1, 3_672_500, currency: "JPY") == nil)
  }

  @Test func homeTotalsConvertForeignAmountsAtTheirOwnScale() {
    let rates = [CurrencyRate(currency: "JPY", rateMicro: 24_500), CurrencyRate(currency: "KWD", rateMicro: 11_942_000)]
    let total = Money.homeTotal(
      [Money(minor: 1_500, currency: "JPY"), Money(minor: -12_345, currency: "KWD"), .aed(100_00)], rates: rates)
    #expect(total.minor == 36_75 - 147_42 + 100_00)
    #expect(total.estimate)
  }

  @Test func settingARateBackfillsAtTheCurrencysScale() {
    var s = Scenario.maya.state
    let id = s.txns[0].id
    s.txns[0].amount = Money(minor: 1_500, currency: "JPY")
    s.txns[0].homeMinor = nil
    s.txns[0].splits = []
    s.setRate("JPY", micro: 24_500)
    #expect(s.txn(id)?.homeMinor == 36_75)
  }

  @Test func csvWritesTheAmountInItsOwnDigits() {
    #expect(CSVExport.decimal(Money(minor: -1_500, currency: "JPY")) == "-1500")
    #expect(CSVExport.decimal(Money(minor: 1_234_567, currency: "KWD")) == "1234.567")
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
    t.amount = Money(minor: 1_500, currency: "JPY")
    #expect(ReviewEngine.tabRow(ReviewEngine.card(t, s), s).amount.rendered(hidden: false) == "JPY 1,500")
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
