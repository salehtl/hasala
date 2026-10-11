// The durable sync state (spec 04 §4.2): verified rows, pinned heads, the
// cursor, the authored head, pending ops and the in-flight batch. Every
// transaction boundary §5 names is one method here, so a crash between two
// statements of one step is impossible by construction:
//
//   persistPage      §5.2 step 6: rows + heads + cursor, one transaction
//   enqueue          §5.4: pending ops durable before the call returns
//   persistBatch     §5.5 step 4: the sealed, signed batch (R-OUT-2)
//   acknowledge      §5.5 step 6: inflight + pending deleted, authored head moved
import CorePrimitives
import CoreWire
import Foundation
import GRDB

public enum StoreError: Error, Sendable, Hashable {
  /// The database refused or failed (a GRDB error, by result code only:
  /// messages can carry values and are never logged).
  case database(code: Int32)
  /// The store holds no `store_meta` row (never created, or wiped).
  case notCreated
  /// A stored value is not the shape this build writes.
  case corrupt(String)
  /// `persistBatch` while another batch is in flight.
  case batchInFlight
  /// `persistBatch` with a batch that does not follow the authored head, or
  /// that carries an op no longer pending: it was sealed from a stale read.
  case staleBatch
}

/// `store_meta` (§4.2).
public struct StoreMeta: Sendable, Hashable {
  public let userID: UserID
  public let writerID: WriterID
  public let apiBase: String
  public let keyEpoch: UInt32
  public let createdAt: Int64

  public init(userID: UserID, writerID: WriterID, apiBase: String, keyEpoch: UInt32, createdAt: Int64) {
    self.userID = userID
    self.writerID = writerID
    self.apiBase = apiBase
    self.keyEpoch = keyEpoch
    self.createdAt = createdAt
  }
}

/// `sync_state.outbox_latch`.
public enum OutboxLatch: String, Sendable, Hashable, CaseIterable {
  case chainBreak = "chain_break"
  case hardStop = "hard_stop"
  case sealerFault = "sealer_fault"
  case accountFull = "account_full"
}

/// `sync_state` (§4.2).
public struct SyncStateRow: Sendable, Hashable {
  public var cursorHot: Int64
  /// This writer's last ACKED counter and hash (genesis: 0 and 32 zero bytes).
  public var authoredHead: Chain.Head
  public var checkpointJSON: Data?
  public var rosterJSON: Data?
  public var latch: OutboxLatch?
  public var epochHWM: UInt32
  public var logGeneration: Int64?
  public var lastPullAt: Int64?
  public var lastPushAt: Int64?
  public var lastFullCheckAt: Int64?
}

/// One verified row as `wire_rows` stores it.
public struct WireRowRecord: Sendable, Hashable {
  public enum Disposition: String, Sendable, Hashable {
    case folded
    case setAside = "set_aside"
    case alarm
  }

  public let seq: Int64
  public let writerID: WriterID
  public let counter: Int64
  public let sizeBucket: Int
  public let blobHash: Hash32
  public let prevHash: Hash32
  public let createdAt: String
  public let blob: Data
  public let headSig: Data?
  public let disposition: Disposition

  public init(
    seq: Int64, writerID: WriterID, counter: Int64, sizeBucket: Int, blobHash: Hash32, prevHash: Hash32,
    createdAt: String, blob: Data, headSig: Data?, disposition: Disposition
  ) {
    self.seq = seq
    self.writerID = writerID
    self.counter = counter
    self.sizeBucket = sizeBucket
    self.blobHash = blobHash
    self.prevHash = prevHash
    self.createdAt = createdAt
    self.blob = blob
    self.headSig = headSig
    self.disposition = disposition
  }
}

/// One op authored here and not yet acknowledged (`pending_ops`).
public struct PendingOp: Sendable, Hashable {
  public let localSeq: Int64
  public let opID: String
  /// The op's canonical JSON object (CoreJSON), as it will travel in a blob.
  public let opJSON: Data
  public let opType: String
  public let entityKind: String?
  public let entityID: String?
  public let enqueuedAt: Int64

  public init(
    localSeq: Int64 = 0, opID: String, opJSON: Data, opType: String, entityKind: String?, entityID: String?,
    enqueuedAt: Int64
  ) {
    self.localSeq = localSeq
    self.opID = opID
    self.opJSON = opJSON
    self.opType = opType
    self.entityKind = entityKind
    self.entityID = entityID
    self.enqueuedAt = enqueuedAt
  }
}

