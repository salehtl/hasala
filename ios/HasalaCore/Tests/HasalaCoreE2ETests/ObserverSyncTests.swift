// Fold and project on pull, end to end over FakeServer (spec 04 §5.2-§5.3,
// §4.3): ops authored on one iPhone reach the other's projection; the outbox
// overlay shows pending edits and drops them once acknowledged; a rejected
// snapshot is rebuilt from the stored, sealed rows without the network; rows
// stored before the observer existed are folded when it opens.
import CoreCrypto
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

  @Test("ops finds ops in sealed stored rows, newest first, and tells a missing id from a failed lookup")
  func opsLookup() async throws {
    let (w, a, b) = try await twoRuntimes()
    try await a.bootstrap()
    var ids: [String] = []
    for (i, m) in ["Zuma", "Talabat", "Careem"].enumerated() {
      let blob = try await a.author { x in _ = try Self.manual(&x, m, 1_000 + Int64(i), at: w.clock.nowMs() + LocalClock.offsetMs) }
      ids.append(blob.ops[0].opID)
      #expect(await a.run(.authored).stop == nil)
    }
    #expect(await b.run(.launch).stop == nil)
    let r = await b.observer.ops(Set(ids + ["op-nowhere"]))
    #expect(Set(r.found.keys) == Set(ids) && r.found.values.allSatisfy { ids.contains($0.opID) })
    #expect(r.missing == ["op-nowhere"] && r.failed.isEmpty)
    let newest = await b.observer.ops([ids[2]])
    #expect(newest.found.keys.sorted() == [ids[2]] && newest.missing.isEmpty && newest.failed.isEmpty)
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

  @Test("a stored row that no longer opens as it did (a changed epoch key) is the integrity alarm and a halt, not a smaller state")
  func coldRefoldRowNoLongerOpens() async throws {
    let (w, a, b) = try await twoRuntimes()
    try await a.bootstrap()
    try await a.author { x in _ = try Self.manual(&x, "Talabat", 6_450, at: w.clock.nowMs() + LocalClock.offsetMs) }
    #expect(await a.run(.authored).stop == nil)
    #expect(await b.run(.launch).stop == nil)
    #expect(try b.reader.activity().count == 1)
    let snapshot = try #require(try b.context.store.foldSnapshot())
    // B's epoch-1 key is replaced (corrupted), and the snapshot is from older fold semantics.
    try b.context.secrets.writeEpochKey(Data(repeating: 0x5A, count: 32), userID: b.context.userID, epoch: 1)
    try await b.context.store.db.write { db in try db.execute(sql: "UPDATE fold_snapshot SET fold_print = 'older semantics'") }
    let again = try Runtime(b.context, projection: b.projection)
    await #expect(throws: SyncStop.halted(.inconsistent("cold_fold_disposition"))) { try await again.observer.open() }
    let events = try b.context.store.foldEvents().map { "\($0.kind):\($0.detail)" }
    #expect(events.contains("integrity_alarm:cold_fold_disposition"))
    #expect(!events.contains { $0.hasPrefix("cold_fold:") })
    // Nothing smaller replaced what B had: no new snapshot, the projection untouched.
    #expect(try b.context.store.foldSnapshot() == nil && snapshot.cursorHot > 0)
    #expect(try b.reader.activity().map(\.merchantRaw) == ["Talabat"])
  }

  @Test("a row an older build set aside is read when an update's cold fold opens it")
  func coldRefoldRereadsSetAside() async throws {
    let (w, a, b) = try await twoRuntimes()
    try await a.bootstrap()
    try await a.author { x in _ = try Self.manual(&x, "Talabat", 6_450, at: w.clock.nowMs() + LocalClock.offsetMs) }
    #expect(await a.run(.authored).stop == nil)
    #expect(await b.run(.launch).stop == nil)
    let full = try await a.state()
    try await b.context.store.db.write { db in
      try db.execute(sql: "UPDATE wire_rows SET disposition = 'set_aside'")
      try db.execute(sql: "UPDATE fold_snapshot SET fold_print = 'older semantics'")
    }
    let again = try Runtime(b.context, projection: b.projection)
    try await again.observer.open()
    #expect(try await again.state().serialized() == full.serialized())
    #expect(try await again.state().unreadable.isEmpty)
    #expect(try again.reader.activity().map(\.merchantRaw) == ["Talabat"])
    let events = try b.context.store.foldEvents().map { "\($0.kind):\($0.detail)" }
    #expect(events.contains { $0.hasPrefix("set_aside_reread:rows_") })
    #expect(!events.contains { $0.hasPrefix("integrity_alarm") })
  }

  @Test("a next-version row set aside under the ceiling stays set aside through a cold fold")
  func coldRefoldKeepsUnshippedSetAside() async throws {
    let (w, a, b) = try await twoRuntimes()
    try await a.bootstrap()
    try await a.author { x in _ = try Self.manual(&x, "Talabat", 6_450, at: w.clock.nowMs() + LocalClock.offsetMs) }
    #expect(await a.run(.authored).stop == nil)
    #expect(await b.run(.launch).stop == nil)
    let ctx = a.context
    let k1 = try EpochKey(epoch: 1, key: try #require(try ctx.secrets.epochKey(userID: ctx.userID, epoch: 1)))
    let seed = try #require(try ctx.secrets.writerSeed(userID: ctx.userID, writerID: ctx.writerID))
    let head = try #require(try ctx.store.chainHeads()[ctx.writerID])
    let counter = head.counter + 1
    let frame = try Sealer(epoch: 1, key: k1).seal(
      plaintextOps: Data(#"{"v":\#(SchemaVersion.current + 1),"kind":"ops","ops":[]}"#.utf8),
      envelope: try Envelope(userID: ctx.userID, writerID: ctx.writerID, counter: counter),
      prevHash: head.hash, random: SeededRandom(seed: "unshipped"))
    let msg = SigningMessage.head(userID: ctx.userID, counter: counter, blobHash: frame.blobHash, writerID: ctx.writerID)
    w.server.injectRow(
      user: ctx.userID, writerID: ctx.writerID.string, counter: counter, prevHash: head.hash.bytes, blob: frame.bytes,
      headSig: try DWK.sign(seed: seed, message: msg))
    w.server.setOpVersionCeiling(SchemaVersion.current)
    #expect(await b.run(.foreground).stop == nil)
    #expect(try b.context.store.wireRows().last?.disposition == .setAside)

    w.server.setOpVersionCeiling(nil)
    try await b.context.store.db.write { db in
      try db.execute(sql: "UPDATE fold_snapshot SET fold_print = 'older semantics'")
    }
    let again = try Runtime(b.context, projection: b.projection)
    try await again.observer.open()
    #expect(try again.reader.activity().map(\.merchantRaw) == ["Talabat"])
    let events = try b.context.store.foldEvents().map { "\($0.kind):\($0.detail)" }
    #expect(!events.contains { $0.hasPrefix("integrity_alarm") })
  }

  @Test("a row stored as opened that a cold fold sets aside still halts")
  func coldRefoldFoldedToSetAsideHalts() async throws {
    let (w, a, b) = try await twoRuntimes()
    try await a.bootstrap()
    try await a.author { x in _ = try Self.manual(&x, "Talabat", 6_450, at: w.clock.nowMs() + LocalClock.offsetMs) }
    #expect(await a.run(.authored).stop == nil)
    #expect(await b.run(.launch).stop == nil)
    try await b.context.store.db.write { db in
      try db.execute(sql: "UPDATE wire_rows SET disposition = 'alarm'")
      try db.execute(sql: "UPDATE fold_snapshot SET fold_print = 'older semantics'")
    }
    let again = try Runtime(b.context, projection: b.projection)
    await #expect(throws: SyncStop.halted(.inconsistent("cold_fold_disposition"))) { try await again.observer.open() }
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
