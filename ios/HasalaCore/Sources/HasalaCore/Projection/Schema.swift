// `projection.sqlite` (spec 04 §4.3; column layouts 03c §3.9, §4.4, §5.6, §6.3,
// §7.3 and 03a §5). The projection is DERIVED: a `projection_version`
// mismatch drops every table and re-projects, never migrates. Money columns
// are INTEGER (GRDB returns Int64; critic A-19).
//
// Additions beyond the owning specs, all derived and display-only:
// `txn.review_lane` (03c §3.7, computed once here so every reader agrees), the
// beta's 03b tables (`account`, `card`, `bill`, `bill_resolution`, `checkin`;
// version 2 added `checkin`), and the fold's notices (`fork_notice`, `anomaly`,
// `plan_overwrite`).
import GRDB

public enum ProjectionSchema {
  /// Bump on any change to a table, a view or a derived column.
  public static let version = 8

  static let tables = [
    "projection_meta", "txn", "txn_alias", "txn_part", "category", "rule", "rule_pattern", "merchant_name", "sender_trust", "project", "goal",
    "plan_cell", "plan_move", "income_source", "category_plan_role", "plan_overwrite", "budget_split", "rate", "account", "card",
    "bill", "bill_resolution", "checkin", "fork_notice", "anomaly",
  ]
  static let views = ["money_line", "rule_stats"]

