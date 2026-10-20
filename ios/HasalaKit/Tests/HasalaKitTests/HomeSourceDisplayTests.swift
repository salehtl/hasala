import HasalaMocks
import HasalaModels
import Testing

@Suite("Home source display")
struct HomeSourceDisplayTests {
  let now = MayaLedger.now

  static func usd(_ id: TxnID, home: Int64?, source: HomeSource?, rate: Int64? = nil) -> Txn {
    Txn(id: id, merchant: "Amazon US", amount: Money(minor: 25_00, currency: "USD"), homeMinor: .some(home),
        homeSource: .some(source), homeRateMicro: rate, postedAt: MayaLedger.now, accountID: "dib", categoryID: "dining")
  }

  static func maya(with txns: Txn...) -> LedgerState {
    var s = MayaLedger.state
    s.txns.append(contentsOf: txns)
    return s
  }

  @Test func theRateReadsWithItsSignificantDecimals() {
    #expect(RateFormat.string(3_672_500) == "3.6725")
    #expect(RateFormat.string(1_000_000) == "1.00")
    #expect(RateFormat.string(24_500) == "0.0245")
    #expect(RateFormat.string(5_100_000) == "5.10")
  }

  @Test func anEstimateShowsAEDWithAnEstimateLine() {
    let h = Self.usd("u1", home: 91_81, source: .rate, rate: 3_672_500).homeAmount
    #expect(h.shown == .aed(91_81))
    #expect(h.estimate && !h.notCounted)
    #expect(h.original == Money(minor: 25_00, currency: "USD"))
    #expect(h.estimateLine == "Estimate at 3.6725 AED per USD. Your bank's charge can be a little higher.")
  }

  @Test func aStatedAmountHasNoMark() {
    let h = Self.usd("u1", home: 92_50, source: .stated).homeAmount
    #expect(h.shown == .aed(92_50))
    #expect(!h.estimate && h.estimateLine == nil)
  }

  @Test func aRowWithNoAEDValueIsNotCounted() {
    let t = Self.usd("u1", home: nil, source: nil)
    #expect(t.isNotCounted)
    let r = ActivityEngine.row(t, Self.maya(with: t))
    #expect(r.notCounted && !r.estimate)
  }

  @Test func anAEDRowIsIdentity() {
    let t = MayaLedger.state.txns[0]
    #expect(t.homeSource == .identity)
    #expect(!t.isEstimate && t.homeAmount.original == nil && t.homeAmount.shown == t.amount)
  }

  @Test func onlyTheRowIsMarkedNotTheTotals() {
    let t = Self.usd("u1", home: 91_81, source: .rate, rate: 3_672_500)
    let s = Self.maya(with: t)
    let days = ActivityEngine.snapshot(s, now: now, filter: TxnFilter()).days
    let day = days.first { $0.rows.contains { $0.id == "u1" } }
    let row = day?.rows.first { $0.id == "u1" }
    #expect(row?.estimate == true && row?.amount == .aed(91_81))
    #expect(TransactionEngine.detail("u1", s, now: now)?.home?.estimate == true)
  }

  @Test func aStatedRowIsNotMarked() {
    let s = Self.maya(with: Self.usd("u1", home: 92_50, source: .stated))
    let days = ActivityEngine.snapshot(s, now: now, filter: TxnFilter()).days
    let row = days.flatMap(\.rows).first { $0.id == "u1" }
    #expect(row?.estimate == false)
  }
}
