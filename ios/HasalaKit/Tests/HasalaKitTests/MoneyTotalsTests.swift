import HasalaMocks
import HasalaModels
import Testing

@Suite("Money totals")
struct MoneyTotalsTests {
  let now = MayaLedger.now
  let october = MayaLedger.october

  static func txn(
    _ id: TxnID, _ amount: Money, home: Int64?? = nil, direction: Direction = .out, category: CategoryID? = "dining",
    needsReview: Bool = false, splits: [SplitLine] = [], isRefund: Bool = false
  ) -> Txn {
    Txn(id: id, merchant: "Shop \(id)", amount: amount, homeMinor: home, direction: direction,
        postedAt: LocalDateTime(2026, 10, 10, 12, 0), accountID: "dib", categoryID: category, needsReview: needsReview,
        splits: splits, isRefund: isRefund)
  }

  static func maya(with txns: Txn...) -> LedgerState {
    var s = MayaLedger.state
    s.txns.append(contentsOf: txns)
    return s
  }

  func glance(_ s: LedgerState) -> WidgetSnapshot {
    GlanceEngine.snapshot(s, now: now, home: HomeEngine.snapshot(s, now: now), amountsHidden: false)
  }

  func tile(_ s: LedgerState, _ label: String) -> Int64 {
    HomeEngine.hero(s, now: now, plan: PlanEngine.snapshot(s, now: now)).tiles.first { $0.label == label }!.value.minor
  }

  func diningLeft(_ s: LedgerState) -> Int64 {
    glance(s).categories.first { $0.id == "dining" }!.left.minor
  }

  @Test func aForeignRowCountsItsHomeAmountInEveryAggregate() {
    let base = MayaLedger.state
    let s = Self.maya(with: Self.txn("usd", Money(minor: 25_00, currency: "USD"), home: .some(91_81)))
    #expect(Spending.spent(s, category: "dining", in: october) - Spending.spent(base, category: "dining", in: october) == 91_81)
    #expect(tile(s, "Wants") - tile(base, "Wants") == 91_81)
    #expect(diningLeft(base) - diningLeft(s) == 91_81)
    #expect(Spending.total(s, in: october) - Spending.total(base, in: october) == 91_81)
  }

  @Test func aForeignRowWithNoHomeAmountIsCountedNowhere() {
    let base = MayaLedger.state
    let s = Self.maya(with: Self.txn("eur", Money(minor: 40_00, currency: "EUR"), home: .some(nil)))
    #expect(Spending.total(s, in: october) == Spending.total(base, in: october))
    #expect(Spending.spent(s, category: "dining", in: october) == Spending.spent(base, category: "dining", in: october))
    #expect(tile(s, "Wants") == tile(base, "Wants"))
    #expect(diningLeft(s) == diningLeft(base))
    let row = glance(s).today!.rows.first { $0.id == "t.eur" }!
    #expect(row.notCounted)
  }

  @Test func foreignBalancesAndBillsWithNoRateStayOutOfHomeTotals() {
    var s = MayaLedger.state
    let base = AccountsEngine.snapshot(s, now: now)
    let comingUp = glance(s).comingUp!.total
    s.accounts.append(Account(id: "eur", name: "EU account", shortName: "EU", kind: .current,
                              balance: Money(minor: 1_000_00, currency: "EUR")))
    s.bills.append(Bill(id: "eur-bill", name: "Cloud", kind: "Subscription", categoryID: "dining",
                        amount: Money(minor: 10_00, currency: "EUR"), usualDay: 12, nextDue: LocalDate(2026, 10, 12)))
    let after = AccountsEngine.snapshot(s, now: now)
    #expect(after.netWorth == base.netWorth)
    #expect(after.everydayTotal == base.everydayTotal)
    #expect(glance(s).comingUp!.total == comingUp)
  }

