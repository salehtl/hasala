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
    let rows = try read { db in
      try Row.fetchAll(
        db,
        sql: "SELECT * FROM acknowledged_ops WHERE NOT (\(Self.foldedAcknowledged)) ORDER BY local_seq",
        arguments: [writerID.string, seq])
    }
    return rows.map {
      PendingOp(
        localSeq: $0["local_seq"], opID: $0["op_id"], opJSON: $0["op_json"], opType: $0["op_type"],
        entityKind: $0["entity_kind"], entityID: $0["entity_id"], enqueuedAt: $0["enqueued_at"])
    }
  }

  public func forgetAcknowledged(writerID: WriterID, foldedThrough seq: Int64) throws(StoreError) {
    try write { db in
      try db.execute(
        sql: "DELETE FROM acknowledged_ops WHERE \(Self.foldedAcknowledged)", arguments: [writerID.string, seq])
    }
  }
}