/// One sealed blob of the batch being uploaded (`inflight_blobs`, R-OUT-2).
public struct InflightBlob: Sendable, Hashable {
  public let counter: Int64
  public let batchID: String
  public let prevHash: Hash32
  public let blobHash: Hash32
  public let sizeBucket: Int
  public let blob: Data
  public let opIDs: [String]
  /// Non-nil on exactly the batch's last row.
  public let headSig: Data?
  public let createdAt: Int64

  public init(
    counter: Int64, batchID: String, prevHash: Hash32, blobHash: Hash32, sizeBucket: Int, blob: Data, opIDs: [String],
    headSig: Data?, createdAt: Int64
  ) {
    self.counter = counter
    self.batchID = batchID
    self.prevHash = prevHash
    self.blobHash = blobHash
    self.sizeBucket = sizeBucket
    self.blob = blob
    self.opIDs = opIDs
    self.headSig = headSig
    self.createdAt = createdAt
  }
}

public final class LedgerStore: Sendable {
  public let db: any DatabaseWriter

  /// Opens (creating if needed) `<directory>/ledger.sqlite` with §4.1's
  /// configuration, after asserting the directory's protection and backup
  /// exclusion; then migrates.
  public static func open(directory: URL) throws(StoreError) -> LedgerStore {
    do {
      try FileHygiene.prepareDirectory(directory)
      let url = directory.appendingPathComponent("ledger.sqlite")
      let pool = try DatabasePool(path: url.path, configuration: configuration())
      let store = try LedgerStore(db: pool)
      try FileHygiene.excludeDatabaseFiles(at: url)
      return store
    } catch let e as StoreError {
      throw e
    } catch let e as DatabaseError {
      throw .database(code: e.resultCode.rawValue)
    } catch {
      throw .corrupt("ledger.sqlite could not be opened")
    }
  }

  /// An in-memory store (tests).
  public static func inMemory() throws(StoreError) -> LedgerStore {
    do {
      return try LedgerStore(db: try DatabaseQueue(configuration: configuration()))
    } catch let e as StoreError {
      throw e
    } catch let e as DatabaseError {
      throw .database(code: e.resultCode.rawValue)
    } catch {
      throw .corrupt("in-memory store")
    }
  }

  /// §4.1: foreign keys on, 5 s busy timeout, at most 4 readers, secure delete.
  static func configuration() -> Configuration {
    var c = Configuration()
    c.foreignKeysEnabled = true
    c.busyMode = .timeout(5)
    c.maximumReaderCount = 4
    c.prepareDatabase { db in try db.execute(sql: "PRAGMA secure_delete = ON") }
    return c
  }

  init(db: any DatabaseWriter) throws(StoreError) {
    self.db = db
    try run { db in try LedgerSchema.migrator.migrate(db) }
  }

  @discardableResult
  func run<T>(_ body: @Sendable (DatabaseWriter) throws -> T) throws(StoreError) -> T {
    do {
      return try body(db)
    } catch let e as StoreError {
      throw e
    } catch let e as DatabaseError {
      throw .database(code: e.resultCode.rawValue)
    } catch {
      throw .corrupt("\(type(of: error))")
    }
  }

  func write<T>(_ body: @Sendable (Database) throws -> T) throws(StoreError) -> T {
    try run { w in try w.write(body) }
  }

  func read<T>(_ body: @Sendable (Database) throws -> T) throws(StoreError) -> T {
    try run { w in try w.read(body) }
  }

  // MARK: - Creation

  /// Creates the store's identity and sync state (enrolment). `logGeneration`
  /// is `meta.log_generation` seen now (§5.7 `server_restored`).
  public func create(_ meta: StoreMeta, epochHWM: UInt32 = 1, logGeneration: Int64? = nil) throws(StoreError) {
    try write { db in
      try db.execute(
        sql: """
          INSERT INTO store_meta (id, format, user_id, writer_id, api_base, key_epoch, created_at)
          VALUES (1, 1, ?, ?, ?, ?, ?)
          """,
        arguments: [meta.userID.string, meta.writerID.string, meta.apiBase, Int64(meta.keyEpoch), meta.createdAt])
      try db.execute(
        sql: "INSERT INTO sync_state (id, authored_hash, epoch_hwm, log_generation) VALUES (1, ?, ?, ?)",
        arguments: [Hash32.zero.bytes, Int64(epochHWM), logGeneration])
    }
  }

