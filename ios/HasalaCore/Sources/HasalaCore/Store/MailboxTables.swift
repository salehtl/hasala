// The Gmail lane's tables in ledger.sqlite (spec 04 §4.2: mailbox_state, mailbox_accounted,
// mailbox_set_aside, mailbox_unreadable, mailbox_staging, bank_health), plus the `pending_ops`
// insert that must share their transaction (§7.5 step 7f: a message's op and its accounting row
// commit together, so a crash can neither lose a message nor author it twice).
//
// Row-level and content-agnostic: CoreMailbox (L4) maps its values onto these rows (it may not
// import GRDB, R6), and the op JSON arrives already authored (CoreDomain's OpAuthor, R5).
//
// The real migration is CoreStore's `"v1"` (LedgerSchema, WS-11). `MailboxTableStore.schema`
// repeats the §4.2 DDL of the tables used here so this store can be tested alone; it must stay
// identical to the migration's text.
import Foundation
import GRDB

public struct MailboxStateRow: Sendable, Equatable {
  public var phase: String
  public var address: String?
  public var watermarkMs: Int64?
  public var profileHistoryID: String?
  public var backfillDays: Int?
  public var scanStartedMs: Int64?
  public var watchExpiresAt: Int64?
  public var haltedOn: String?
  public var haltedDetail: String?
  public var lastCycleAt: Int64?
  public var lastSuccessAt: Int64?
  public var lastHolderCheckAt: Int64?

  public init(phase: String) { self.phase = phase }
}

public struct MailboxAccountedRow: Sendable, Equatable {
  public var messageID: String
  public var outcome: String
  public var internalDate: Int64
  public var at: Int64
  public init(messageID: String, outcome: String, internalDate: Int64, at: Int64) {
    self.messageID = messageID
    self.outcome = outcome
    self.internalDate = internalDate
    self.at = at
  }
}

public struct MailboxSetAsideRow: Sendable, Equatable {
  public var messageID: String
  public var domain: String
  public var internalDate: Int64
  public var at: Int64
  public init(messageID: String, domain: String, internalDate: Int64, at: Int64) {
    self.messageID = messageID
    self.domain = domain
    self.internalDate = internalDate
    self.at = at
  }
}

public struct MailboxUnreadableRow: Sendable, Equatable {
  public var messageID: String
  public var reason: String
  public var domain: String?
  public var internalDate: Int64?
  public var at: Int64
  public init(messageID: String, reason: String, domain: String?, internalDate: Int64?, at: Int64) {
    self.messageID = messageID
    self.reason = reason
    self.domain = domain
    self.internalDate = internalDate
    self.at = at
  }
}

public struct MailboxStagingRow: Sendable, Equatable {
  public var messageID: String
  public var ingestID: String
  public var bank: String
  public var last4: String
  public var gatesJSON: Data
  public var draftJSON: Data
  public var internalDate: Int64
  public init(
    messageID: String, ingestID: String, bank: String, last4: String, gatesJSON: Data, draftJSON: Data,
    internalDate: Int64
  ) {
    self.messageID = messageID
    self.ingestID = ingestID
    self.bank = bank
    self.last4 = last4
    self.gatesJSON = gatesJSON
    self.draftJSON = draftJSON
    self.internalDate = internalDate
  }
}

public struct MailboxUnparsedSenderRow: Sendable, Equatable {
  public var messageID: String
  public var domain: String
  public var at: Int64
  public init(messageID: String, domain: String, at: Int64) {
    self.messageID = messageID
    self.domain = domain
    self.at = at
  }
}

public struct BankHealthRecord: Sendable, Equatable {
  public var domain: String
  public var lastEmailAt: Int64?
  public var month: String
  public var readThisMonth: Int
}

/// One authored op for `pending_ops` (§4.2), canonical JSON already validated by its author.
public struct MailboxPendingOpRow: Sendable, Equatable {
  public var opID: String
  public var opJSON: Data
  public var opType: String
  public var entityKind: String?
  public var entityID: String?
  public var enqueuedAt: Int64
  public init(opID: String, opJSON: Data, opType: String, entityKind: String?, entityID: String?, enqueuedAt: Int64) {
    self.opID = opID
    self.opJSON = opJSON
    self.opType = opType
    self.entityKind = entityKind
    self.entityID = entityID
    self.enqueuedAt = enqueuedAt
  }
}

