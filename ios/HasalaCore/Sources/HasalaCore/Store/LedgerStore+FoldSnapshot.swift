// `fold_snapshot` (spec 04 §4.2, §5.3): the saved fold, bound to the log it
// was folded from.
//
//   bound_tip = SHA256(seq ‖ 0x00 ‖ "hot" ‖ 0x00 ‖ writer_id ‖ 0x00 ‖ writer_counter ‖ 0x00
//                      ‖ blob_hash ‖ prev_hash)
//
// over the `wire_rows` row at `cursor_hot` (integers as decimal ASCII, hashes as
// their 32 raw bytes), and `digest` = SHA256(payload). The payload's format and
// fold fingerprint belong to CoreReplay (`StateSnapshot`); this file only keeps
// the row and the checks that need the log.
//
// The snapshot is written in the same transaction as the page it follows
// (`persistPage(..., snapshot:)`), so its cursor and the store's cursor never
// disagree after a commit. Loading checks it cheapest-first and reports the
// first rejection; a rejected row is deleted and the caller cold-folds.
import CorePrimitives
import CoreWire
import Foundation
import GRDB

/// One `fold_snapshot` row.
public struct FoldSnapshotRecord: Sendable, Hashable {
  /// The row layout this build writes (`version`).
  public static let currentVersion = 1
  /// §5.3: above this many payload bytes no snapshot is kept.
  public static let byteBudget = 6_000_000

  public var version: Int
  /// The first 32 hex of the fold fingerprint (`FoldCanary.foldPrint`).
  public var foldPrint: String
  public var cursorHot: Int64
  public var boundTip: Data
  public var digest: Data
  public var payload: Data
  public var savedAt: Int64

  public init(
    version: Int = FoldSnapshotRecord.currentVersion, foldPrint: String, cursorHot: Int64, boundTip: Data, digest: Data,
    payload: Data, savedAt: Int64
  ) {
    self.version = version
    self.foldPrint = foldPrint
    self.cursorHot = cursorHot
    self.boundTip = boundTip
    self.digest = digest
    self.payload = payload
    self.savedAt = savedAt
  }
}

/// What a page's transaction does to the snapshot row.
public enum FoldSnapshotChange: Sendable, Hashable {
  /// Leave the row as it is.
  case keep
  /// Replace it with `payload` (a `StateSnapshot` encoding), bound to the page's last row.
  case save(foldPrint: String, payload: Data)
  /// Remove it (the state outgrew the budget, or could not be encoded).
  case delete
}

/// Why a stored snapshot was not used (§5.3 load order), as `fold_events` details.
public enum FoldSnapshotRejection: String, Error, Sendable, Hashable {
  /// No row, while the store holds folded rows.
  case absent
  case version
  case foldPrint = "fold_print"
  /// `bound_tip` names another row than the one at the cursor.
  case logDiverged = "log_diverged"
  /// `digest` does not match the payload.
  case corrupt
  /// The payload did not decode (reported by the caller, which owns the format).
  case undecodable
  /// The snapshot's cursor is not the store's.
  case cursorDisagreement = "cursor_disagreement"
}

extension LedgerStore {
  /// `bound_tip` of one row identity.
  public static func boundTip(seq: Int64, writerID: WriterID, counter: Int64, blobHash: Hash32, prevHash: Hash32) -> Data {
    var b = Data()
    b.append(contentsOf: Array(String(seq).utf8))
    b.append(0)
    b.append(contentsOf: Array("hot".utf8))
    b.append(0)
    b.append(contentsOf: Array(writerID.string.utf8))
    b.append(0)
    b.append(contentsOf: Array(String(counter).utf8))
    b.append(0)
    b.append(blobHash.bytes)
    b.append(prevHash.bytes)
    return sha256(b)
  }

  /// `bound_tip` over the stored row at `seq`; nil when there is none.
  public func boundTip(at seq: Int64) throws(StoreError) -> Data? {
    let row = try read { db in
      try Row.fetchOne(
        db, sql: "SELECT writer_id, writer_counter, blob_hash, prev_hash FROM wire_rows WHERE seq = ?", arguments: [seq])
    }
    guard let row else { return nil }
    guard let w = WriterID(row["writer_id"] as String), let bh = Hash32(row["blob_hash"] as Data),
      let ph = Hash32(row["prev_hash"] as Data)
    else { throw .corrupt("wire_rows") }
    return Self.boundTip(seq: seq, writerID: w, counter: row["writer_counter"], blobHash: bh, prevHash: ph)
  }

  /// The stored snapshot row, unchecked.
  public func foldSnapshot() throws(StoreError) -> FoldSnapshotRecord? {
    let row = try read { db in try Row.fetchOne(db, sql: "SELECT * FROM fold_snapshot WHERE id = 1") }
    guard let row else { return nil }
    return FoldSnapshotRecord(
      version: row["version"], foldPrint: row["fold_print"], cursorHot: row["cursor_hot"], boundTip: row["bound_tip"],
      digest: row["digest"], payload: row["payload"], savedAt: row["saved_at"])
  }