  /// Creates every table, after dropping every view and table a different
  /// version left behind, whatever their names and references. Foreign keys
  /// are checked at commit (`defer_foreign_keys`, which works inside the
  /// caller's transaction), and children go before parents anyway, so no
  /// drop order of any older layout can fail on a reference.
  static func create(_ db: Database) throws {
    try db.execute(sql: "PRAGMA defer_foreign_keys = ON")
    let old = try String.fetchAll(
      db, sql: "SELECT name FROM sqlite_master WHERE type = 'view' AND name NOT LIKE 'sqlite_%'")
    for v in Set(views).union(old) { try db.execute(sql: "DROP VIEW IF EXISTS \(quoted(v))") }
    let present = try String.fetchAll(
      db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'")
    let known = tables.reversed().filter { present.contains($0) }
    for t in known + present.filter({ !tables.contains($0) }).sorted() {
      try db.execute(sql: "DROP TABLE IF EXISTS \(quoted(t))")
    }
    try db.execute(sql: ddl)
  }

  /// An SQL identifier, double-quoted.
  static func quoted(_ name: String) -> String { "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }

  static let ddl = """
    CREATE TABLE projection_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);

    CREATE TABLE txn (
      ord                   INTEGER PRIMARY KEY,
      id                    TEXT NOT NULL UNIQUE,
      ingest_id             TEXT NOT NULL,
      amount_minor          INTEGER NOT NULL CHECK (amount_minor >= 0),
      currency              TEXT NOT NULL,
      direction             TEXT NOT NULL CHECK (direction IN ('debit','credit','')),
      posted_at             TEXT NOT NULL,
      posted_ms             INTEGER NOT NULL,
      local_date            TEXT NOT NULL,
      local_month           TEXT NOT NULL,
      posted_precision      TEXT NOT NULL CHECK (posted_precision IN ('day','time')),
      merchant_raw          TEXT NOT NULL,
      merchant_key          TEXT NOT NULL,
      display_name          TEXT NOT NULL,
      location              TEXT,
      last4                 TEXT NOT NULL,
      bank                  TEXT,
      gates_json            TEXT,
      category              TEXT,
      category_source       TEXT NOT NULL CHECK (category_source IN ('none','user','held','rule','dictionary','model')),
      category_source_ref   TEXT,
      needs_review          INTEGER NOT NULL CHECK (needs_review IN (0,1)),
      unparsed              INTEGER NOT NULL CHECK (unparsed IN (0,1)),
      tier                  TEXT NOT NULL,
      provenance            TEXT NOT NULL,
      entry_method          TEXT CHECK (entry_method IN ('mailbox','manual','import')),
      amount_home_minor     INTEGER,
      home_source           TEXT CHECK (home_source IN ('identity','rate','stated')),
      home_rate_micro       INTEGER,
      split                 INTEGER NOT NULL CHECK (split IN (0,1)),
      superseded_by         TEXT,
      successor_id          TEXT,
      possible_duplicate_of TEXT,
      duplicate_disposition TEXT,
      mailbox_message_id    TEXT,
      note                  TEXT,
      archived              TEXT CHECK (archived IN ('user','not_a_transaction')),
      account_id            TEXT,
      effective_account_id  TEXT,
      counter_account_id    TEXT,
      project_id            TEXT,
      refund_of             TEXT,
      refund_target         TEXT,
      refund_state          TEXT CHECK (refund_state IN ('ok','broken')),
      transfer_peer         TEXT,
      transfer_target       TEXT,
      transfer_state        TEXT CHECK (transfer_state IN ('ok','one_sided','broken')),
      is_new_merchant       INTEGER NOT NULL,
      version               INTEGER NOT NULL,
      pending               INTEGER NOT NULL DEFAULT 0 CHECK (pending IN (0,1)),
      review_lane           TEXT CHECK (review_lane IN ('unreadable','duplicate','needs_review','uncategorized','copy')),
      source_mailbox        TEXT,
      source_provider       TEXT,
      user_touched          INTEGER NOT NULL DEFAULT 0 CHECK (user_touched IN (0,1)),
      copy_of               TEXT,
      copy_decision         TEXT CHECK (copy_decision IN ('keep_both')),
      held_copy             INTEGER NOT NULL DEFAULT 0 CHECK (held_copy IN (0,1)),
      merchant_group        TEXT NOT NULL,
      categorized_ms        INTEGER
    );
    CREATE INDEX txn_local_month ON txn(local_month, posted_ms DESC);
    CREATE INDEX txn_category    ON txn(category);
    CREATE INDEX txn_project     ON txn(project_id) WHERE project_id IS NOT NULL;
    CREATE INDEX txn_source_ref  ON txn(category_source, category_source_ref);
    CREATE INDEX txn_merchant    ON txn(merchant_key);
    CREATE INDEX txn_merchant_group ON txn(merchant_group, posted_ms DESC);
    CREATE INDEX txn_mailbox_message ON txn(mailbox_message_id) WHERE mailbox_message_id IS NOT NULL;
    CREATE INDEX txn_needs_review    ON txn(needs_review) WHERE needs_review = 1;
    CREATE INDEX txn_review_lane     ON txn(review_lane) WHERE review_lane IS NOT NULL;
    CREATE INDEX txn_source_mailbox  ON txn(source_provider, source_mailbox) WHERE source_mailbox IS NOT NULL;

    CREATE TABLE txn_alias (
      txn_id             TEXT NOT NULL REFERENCES txn(id),
      idx                INTEGER NOT NULL,
      alias_txn_id       TEXT NOT NULL,
      ingest_id          TEXT NOT NULL,
      source_mailbox     TEXT,
      source_provider    TEXT,
      mailbox_message_id TEXT,
      kind               TEXT NOT NULL CHECK (kind IN ('certain','user')),
      PRIMARY KEY (txn_id, idx)
    );
    CREATE INDEX txn_alias_ingest  ON txn_alias(ingest_id);
    CREATE INDEX txn_alias_message ON txn_alias(mailbox_message_id) WHERE mailbox_message_id IS NOT NULL;

    CREATE TABLE txn_part (
      txn_id            TEXT NOT NULL REFERENCES txn(id),
      idx               INTEGER NOT NULL,
      category          TEXT NOT NULL,
      amount_minor      INTEGER NOT NULL CHECK (amount_minor > 0),
      amount_home_minor INTEGER,
      note              TEXT,
      PRIMARY KEY (txn_id, idx)
    );

    CREATE TABLE category (
      id      TEXT PRIMARY KEY,
      ord     INTEGER NOT NULL,
      name    TEXT NOT NULL,
      kind    TEXT NOT NULL CHECK (kind IN ('spending','income','excluded')),
      bucket  TEXT CHECK (bucket IN ('need','want','saving')),
      hue     TEXT NOT NULL CHECK (hue IN ('sand','lilac','mint','sky','grey')),
      icon    TEXT NOT NULL,
      active  INTEGER NOT NULL CHECK (active IN (0,1)),
      builtin INTEGER NOT NULL CHECK (builtin IN (0,1)),
      parent  TEXT,
      CHECK ((kind = 'spending') = (bucket IS NOT NULL))
    );

    CREATE TABLE rule (
      id         TEXT PRIMARY KEY,
      match      TEXT NOT NULL CHECK (match IN ('exact','starts_with','contains','regex')),
      category   TEXT NOT NULL,
      priority   INTEGER NOT NULL,
      enabled    INTEGER NOT NULL CHECK (enabled IN (0,1)),
      removed    INTEGER NOT NULL CHECK (removed IN (0,1)),
      origin     TEXT NOT NULL CHECK (origin IN ('manual','learned','legacy')),
      created_at TEXT,
      created_ms INTEGER,
      version    INTEGER NOT NULL,
      defect     TEXT
    );
    CREATE TABLE rule_pattern (
      rule_id TEXT NOT NULL REFERENCES rule(id), idx INTEGER NOT NULL, pattern TEXT NOT NULL,
      PRIMARY KEY (rule_id, idx));

    CREATE TABLE merchant_name (merchant_key TEXT PRIMARY KEY, display_name TEXT, op_id TEXT NOT NULL);

    CREATE TABLE sender_trust (
      domain  TEXT PRIMARY KEY, trusted INTEGER NOT NULL CHECK (trusted IN (0,1)),
      ignored TEXT CHECK (ignored IN ('forwarder','shared_suffix')),
      op_id   TEXT NOT NULL);

    CREATE TABLE project (
      id TEXT PRIMARY KEY, name TEXT NOT NULL, starts_on TEXT, ends_on TEXT,
      budget_minor INTEGER, count_in_plan INTEGER NOT NULL CHECK (count_in_plan IN (0,1)),
      status TEXT NOT NULL CHECK (status IN ('active','completed','removed')),
      completed_on TEXT, icon TEXT NOT NULL, created_at TEXT NOT NULL, version INTEGER NOT NULL);

    CREATE TABLE goal (
      id TEXT PRIMARY KEY, name TEXT NOT NULL, target_minor INTEGER NOT NULL, target_month TEXT,
      source_kind TEXT NOT NULL CHECK (source_kind IN ('category','account')),
      category_id TEXT, since TEXT, account_id TEXT, starting_minor INTEGER NOT NULL,
      status TEXT NOT NULL CHECK (status IN ('active','completed','removed')),
      completed_on TEXT, icon TEXT NOT NULL, created_at TEXT NOT NULL, version INTEGER NOT NULL,
      CHECK ((source_kind = 'category') = (category_id IS NOT NULL AND since IS NOT NULL)),
      CHECK ((source_kind = 'account')  = (account_id IS NOT NULL)));

    CREATE TABLE plan_cell (
      category_id            TEXT    NOT NULL,
      month                  TEXT    NOT NULL CHECK (length(month)=7 AND substr(month,5,1)='-'),
      latest_set_minor       INTEGER,
      onward_set_minor       INTEGER,
      moves_all_minor        INTEGER NOT NULL DEFAULT 0,
      moves_since_set_minor  INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY (category_id, month)
    ) WITHOUT ROWID;

    CREATE TABLE plan_move (
      op_id        TEXT    PRIMARY KEY,
      seq          INTEGER NOT NULL,
      idx          INTEGER NOT NULL,
      month        TEXT    NOT NULL,
      from_category_id TEXT,
      to_category_id   TEXT,
      amount_minor INTEGER NOT NULL CHECK (amount_minor > 0),
      reason       TEXT    NOT NULL CHECK (reason IN ('move','assign','auto_assign','undo')),
      batch_id     TEXT,
      undoes       TEXT,
      undone       INTEGER NOT NULL CHECK (undone IN (0,1))
    );
    CREATE INDEX plan_move_month ON plan_move (month, seq, idx);

    CREATE TABLE income_source (
      id TEXT PRIMARY KEY, name TEXT NOT NULL, category_id TEXT NOT NULL,
      amount_minor INTEGER NOT NULL CHECK (amount_minor >= 0),
      payday INTEGER NOT NULL CHECK (payday BETWEEN 1 AND 31),
      active INTEGER NOT NULL CHECK (active IN (0,1))
    );

    CREATE TABLE category_plan_role (
      category_id TEXT PRIMARY KEY, role TEXT NOT NULL CHECK (role IN ('everyday','bills'))
    );

    CREATE TABLE plan_overwrite (
      at_seq       INTEGER NOT NULL,
      key_kind     TEXT    NOT NULL CHECK (key_kind IN ('budget','income_source','plan_role')),
      key          TEXT    NOT NULL,
      replaced_op  TEXT    NOT NULL,
      by_op        TEXT    NOT NULL PRIMARY KEY,
      replaced_value TEXT  NOT NULL
    );

    CREATE TABLE budget_split (id INTEGER PRIMARY KEY CHECK (id = 1), need INTEGER NOT NULL, want INTEGER NOT NULL,
      saving INTEGER NOT NULL, monthly_total_minor INTEGER);

    CREATE TABLE rate (currency TEXT PRIMARY KEY, rate_micro INTEGER, updated_at TEXT, home INTEGER NOT NULL);

    CREATE TABLE account (
      id TEXT PRIMARY KEY, name TEXT NOT NULL, institution TEXT, kind TEXT NOT NULL, in_plan INTEGER NOT NULL,
      currency TEXT NOT NULL, statement_due_day INTEGER, active INTEGER NOT NULL, closed_on TEXT, color TEXT,
      first_seq INTEGER NOT NULL);
    CREATE TABLE card (bank TEXT, last4 TEXT NOT NULL, state TEXT NOT NULL, account TEXT, at_seq INTEGER NOT NULL);
    CREATE TABLE bill (
      id TEXT PRIMARY KEY, name TEXT NOT NULL, keys_json TEXT NOT NULL, direction TEXT NOT NULL, currency TEXT NOT NULL,
      amount_mode TEXT NOT NULL, amount_minor INTEGER NOT NULL, tolerance_bp INTEGER, cadence_unit TEXT NOT NULL,
      cadence_every INTEGER NOT NULL, anchor TEXT NOT NULL, start TEXT NOT NULL, end TEXT, category TEXT, account TEXT,
      source TEXT NOT NULL, status TEXT NOT NULL, changes_json TEXT, pauses_json TEXT, created_at TEXT,
      first_seq INTEGER NOT NULL, version INTEGER NOT NULL);
    CREATE TABLE bill_resolution (bill TEXT NOT NULL, due TEXT NOT NULL, resolution TEXT NOT NULL, txn TEXT, until TEXT,
      at_seq INTEGER NOT NULL, PRIMARY KEY (bill, due));
    CREATE TABLE checkin (
      id TEXT PRIMARY KEY, account TEXT NOT NULL, as_of TEXT NOT NULL, as_of_ms INTEGER NOT NULL,
      balance_minor INTEGER NOT NULL, source TEXT NOT NULL, resolution TEXT, adjustment_minor INTEGER,
      void INTEGER NOT NULL CHECK (void IN (0,1)), at_seq INTEGER NOT NULL);
    CREATE INDEX checkin_account ON checkin (account, as_of_ms DESC);

    CREATE TABLE fork_notice (ord INTEGER PRIMARY KEY, entity_kind TEXT NOT NULL, entity_id TEXT NOT NULL,
      winner_op TEXT NOT NULL, loser_op TEXT NOT NULL, at_seq INTEGER NOT NULL);
    CREATE TABLE anomaly (ord INTEGER PRIMARY KEY, kind TEXT NOT NULL, detail TEXT NOT NULL, at_seq INTEGER NOT NULL);

    CREATE VIEW money_line AS
    WITH line AS (
      SELECT t.id AS txn_id, -1 AS part_idx, t.category AS category,
             t.amount_home_minor AS home_minor, t.category_source AS category_source
        FROM txn t WHERE t.split = 0
      UNION ALL
      SELECT t.id, p.idx, p.category, p.amount_home_minor, 'user'
        FROM txn t JOIN txn_part p ON p.txn_id = t.id WHERE t.split = 1
    )
    SELECT l.txn_id, l.part_idx, l.category, c.kind AS kind, c.bucket AS bucket,
           t.direction, t.currency, l.home_minor, t.local_date, t.local_month, t.posted_ms,
           t.display_name, t.merchant_key, t.effective_account_id,
           CASE WHEN p.id IS NOT NULL THEN t.project_id END AS project_id,
           CASE
             WHEN c.kind = 'excluded' THEN 'excluded'
             WHEN c.kind = 'income'   THEN 'income'
             WHEN c.kind = 'spending' AND t.direction = 'debit'  THEN 'spend'
             WHEN c.kind = 'spending' AND t.direction = 'credit' THEN 'refund'
             WHEN t.direction = 'debit' THEN 'uncategorized_out'
             ELSE 'uncategorized_in'
           END AS flow,
           CASE
             WHEN l.home_minor IS NULL THEN NULL
             WHEN c.kind = 'excluded' THEN 0
             WHEN c.kind = 'income' THEN CASE t.direction WHEN 'credit' THEN l.home_minor ELSE -l.home_minor END
             WHEN t.direction = 'debit' THEN l.home_minor
             ELSE -l.home_minor
           END AS signed_home_minor,
           CASE WHEN t.needs_review = 0
                 AND (l.category_source <> 'model' OR substr(t.category_source_ref, 1, 8) = 'cf-clef/')
                 AND (t.possible_duplicate_of IS NULL OR t.duplicate_disposition = 'different')
                THEN 1 ELSE 0 END AS confirmed,
           CASE WHEN p.id IS NOT NULL AND p.count_in_plan = 0 THEN 0 ELSE 1 END AS in_plan
      FROM line l
      JOIN txn t ON t.id = l.txn_id
      LEFT JOIN category c ON c.id = l.category
      LEFT JOIN project p ON p.id = t.project_id AND p.status <> 'removed'
     WHERE t.superseded_by IS NULL AND t.unparsed = 0 AND t.archived IS NULL AND t.held_copy = 0;

    CREATE VIEW rule_stats AS
      SELECT category_source_ref AS rule_id, COUNT(*) AS match_count
        FROM txn
       WHERE category_source = 'rule' AND superseded_by IS NULL AND archived IS NULL
       GROUP BY category_source_ref;
    """
}
