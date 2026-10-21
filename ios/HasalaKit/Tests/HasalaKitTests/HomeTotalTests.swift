import HasalaMocks
@testable import HasalaModels
import Testing

@Suite("Home totals")
struct HomeTotalTests {
  let now = MayaLedger.now

  static let usd = Money(minor: 1_000_00, currency: "USD")
  static let eur = Money(minor: 500_00, currency: "EUR")

  static func withAccounts(_ balances: (AccountID, Money, Bool)...) -> LedgerState {
    var s = MayaLedger.state
    for (id, balance, inPlan) in balances {
      s.accounts.append(Account(id: id, name: "Account \(id)", shortName: id, kind: .current, balance: balance,
                                inPlan: inPlan))
    }
    return s
  }

  static func withBills(_ amounts: (BillID, Money)...) -> LedgerState {
    var s = MayaLedger.state
    for (id, amount) in amounts {
      s.bills.append(Bill(id: id, name: "Bill \(id)", kind: "Subscription", categoryID: "dining", amount: amount,
                          usualDay: 12, nextDue: LocalDate(2026, 10, 12)))
    }
    return s
  }

  @Test func homeAmountsAreExact() {
    let t = Money.homeTotal([.aed(10_00), .aed(-2_50)], rates: [])
    #expect(t.minor == 7_50)
    #expect(t.mark == nil)
  }

  @Test func aRatedAmountIsAnEstimateAtTheCurrentRate() {
    let t = Money.homeTotal([.aed(10_00), Self.usd], rates: [CurrencyRate(currency: "USD", rateMicro: 3_672_500)])
    #expect(t.minor == 10_00 + 3_672_50)
    #expect(t.estimate)
    #expect(t.mark?.line == nil)
  }

  @Test func aNegativeRatedAmountConvertsWithItsSign() {
    let t = Money.homeTotal([Money(minor: -10_00, currency: "USD")], rates: [CurrencyRate(currency: "USD", rateMicro: 3_672_500)])
    #expect(t.minor == -36_73)
  }

  @Test func anAmountWithNoRateIsLeftOutAndCounted() {
    let t = Money.homeTotal([.aed(10_00), Self.eur, Self.eur, Money(minor: 0, currency: "GBP")],
                            rates: [CurrencyRate(currency: "EUR", rateMicro: nil)])
    #expect(t.minor == 10_00)
    #expect(!t.estimate)
    #expect(t.leftOutCount == 2)
    #expect(t.mark?.currency == "EUR")
    #expect(t.mark?.line == "Not counted: 2 in EUR")
    #expect(t.mark?.caption == "2 not counted")
  }

  @Test func severalCurrenciesWithNoRateSayHowMany() {
    let t = Money.homeTotal([Self.eur, Money(minor: 1_00, currency: "GBP")], rates: [])
    #expect(t.mark?.currency == nil)
    #expect(t.mark?.line == "Not counted: 2 with no rate")
  }

  @Test func netWorthAndEverydayMarkWhatTheyLeaveOut() {
    let base = AccountsEngine.snapshot(MayaLedger.state, now: now)
    #expect(base.netWorthMark == nil)
    #expect(base.everydayMark == nil)
    let s = Self.withAccounts(("us", Self.usd, true), ("eu", Self.eur, true), ("eu2", Self.eur, false))
    let a = AccountsEngine.snapshot(s, now: now)
    #expect(a.netWorth.minor - base.netWorth.minor == 3_672_50)
    #expect(a.netWorthMark == TotalMark(estimate: true, leftOut: ["EUR": 2]))
    #expect(a.everydayTotal.minor - base.everydayTotal.minor == 3_672_50)
    #expect(a.everydayMark == TotalMark(estimate: true, leftOut: ["EUR": 1]))
  }

  @Test func profileAccountsLineLeavesTheSymbolOffNetWorth() {
    let s = Self.withAccounts(("us", Self.usd, true), ("eu", Self.eur, true))
    let line = ProfileEngine.snapshot(s, now: now).accounts.rendered(hidden: false)
    #expect(line == "6 · net worth 231,241 · 1 not counted")
    #expect(ProfileEngine.snapshot(MayaLedger.state, now: now).accounts.rendered(hidden: false)
      == "4 · net worth 227,568")
  }

  @Test func insightsNetWorthMarksWhatItLeavesOut() {
    let s = Self.withAccounts(("eu", Self.eur, true))
    let r = InsightsEngine.snapshot(s, months: MayaLedger.october...MayaLedger.october, now: now).reports.first!
    #expect(r.value == .money(.aed(227_568_00)))
    #expect(r.mark?.leftOutCount == 1)
    #expect(r.caption.hasSuffix(" · 1 not counted"))
    let base = InsightsEngine.snapshot(MayaLedger.state, months: MayaLedger.october...MayaLedger.october, now: now)
    #expect(base.reports.first?.mark == nil)
  }

  @Test func netWorthWidgetMarksWhatItLeavesOut() {
    let w = HomeEngine.netWorthWidget(Self.withAccounts(("us", Self.usd, true), ("eu", Self.eur, true)))!
    #expect(w.total == .aed(227_568_00 + 3_672_50))
    #expect(w.mark == TotalMark(estimate: true, leftOut: ["EUR": 1]))
    #expect(HomeEngine.netWorthWidget(MayaLedger.state)?.mark == nil)
  }

  @Test func nextFourteenDaysMarksBillsWithNoRate() {
    let base = BillsEngine.snapshot(MayaLedger.state, now: now)
    #expect(base.next14Mark == nil)
    let b = BillsEngine.snapshot(Self.withBills(("us", Money(minor: 10_00, currency: "USD")), ("eu", Self.eur)), now: now)
    #expect(b.next14.minor - base.next14.minor == 36_73)
    #expect(b.next14Mark == TotalMark(estimate: true, leftOut: ["EUR": 1]))
  }

  @Test func comingUpMarksBillsWithNoRate() {
    func comingUp(_ s: LedgerState) -> ComingUpWidget {
      GlanceEngine.snapshot(s, now: now, home: HomeEngine.snapshot(s, now: now), amountsHidden: false).comingUp!
    }
    let base = comingUp(MayaLedger.state)
    #expect(base.mark == nil)
    let c = comingUp(Self.withBills(("us", Money(minor: 10_00, currency: "USD")), ("eu", Self.eur)))
    #expect(c.total.minor - base.total.minor == 36_73)
    #expect(c.mark == TotalMark(estimate: true, leftOut: ["EUR": 1]))
  }

  @Test func billsToComeConvertAtTheRate() {
    let base = HomeEngine.billsThisMonth(MayaLedger.state, month: MayaLedger.october)
    let s = Self.withBills(("us", Money(minor: 10_00, currency: "USD")), ("eu", Self.eur))
    #expect(HomeEngine.billsThisMonth(s, month: MayaLedger.october).toCome - base.toCome == 36_73)
  }

  @Test func setAFoundRateAndTheTotalCountsIt() {
    var s = Self.withAccounts(("eu", Self.eur, true))
    #expect(ExchangeRates.page(s).missing.map(\.currency) == ["EUR"])
    s.setRate("EUR", micro: 4_000_000)
    let a = AccountsEngine.snapshot(s, now: now)
    #expect(a.netWorth == .aed(227_568_00 + 2_000_00))
    #expect(a.netWorthMark == TotalMark(estimate: true))
    #expect(ExchangeRates.page(s).missing.isEmpty)
  }
}
