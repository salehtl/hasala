// The fold snapshot row (spec 04 §5.3): written with its page, bound to the
// row at the cursor, and every load check in order (version, fold print,
// bound tip, digest, cursor), each rejection deleting the row and leaving a
// content-free fold event. Also the pending-op reads the authors use.
import CorePrimitives
import CoreWire
import Foundation
import GRDB
import Testing

@testable import CoreStore

@Suite("CoreStore: fold snapshot and pending reads")
struct FoldSnapshotStoreTests {
  static let print = "0123456789abcdef0123456789abcdef"

  static func row(_ seq: Int64, _ counter: Int64, prev: Hash32) -> WireRowRecord {
    WireRowRecord(
      seq: seq, writerID: other, counter: counter, sizeBucket: 1024, blobHash: h(UInt8(seq)), prevHash: prev, createdAt: "t",
      blob: Data(count: 1024), headSig: nil, disposition: .folded)
  }

  /// A store with rows 1-2 and a snapshot saved with the page.
  static func stored(payload: Data = Data("state".utf8)) throws -> LedgerStore {
    let s = try created()
    try s.persistPage(
      rows: [row(1, 1, prev: .zero), row(2, 2, prev: h(1))], heads: [other: Chain.Head(counter: 2, hash: h(2))], cursor: 2,
      at: 5, snapshot: .save(foldPrint: print, payload: payload))
    return s
  }

  static func events(_ s: LedgerStore) throws -> [String] { try s.foldEvents().map { "\($0.kind):\($0.detail)" } }

  @Test("bound_tip is SHA-256 of seq, \"hot\", writer, counter (decimal, NUL-separated), blob hash and prev hash")
  func boundTip() throws {
    var b = Data("2".utf8)
    b.append(0)
    b.append(Data("hot".utf8))
    b.append(0)
    b.append(Data(other.string.utf8))
    b.append(0)
    b.append(Data("2".utf8))
    b.append(0)
    b.append(h(2).bytes)
    b.append(h(1).bytes)
    #expect(LedgerStore.boundTip(seq: 2, writerID: other, counter: 2, blobHash: h(2), prevHash: h(1)) == sha256(b))
    let s = try Self.stored()
    #expect(try s.boundTip(at: 2) == sha256(b))
    #expect(try s.boundTip(at: 3) == nil)
  }

