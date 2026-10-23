// `ledger.sqlite`, GRDB migration "v1" (spec 04 §4.2), table for table.
//
// The Gmail lane's, the notification planner's and onboarding's tables are
// created here too, because §4.2 puts them in this one migration; their owners
// (WS-12, WS-13) read and write them through their own repositories. 03c §8.6.7's
// `fm_cache` and `pipeline_meta` are 03c's DDL and are added by the
// categorization lane in a later migration (TODO(WS-10/WS-16)).
import GRDB

enum LedgerSchema {
  static let v1: [String] = [
    """
    CREATE TABLE store_meta (
      id            INTEGER PRIMARY KEY CHECK (id = 1),
      format        INTEGER NOT NULL,
      user_id       TEXT    NOT NULL,
      writer_id     TEXT    NOT NULL CHECK (writer_id GLOB 'ios-*' AND length(writer_id) <= 64),
      api_base      TEXT    NOT NULL,
      key_epoch     INTEGER NOT NULL CHECK (key_epoch >= 1),
      created_at    INTEGER NOT NULL
    )
    """,
    """
    CREATE TABLE wire_rows (
      seq            INTEGER NOT NULL PRIMARY KEY CHECK (seq > 0),
      writer_id      TEXT    NOT NULL,
      writer_counter INTEGER NOT NULL CHECK (writer_counter > 0),
      type_flag      TEXT    NOT NULL CHECK (type_flag = 'edit'),
      size_bucket    INTEGER NOT NULL,
      blob_hash      BLOB    NOT NULL CHECK (length(blob_hash) = 32),
      prev_hash      BLOB    NOT NULL CHECK (length(prev_hash) = 32),
      created_at     TEXT    NOT NULL,
      blob           BLOB    NOT NULL,
      head_sig       BLOB    CHECK (head_sig IS NULL OR length(head_sig) = 64),
      disposition    TEXT    NOT NULL CHECK (disposition IN ('folded','set_aside','alarm')),
      UNIQUE (writer_id, writer_counter)
    ) WITHOUT ROWID
    """,
    """
    CREATE TABLE chain_heads (
      writer_id  TEXT    PRIMARY KEY,
      counter    INTEGER NOT NULL,
      hash       BLOB    NOT NULL CHECK (length(hash) = 32)
    ) WITHOUT ROWID
    """,
    """
    CREATE TABLE sync_state (
      id                    INTEGER PRIMARY KEY CHECK (id = 1),
      cursor_hot            INTEGER NOT NULL DEFAULT 0,
      authored_counter      INTEGER NOT NULL DEFAULT 0,
      authored_hash         BLOB    NOT NULL,
      checkpoint_json       BLOB,
      roster_json           BLOB,
      outbox_latch          TEXT CHECK (outbox_latch IS NULL OR outbox_latch IN
                              ('chain_break','hard_stop','sealer_fault','account_full')),
      epoch_hwm             INTEGER NOT NULL DEFAULT 1 CHECK (epoch_hwm BETWEEN 1 AND 2147483647),
      log_generation        INTEGER CHECK (log_generation IS NULL OR log_generation >= 1),
      last_pull_at          INTEGER, last_push_at INTEGER, last_full_check_at INTEGER
    )
    """,
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
    CREATE TABLE inflight_blobs (
      writer_counter INTEGER PRIMARY KEY,
      batch_id       TEXT    NOT NULL,
      prev_hash      BLOB    NOT NULL CHECK (length(prev_hash) = 32),
      blob_hash      BLOB    NOT NULL CHECK (length(blob_hash) = 32),
      size_bucket    INTEGER NOT NULL,
      blob           BLOB    NOT NULL,
      op_ids_json    BLOB    NOT NULL,
      head_sig       BLOB    CHECK (head_sig IS NULL OR length(head_sig) = 64),
      created_at     INTEGER NOT NULL
    ) WITHOUT ROWID
    """,
    """
    CREATE TABLE fold_snapshot (
      id          INTEGER PRIMARY KEY CHECK (id = 1),
      version     INTEGER NOT NULL,
      fold_print  TEXT    NOT NULL,
      cursor_hot  INTEGER NOT NULL,
      bound_tip   BLOB    NOT NULL,
      digest      BLOB    NOT NULL,
      payload     BLOB    NOT NULL,
      bytes       INTEGER NOT NULL,
      saved_at    INTEGER NOT NULL
    )
    """,
    """
    CREATE TABLE fold_events (id INTEGER PRIMARY KEY AUTOINCREMENT, at INTEGER NOT NULL,
                              kind TEXT NOT NULL, detail TEXT NOT NULL)
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
    "CREATE TABLE search_recent (query TEXT PRIMARY KEY, used_ms INTEGER NOT NULL) WITHOUT ROWID",
    """
    CREATE TABLE notification_ledger (
      dedupe_key  TEXT PRIMARY KEY,
      kind        INTEGER NOT NULL CHECK (kind BETWEEN 1 AND 11),
      fired_at    INTEGER NOT NULL,
      route       TEXT NOT NULL,
      title       TEXT NOT NULL, body TEXT NOT NULL,
      read_at     INTEGER
    ) WITHOUT ROWID
    """,
    "CREATE INDEX notification_ledger_fired ON notification_ledger (fired_at DESC)",
    """
    CREATE TABLE security_cursor (
      id                 INTEGER PRIMARY KEY CHECK (id = 1),
      key_history_id     INTEGER,
      auth_event_id      TEXT,
      checked_at         INTEGER
    )
    """,
    "CREATE TABLE onboarding_draft (id INTEGER PRIMARY KEY CHECK (id = 1), json BLOB NOT NULL)",
  ]

