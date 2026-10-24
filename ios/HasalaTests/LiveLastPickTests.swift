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
    #expect(try l.reader.lastPicks().isEmpty)
    #expect(try LedgerStateMapper.map(l.reader, context: Mapper.context()).txns.allSatisfy { $0.lastPick == nil })
    await l.store.reload()

    try l.store.apply(.categorize(inc[0], "subscriptions", learnRule: false, project: nil))
    for id in [com[0], com[1], inc[1], paypal] { #expect(l.store.state.txn(id)?.lastPick == "subscriptions") }
    #expect(l.store.state.txn(refund)?.lastPick == nil)
    try await Mapper.eventually { try l.row(inc[0])?.categorySource == "user" }
    #expect(try l.reader.lastPicks() == [LastPick.Key(group: "n:tailscale", direction: "debit"): "subscriptions"])

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
}
