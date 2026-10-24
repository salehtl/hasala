import CoreCategorize
import CoreReplay
import CoreTestSupport
import Foundation
import Testing

@testable import CoreDomain

@Suite("A merchant the person sorted is never asked about")
struct LastPickSweepTests {
  typealias T = ModelSuggestionSweepTests
  typealias B = BacklogSortTests

  static func picking(_ rows: [SweepRow], _ picks: [String: String]) -> [SweepRow] {
    rows.map { r in
      SweepRow(
        id: r.id, merchantRaw: r.merchantRaw, direction: r.direction, category: r.category, sourceKind: r.sourceKind,
        sourceRef: r.sourceRef, needsReview: r.needsReview, candidate: r.candidate, version: r.version, template: r.template,
        merchantGroup: r.merchantGroup, categorizedMs: r.categorizedMs, rejected: r.rejected, picked: picks[r.merchantRaw])
    }
  }

  @Test("a picked row is not eligible and never joins the model queue")
  func eligibility() throws {
    var l = T.Ledger()
    let ids = try l.ingest([("QASR CORNER STORE", "debit"), ("CAFE EXAMPLE JBR", "debit")])
    let rows = Self.picking(l.rows(), ["QASR CORNER STORE": "groceries"])
    let picked = try #require(rows.first { $0.id == ids[0] })
    #expect(picked.picked == "groceries" && !ModelSuggestionSweep.eligible(picked))
    #expect(ModelSuggestionSweep.eligible(try #require(rows.first { $0.id == ids[1] })))
    #expect(ModelSuggestionSweep.queue(rows: rows, categorizer: T.categorizer).map(\.id) == [ids[1]])
  }

  @Test("the foreground sweep sends neither Cloudflare nor Apple's model a picked merchant")
  func foreground() async throws {
    var l = T.Ledger()
    let ids = try l.ingest([("QASR CORNER STORE", "debit"), ("QASR CORNER STORE", "debit"), ("CAFE EXAMPLE JBR", "debit")])
    let cloud = RecordingModel("cf-clef/1", reply: .category("shopping"))
    let device = RecordingModel("apple-fm/26.1", reply: .category("dining"))
    let s = try await ModelSuggestionSweep.suggest(
      rows: Self.picking(l.rows(), ["QASR CORNER STORE": "groceries"]), categorizer: T.categorizer, allowed: T.allowed,
      stages: [.cloud(cloud), .onDevice(device)], context: .foreground, cache: MemoryCache(), now: { now })
    #expect(cloud.calls.map(\.subject) == ["cafe example jbr"])
    #expect(device.calls.isEmpty)
    #expect(s.map(\.txnID) == [ids[2]])
  }

  @Test("the background plan, its counts and its pass leave a picked merchant out")
  func background() async throws {
    var l = T.Ledger()
    let ids = try l.ingest([("QASR CORNER STORE", "debit"), ("CAFE EXAMPLE JBR", "debit"), ("QASR CORNER STORE", "debit")])
    let rows = Self.picking(l.rows(), ["QASR CORNER STORE": "groceries"])
    let plan = try BacklogSort.plan(rows: rows, categorizer: T.categorizer, memo: .init()) { _ in nil }
    #expect(plan.queued.map(\.row.id) == [ids[1]])
    #expect(plan.pending == ["cafe example jbr"])
    let counts = try BacklogSort.counts(rows: rows, categorizer: T.categorizer) { _ in nil }
    #expect(counts.waitingNames == 1 && counts.pendingTxnIDs == [ids[1]])
    let everyone = try BacklogSort.counts(rows: l.rows(), categorizer: T.categorizer) { _ in nil }
    #expect(everyone.waitingNames == 2)

    let cloud = BacklogCloud(fallback: (.category("shopping"), true))
    let p = try await BacklogSort.pass(
      rows: rows, categorizer: T.categorizer, allowed: T.allowed, cloud: cloud, memo: .init(), cache: MemoryCache(), now: { now },
      autoFile: true)
    #expect(cloud.calls == ["cafe example jbr"])
    #expect(p.suggestions.map(\.txnID) == [ids[1]] && p.pending == 0)
  }

  @Test("a pick that lands while Cloudflare answers files nothing for that merchant")
  func midRequest() async throws {
    var l = T.Ledger()
    let ids = try l.ingest([("QASR CORNER STORE", "debit"), ("QASR CORNER STORE", "debit"), ("CAFE EXAMPLE JBR", "debit")])
    let read = l.rows()
    let cloud = BacklogCloud(fallback: (.category("shopping"), true))
    var u = OpAuthor(l.context())
    u.categorize(txnID: ids[0], parentVersion: l.state.txns[ids[0]]!.version, category: "groceries")
    try l.fold(try u.build())
    let snapshot = l
    let r = try await BacklogSort.run(
      rows: read, categorizer: T.categorizer, allowed: T.allowed, cloud: cloud, memo: .init(), cache: MemoryCache(), now: { now },
      autoFile: true, stamps: AuthorStamps(),
      reread: { (Self.picking(snapshot.rows(), ["QASR CORNER STORE": "groceries"]), snapshot.context()) })
    #expect(Set(cloud.calls) == ["qasr corner store", "cafe example jbr"])
    #expect(try B.review(r.blobs) == [ids[2]: true])
    #expect(r.filing.suggested == [ids[2]])

    let fresh = Self.picking(snapshot.rows(), ["QASR CORNER STORE": "groceries"])
    let early = [
      ModelSuggestionSweep.Suggestion(txnID: ids[1], version: read.first { $0.id == ids[1] }!.version!, category: "shopping", modelTag: "cf-clef/1")
    ]
    #expect(ModelSuggestionSweep.items(early, current: fresh).isEmpty)
    #expect(ModelSuggestionSweep.items(early, current: snapshot.rows()).count == 1)
  }
}