  /// The stored snapshot when every check this store can make passes (§5.3:
  /// version, fold print, bound tip, digest, cursor); otherwise the row is
  /// deleted, a `fold_events` entry is written, and the rejection is returned.
  /// `.absent` is returned (and recorded) only when the store holds rows.
  /// Decoding the payload is the caller's last check (`rejectFoldSnapshot`).
  public func loadFoldSnapshot(foldPrint: String, at now: Int64) throws(StoreError) -> Result<
    FoldSnapshotRecord, FoldSnapshotRejection
  >? {
    let cursor = try syncState().cursorHot
    guard let r = try foldSnapshot() else {
      guard cursor > 0 else { return nil }
      try recordFoldEvent(kind: "snapshot_rejected", detail: FoldSnapshotRejection.absent.rawValue, at: now)
      return .failure(.absent)
    }
    var rejection: FoldSnapshotRejection?
    if r.version != FoldSnapshotRecord.currentVersion {
      rejection = .version
    } else if r.foldPrint != foldPrint {
      rejection = .foldPrint
    } else if try boundTip(at: r.cursorHot) != r.boundTip {
      rejection = .logDiverged
    } else if sha256(r.payload) != r.digest {
      rejection = .corrupt
    } else if r.cursorHot != cursor {
      rejection = .cursorDisagreement
    }
    if let rejection {
      try rejectFoldSnapshot(rejection, at: now)
      return .failure(rejection)
    }
    return .success(r)
  }

  /// Deletes the snapshot row and records why.
  public func rejectFoldSnapshot(_ why: FoldSnapshotRejection, at now: Int64) throws(StoreError) {
    try write { db in try db.execute(sql: "DELETE FROM fold_snapshot") }
    try recordFoldEvent(kind: "snapshot_rejected", detail: why.rawValue, at: now)
  }

  /// Saves `payload` as the snapshot at the store's current cursor (after a
  /// cold fold, which writes no page). Nothing is saved when the store holds no
  /// row at the cursor (cursor 0), or above the byte budget.
  @discardableResult
  public func saveFoldSnapshot(foldPrint: String, payload: Data, at now: Int64) throws(StoreError) -> Bool {
    try write { db in
      try Self.applySnapshot(.save(foldPrint: foldPrint, payload: payload), cursor: nil, tip: nil, at: now, db)
    }
  }

  /// Writes `change` inside a transaction. `cursor` and `tip` are the page's
  /// (nil: read the store's own cursor and the row there). Returns whether a
  /// snapshot row was written.
  @discardableResult
  static func applySnapshot(_ change: FoldSnapshotChange, cursor: Int64?, tip: Data?, at now: Int64, _ db: Database)
    throws -> Bool
  {
    switch change {
    case .keep:
      return false
    case .delete:
      try db.execute(sql: "DELETE FROM fold_snapshot")
      return false
    case .save(let print, let payload):
      guard payload.count <= FoldSnapshotRecord.byteBudget else {
        try db.execute(sql: "DELETE FROM fold_snapshot")
        try db.execute(
          sql: "INSERT INTO fold_events (at, kind, detail) VALUES (?, 'snapshot_skipped', 'over_budget')", arguments: [now])
        return false
      }
      let c: Int64
      if let cursor {
        c = cursor
      } else {
        c = try Int64.fetchOne(db, sql: "SELECT cursor_hot FROM sync_state WHERE id = 1") ?? 0
      }
      var boundTip = tip
      if boundTip == nil, c > 0,
        let row = try Row.fetchOne(
          db, sql: "SELECT writer_id, writer_counter, blob_hash, prev_hash FROM wire_rows WHERE seq = ?", arguments: [c]),
        let w = WriterID(row["writer_id"] as String), let bh = Hash32(row["blob_hash"] as Data),
        let ph = Hash32(row["prev_hash"] as Data)
      {
        boundTip = Self.boundTip(seq: c, writerID: w, counter: row["writer_counter"], blobHash: bh, prevHash: ph)
      }
      guard let boundTip else {
        try db.execute(sql: "DELETE FROM fold_snapshot")
        return false
      }
      try db.execute(
        sql: """
          INSERT INTO fold_snapshot (id, version, fold_print, cursor_hot, bound_tip, digest, payload, bytes, saved_at)
          VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(id) DO UPDATE SET version = excluded.version, fold_print = excluded.fold_print,
            cursor_hot = excluded.cursor_hot, bound_tip = excluded.bound_tip, digest = excluded.digest,
            payload = excluded.payload, bytes = excluded.bytes, saved_at = excluded.saved_at
          """,
        arguments: [
          FoldSnapshotRecord.currentVersion, print, c, boundTip, sha256(payload), payload, payload.count, now,
        ])
      return true
    }
  }
}
