import HasalaMocks
@testable import HasalaModels
import Testing

@Suite("Sorted by Cloudflare AI · the full list")
struct CloudflareFiledTests {
  static func filed(_ id: TxnID, daysAgo: Int) -> Txn {
    let at = LocalDateTime(date: MayaLedger.now.date.adding(days: -daysAgo), hour: 9, minute: 0)
    var t = RefundCountingTests.row(id, 30_00, .out, category: "dining")
    t.categorySource = .model(tag: CategorySource.cloudflareModelPrefix + "1")
    t.categorizedAt = at
    t.merchantGroup = "g-\(id)"
    return t
  }

  @Test func theFullListHasNoWeekLimit() {
    let s = RefundCountingTests.with(Self.filed("old", daysAgo: 40), Self.filed("new", daysAgo: 2))
    let all = SortedForYouEngine.cloudflareFiled(s, now: MayaLedger.now).items.flatMap(\.txnIDs)
    #expect(all.contains("old") && all.contains("new"))
    let week = SortedForYouEngine.snapshot(s, now: MayaLedger.now).items.flatMap(\.txnIDs)
    #expect(!week.contains("old") && week.contains("new"))
  }
}

@Suite("Recurring · no category picked for you")
struct RecurringDraftCategoryTests {
  @Test func aPaymentWithNoCategoryDraftsWithNone() throws {
    var t = RefundCountingTests.row("np", 55_00, .out, category: nil)
    t.suggestion = nil
    let s = RefundCountingTests.with(t)
    let d = try #require(BillsEngine.draft(from: "np", s, now: MayaLedger.now))
    #expect(d.categoryID.isEmpty)
  }
}
