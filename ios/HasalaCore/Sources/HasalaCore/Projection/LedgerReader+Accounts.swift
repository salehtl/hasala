// `LedgerReader`'s bills-and-accounts queries (03b, beta scope) and the records
// the plan and the Gmail lane read: money accounts, card links, check-ins, bills
// and their resolutions, projects, income sources, sender trust. Every query
// returns CoreReplay's record types as the fold materialized them, in a stable
// order, with the pending overlay already applied by the projector.
import CoreJSON
import CoreReplay
import Foundation
import GRDB

extension LedgerReader {
  // MARK: Accounts and cards (03b §4.2-§4.4)

  /// Every money account, active or closed, in fold order (first definition first).
  public func accounts() throws -> [Account] {
    try db.read { db in
      try Row.fetchAll(db, sql: "SELECT * FROM account ORDER BY first_seq, rowid").map { r in
        Account(
          id: r["id"], name: r["name"], institution: r["institution"], kind: r["kind"], inPlan: r["in_plan"],
          currency: r["currency"], statementDueDay: r["statement_due_day"], active: r["active"], closedOn: r["closed_on"],
          color: r["color"], firstSeq: r["first_seq"])
      }
    }
  }

  /// Every card link (`mine` and `not_mine`; a forgotten card has no row).
  public func cards() throws -> [CardLink] {
    try db.read { db in
      try Row.fetchAll(db, sql: "SELECT * FROM card ORDER BY bank, last4").map { r in
        CardLink(bank: r["bank"], last4: r["last4"], state: r["state"], account: r["account"], atSeq: r["at_seq"])
      }
    }
  }

  /// Balance check-ins, newest first per account; voided ones included (`void`).
  public func checkins(account: String? = nil) throws -> [Checkin] {
    var sql = "SELECT * FROM checkin"
    var args: [(any DatabaseValueConvertible)?] = []
    if let account {
      sql += " WHERE account = ?"
      args.append(account)
    }
    sql += " ORDER BY account, as_of_ms DESC, at_seq DESC"
    let a = args
    return try db.read { db in
      try Row.fetchAll(db, sql: sql, arguments: StatementArguments(a)).map { r in
        Checkin(
          id: r["id"], account: r["account"], asOf: r["as_of"], balanceMinor: r["balance_minor"], source: r["source"],
          resolution: r["resolution"], adjustmentMinor: r["adjustment_minor"], void: r["void"], atSeq: r["at_seq"])
      }
    }
  }

  // MARK: Bills (03b §3)

  /// Every bill record (active, cancelled or dismissed), in fold order.
  public func bills() throws -> [(id: String, bill: Bill)] {
    try db.read { db in
      try Row.fetchAll(db, sql: "SELECT * FROM bill ORDER BY first_seq, rowid").map { r in
        let keys = ((try? JSONDecoder().decode([String].self, from: Data((r["keys_json"] as String).utf8))) ?? [])
        return (
          r["id"],
          Bill(
            name: r["name"], keys: keys, direction: r["direction"], currency: r["currency"], amountMode: r["amount_mode"],
            amountMinor: r["amount_minor"], toleranceBp: r["tolerance_bp"],
            cadence: BillCadence(unit: r["cadence_unit"], every: r["cadence_every"]), anchor: r["anchor"], start: r["start"],
            end: r["end"], category: r["category"], account: r["account"], source: r["source"], status: r["status"],
            changes: Self.billChanges(r["changes_json"]), pauses: Self.billPauses(r["pauses_json"]), createdAt: r["created_at"],
            firstSeq: r["first_seq"], version: r["version"])
        )
      }
    }
  }

  static func billChanges(_ json: String?) -> [BillChange] {
    guard let json, let list = (try? JSONParser.parse(text: json))?.arrayValue else { return [] }
    return list.compactMap { v in
      guard let o = v.objectValue, let from = o["from"]?.stringValue, let mode = o["amount_mode"]?.stringValue,
        let amount = o["amount_minor"]?.stringValue.flatMap({ Int64($0) })
      else { return nil }
      var tolerance: Int64?
      if case .number(let n)? = o["tolerance_bp"] { tolerance = n.int64Value }
      return BillChange(from: from, amountMode: mode, amountMinor: amount, toleranceBp: tolerance)
    }
  }

  static func billPauses(_ json: String?) -> [BillPause] {
    guard let json, let list = (try? JSONParser.parse(text: json))?.arrayValue else { return [] }
    return list.compactMap { v in
      guard let o = v.objectValue, let from = o["from"]?.stringValue else { return nil }
      return BillPause(from: from, until: o["until"]?.stringValue)
    }
  }