  public func meta() throws(StoreError) -> StoreMeta? {
    let row = try read { db in try Row.fetchOne(db, sql: "SELECT * FROM store_meta WHERE id = 1") }
    guard let row else { return nil }
    guard let u = UserID(row["user_id"] as String), let w = WriterID(row["writer_id"] as String) else {
      throw .corrupt("store_meta ids")
    }
    return StoreMeta(
      userID: u, writerID: w, apiBase: row["api_base"], keyEpoch: UInt32(row["key_epoch"] as Int64),
      createdAt: row["created_at"])
  }

  // MARK: - Sync state

  public func syncState() throws(StoreError) -> SyncStateRow {
    let row = try read { db in try Row.fetchOne(db, sql: "SELECT * FROM sync_state WHERE id = 1") }
    guard let row else { throw .notCreated }
    guard let h = Hash32(row["authored_hash"] as Data) else { throw .corrupt("authored_hash") }
    let latch: String? = row["outbox_latch"]
    return SyncStateRow(
      cursorHot: row["cursor_hot"], authoredHead: Chain.Head(counter: row["authored_counter"], hash: h),
      checkpointJSON: row["checkpoint_json"], rosterJSON: row["roster_json"],
      latch: latch.flatMap(OutboxLatch.init(rawValue:)), epochHWM: UInt32(row["epoch_hwm"] as Int64),
      logGeneration: row["log_generation"], lastPullAt: row["last_pull_at"], lastPushAt: row["last_push_at"],
      lastFullCheckAt: row["last_full_check_at"])
  }

  public func setLatch(_ latch: OutboxLatch?) throws(StoreError) {
    try write { db in
      try db.execute(sql: "UPDATE sync_state SET outbox_latch = ? WHERE id = 1", arguments: [latch?.rawValue])
    }
  }

  public func setEpochHWM(_ e: UInt32) throws(StoreError) {
    try write { db in
      try db.execute(
        sql: "UPDATE sync_state SET epoch_hwm = max(epoch_hwm, ?) WHERE id = 1", arguments: [Int64(e)])
    }
  }

  public func setRoster(_ json: Data) throws(StoreError) {
    try write { db in try db.execute(sql: "UPDATE sync_state SET roster_json = ? WHERE id = 1", arguments: [json]) }
  }

  public func setCheckpoint(_ json: Data?) throws(StoreError) {
    try write { db in
      try db.execute(sql: "UPDATE sync_state SET checkpoint_json = ? WHERE id = 1", arguments: [json])
    }
  }

  public func setLastPull(_ at: Int64) throws(StoreError) {
    try write { db in try db.execute(sql: "UPDATE sync_state SET last_pull_at = ? WHERE id = 1", arguments: [at]) }
  }

  /// Same-iPhone restore (§4.7 row 8): the authored head becomes the VERIFIED
  /// server head of this writer before anything is authored.
  public func setAuthoredHead(_ head: Chain.Head) throws(StoreError) {
    try write { db in
      try db.execute(
        sql: "UPDATE sync_state SET authored_counter = ?, authored_hash = ? WHERE id = 1",
        arguments: [head.counter, head.hash.bytes])
    }
  }

  // MARK: - Pulled rows

  public func chainHeads() throws(StoreError) -> [WriterID: Chain.Head] {
    let rows = try read { db in try Row.fetchAll(db, sql: "SELECT writer_id, counter, hash FROM chain_heads") }
    var out: [WriterID: Chain.Head] = [:]
    for r in rows {
      guard let w = WriterID(r["writer_id"] as String), let h = Hash32(r["hash"] as Data) else {
        throw .corrupt("chain_heads")
      }
      out[w] = Chain.Head(counter: r["counter"], hash: h)
    }
    return out
  }

