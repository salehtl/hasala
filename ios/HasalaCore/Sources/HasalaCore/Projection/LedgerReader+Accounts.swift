// `LedgerReader`'s bills-and-accounts queries (03b, beta scope) and the records
// the plan and the Gmail lane read: money accounts, card links, check-ins, bills
// and their resolutions, projects, income sources, sender trust. Every query
// returns CoreReplay's record types as the fold materialized them, in a stable
// order, with the pending overlay already applied by the projector.
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
            firstSeq: r["first_seq"], version: r["version"])
        )
      }
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
      try Int.fetchOne(db, sql: "SELECT count(*) FROM txn WHERE ingest_id = ?", arguments: [ingestID]) ?? 0
    } > 0
  }

  public func newestMailboxPostedMs() throws -> Int64? {
    try db.read { db in
      try Int64.fetchOne(db, sql: "SELECT max(posted_ms) FROM txn WHERE mailbox_message_id IS NOT NULL")
    }
  }
}
