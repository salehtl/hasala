@testable import HasalaModels
import Testing

@Suite("Activity day totals")
struct ActivityDayTotalTests {
  static func s(_ txns: [Txn]) -> LedgerState { InsightsFixture.ledger(txns) }

  @Test func aDayShowsSpendingApartFromMoneyIn() {
    var held = InsightsFixture.txn("1", 50_00)
    held.heldCopy = HeldCopy(of: "x", fromOtherInbox: false)
    let txns = [
      InsightsFixture.txn("1", 601_00), InsightsFixture.txn("salary", 1_250_00, direction: .in),
      InsightsFixture.txn("transfer", 300_00, isTransfer: true), held,
    ]
    let day = ActivityEngine.group(txns, Self.s(txns), today: LocalDate(2026, 6, 10))[0]
    #expect(day.spent == .aed(601_00))
    #expect(day.moneyIn == .aed(1_250_00))
    #expect(day.totalLine?.rendered(hidden: false) == "601.00 spent")
  }

  @Test func aRefundNetsAgainstTheDaysSpending() {
    let txns = [InsightsFixture.txn("1", 100_00), InsightsFixture.txn("1", 40_00, direction: .in)]
    let day = ActivityEngine.group(txns, Self.s(txns), today: LocalDate(2026, 6, 10))[0]
    #expect(day.spent == .aed(60_00))
    #expect(day.moneyIn == nil)
  }

  @Test func aDayOfOnlyTransfersHasNoTotal() {
    let txns = [InsightsFixture.txn("transfer", 300_00, isTransfer: true)]
    let day = ActivityEngine.group(txns, Self.s(txns), today: LocalDate(2026, 6, 10))[0]
    #expect(day.totalLine == nil)
  }

  @Test func aDayOfOnlyMoneyInSaysIn() {
    let txns = [InsightsFixture.txn("salary", 1_250_00, direction: .in)]
    let day = ActivityEngine.group(txns, Self.s(txns), today: LocalDate(2026, 6, 10))[0]
    #expect(day.totalLine?.rendered(hidden: false) == "+1,250.00 in")
  }
}
