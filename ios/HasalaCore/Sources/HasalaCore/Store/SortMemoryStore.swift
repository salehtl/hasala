import Foundation
import GRDB

public final class SortMemoryStore: Sendable {
  private let db: any DatabaseWriter

  public init(_ store: LedgerStore) { db = store.db }

  public func load() throws -> Data? {
    try db.read { db in try Data.fetchOne(db, sql: "SELECT json FROM sort_memory WHERE id = 1") }
  }

  public func save(_ json: Data) throws {
    try db.write { db in
      try db.execute(sql: "INSERT OR REPLACE INTO sort_memory (id, json) VALUES (1, ?)", arguments: [json])
    }
  }

  public func clear() throws {
    try db.write { db in try db.execute(sql: "DELETE FROM sort_memory") }
  }
}