/// Everything one mailbox step writes, applied in ONE transaction.
public struct MailboxWrite: Sendable {
  public var pending: [MailboxPendingOpRow] = []
  public var accounted: [MailboxAccountedRow] = []
  public var setAside: [MailboxSetAsideRow] = []
  public var unreadable: [MailboxUnreadableRow] = []
  public var stage: [MailboxStagingRow] = []
  public var unstage: [String] = []
  public var pruneAccountedBelow: Int64?
  /// (domain, local month `YYYY-MM`, internalDate ms) per read message.
  public var health: [(domain: String, month: String, internalDate: Int64)] = []
  public var addImports: [(domain: String, sinceMs: Int64)] = []
  public var doneImports: [String] = []
  public var unparsedSenders: [MailboxUnparsedSenderRow] = []
  public var reader: Data?
  public var state: MailboxStateRow?
  public var clearAll = false
  public init() {}
}

public final class MailboxTableStore: Sendable {
  public static let setAsideRing = 200
  public static let unreadableRing = 1_000
  public static let unparsedSenderRing = 1_000

  let db: any DatabaseWriter

  public init(writer: any DatabaseWriter) { db = writer }

  /// A store over a private in-memory database with `schema` applied (tests, previews).
  public static func inMemory() throws -> MailboxTableStore {
    let q = try DatabaseQueue()
    try q.write { db in for s in schema { try db.execute(sql: s) } }
    return MailboxTableStore(writer: q)
  }

  /// §4.2's DDL for the tables this store touches (identical to LedgerSchema's migration "v1").
  public static let schema: [String] = [
    """
    CREATE TABLE pending_ops (
      local_seq    INTEGER PRIMARY KEY AUTOINCREMENT,
      op_id        TEXT    NOT NULL UNIQUE,
      op_json      BLOB    NOT NULL,
      op_type      TEXT    NOT NULL,
      entity_kind  TEXT, entity_id TEXT,
      enqueued_at  INTEGER NOT NULL
    )
    """,
    """
    CREATE TABLE mailbox_state (
      id                    INTEGER PRIMARY KEY CHECK (id = 1),
      phase                 TEXT NOT NULL CHECK (phase IN
                              ('unlinked','scanning','awaiting_cards','authoring_backfill','active',
                               'other_device','reconnect_required','halted')),
      address               TEXT,
      watermark_ms          INTEGER,
      profile_history_id    TEXT,
      backfill_days         INTEGER CHECK (backfill_days IN (30, 90, 365)),
      scan_started_ms       INTEGER,
      list_page_token       TEXT,
      watch_expires_at      INTEGER,
      halted_on             TEXT, halted_detail TEXT,
      last_cycle_at         INTEGER, last_success_at INTEGER, last_holder_check_at INTEGER
    )
    """,
    """
    CREATE TABLE mailbox_accounted (
      message_id    TEXT PRIMARY KEY,
      outcome       TEXT NOT NULL CHECK (outcome IN ('op','set_aside','unreadable','dup','gone')),
      internal_date INTEGER NOT NULL,
      at            INTEGER NOT NULL
    ) WITHOUT ROWID
    """,
    """
    CREATE TABLE mailbox_set_aside (
      message_id  TEXT PRIMARY KEY, domain TEXT NOT NULL, internal_date INTEGER NOT NULL, at INTEGER NOT NULL
    ) WITHOUT ROWID
    """,
    """
    CREATE TABLE mailbox_unreadable (
      message_id  TEXT PRIMARY KEY, reason TEXT NOT NULL, domain TEXT, internal_date INTEGER, at INTEGER NOT NULL
    ) WITHOUT ROWID
    """,
    """
    CREATE TABLE mailbox_staging (
      message_id    TEXT PRIMARY KEY,
      ingest_id     TEXT NOT NULL CHECK (length(ingest_id) = 64),
      bank          TEXT NOT NULL,
      last4         TEXT NOT NULL,
      gates_json    BLOB NOT NULL,
      draft_json    BLOB NOT NULL,
      internal_date INTEGER NOT NULL
    ) WITHOUT ROWID
    """,
    """
    CREATE TABLE bank_health (
      domain TEXT PRIMARY KEY, last_email_at INTEGER, month TEXT NOT NULL, read_this_month INTEGER NOT NULL
    ) WITHOUT ROWID
    """,
    "CREATE TABLE mailbox_sender_address (address TEXT PRIMARY KEY COLLATE NOCASE, at INTEGER NOT NULL) WITHOUT ROWID",
    "CREATE TABLE mailbox_parsing (message_id TEXT PRIMARY KEY, at INTEGER NOT NULL) WITHOUT ROWID",
    "CREATE TABLE mailbox_pending_import (domain TEXT PRIMARY KEY, since_ms INTEGER NOT NULL) WITHOUT ROWID",
    "CREATE TABLE mailbox_unparsed_sender (message_id TEXT PRIMARY KEY, domain TEXT NOT NULL, at INTEGER NOT NULL) WITHOUT ROWID",
    "CREATE TABLE mailbox_reader (id INTEGER PRIMARY KEY CHECK (id = 1), json BLOB NOT NULL)",
  ]