  @Test("persistPage writes the snapshot in the page's transaction, at the page's cursor")
  func savedWithPage() throws {
    let s = try Self.stored()
    let r = try #require(try s.foldSnapshot())
    #expect(r.version == FoldSnapshotRecord.currentVersion && r.foldPrint == Self.print && r.cursorHot == 2 && r.savedAt == 5)
    #expect(r.boundTip == (try s.boundTip(at: 2)) && r.digest == sha256(Data("state".utf8)) && r.payload == Data("state".utf8))
    #expect(try s.db.read { db in try Int.fetchOne(db, sql: "SELECT bytes FROM fold_snapshot") } == 5)
    guard case .success(let loaded)? = try s.loadFoldSnapshot(foldPrint: Self.print, at: 6) else {
      Issue.record("the snapshot did not load")
      return
    }
    #expect(loaded == r)
    // A page that fails rolls the snapshot back with it.
    let dup = Self.row(3, 2, prev: h(2))
    #expect(throws: StoreError.self) {
      try s.persistPage(rows: [dup], heads: [:], cursor: 3, at: 7, snapshot: .save(foldPrint: Self.print, payload: Data("new".utf8)))
    }
    #expect(try s.foldSnapshot()?.payload == Data("state".utf8))
    // `.delete` removes it; `.keep` leaves it.
    try s.persistPage(rows: [Self.row(3, 3, prev: h(2))], heads: [:], cursor: 3, at: 8, snapshot: .delete)
    #expect(try s.foldSnapshot() == nil)
  }

  @Test("each load check rejects in order, deletes the row and records why")
  func rejections() throws {
    // Absent while rows exist (cursor 0 is a fresh store: nothing to report).
    let fresh = try created()
    #expect(try fresh.loadFoldSnapshot(foldPrint: Self.print, at: 1) == nil)
    let bare = try created()
    try bare.persistPage(rows: [Self.row(1, 1, prev: .zero)], heads: [:], cursor: 1, at: 1)
    #expect(try bare.loadFoldSnapshot(foldPrint: Self.print, at: 2) == .failure(.absent))
    #expect(try Self.events(bare) == ["snapshot_rejected:absent"])

    func check(_ change: (LedgerStore) throws -> Void, _ want: FoldSnapshotRejection) throws {
      let s = try Self.stored()
      try change(s)
      #expect(try s.loadFoldSnapshot(foldPrint: Self.print, at: 9) == .failure(want))
      #expect(try s.foldSnapshot() == nil)
      #expect(try Self.events(s).last == "snapshot_rejected:\(want.rawValue)")
    }
    try check({ s in try s.db.write { db in try db.execute(sql: "UPDATE fold_snapshot SET version = 99") } }, .version)
    try check({ s in try s.db.write { db in try db.execute(sql: "UPDATE fold_snapshot SET fold_print = 'other'") } }, .foldPrint)
    try check({ s in try s.db.write { db in try db.execute(sql: "UPDATE fold_snapshot SET bound_tip = zeroblob(32)") } }, .logDiverged)
    try check({ s in try s.db.write { db in try db.execute(sql: "UPDATE fold_snapshot SET payload = x'00'") } }, .corrupt)
    try check({ s in try s.persistPage(rows: [Self.row(3, 3, prev: h(2))], heads: [:], cursor: 3, at: 8) }, .cursorDisagreement)
    // The caller's own decode check.
    let s = try Self.stored()
    try s.rejectFoldSnapshot(.undecodable, at: 9)
    #expect(try s.foldSnapshot() == nil && Self.events(s) == ["snapshot_rejected:undecodable"])
  }

  @Test("a payload over the 6 MB budget is not kept; a cold fold saves at the store's own cursor")
  func budgetAndStandalone() throws {
    let s = try Self.stored(payload: Data(count: FoldSnapshotRecord.byteBudget + 1))
    #expect(try s.foldSnapshot() == nil)
    #expect(try Self.events(s) == ["snapshot_skipped:over_budget"])
    #expect(try s.saveFoldSnapshot(foldPrint: Self.print, payload: Data("cold".utf8), at: 3))
    #expect(try s.foldSnapshot()?.cursorHot == 2 && s.foldSnapshot()?.boundTip == s.boundTip(at: 2))
    #expect(try !created().saveFoldSnapshot(foldPrint: Self.print, payload: Data("x".utf8), at: 1))  // no row at cursor 0
  }

  @Test("pending reads: ingest ids by exact member, the newest stamp as canonical text")
  func pending() throws {
    let s = try created()
    #expect(try s.latestPendingAuthoredAt() == nil)
    let ingest = String(repeating: "ab", count: 32)
    func op(_ id: String, _ type: String, _ at: String, ingest: String? = nil) -> PendingOp {
      let i = ingest.map { #","ingest_id":"\#($0)""# } ?? ""
      let json = #"{"v":4,"type":"\#(type)","op_id":"\#(id)","authored_at":"\#(at)","parent_version":null\#(i),"payload":{}}"#
      return PendingOp(opID: id, opJSON: Data(json.utf8), opType: type, entityKind: nil, entityID: nil, enqueuedAt: 1)
    }
    try s.enqueue([
      op("a", "txn_ingested", "2026-10-10T09:40:00.002Z", ingest: ingest), op("b", "merchant_named", "2026-10-10T09:40:00.010Z"),
      op("c", "rate_set", "2026-10-09T09:40:00.000Z"),
    ])
    #expect(try s.hasPendingIngest(ingest))
    #expect(try !s.hasPendingIngest(String(repeating: "cd", count: 32)))
    #expect(try !s.hasPendingIngest("%"))
    #expect(try !s.hasPendingIngest(String(repeating: "AB", count: 32)))
    #expect(try s.latestPendingAuthoredAt() == "2026-10-10T09:40:00.010Z")
  }
}
