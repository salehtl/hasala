import Foundation
import GRDB
import Testing

@testable import CoreStore

@Suite("CoreStore: fm_cache")
struct FMCacheTests {
  static let taxonomy = String(repeating: "ab", count: 32)

  @Test("the fm_cache migration creates the table, and no subject is stored in plaintext")
  func migration() throws {
    let s = try LedgerStore.inMemory()
    let columns = try s.db.read { db in try Row.fetchAll(db, sql: "PRAGMA table_info(fm_cache)").map { $0["name"] as String } }
    #expect(columns == ["key", "expires_at_ms"])
    let migrations = try s.db.read { db in try LedgerSchema.migrator.appliedMigrations(db) }
    #expect(migrations == ["v1", "fm_cache", "mailbox_sender_address", "mailbox_parsing", "mailbox_pending_import"])
    let cache = FMCache(s)
    try cache.recordUnknown([(subject: "cafe example jbr", modelTag: "apple-fm/26.1")], taxonomyHash: Self.taxonomy, now: 0)
    let keys = try s.db.read { db in try String.fetchAll(db, sql: "SELECT key FROM fm_cache") }
    #expect(keys.count == 1 && keys[0].utf8.count == 64 && !keys[0].contains("cafe"))
  }

  @Test("unknowns are cached for 30 days per subject, taxonomy and model tag; purge drops the expired")
  func ttlAndPurge() throws {
    let cache = FMCache(try LedgerStore.inMemory())
    let day: Int64 = 86_400_000
    try cache.recordUnknown(
      [(subject: "cafe example jbr", modelTag: "apple-fm/26.1"), (subject: "مطعم الياسمين الشعبي", modelTag: "cf-clef/1")],
      taxonomyHash: Self.taxonomy, now: 1_000)
    #expect(try cache.isCached(subject: "cafe example jbr", taxonomyHash: Self.taxonomy, modelTag: "apple-fm/26.1", now: 1_000 + 30 * day - 1))
    #expect(!(try cache.isCached(subject: "cafe example jbr", taxonomyHash: Self.taxonomy, modelTag: "apple-fm/26.1", now: 1_000 + 30 * day)))
    #expect(!(try cache.isCached(subject: "cafe example jbr", taxonomyHash: Self.taxonomy, modelTag: "cf-clef/1", now: 1_000)))
    #expect(!(try cache.isCached(subject: "cafe example jbr", taxonomyHash: String(repeating: "cd", count: 32), modelTag: "apple-fm/26.1", now: 1_000)))
    #expect(try cache.isCached(subject: "مطعم الياسمين الشعبي", taxonomyHash: Self.taxonomy, modelTag: "cf-clef/1", now: 1_000))
    try cache.recordUnknown([(subject: "cafe example jbr", modelTag: "apple-fm/26.1")], taxonomyHash: Self.taxonomy, now: 10 * day)
    #expect(try cache.count() == 2)
    #expect(try cache.purgeExpired(now: 1_000 + 30 * day) == 1)
    #expect(try cache.count() == 1)
    #expect(try cache.isCached(subject: "cafe example jbr", taxonomyHash: Self.taxonomy, modelTag: "apple-fm/26.1", now: 1_000 + 30 * day))
    #expect(try cache.purgeExpired(now: 40 * day) == 1)
    #expect(try cache.count() == 0)
    try cache.recordUnknown([], taxonomyHash: Self.taxonomy, now: 0)
  }
}