  public func loadReader() throws -> Data? {
    try db.read { db in try Data.fetchOne(db, sql: "SELECT json FROM mailbox_reader WHERE id = 1") }
  }

  public func pendingImports() throws -> [(domain: String, sinceMs: Int64)] {
    try db.read { db in
      try Row.fetchAll(db, sql: "SELECT domain, since_ms FROM mailbox_pending_import ORDER BY domain").map {
        (($0["domain"] as String), ($0["since_ms"] as Int64))
      }
    }
  }

  public func unparsedSenders() throws -> [String: String] {
    try db.read { db in
      Dictionary(
        try Row.fetchAll(db, sql: "SELECT message_id, domain FROM mailbox_unparsed_sender").map {
          (($0["message_id"] as String), ($0["domain"] as String))
        }, uniquingKeysWith: { a, _ in a })
    }
  }

  public func isParsing(_ messageID: String) throws -> Bool {
    try db.read { db in
      try Bool.fetchOne(db, sql: "SELECT 1 FROM mailbox_parsing WHERE message_id = ?", arguments: [messageID]) ?? false
    }
  }

  public func markParsing(_ messageID: String, at: Int64) throws {
    try db.write { db in
      try db.execute(
        sql: "INSERT OR REPLACE INTO mailbox_parsing (message_id, at) VALUES (?, ?)", arguments: [messageID, at])
    }
  }

  public func clearParsing(_ messageID: String) throws {
    try db.write { db in
      try db.execute(sql: "DELETE FROM mailbox_parsing WHERE message_id = ?", arguments: [messageID])
    }
  }

  public func senderAddresses() throws -> [String] {
    try db.read { db in try String.fetchAll(db, sql: "SELECT address FROM mailbox_sender_address ORDER BY at, address") }
  }

  public func addSenderAddress(_ address: String, at: Int64) throws {
    try db.write { db in
      try db.execute(
        sql: "INSERT OR IGNORE INTO mailbox_sender_address (address, at) VALUES (?, ?)", arguments: [address, at])
    }
  }

  public func loadState() throws -> MailboxStateRow? {
    try db.read { db in
      guard let r = try Row.fetchOne(db, sql: "SELECT * FROM mailbox_state WHERE id = 1") else { return nil }
      var s = MailboxStateRow(phase: r["phase"])
      s.address = r["address"]
      s.watermarkMs = r["watermark_ms"]
      s.profileHistoryID = r["profile_history_id"]
      s.backfillDays = r["backfill_days"]
      s.scanStartedMs = r["scan_started_ms"]
      s.watchExpiresAt = r["watch_expires_at"]
      s.haltedOn = r["halted_on"]
      s.haltedDetail = r["halted_detail"]
      s.lastCycleAt = r["last_cycle_at"]
      s.lastSuccessAt = r["last_success_at"]
      s.lastHolderCheckAt = r["last_holder_check_at"]
      return s
    }
  }

