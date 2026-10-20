import CoreCategorize
import GRDB

public final class FMCache: ModelAnswerCache {
  public static let ttlMs: Int64 = 30 * 86_400_000

  private let db: any DatabaseWriter

  public init(_ store: LedgerStore) { db = store.db }

  public func isCached(subject: String, taxonomyHash: String, modelTag: String, now: Int64) throws -> Bool {
    let key = ModelTier.cacheKey(subject: subject, taxonomyHash: taxonomyHash, modelTag: modelTag)
    return try db.read { db in
      try Bool.fetchOne(db, sql: "SELECT 1 FROM fm_cache WHERE key = ? AND expires_at_ms > ?", arguments: [key, now]) ?? false
    }
  }

  public func recordUnknown(_ entries: [(subject: String, modelTag: String)], taxonomyHash: String, now: Int64) throws {
    guard !entries.isEmpty else { return }
    let rows = entries.map { e in
      (ModelTier.cacheKey(subject: e.subject, taxonomyHash: taxonomyHash, modelTag: e.modelTag), now + Self.ttlMs)
    }
    try db.write { db in
      for (key, expires) in rows {
        try db.execute(sql: "INSERT OR REPLACE INTO fm_cache (key, expires_at_ms) VALUES (?, ?)", arguments: [key, expires])
      }
    }
  }

  @discardableResult
  public func purgeExpired(now: Int64) throws -> Int {
    try db.write { db in
      try db.execute(sql: "DELETE FROM fm_cache WHERE expires_at_ms <= ?", arguments: [now])
      return db.changesCount
    }
  }

  public func count() throws -> Int {
    try db.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM fm_cache") ?? 0 }
  }
}
