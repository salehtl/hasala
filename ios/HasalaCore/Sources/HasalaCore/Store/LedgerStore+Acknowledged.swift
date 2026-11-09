import CorePrimitives
import Foundation
import GRDB

extension LedgerSchema {
  static let acknowledgedOps = [
    """
    CREATE TABLE acknowledged_ops (
      local_seq      INTEGER PRIMARY KEY,
      op_id          TEXT    NOT NULL UNIQUE,
      op_json        BLOB    NOT NULL,
      op_type        TEXT    NOT NULL,
      entity_kind    TEXT, entity_id TEXT,
      enqueued_at    INTEGER NOT NULL,
      writer_counter INTEGER NOT NULL
    )
    """
  ]
}

extension LedgerStore {
  static let foldedAcknowledged = """
    writer_counter IN (SELECT writer_counter FROM wire_rows WHERE writer_id = ? AND seq <= ?)
    """

  public func acknowledgedOps(writerID: WriterID, foldedThrough seq: Int64) throws(StoreError) -> [PendingOp] {
    let rows = try read { db in try Self.unfoldedAcknowledged(db, writerID: writerID, foldedThrough: seq) }
    return rows.map(Self.pendingOp)
  }

  public func outboxOverlay(writerID: WriterID, foldedThrough seq: Int64) throws(StoreError) -> [PendingOp] {
    let rows = try read { db in
      try Self.unfoldedAcknowledged(db, writerID: writerID, foldedThrough: seq) + Self.pendingRows(db, limit: 10_000)
    }
    return rows.map(Self.pendingOp)
  }

  private static func unfoldedAcknowledged(_ db: Database, writerID: WriterID, foldedThrough seq: Int64) throws -> [Row] {
    try Row.fetchAll(
      db,
      sql: "SELECT * FROM acknowledged_ops WHERE NOT (\(foldedAcknowledged)) ORDER BY local_seq",
      arguments: [writerID.string, seq])
  }

  public func forgetAcknowledged(writerID: WriterID, foldedThrough seq: Int64) throws(StoreError) {
    try write { db in
      try db.execute(
        sql: "DELETE FROM acknowledged_ops WHERE \(Self.foldedAcknowledged)", arguments: [writerID.string, seq])
    }
  }
}
