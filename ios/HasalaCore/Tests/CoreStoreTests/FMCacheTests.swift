import Foundation
import GRDB
import Testing

import CoreCategorize

@testable import CoreStore

@Suite("CoreStore: fm_cache")
struct FMCacheTests {
  static let taxonomy = String(repeating: "ab", count: 32)

  @Test("the fm_cache migration creates the table, and no subject is stored in plaintext")
  func migration() throws {
    let s = try LedgerStore.inMemory()
    let columns = try s.db.read { db in try Row.fetchAll(db, sql: "PRAGMA table_info(fm_cache)").map { $0["name"] as String } }
    #expect(columns == ["key", "expires_at_ms", "category", "auto_file"])
    let migrations = try s.db.read { db in try LedgerSchema.migrator.appliedMigrations(db) }
    #expect(
      migrations == [
        "v1", "fm_cache", "mailbox_sender_address", "mailbox_parsing", "mailbox_pending_import", "mailbox_unparsed_sender",
        "fm_cache_answers", "backlog_run", "sort_memory", "fm_kept", "mailbox_reader", "mailbox_reader_shapes",
      ])
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

  @Test("a kept answer is keyed by subject and model tag only, survives the purge, and is dropped on request")
  func kept() throws {
    let s = try LedgerStore.inMemory()
    let cache = FMCache(s)
    let day: Int64 = 86_400_000
    let answer = ModelTier.StagedSuggestion(subject: "cafe example jbr", category: "shopping", modelTag: "cf-clef/1", autoFile: true)
    try cache.recordAnswers([answer], taxonomyHash: Self.taxonomy, now: 1_000)
    try cache.keepAnswers([answer])
    #expect(try cache.purgeExpired(now: 400 * day) == 1)
    #expect(try cache.answer(subject: "cafe example jbr", taxonomyHash: Self.taxonomy, modelTag: "cf-clef/1", now: 400 * day) == nil)
    #expect(try cache.keptAnswer(subject: "cafe example jbr", modelTag: "cf-clef/1") == "shopping")
    #expect(try cache.keptAnswer(subject: "cafe example jbr", modelTag: "apple-fm/26.1") == nil)
    let keys = try s.db.read { db in try String.fetchAll(db, sql: "SELECT key FROM fm_kept") }
    #expect(keys.count == 1 && keys[0].utf8.count == 64 && !keys[0].contains("cafe"))
    try cache.keepAnswers([.init(subject: "cafe example jbr", category: "dining", modelTag: "cf-clef/1")])
    #expect(try cache.keptAnswer(subject: "cafe example jbr", modelTag: "cf-clef/1") == "dining" && cache.keptCount() == 1)
    try cache.keepAnswers([])
    try cache.dropKept([])
    try cache.dropKept([(subject: "cafe example jbr", modelTag: "cf-clef/1")])
    #expect(try cache.keptAnswer(subject: "cafe example jbr", modelTag: "cf-clef/1") == nil && cache.keptCount() == 0)
  }

  @Test("category answers are kept for 30 days with their grade, keyed by subject, taxonomy and model tag")
  func answers() throws {
    let cache = FMCache(try LedgerStore.inMemory())
    let day: Int64 = 86_400_000
    try cache.recordAnswers(
      [
        .init(subject: "cafe example jbr", category: "dining", modelTag: "cf-clef/1", autoFile: true),
        .init(subject: "shop example", category: "shopping", modelTag: "cf-clef/1"),
      ], taxonomyHash: Self.taxonomy, now: 1_000)
    #expect(try cache.answer(subject: "cafe example jbr", taxonomyHash: Self.taxonomy, modelTag: "cf-clef/1", now: 1_000) == .category("dining", autoFile: true))
    #expect(try cache.answer(subject: "shop example", taxonomyHash: Self.taxonomy, modelTag: "cf-clef/1", now: 1_000) == .category("shopping", autoFile: false))
    #expect(try cache.answer(subject: "cafe example jbr", taxonomyHash: Self.taxonomy, modelTag: "apple-fm/26.1", now: 1_000) == nil)
    #expect(try cache.answer(subject: "cafe example jbr", taxonomyHash: Self.taxonomy, modelTag: "cf-clef/1", now: 1_000 + 30 * day) == nil)
    #expect(try cache.isCached(subject: "shop example", taxonomyHash: Self.taxonomy, modelTag: "cf-clef/1", now: 1_000))
    try cache.recordUnknown([(subject: "shop example", modelTag: "cf-clef/1")], taxonomyHash: Self.taxonomy, now: 2_000)
    #expect(try cache.answer(subject: "shop example", taxonomyHash: Self.taxonomy, modelTag: "cf-clef/1", now: 2_000) == .unknown)
    #expect(try cache.purgeExpired(now: 1_000 + 30 * day) == 1)
  }

  @Test("an unknown cached before the answer columns existed still reads as unknown")
  func oldRows() throws {
    let queue = try DatabaseQueue()
    let key = ModelTier.cacheKey(subject: "cafe example jbr", taxonomyHash: Self.taxonomy, modelTag: "cf-clef/1")
    try LedgerSchema.migrator.migrate(queue, upTo: "mailbox_unparsed_sender")
    try queue.write { db in
      try db.execute(sql: "INSERT INTO fm_cache (key, expires_at_ms) VALUES (?, ?)", arguments: [key, 5_000])
    }
    try LedgerSchema.migrator.migrate(queue)
    let row = try queue.read { db in try Row.fetchOne(db, sql: "SELECT category, auto_file FROM fm_cache WHERE key = ?", arguments: [key]) }
    #expect(row?["category"] as String? == nil && row?["auto_file"] as Int64? == 0)
  }

  @Test("the backlog run record is one row, replaced on save")
  func backlogRun() throws {
    let store = BacklogRunStore(try LedgerStore.inMemory())
    #expect(try store.load() == nil)
    try store.save(Data("{\"a\":1}".utf8))
    try store.save(Data("{\"a\":2}".utf8))
    #expect(try store.load() == Data("{\"a\":2}".utf8))
    try store.clear()
    #expect(try store.load() == nil)
  }

  @Test("the sort memory is one row, replaced on save, and erased with the store")
  func sortMemory() throws {
    let store = SortMemoryStore(try LedgerStore.inMemory())
    #expect(try store.load() == nil)
    try store.save(Data("{\"r\":1}".utf8))
    try store.save(Data("{\"r\":2}".utf8))
    #expect(try store.load() == Data("{\"r\":2}".utf8))
    try store.clear()
    #expect(try store.load() == nil)
  }
}
