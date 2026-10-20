import HasalaMocks
import HasalaModels
import Testing

@Suite("Exchange rates")
struct ExchangeRatesTests {
  let october = MayaLedger.october

  static func row(_ id: TxnID, _ minor: Int64, _ ccy: String, home: Int64? = nil, archived: Bool = false) -> Txn {
    Txn(id: id, merchant: "Shop", amount: Money(minor: minor, currency: ccy), homeMinor: .some(home),
        postedAt: LocalDateTime(2026, 10, 10, 12, 0), accountID: "dib", categoryID: "dining", archived: archived)
  }

  @Test func parseReadsDecimalRatesAsMicro() {
    #expect(ExchangeRates.parse("3.6725") == 3_672_500)
    #expect(ExchangeRates.parse(" 4,05 ") == 4_050_000)
    #expect(ExchangeRates.parse(".5") == 500_000)
    #expect(ExchangeRates.parse("12") == 12_000_000)
    #expect(ExchangeRates.parse("0.000001") == 1)
  }

  @Test func parseRefusesWhatIsNotARate() {
    for bad in ["", ".", "0", "0.0000001", "-1", "1.2.3", "abc", "1e3", "٣.٦", "99999999"] {
      #expect(ExchangeRates.parse(bad) == nil, "\(bad)")
    }
  }

  @Test func formatTrimsZerosAndKeepsTwoDecimals() {
    #expect(ExchangeRates.format(3_672_500) == "3.6725")
    #expect(ExchangeRates.format(4_000_000) == "4.00")
    #expect(ExchangeRates.format(979_333) == "0.979333")
    #expect(ExchangeRates.format(1) == "0.000001")
  }

  @Test func pegsFollowTheDirhamsUSDollarPeg() {
    #expect(ExchangeRates.pegs["USD"] == 3_672_500)
    #expect(ExchangeRates.pegs["SAR"] == 979_333)
    #expect(ExchangeRates.pegs["QAR"] == 1_008_929)
    #expect(ExchangeRates.pegs["OMR"] == 9_551_365)
    #expect(ExchangeRates.pegs["BHD"] == 9_767_287)
    #expect(ExchangeRates.pegs["AED"] == nil)
  }

  @Test func settableNeedsACodeThatIsNotHome() {
    #expect(ExchangeRates.isSettable("EUR", 4_000_000))
    #expect(ExchangeRates.isSettable("EUR", nil))
    #expect(!ExchangeRates.isSettable("AED", 1_000_000))
    #expect(!ExchangeRates.isSettable("eur", 4_000_000))
    #expect(!ExchangeRates.isSettable("EURO", 4_000_000))
    #expect(!ExchangeRates.isSettable("EUR", 0))
  }

  @Test func pageListsRatesAndCurrenciesNotCounted() {
    var s = MayaLedger.state
    s.txns += [
      Self.row("eur-1", 10_00, "EUR"), Self.row("eur-2", 20_00, "EUR"), Self.row("sar-1", 50_00, "SAR"),
      Self.row("gbp-old", 5_00, "GBP", archived: true), Self.row("usd-1", 25_00, "USD", home: 91_81),
    ]
    let page = ExchangeRates.page(s)
    #expect(page.rates.map(\.currency) == ["USD"])
    #expect(page.rates.first?.isPeg == true)
    #expect(page.missing.map(\.currency) == ["EUR", "SAR"])
    #expect(page.missing.map(\.notCounted) == [2, 1])
    #expect(page.missing.last?.peg == 979_333)
  }

  @Test func aRemovedRateShowsUnderNotCounted() {
    var s = MayaLedger.state
    s.unsetRate("USD")
    let page = ExchangeRates.page(s)
    #expect(page.rates.isEmpty)
    #expect(page.missing.map(\.currency) == ["USD"])
  }

  @Test func settingARateCountsOnlyRowsWithoutAHomeAmount() {
    var s = MayaLedger.state
    s.txns += [Self.row("eur-1", 10_00, "EUR"), Self.row("eur-old", 10_00, "EUR", home: 42_00)]
    let before = Spending.total(s, in: october)
    s.setRate("EUR", micro: 4_050_000)
    #expect(s.txn("eur-1")?.homeMinor == 40_50)
    #expect(s.txn("eur-1")?.homeSource == .rate)
    #expect(s.txn("eur-1")?.homeRateMicro == 4_050_000)
    #expect(s.txn("eur-1")?.isEstimate == true)
    #expect(s.txn("eur-old")?.homeMinor == 42_00)
    #expect(Spending.total(s, in: october) - before == 40_50)
    #expect(ExchangeRates.page(s).missing.isEmpty)
  }

  @Test func removingARateKeepsCountedRows() {
    var s = MayaLedger.state
    s.txns.append(Self.row("eur-1", 10_00, "EUR"))
    s.setRate("EUR", micro: 4_000_000)
    s.unsetRate("EUR")
    #expect(s.txn("eur-1")?.homeMinor == 40_00)
    #expect(s.rates.first { $0.currency == "EUR" }?.rateMicro == nil)
  }

  @MainActor @Test func theMockAppliesRateEdits() throws {
    var state = MayaLedger.state
    state.txns.append(Self.row("eur-1", 10_00, "EUR"))
    let store = InMemoryLedger(state: state)
    #expect(try store.apply(.setRate(currency: "EUR", rateMicro: 4_000_000)) == nil)
    #expect(store.state.txn("eur-1")?.homeMinor == 40_00)
    #expect(throws: ActionError.invalidAmount) { try store.apply(.setRate(currency: "AED", rateMicro: 1_000_000)) }
    #expect(throws: ActionError.invalidAmount) { try store.apply(.setRate(currency: "EUR", rateMicro: 0)) }
    try store.apply(.unsetRate(currency: "EUR"))
    #expect(store.state.rates.first { $0.currency == "EUR" }?.rateMicro == nil)
  }
}