  /// Which of `ids` are accounted or staged.
  public func accounted(among ids: [String]) throws -> Set<String> {
    guard !ids.isEmpty else { return [] }
    return try db.read { db in
      var out = Set<String>()
      for chunk in stride(from: 0, to: ids.count, by: 500).map({ Array(ids[$0..<min($0 + 500, ids.count)]) }) {
        let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
        let args = StatementArguments(chunk)
        for t in ["mailbox_accounted", "mailbox_staging"] {
          out.formUnion(try String.fetchAll(db, sql: "SELECT message_id FROM \(t) WHERE message_id IN (\(marks))", arguments: args))
        }
      }
      return out
    }
  }

  public func staged(limit: Int) throws -> [MailboxStagingRow] {
    try db.read { db in
      try Row.fetchAll(
        db, sql: "SELECT * FROM mailbox_staging ORDER BY internal_date, message_id LIMIT ?", arguments: [limit]
      ).map {
        MailboxStagingRow(
          messageID: $0["message_id"], ingestID: $0["ingest_id"], bank: $0["bank"], last4: $0["last4"],
          gatesJSON: $0["gates_json"], draftJSON: $0["draft_json"], internalDate: $0["internal_date"])
      }
    }
  }

  public func stagedCount() throws -> Int {
    try db.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM mailbox_staging") ?? 0 }
  }

  public func setAside() throws -> [MailboxSetAsideRow] {
    try db.read { db in
      try Row.fetchAll(db, sql: "SELECT * FROM mailbox_set_aside ORDER BY internal_date DESC").map {
        MailboxSetAsideRow(messageID: $0["message_id"], domain: $0["domain"], internalDate: $0["internal_date"], at: $0["at"])
      }
    }
  }

  public func unreadable() throws -> [MailboxUnreadableRow] {
    try db.read { db in
      try Row.fetchAll(db, sql: "SELECT * FROM mailbox_unreadable ORDER BY at DESC").map {
        MailboxUnreadableRow(
          messageID: $0["message_id"], reason: $0["reason"], domain: $0["domain"], internalDate: $0["internal_date"],
          at: $0["at"])
      }
    }
  }

  public func bankHealth() throws -> [BankHealthRecord] {
    try db.read { db in
      try Row.fetchAll(db, sql: "SELECT * FROM bank_health ORDER BY domain").map {
        BankHealthRecord(domain: $0["domain"], lastEmailAt: $0["last_email_at"], month: $0["month"], readThisMonth: $0["read_this_month"])
      }
    }
  }