  @Test func splittingAForeignRowKeepsItsCurrencyAndApportionsTheHomeAmount() {
    let t = Self.txn("usd", Money(minor: 25_00, currency: "USD"), home: .some(91_81))
    let lines = t.apportioned([
      SplitLine(id: 0, categoryID: "groceries", amount: .aed(15_00)),
      SplitLine(id: 1, categoryID: "dining", amount: .aed(10_00)),
    ])
    #expect(lines.map(\.amount) == [Money(minor: 15_00, currency: "USD"), Money(minor: 10_00, currency: "USD")])
    #expect(lines.map(\.homeMinor) == [55_08, 36_73])
    #expect(Self.txn("eur", Money(minor: 25_00, currency: "EUR"), home: .some(nil)).apportioned(lines).map(\.homeMinor)
      == [nil, nil])
  }

  @Test func aSplitRefundReducesSpending() {
    let base = MayaLedger.state
    let refund = Self.txn("refund", .aed(30_00), direction: .in, splits: [
      SplitLine(id: 0, categoryID: "groceries", amount: .aed(20_00)),
      SplitLine(id: 1, categoryID: "dining", amount: .aed(10_00)),
    ], isRefund: true)
    let s = Self.maya(with: refund)
    #expect(refund.lines.map(\.minor) == [-20_00, -10_00])
    #expect(Spending.total(s, in: october) - Spending.total(base, in: october) == -30_00)
    #expect(s.spent("dining", in: october).minor - base.spent("dining", in: october).minor == -10_00)
    #expect(tile(s, "Needs") - tile(base, "Needs") == -20_00)
    let insights = { (s: LedgerState) in InsightsEngine.Totals(InsightsEngine.lines(s)) }
    #expect(insights(s).needs - insights(base).needs == -20_00)
  }

  @Test func aSplitPurchaseStillAddsToSpending() {
    let base = MayaLedger.state
    let s = Self.maya(with: Self.txn("buy", .aed(30_00), splits: [
      SplitLine(id: 0, categoryID: "groceries", amount: .aed(20_00)),
      SplitLine(id: 1, categoryID: "dining", amount: .aed(10_00)),
    ]))
    #expect(Spending.total(s, in: october) - Spending.total(base, in: october) == 30_00)
  }

  @Test func inReviewSpendingCountsOnHomeAndInWidgets() {
    let base = MayaLedger.state
    let s = Self.maya(with: Self.txn("review", .aed(50_00), needsReview: true))
    #expect(Spending.total(s, in: october) - Spending.total(base, in: october) == 50_00)
    #expect(Spending.spent(s, category: "dining", in: october) - Spending.spent(base, category: "dining", in: october)
      == 50_00)
    #expect(tile(s, "Wants") - tile(base, "Wants") == 50_00)
    #expect(diningLeft(base) - diningLeft(s) == 50_00)
    #expect(glance(s).today!.rows.contains { $0.id == "t.review" })
  }

  @Test func inReviewSpendingCountsInThePlan() {
    let base = MayaLedger.state
    let s = Self.maya(with: Self.txn("review", .aed(50_00), needsReview: true))
    func plan(_ s: LedgerState) -> PlanSnapshot { PlanEngine.snapshot(s, now: now) }
    func wants(_ s: LedgerState) -> PlanSection { plan(s).sections.first { $0.bucket == .wants }! }
    func dining(_ s: LedgerState) -> PlanRowModel { wants(s).rows.first { $0.id == "dining" }! }
    #expect(s.spent("dining", in: october).minor - base.spent("dining", in: october).minor == 50_00)
    #expect(dining(s).spent.minor - dining(base).spent.minor == 50_00)
    #expect(wants(base).left.minor - wants(s).left.minor == 50_00)
    #expect(s.spent("dining", in: october).minor == Spending.spent(s, category: "dining", in: october))
  }

  @Test func theReviewLineDoesNotSayTheAmountIsLeftOut() {
    let n = NotificationsEngine.snapshot(MayaLedger.state, now: now)
    let line = n.needsALook.first { $0.id == "review" }!.line.rendered(hidden: false)
    #expect(line == "AED 827.28 still to check")
    #expect(!line.contains("plan"))
  }

  @Test func theToReviewCaptionDoesNotSayTheAmountIsUncounted() {
    #expect(ToReviewWidget(count: 2, notCounted: .aed(120_00)).caption.rendered(hidden: false) == "120 still to check")
  }

  @Test func aNegativeTodayKeepsItsSign() {
    var s = MayaLedger.state
    s.txns.removeAll { $0.postedAt.date == now.date }
    s.txns.append(Self.txn("refund", .aed(50_00), direction: .in, isRefund: true))
    let today = glance(s).today!
    #expect(today.summary.rendered(hidden: false) == "1 transaction · \u{2212}50")
  }

  @Test func aNegativeNetWorthKeepsItsSign() {
    var s = MayaLedger.state
    s.accounts = [Account(id: "card", name: "Card", shortName: "Card", kind: .credit, balance: .aed(-500_00))]
    #expect(glance(s).netWorth!.total == .aed(-500_00))
    #expect(AccountsEngine.snapshot(s, now: now).netWorth == .aed(-500_00))
  }

  @Test func aMonthOfRefundsIsANegativeTotal() {
    var s = MayaLedger.state
    s.txns.removeAll { $0.postedAt.date.yearMonth == october }
    s.txns.append(Self.txn("refund", .aed(50_00), direction: .in, isRefund: true))
    #expect(HomeEngine.hero(s, now: now, plan: PlanEngine.snapshot(s, now: now)).spent == .aed(-50_00))
  }

  @Test func theCSVHasTheOriginalAmountAndTheHomeAmount() {
    let s = Self.maya(
      with: Self.txn("usd", Money(minor: 25_00, currency: "USD"), home: .some(91_81)),
      Self.txn("eur", Money(minor: 40_00, currency: "EUR"), home: .some(nil), direction: .in))
    let csv = CSVExport.csv(s.txns.filter { $0.id == "usd" || $0.id == "eur" }.map { ExportRow($0, s) })
    let lines = csv.components(separatedBy: "\r\n")
    #expect(lines[0].hasPrefix("Date,Description,Amount,Currency,AED amount,Direction,"))
    #expect(lines[1].hasPrefix("2026-10-10,Shop usd,-25.00,USD,-91.81,Spending,"))
    #expect(lines[2].hasPrefix("2026-10-10,Shop eur,40.00,EUR,,Income,"))
  }
}