  /// §5.2 step 6: the page's rows, the new heads and the cursor, in ONE
  /// transaction. Heads come from verified bodies only. `snapshot` is the fold
  /// snapshot the page's fold produced (§5.3), bound to the row at `cursor`, so
  /// the snapshot and the cursor commit together.
  public func persistPage(
    rows: [WireRowRecord], heads: [WriterID: Chain.Head], cursor: Int64, at: Int64,
    snapshot: FoldSnapshotChange = .keep
  ) throws(StoreError) {
    let tip = rows.last(where: { $0.seq == cursor }).map {
      Self.boundTip(seq: $0.seq, writerID: $0.writerID, counter: $0.counter, blobHash: $0.blobHash, prevHash: $0.prevHash)
    }
    try write { db in
      for r in rows {
        try db.execute(
          sql: """
            INSERT INTO wire_rows (seq, writer_id, writer_counter, type_flag, size_bucket, blob_hash, prev_hash,
                                   created_at, blob, head_sig, disposition)
            VALUES (?, ?, ?, 'edit', ?, ?, ?, ?, ?, ?, ?)
            """,
          arguments: [
            r.seq, r.writerID.string, r.counter, r.sizeBucket, r.blobHash.bytes, r.prevHash.bytes, r.createdAt, r.blob,
            r.headSig, r.disposition.rawValue,
          ])
      }
      for (w, h) in heads {
        try db.execute(
          sql: """
            INSERT INTO chain_heads (writer_id, counter, hash) VALUES (?, ?, ?)
            ON CONFLICT(writer_id) DO UPDATE SET counter = excluded.counter, hash = excluded.hash
            """,
          arguments: [w.string, h.counter, h.hash.bytes])
      }
      try db.execute(
        sql: "UPDATE sync_state SET cursor_hot = ?, last_pull_at = ? WHERE id = 1", arguments: [cursor, at])
      try Self.applySnapshot(snapshot, cursor: cursor, tip: tip, at: at, db)
    }
  }

  /// Rows above `seq`, oldest first (cold folds, audits).
  public func wireRows(after seq: Int64 = 0, limit: Int = 250) throws(StoreError) -> [WireRowRecord] {
    let rows = try read { db in
      try Row.fetchAll(
        db, sql: "SELECT * FROM wire_rows WHERE seq > ? ORDER BY seq LIMIT ?", arguments: [seq, limit])
    }
    return try rows.map { r throws(StoreError) in
      guard let w = WriterID(r["writer_id"] as String), let bh = Hash32(r["blob_hash"] as Data),
        let ph = Hash32(r["prev_hash"] as Data),
        let d = WireRowRecord.Disposition(rawValue: r["disposition"] as String)
      else { throw .corrupt("wire_rows") }
      return WireRowRecord(
        seq: r["seq"], writerID: w, counter: r["writer_counter"], sizeBucket: r["size_bucket"], blobHash: bh,
        prevHash: ph, createdAt: r["created_at"], blob: r["blob"], headSig: r["head_sig"], disposition: d)
    }
  }

  public func wireRowCount() throws(StoreError) -> Int {
    try read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM wire_rows") ?? 0 }
  }

  // MARK: - Pending ops (§5.4)