  /// message_id -> outcome (tests and diagnostics).
  public func accountedRowsForTests() throws -> [String: String] {
    try db.read { db in
      Dictionary(
        uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT message_id, outcome FROM mailbox_accounted").map {
          (($0["message_id"] as String), ($0["outcome"] as String))
        })
    }
  }

  /// `pending_ops` rows (tests; the outbox reads them through LedgerStore).
  public func pendingOpIDs() throws -> [String] {
    try db.read { db in try String.fetchAll(db, sql: "SELECT op_id FROM pending_ops ORDER BY local_seq") }
  }

  public func commit(_ w: MailboxWrite) throws {
    try db.write { db in
      if w.clearAll {
        for t in [
          "mailbox_accounted", "mailbox_set_aside", "mailbox_unreadable", "mailbox_staging", "bank_health", "mailbox_parsing",
          "mailbox_pending_import", "mailbox_reader",
        ] {
          try db.execute(sql: "DELETE FROM \(t)")
        }
      }
      for p in w.pending {
        try db.execute(
          sql: """
            INSERT INTO pending_ops (op_id, op_json, op_type, entity_kind, entity_id, enqueued_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """, arguments: [p.opID, p.opJSON, p.opType, p.entityKind, p.entityID, p.enqueuedAt])
      }
      for a in w.accounted {
        try db.execute(
          sql: "INSERT OR REPLACE INTO mailbox_accounted (message_id, outcome, internal_date, at) VALUES (?, ?, ?, ?)",
          arguments: [a.messageID, a.outcome, a.internalDate, a.at])
      }
      for s in w.setAside {
        try db.execute(
          sql: "INSERT OR REPLACE INTO mailbox_set_aside (message_id, domain, internal_date, at) VALUES (?, ?, ?, ?)",
          arguments: [s.messageID, s.domain, s.internalDate, s.at])
      }
      if !w.setAside.isEmpty {
        try db.execute(
          sql: """
            DELETE FROM mailbox_set_aside WHERE message_id NOT IN
              (SELECT message_id FROM mailbox_set_aside ORDER BY internal_date DESC LIMIT ?)
            """, arguments: [Self.setAsideRing])
      }
      for u in w.unreadable {
        try db.execute(
          sql: "INSERT OR REPLACE INTO mailbox_unreadable (message_id, reason, domain, internal_date, at) VALUES (?, ?, ?, ?, ?)",
          arguments: [u.messageID, u.reason, u.domain, u.internalDate, u.at])
      }
      if !w.unreadable.isEmpty {
        try db.execute(
          sql: """
            DELETE FROM mailbox_unreadable WHERE message_id NOT IN
              (SELECT message_id FROM mailbox_unreadable ORDER BY at DESC LIMIT ?)
            """, arguments: [Self.unreadableRing])
      }
      for s in w.stage {
        try db.execute(
          sql: """
            INSERT OR REPLACE INTO mailbox_staging
              (message_id, ingest_id, bank, last4, gates_json, draft_json, internal_date)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """, arguments: [s.messageID, s.ingestID, s.bank, s.last4, s.gatesJSON, s.draftJSON, s.internalDate])
      }
      for u in w.unparsedSenders {
        try db.execute(
          sql: "INSERT OR REPLACE INTO mailbox_unparsed_sender (message_id, domain, at) VALUES (?, ?, ?)",
          arguments: [u.messageID, u.domain, u.at])
      }
      if !w.unparsedSenders.isEmpty {
        try db.execute(
          sql: """
            DELETE FROM mailbox_unparsed_sender WHERE message_id NOT IN
              (SELECT message_id FROM mailbox_unparsed_sender ORDER BY at DESC, message_id DESC LIMIT ?)
            """, arguments: [Self.unparsedSenderRing])
      }
      for id in w.unstage {
        try db.execute(sql: "DELETE FROM mailbox_staging WHERE message_id = ?", arguments: [id])
      }
      if let r = w.reader {
        try db.execute(sql: "INSERT OR REPLACE INTO mailbox_reader (id, json) VALUES (1, ?)", arguments: [r])
      }
      if let below = w.pruneAccountedBelow {
        try db.execute(sql: "DELETE FROM mailbox_accounted WHERE internal_date < ?", arguments: [below])
      }
      for h in w.health {
        let row = try Row.fetchOne(db, sql: "SELECT * FROM bank_health WHERE domain = ?", arguments: [h.domain])
        var month: String = row?["month"] ?? h.month
        var count: Int = row?["read_this_month"] ?? 0
        var last: Int64? = row?["last_email_at"]
        if h.month > month {
          month = h.month
          count = 0
        }
        if h.month == month { count += 1 }
        last = max(last ?? 0, h.internalDate)
        try db.execute(
          sql: "INSERT OR REPLACE INTO bank_health (domain, last_email_at, month, read_this_month) VALUES (?, ?, ?, ?)",
          arguments: [h.domain, last, month, count])
      }
      for i in w.addImports {
        try db.execute(
          sql: """
            INSERT INTO mailbox_pending_import (domain, since_ms) VALUES (?, ?)
            ON CONFLICT(domain) DO UPDATE SET since_ms = min(since_ms, excluded.since_ms)
            """, arguments: [i.domain, i.sinceMs])
      }
      for d in w.doneImports {
        try db.execute(sql: "DELETE FROM mailbox_pending_import WHERE domain = ?", arguments: [d])
      }
      if let s = w.state {
        try db.execute(
          sql: """
            INSERT OR REPLACE INTO mailbox_state
              (id, phase, address, watermark_ms, profile_history_id, backfill_days, scan_started_ms,
               list_page_token, watch_expires_at, halted_on, halted_detail, last_cycle_at, last_success_at,
               last_holder_check_at)
            VALUES (1, ?, ?, ?, ?, ?, ?, NULL, ?, ?, ?, ?, ?, ?)
            """,
          arguments: [
            s.phase, s.address, s.watermarkMs, s.profileHistoryID, s.backfillDays, s.scanStartedMs, s.watchExpiresAt,
            s.haltedOn, s.haltedDetail, s.lastCycleAt, s.lastSuccessAt, s.lastHolderCheckAt,
          ])
      }
    }
  }
}