  static let fmCache: [String] = [
    "CREATE TABLE fm_cache (key TEXT PRIMARY KEY, expires_at_ms INTEGER NOT NULL)",
    "CREATE INDEX fm_cache_expires ON fm_cache (expires_at_ms)",
  ]

  static let fmCacheAnswers: [String] = [
    "ALTER TABLE fm_cache ADD COLUMN category TEXT",
    "ALTER TABLE fm_cache ADD COLUMN auto_file INTEGER NOT NULL DEFAULT 0",
  ]

  static let backlogRun: [String] = [
    "CREATE TABLE backlog_run (id INTEGER PRIMARY KEY CHECK (id = 1), json BLOB NOT NULL)"
  ]

  static let sortMemory: [String] = [
    "CREATE TABLE sort_memory (id INTEGER PRIMARY KEY CHECK (id = 1), json BLOB NOT NULL)"
  ]

  static let mailboxSenderAddress: [String] = [
    "CREATE TABLE mailbox_sender_address (address TEXT PRIMARY KEY COLLATE NOCASE, at INTEGER NOT NULL) WITHOUT ROWID"
  ]

  static let mailboxParsing: [String] = [
    "CREATE TABLE mailbox_parsing (message_id TEXT PRIMARY KEY, at INTEGER NOT NULL) WITHOUT ROWID"
  ]

  static let mailboxPendingImport: [String] = [
    "CREATE TABLE mailbox_pending_import (domain TEXT PRIMARY KEY, since_ms INTEGER NOT NULL) WITHOUT ROWID"
  ]

  static let mailboxUnparsedSender: [String] = [
    "CREATE TABLE mailbox_unparsed_sender (message_id TEXT PRIMARY KEY, domain TEXT NOT NULL, at INTEGER NOT NULL) WITHOUT ROWID"
  ]

  static var migrator: DatabaseMigrator {
    var m = DatabaseMigrator()
    m.registerMigration("v1") { db in
      for sql in v1 { try db.execute(sql: sql) }
    }
    m.registerMigration("fm_cache") { db in
      for sql in fmCache { try db.execute(sql: sql) }
    }
    m.registerMigration("mailbox_sender_address") { db in
      for sql in mailboxSenderAddress { try db.execute(sql: sql) }
    }
    m.registerMigration("mailbox_parsing") { db in
      for sql in mailboxParsing { try db.execute(sql: sql) }
    }
    m.registerMigration("mailbox_pending_import") { db in
      for sql in mailboxPendingImport { try db.execute(sql: sql) }
    }
    m.registerMigration("mailbox_unparsed_sender") { db in
      for sql in mailboxUnparsedSender { try db.execute(sql: sql) }
    }
    m.registerMigration("fm_cache_answers") { db in
      for sql in fmCacheAnswers { try db.execute(sql: sql) }
    }
    m.registerMigration("backlog_run") { db in
      for sql in backlogRun { try db.execute(sql: sql) }
    }
    m.registerMigration("sort_memory") { db in
      for sql in sortMemory { try db.execute(sql: sql) }
    }
    return m
  }
}
