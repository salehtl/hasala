// Reads over `pending_ops` that the authors need without decoding every op:
//
//   - the Gmail lane's "already authored here?" check (spec 04 §7.5): an ingest
//     id that sits in `pending_ops` was authored on this device and must not be
//     authored again, even before the op uploads and folds;
//   - the author rule's `own_last_ms` (03c §1.8.2, 04 §5.4): the newest
//     `authored_at` still pending.
//
// Pending ops are canonical op JSON (CoreJSON's writer): no whitespace, so a
// member reads exactly `"name":"value"`, and `authored_at` is always the
// canonical 24-byte instant, which sorts as text.
import Foundation
import GRDB

extension LedgerStore {
  /// Whether a pending `txn_ingested` or `txn_superseded` carries `ingestID`
  /// (64 lower-case hex; anything else is never pending).
  public func hasPendingIngest(_ ingestID: String) throws(StoreError) -> Bool {
    let u = Array(ingestID.utf8)
    guard u.count == 64, u.allSatisfy({ (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }) else { return false }
    // The id holds no LIKE wildcard.
    let pattern = "%\"ingest_id\":\"\(ingestID)\"%"
    return try read { db in
      try Int.fetchOne(
        db,
        sql: """
          SELECT count(*) FROM pending_ops
           WHERE op_type IN ('txn_ingested', 'txn_superseded') AND CAST(op_json AS TEXT) LIKE ?
          """,
        arguments: [pattern]) ?? 0
    } > 0
  }

  /// The newest `authored_at` among pending ops (canonical instant text), or nil.
  public func latestPendingAuthoredAt() throws(StoreError) -> String? {
    try read { db in
      try String.fetchOne(
        db,
        sql: """
          SELECT max(substr(j, instr(j, '"authored_at":"') + 15, 24))
            FROM (SELECT CAST(op_json AS TEXT) AS j FROM pending_ops) WHERE instr(j, '"authored_at":"') > 0
          """)
    }
  }
}
