import HasalaMocks
import HasalaModels
import Testing

@Suite("Home amounts")
struct HomeAmountTests {
  let now = MayaLedger.now
  let october = MayaLedger.october

  static func usd(_ id: TxnID, home: Int64?, project: ProjectID? = nil, needsReview: Bool = false) -> Txn {
    Txn(id: id, merchant: "Amazon US", amount: Money(minor: 25_00, currency: "USD"), homeMinor: .some(home),
        postedAt: LocalDateTime(2026, 10, 10, 12, 0), accountID: "dib",
        categoryID: needsReview ? nil : "dining", needsReview: needsReview, projectID: project)
  }

  static func maya(with txns: Txn...) -> LedgerState {
    var s = MayaLedger.state
    s.txns.append(contentsOf: txns)
    return s
  }

  @Test func mayaRowsCarryTheirAmountAsHome() {
    for t in MayaLedger.state.txns {
      #expect(t.homeMinor == t.amount.minor)
      for sp in t.splits { #expect(sp.homeMinor == sp.amount.minor) }
    }
  }

  @Test func aUSDRowWithAHomeAmountCountsItsAEDValue() {
    let base = MayaLedger.state
    let s = Self.maya(with: Self.usd("usd-rated", home: 91_81), Self.usd("usd-project", home: 36_73, project: "japan"),
                      Self.usd("usd-review", home: 18_36, needsReview: true))

    #expect(Spending.total(s, in: october) - Spending.total(base, in: october) == 91_81 + 18_36)
    #expect(s.spent("dining", in: october).minor - base.spent("dining", in: october).minor == 91_81)
    let dining = { (s: LedgerState) in InsightsEngine.Totals(InsightsEngine.lines(s)).byCategory["dining"] ?? 0 }
    #expect(dining(Self.maya(with: Self.usd("usd-rated", home: 91_81))) - dining(base) == 91_81)

    let japan = { (s: LedgerState) in PlanEngine.snapshot(s, now: now).projects.first { $0.id == "japan" }!.spent.minor }
    #expect(japan(s) - japan(base) == 36_73)

    let review = { (s: LedgerState) in ActivityEngine.reviewSummary(s, now: now).unplanned.minor }
    #expect(review(s) - review(base) == 18_36)
  }

  @Test func aUSDRowWithNoRateIsInNoTotal() {
    let base = MayaLedger.state
    let s = Self.maya(with: Self.usd("usd-pending", home: nil), Self.usd("usd-pending-project", home: nil, project: "japan"),
                      Self.usd("usd-pending-review", home: nil, needsReview: true))

    #expect(Spending.total(s, in: october) == Spending.total(base, in: october))
    #expect(s.spent("dining", in: october) == base.spent("dining", in: october))
    #expect(InsightsEngine.Totals(InsightsEngine.lines(s)) == InsightsEngine.Totals(InsightsEngine.lines(base)))
    let japan = { (s: LedgerState) in PlanEngine.snapshot(s, now: now).projects.first { $0.id == "japan" }! }
    #expect(japan(s).spent == japan(base).spent)
    #expect(japan(s).pending == japan(base).pending)
    #expect(japan(s).mark?.leftOut == ["USD": 1])
    #expect(ActivityEngine.reviewSummary(s, now: now).unplanned == ActivityEngine.reviewSummary(base, now: now).unplanned)
    #expect(HomeEngine.hero(s, now: now, plan: PlanEngine.snapshot(s, now: now)).spent
      == HomeEngine.hero(base, now: now, plan: PlanEngine.snapshot(base, now: now)).spent)
    #expect(AskEngine.answer(s, filter: AskFilter(category: "dining")).total
      == AskEngine.answer(base, filter: AskFilter(category: "dining")).total)
  }

  @Test func aRowInAnotherCurrencyDefaultsToNoHomeAmount() {
    let t = Txn(id: "x", merchant: "X", amount: Money(minor: 10_00, currency: "EUR"), postedAt: now)
    #expect(t.homeMinor == nil)
    #expect(Txn(id: "y", merchant: "Y", amount: .aed(10_00), postedAt: now).homeMinor == 10_00)
  }
}
