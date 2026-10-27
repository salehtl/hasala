import CoreReplay
import Foundation
import GRDB

public struct TextRowSpan: Sendable, Equatable {
  public var oldestPostedMs: Int64
  public var newestPostedMs: Int64
  public var count: Int

  public init(oldestPostedMs: Int64, newestPostedMs: Int64, count: Int) {
    self.oldestPostedMs = oldestPostedMs
    self.newestPostedMs = newestPostedMs
    self.count = count
  }
}

extension LedgerReader {
  public func textRows(postedFromMs: Int64, toMs: Int64) throws -> [TxnRow] {
    try db.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT * FROM txn WHERE superseded_by IS NULL AND archived IS NULL AND channel = ? AND posted_ms >= ? AND posted_ms <= ?
          ORDER BY posted_ms, id
          """, arguments: [TxnChannel.sms, postedFromMs, toMs]
      ).map(TxnRow.init)
    }
  }

  public func textRows(bank: String, last4: String) throws -> [TxnRow] {
    try db.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT * FROM txn WHERE superseded_by IS NULL AND archived IS NULL AND channel = ? AND bank = ? AND last4 = ?
          ORDER BY posted_ms, id
          """, arguments: [TxnChannel.sms, bank, last4]
      ).map(TxnRow.init)
    }
  }

  public func textRowSpan() throws -> TextRowSpan? {
    try db.read { db in
      guard
        let r = try Row.fetchOne(
          db, sql: "SELECT min(posted_ms) AS lo, max(posted_ms) AS hi, count(*) AS n FROM txn WHERE superseded_by IS NULL AND channel = ?",
          arguments: [TxnChannel.sms]),
        let lo: Int64 = r["lo"], let hi: Int64 = r["hi"]
      else { return nil }
      return TextRowSpan(oldestPostedMs: lo, newestPostedMs: hi, count: r["n"])
    }
  }

  public func hasTextRows() throws -> Bool { try textRowSpan() != nil }

  public func liveRows(postedFromMs: Int64, toMs: Int64) throws -> [TxnRow] {
    try db.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT * FROM txn WHERE superseded_by IS NULL AND archived IS NULL AND posted_ms >= ? AND posted_ms <= ?
          ORDER BY posted_ms, id
          """, arguments: [postedFromMs, toMs]
      ).map(TxnRow.init)
    }
  }
}