  /// Inserts `ops` in one transaction; durable when this returns.
  public func enqueue(_ ops: [PendingOp]) throws(StoreError) {
    try write { db in
      for op in ops {
        try db.execute(
          sql: """
            INSERT INTO pending_ops (op_id, op_json, op_type, entity_kind, entity_id, enqueued_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
          arguments: [op.opID, op.opJSON, op.opType, op.entityKind, op.entityID, op.enqueuedAt])
      }
    }
  }

  public func pendingOps(limit: Int = 10_000) throws(StoreError) -> [PendingOp] {
    let rows = try read { db in
      try Row.fetchAll(db, sql: "SELECT * FROM pending_ops ORDER BY local_seq LIMIT ?", arguments: [limit])
    }
    return rows.map {
      PendingOp(
        localSeq: $0["local_seq"], opID: $0["op_id"], opJSON: $0["op_json"], opType: $0["op_type"],
        entityKind: $0["entity_kind"], entityID: $0["entity_id"], enqueuedAt: $0["enqueued_at"])
    }
  }

  public func pendingCount() throws(StoreError) -> Int {
    try read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM pending_ops") ?? 0 }
  }

  // MARK: - The in-flight batch (§5.5, R-OUT-2/3)

  /// Persists a sealed, signed batch in one transaction (write-ahead).
  public func persistBatch(_ blobs: [InflightBlob]) throws(StoreError) {
    try write { db in
      guard try Int.fetchOne(db, sql: "SELECT count(*) FROM inflight_blobs") == 0 else {
        throw StoreError.batchInFlight
      }
      // The batch must continue the authored head and seal only pending ops,
      // checked inside this transaction (a defence behind the engine's
      // one-run-at-a-time rule: a batch sealed from a stale read would put a
      // duplicate op in the shared log).
      guard let first = blobs.first,
        let head = try Row.fetchOne(db, sql: "SELECT authored_counter, authored_hash FROM sync_state WHERE id = 1"),
        first.counter == (head["authored_counter"] as Int64) + 1,
        first.prevHash.bytes == (head["authored_hash"] as Data)
      else { throw StoreError.staleBatch }
      var expected = first.counter
      var prev = first.prevHash
      var seen = Set<String>()
      for b in blobs {
        guard b.counter == expected, b.prevHash == prev else { throw StoreError.staleBatch }
        expected += 1
        prev = b.blobHash
        for id in b.opIDs {
          guard seen.insert(id).inserted,
            try Int.fetchOne(db, sql: "SELECT count(*) FROM pending_ops WHERE op_id = ?", arguments: [id]) == 1
          else { throw StoreError.staleBatch }
        }
      }
      for b in blobs {
        let ids = try JSONEncoder().encode(b.opIDs)
        try db.execute(
          sql: """
            INSERT INTO inflight_blobs (writer_counter, batch_id, prev_hash, blob_hash, size_bucket, blob,
                                        op_ids_json, head_sig, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
          arguments: [
            b.counter, b.batchID, b.prevHash.bytes, b.blobHash.bytes, b.sizeBucket, b.blob, ids, b.headSig,
            b.createdAt,
          ])
      }
    }
  }

  /// The in-flight batch, counters ascending (empty when none).
  public func inflight() throws(StoreError) -> [InflightBlob] {
    let rows = try read { db in try Row.fetchAll(db, sql: "SELECT * FROM inflight_blobs ORDER BY writer_counter") }
    return try rows.map { r throws(StoreError) in
      guard let ph = Hash32(r["prev_hash"] as Data), let bh = Hash32(r["blob_hash"] as Data),
        let ids = try? JSONDecoder().decode([String].self, from: r["op_ids_json"] as Data)
      else { throw .corrupt("inflight_blobs") }
      return InflightBlob(
        counter: r["writer_counter"], batchID: r["batch_id"], prevHash: ph, blobHash: bh,
        sizeBucket: r["size_bucket"], blob: r["blob"], opIDs: ids, headSig: r["head_sig"],
        createdAt: r["created_at"])
    }
  }

  /// §5.5 step 6 (and a 409 resend's already-stored rows): the acknowledged
  /// blobs and their ops leave, and the authored head moves to `head`.
  public func acknowledge(counters: [Int64], head: Chain.Head, at: Int64) throws(StoreError) {
    try write { db in
      for c in counters {
        guard
          let ids = try Data.fetchOne(
            db, sql: "SELECT op_ids_json FROM inflight_blobs WHERE writer_counter = ?", arguments: [c])
        else { continue }
        for id in try JSONDecoder().decode([String].self, from: ids) {
          try db.execute(sql: "DELETE FROM pending_ops WHERE op_id = ?", arguments: [id])
        }
        try db.execute(sql: "DELETE FROM inflight_blobs WHERE writer_counter = ?", arguments: [c])
      }
      try db.execute(
        sql: """
          UPDATE sync_state SET authored_counter = max(authored_counter, ?),
            authored_hash = CASE WHEN ? >= authored_counter THEN ? ELSE authored_hash END,
            last_push_at = ? WHERE id = 1
          """,
        arguments: [head.counter, head.counter, head.hash.bytes, at])
    }
  }

  /// Discards the in-flight batch WITHOUT acknowledging it: only after a
  /// definitive refusal that stored nothing (`409 stale_epoch`, R-OUT-4). The
  /// ops stay pending and are sealed again.
  public func discardInflight() throws(StoreError) {
    try write { db in try db.execute(sql: "DELETE FROM inflight_blobs") }
  }

  // MARK: - Fold events (content-free ring of 64)

  public func recordFoldEvent(kind: String, detail: String, at: Int64) throws(StoreError) {
    try write { db in
      try db.execute(
        sql: "INSERT INTO fold_events (at, kind, detail) VALUES (?, ?, ?)", arguments: [at, kind, detail])
      try Self.pruneFoldEvents(db)
    }
  }

  /// `fold_events` keeps its newest 64 entries.
  static func pruneFoldEvents(_ db: Database) throws {
    try db.execute(
      sql: "DELETE FROM fold_events WHERE id NOT IN (SELECT id FROM fold_events ORDER BY id DESC LIMIT 64)")
  }

  public func foldEvents() throws(StoreError) -> [(kind: String, detail: String)] {
    let rows = try read { db in try Row.fetchAll(db, sql: "SELECT kind, detail FROM fold_events ORDER BY id") }
    return rows.map { (kind: $0["kind"] as String, detail: $0["detail"] as String) }
  }
}
