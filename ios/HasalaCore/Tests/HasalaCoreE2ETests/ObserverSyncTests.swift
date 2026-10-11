// Fold and project on pull, end to end over FakeServer (spec 04 §5.2-§5.3,
// §4.3): ops authored on one iPhone reach the other's projection; the outbox
// overlay shows pending edits and drops them once acknowledged; a rejected
// snapshot is rebuilt from the stored, sealed rows without the network; rows
// stored before the observer existed are folded when it opens.
import CoreDomain
import CoreJSON
import CoreProjection
import CoreReplay
import CoreSync
import CoreTestSupport
import Foundation
import Testing

@Suite("Fold and project on pull (two iPhones, FakeServer)")
struct ObserverSyncTests {
  static func manual(_ a: inout OpAuthor, _ merchant: String, _ amount: Int64, at wallMs: Int64) throws -> String {
    try a.manualEntry(
      amountMinor: amount, currency: "AED", direction: "debit", localWallMs: wallMs, merchant: merchant, category: "dining")
  }

  @Test("A's ops fold into B's projection; both iPhones fold the same state")
  func roundTrip() async throws {
    let (w, a, b) = try await twoRuntimes()
    try await a.bootstrap()
    let wall = w.clock.nowMs() + LocalClock.offsetMs
    var id = ""
    try await a.author { x in id = try Self.manual(&x, "Zuma", 41_200, at: wall) }
    // Before the upload: A shows it pending.
    #expect(try a.reader.txn(id)?.pending == true)
    let out = await a.run(.authored)
    #expect(out.stop == nil && out.pushed.opsAcknowledged == 3)
    #expect(try a.reader.txn(id)?.pending == false)
    #expect(try a.reader.txn(id)?.amountHomeMinor == 41_200)

    #expect(await b.run(.launch).stop == nil)
    let row = try #require(try b.reader.txn(id))
    #expect(row.merchantRaw == "Zuma" && row.category == "dining" && !row.pending)
    #expect(try await a.state().serialized() == b.state().serialized())
    #expect(try b.context.store.foldSnapshot()?.cursorHot == b.context.store.syncState().cursorHot)

    // B edits; A sees it after its next run.
    let v = row.version
    try await b.author { x in x.categorize(txnID: id, parentVersion: v, category: "entertainment") }
    #expect(await b.run(.authored).stop == nil)
    #expect(await a.run(.foreground).stop == nil)
    #expect(try a.reader.txn(id)?.category == "entertainment")
  }

  @Test("a rejected snapshot is rebuilt from the stored rows: same state, no network")
  func coldRefold() async throws {
    let (w, a, b) = try await twoRuntimes()
    try await a.bootstrap()
    try await a.author { x in _ = try Self.manual(&x, "Talabat", 6_450, at: w.clock.nowMs() + LocalClock.offsetMs) }
    #expect(await a.run(.authored).stop == nil)
    #expect(await b.run(.launch).stop == nil)
    let before = try await b.state()
    try await b.context.store.db.write { db in try db.execute(sql: "UPDATE fold_snapshot SET fold_print = 'older semantics'") }
    let uploads = w.server.uploadCount
    let again = try Runtime(b.context)
    try await again.observer.open()
    #expect(try await again.state().serialized() == before.serialized())
    #expect(try await again.state() == before)
    #expect(w.server.uploadCount == uploads)
    let events = try b.context.store.foldEvents().map { "\($0.kind):\($0.detail)" }
    #expect(events.contains("snapshot_rejected:fold_print") && events.contains { $0.hasPrefix("cold_fold:") })
    #expect(try b.context.store.foldSnapshot()?.foldPrint == FoldCanary.foldPrint)
    #expect(try again.reader.activity().map(\.merchantRaw) == ["Talabat"])
  }

  @Test("rows pulled before the observer existed are folded when it opens")
  func observerLessRows() async throws {
    let (w, a, b) = try await twoRuntimes()
    try await a.bootstrap()
    try await a.author { x in _ = try Self.manual(&x, "Common Grounds", 8_100, at: w.clock.nowMs() + LocalClock.offsetMs) }
    #expect(await a.run(.authored).stop == nil)
    // B pulls with the bare engine (as builds before this one did): rows stored, nothing folded.
    #expect(await SyncEngine(context: b.context).run(.launch).stop == nil)
    #expect(try b.context.store.foldSnapshot() == nil && b.context.store.wireRowCount() > 0)
    let fresh = try Runtime(b.context)
    try await fresh.observer.open()
    #expect(try fresh.reader.activity().map(\.merchantRaw) == ["Common Grounds"])
    #expect(try await fresh.state().serialized() == a.state().serialized())
    #expect(try b.context.store.foldEvents().contains { $0.kind == "snapshot_rejected" && $0.detail == "absent" })
  }
}
