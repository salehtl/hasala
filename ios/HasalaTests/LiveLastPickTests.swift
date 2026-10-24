import CoreCategorize
import CoreDomain
import CoreProjection
import CoreReplay
import CoreWire
import Foundation
import HasalaMocks
import HasalaModels
import Testing

@testable import Hasala

@MainActor
@Suite("Live: your last pick comes first")
struct LiveLastPickTests {
  typealias Sorting = LiveSortingTests
  typealias Mapper = LiveLedgerMapperTests

  static func picks(_ r: LedgerReader) throws -> [LastPick.Key: String] {
    LastPick.picks(try (r.activity(limit: 1_000_000) + r.archived(limit: 1_000_000)).map(\.pickRow))
  }

  @Test func theMapperPassesThePersonsNewestPickToWaitingRowsAndHeldRowsDoNotCount() async throws {
    let l = try await Sorting.ledger(suite: "lastpick.map", rows: Sorting.tailscale, guesses: ["bright": "shopping"])
    let com = try #require(l.ids["com"]), inc = try #require(l.ids["inc"]), bright = try #require(l.ids["bright"])
    let paypal = try #require(l.ids["paypal"]?.first), refund = try #require(l.ids["refund"]?.first)
    #expect(l.store.state.txns.allSatisfy { $0.lastPick == nil })

    let version = try #require(try l.row(com[1])?.version)
    let held = try l.a.observer.stamps.build(try await l.a.observer.authorContext()) { o throws(AuthorError) in
      o.categorize(txnID: com[1], parentVersion: version, category: "dining", needsReview: true, source: CategorySource(kind: .held))
    }
    if let held { try await l.a.outbox.enqueue(held.ops) }
    try await l.a.observer.reproject()
    #expect(try l.row(com[1])?.categorySource == "held")
    #expect(try Self.picks(l.reader).isEmpty)
    #expect(try LedgerStateMapper.map(l.reader, context: Mapper.context()).txns.allSatisfy { $0.lastPick == nil })
    await l.store.reload()

    try l.store.apply(.categorize(inc[0], "subscriptions", learnRule: false, project: nil))
    for id in [com[0], com[1], inc[1], paypal] { #expect(l.store.state.txn(id)?.lastPick == "subscriptions") }
    #expect(l.store.state.txn(refund)?.lastPick == nil)
    try await Mapper.eventually { try l.row(inc[0])?.categorySource == "user" }
    #expect(try Self.picks(l.reader) == [LastPick.Key(group: "n:tailscale", direction: "debit"): "subscriptions"])

    let mapped = try LedgerStateMapper.map(l.reader, context: Mapper.context())
    for id in [com[0], com[1], inc[1], paypal] { #expect(mapped.txn(id)?.lastPick == "subscriptions") }
    #expect(mapped.txn(inc[0])?.lastPick == nil && mapped.txn(refund)?.lastPick == nil)
    let card = ReviewEngine.card(try #require(mapped.txn(paypal)), mapped)
    #expect(card.suggestion?.id == "subscriptions" && card.suggestedBy == "Your last pick")
    let sweep = try #require(try l.reader.sweepRows().first { $0.id == com[0] })
    #expect(sweep.picked == "subscriptions" && !ModelSuggestionSweep.eligible(sweep))

    try l.store.apply(.categorize(bright[0], "healthcare", learnRule: false, project: nil))
    #expect(l.store.state.txn(bright[1])?.reviewSuggestion == "healthcare")
    try await Mapper.eventually { try l.row(bright[0])?.category == "healthcare" }
    let after = try LedgerStateMapper.map(l.reader, context: Mapper.context())
    let other = try #require(after.txn(bright[1]))
    #expect(other.lastPick == "healthcare" && other.modelSuggestion == "shopping")
    #expect(ReviewEngine.card(other, after).suggestedBy == "Your last pick")
  }

  @Test func aPickInAHiddenCategoryShowsNoSuggestionAndTheModelsStillSkipTheMerchant() async throws {
    let l = try await Sorting.ledger(suite: "lastpick.hidden", rows: Sorting.tailscale)
    let com = try #require(l.ids["com"])
    try l.store.apply(.categorize(com[0], "travel", learnRule: false, project: nil))
    try await Mapper.eventually { try l.row(com[0])?.category == "travel" }
    try l.store.apply(.archiveCategory("travel", moveTo: nil))
    try await Mapper.eventually { try l.reader.taxonomy().info("travel")?.active == false }
    #expect(try l.reader.taxonomy().info("travel")?.active == false)
    let mapped = try LedgerStateMapper.map(l.reader, context: Mapper.context())
    let waiting = try #require(mapped.txn(com[1]))
    #expect(waiting.inReview && waiting.lastPick == "travel")
    #expect(ReviewEngine.card(waiting, mapped).suggestion == nil)
    #expect(ReviewEngine.card(waiting, mapped).suggestedBy == nil)
    let sweep = try #require(try l.reader.sweepRows().first { $0.id == com[1] })
    #expect(sweep.picked == "travel" && !ModelSuggestionSweep.eligible(sweep))
  }

  @Test func undoingAReSortGivesTheEarlierPickBackAndKeepsItsSortTime() async throws {
    let clock = Sorting.MovableClock(ms: Sorting.weeksAgo)
    let l = try await Sorting.ledger(suite: "lastpick.undo", rows: Sorting.tailscale, clock: clock)
    let com = try #require(l.ids["com"]), inc = try #require(l.ids["inc"]), paypal = try #require(l.ids["paypal"]?.first)
    try l.store.apply(.categorize(com[0], "groceries", learnRule: false, project: nil))
    try await Mapper.eventually { try l.row(com[0])?.categorySource == "user" }
    let first = try #require(try l.row(com[0])?.categorizedMs)
    clock.set(Sorting.weeksAgo + 3_600_000)
    try l.store.apply(.categorize(inc[0], "subscriptions", learnRule: false, project: nil))
    try await Mapper.eventually { try l.row(inc[0])?.categorySource == "user" }
    for (n, category) in ["dining", "shopping"].enumerated() {
      clock.set(Sorting.weeksAgo + Int64(2 + 2 * n) * 3_600_000)
      let token = try #require(try l.store.apply(.categorize(com[0], category, learnRule: false, project: nil)))
      #expect(l.store.state.txn(paypal)?.lastPick == category)
      try await Mapper.eventually { try l.row(com[0])?.category == category && l.store.state.txn(paypal)?.lastPick == category }
      clock.set(Sorting.weeksAgo + Int64(3 + 2 * n) * 3_600_000)
      l.store.undo(token)
      try await Mapper.eventually { l.store.state.txn(com[0])?.categoryID == "groceries" }
      #expect(try l.row(com[0])?.categorySource == "user" && (l.row(com[0])?.categorizedMs ?? 0) > first)
      #expect(l.store.state.txn(com[0])?.categorizedAt == LedgerStateMapper.localTime(first))
      #expect(l.store.state.txn(paypal)?.lastPick == "subscriptions", "\(category)")
    }
    #expect(try LedgerStateMapper.map(l.reader, context: Mapper.context()).txn(paypal)?.lastPick == "groceries")
    #expect(l.memory.value.undone?.keys.sorted() == [com[0]])
    try l.store.apply(.categorize(com[0], "dining", learnRule: false, project: nil))
    try await Mapper.eventually { try l.row(com[0])?.category == "dining" && l.store.state.txn(paypal)?.lastPick == "dining" }
    #expect(l.store.state.txn(paypal)?.lastPick == "dining")
  }

  @Test func theOtherFilingsKeepThePickUntilTheReload() throws {
    var s = Scenario.mayaBacklog.state
    for i in s.txns.indices where s.txns[i].id == "bl-qasr-6" {
      s.txns[i].categoryID = "dining"
      s.txns[i].categorySource = .model(tag: "cf-clef/1")
      s.txns[i].needsReview = false
      s.txns[i].lastPick = nil
    }
    #expect(s.txn("bl-qasr-2")?.lastPick == "shopping" && s.txn("bl-qasr-6")?.inReview == false)
    let now = MayaLedger.now

    var transfer = s
    _ = try LiveLedgerStore.patch(.markTransfer("bl-qasr-1"), &transfer, now: now)
    #expect(transfer.txn("bl-qasr-2")?.lastPick == "transfer" && transfer.txn("bl-qasr-1")?.lastPick == nil)

    var refund = s
    _ = try LiveLedgerStore.patch(.markRefund("bl-qasr-1"), &refund, now: now)
    #expect(refund.txn("bl-qasr-2")?.lastPick == "refunds")
    _ = try LiveLedgerStore.patch(.markRefund("bl-qasr-1"), &refund, now: now)
    #expect(refund.txn("bl-qasr-1")?.inReview == true)
    #expect(refund.txn("bl-qasr-1")?.lastPick == nil && refund.txn("bl-qasr-2")?.lastPick == nil)

    var splitPick = s
    let lines = [
      SplitLine(id: 0, categoryID: "groceries", amount: .aed(30_00)), SplitLine(id: 1, categoryID: "shopping", amount: .aed(25_00)),
    ]
    _ = try LiveLedgerStore.patch(.split("bl-qasr-filed-7", lines), &splitPick, now: now)
    #expect(splitPick.txns.filter { $0.groupRef == MayaBacklog.qasrGroup }.allSatisfy { $0.lastPick == nil })

    var splitWaiting = s
    let waiting = [
      SplitLine(id: 0, categoryID: "groceries", amount: .aed(10_00)), SplitLine(id: 1, categoryID: "shopping", amount: .aed(13_50)),
    ]
    _ = try LiveLedgerStore.patch(.split("bl-qasr-1", waiting), &splitWaiting, now: now)
    #expect(splitWaiting.txn("bl-qasr-2")?.lastPick == "shopping" && splitWaiting.txn("bl-qasr-1")?.lastPick == nil)

    var returned = s
    _ = try LiveLedgerStore.patch(.returnToReview(["bl-qasr-6"]), &returned, now: now)
    #expect(returned.txn("bl-qasr-6")?.inReview == true && returned.txn("bl-qasr-6")?.lastPick == "shopping")
  }
}
