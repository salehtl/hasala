import CoreCategorize
import GRDB

public final class FMCache: ModelAnswerCache {
  public static let ttlMs: Int64 = 30 * 86_400_000

  private let db: any DatabaseWriter

  public init(_ store: LedgerStore) { db = store.db }

  public func answer(subject: String, taxonomyHash: String, modelTag: String, now: Int64) throws -> CachedAnswer? {
    let key = ModelTier.cacheKey(subject: subject, taxonomyHash: taxonomyHash, modelTag: modelTag)
    return try db.read { db in
      guard
        let row = try Row.fetchOne(
          db, sql: "SELECT category, auto_file FROM fm_cache WHERE key = ? AND expires_at_ms > ?", arguments: [key, now])
      else { return nil }
      guard let category: String = row["category"] else { return .unknown }
      return .category(category, autoFile: row["auto_file"] as Bool? ?? false)
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

  public func recordAnswers(_ entries: [ModelTier.StagedSuggestion], taxonomyHash: String, now: Int64) throws {
    guard !entries.isEmpty else { return }
    try db.write { db in
      for e in entries {
        try db.execute(
          sql: "INSERT OR REPLACE INTO fm_cache (key, expires_at_ms, category, auto_file) VALUES (?, ?, ?, ?)",
          arguments: [
            ModelTier.cacheKey(subject: e.subject, taxonomyHash: taxonomyHash, modelTag: e.modelTag), now + Self.ttlMs, e.category,
            e.autoFile,
          ])
      }
    }
  }

  public func keptAnswer(subject: String, modelTag: String) throws -> String? {
    let key = ModelTier.keptKey(subject: subject, modelTag: modelTag)
    return try db.read { db in try String.fetchOne(db, sql: "SELECT category FROM fm_kept WHERE key = ?", arguments: [key]) }
  }

  public func keepAnswers(_ entries: [ModelTier.StagedSuggestion]) throws {
    guard !entries.isEmpty else { return }
    try db.write { db in
      for e in entries {
        try db.execute(
          sql: "INSERT OR REPLACE INTO fm_kept (key, category) VALUES (?, ?)",
          arguments: [ModelTier.keptKey(subject: e.subject, modelTag: e.modelTag), e.category])
      }
    }
  }

  public func dropKept(_ entries: [(subject: String, modelTag: String)]) throws {
    guard !entries.isEmpty else { return }
    try db.write { db in
      for e in entries {
        try db.execute(sql: "DELETE FROM fm_kept WHERE key = ?", arguments: [ModelTier.keptKey(subject: e.subject, modelTag: e.modelTag)])
      }
    }
  }

  public func keptCount() throws -> Int {
    try db.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM fm_kept") ?? 0 }
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