  /// The resolved occurrences (`paid`, `skipped`, `snoozed`), per bill by due date.
  public func billResolutions(bill: String? = nil) throws -> [BillResolution] {
    var sql = "SELECT * FROM bill_resolution"
    var args: [(any DatabaseValueConvertible)?] = []
    if let bill {
      sql += " WHERE bill = ?"
      args.append(bill)
    }
    sql += " ORDER BY bill, due"
    let a = args
    return try db.read { db in
      try Row.fetchAll(db, sql: sql, arguments: StatementArguments(a)).map { r in
        BillResolution(bill: r["bill"], due: r["due"], resolution: r["resolution"], txn: r["txn"], until: r["until"], atSeq: r["at_seq"])
      }
    }
  }

  public func forkNotices(kind: String? = nil) throws -> [ForkNotice] {
    var sql = "SELECT * FROM fork_notice"
    var args: [(any DatabaseValueConvertible)?] = []
    if let kind {
      sql += " WHERE entity_kind = ?"
      args.append(kind)
    }
    sql += " ORDER BY ord"
    let a = args
    return try db.read { db in
      try Row.fetchAll(db, sql: sql, arguments: StatementArguments(a)).map { r in
        ForkNotice(entityKind: r["entity_kind"], entityID: r["entity_id"], winnerOp: r["winner_op"], loserOp: r["loser_op"], atSeq: r["at_seq"])
      }
    }
  }

  // MARK: Projects, income, trust

  /// Projects that are not removed, soonest start first (undated last).
  public func projects() throws -> [(id: String, project: Project)] {
    try db.read { db in
      try Row.fetchAll(
        db, sql: "SELECT * FROM project WHERE status <> 'removed' ORDER BY starts_on IS NULL, starts_on, name, id"
      ).map { r in
        (
          r["id"],
          Project(
            name: r["name"], startsOn: r["starts_on"], endsOn: r["ends_on"], budgetMinor: r["budget_minor"],
            countInPlan: r["count_in_plan"], status: r["status"], completedOn: r["completed_on"], icon: r["icon"],
            createdAt: r["created_at"], version: r["version"])
        )
      }
    }
  }

  /// The plan's income sources (03a §3.4), active or not. `write` is not projected.
  public func incomeSources() throws -> [IncomeSource] {
    try planState().incomeSources.values.map { $0 }
  }

  /// The `sender_trust_set` fold: domain → trusted (forwarder and shared-suffix
  /// domains included, as the fold keeps them; `queryDomains` filters those).
  public func senderTrust() throws -> [String: Bool] {
    try db.read { db in
      var out: [String: Bool] = [:]
      for r in try Row.fetchAll(db, sql: "SELECT domain, trusted FROM sender_trust") { out[r["domain"]] = r["trusted"] }
      return out
    }
  }

  /// Whether any projected row (live or superseded, pending included) carries `ingestID`.
  public func hasIngest(_ ingestID: String) throws -> Bool {
    try db.read { db in
      try Int.fetchOne(
        db, sql: "SELECT (SELECT count(*) FROM txn WHERE ingest_id = ?) + (SELECT count(*) FROM txn_alias WHERE ingest_id = ?)",
        arguments: [ingestID, ingestID]) ?? 0
    } > 0
  }

  public func newestMailboxPostedMs() throws -> Int64? {
    try db.read { db in
      try Int64.fetchOne(db, sql: "SELECT max(posted_ms) FROM txn WHERE mailbox_message_id IS NOT NULL")
    }
  }

  public func mailboxImports(grantID: String, provider: String, legacy: Bool) throws -> MailboxImportCounts {
    let account = MailboxGrant.account(of: grantID)
    return try db.read { db in
      let row = try Row.fetchOne(
        db,
        sql: """
          SELECT count(*) AS total, coalesce(sum(user_touched), 0) AS touched FROM txn
          WHERE superseded_by IS NULL AND source_provider = ? AND (source_mailbox = ? OR (? AND source_mailbox = ?))
          """, arguments: [provider, grantID, legacy, account])
      return MailboxImportCounts(total: row?["total"] ?? 0, edited: row?["touched"] ?? 0)
    }
  }

  public func otherMailboxCount(grantID: String, provider: String) throws -> Int {
    let account = MailboxGrant.account(of: grantID)
    return try db.read { db in
      try Int.fetchOne(
        db,
        sql: """
          SELECT count(DISTINCT source_mailbox) FROM txn
          WHERE source_provider = ? AND source_mailbox != ? AND substr(source_mailbox, 1, ?) = ?
          """, arguments: [provider, grantID, account.utf8.count + MailboxGrant.mailboxMarker.utf8.count, account + MailboxGrant.mailboxMarker])
        ?? 0
    }
  }
}

public struct MailboxImportCounts: Sendable, Equatable {
  public var total: Int
  public var edited: Int

  public init(total: Int, edited: Int) {
    self.total = total
    self.edited = edited
  }
}
