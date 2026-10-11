// `LedgerReader` (spec 04 §2.2, §4.3): typed queries over `projection.sqlite`
// for the beta's screens (Home, Activity, Review, Plan, Rules, Bank alerts),
// and `ValueObservation` streams so a screen refreshes after each projection.
// Every query returns plain values; nothing here writes.
import CoreCategorize
import CoreDomain
import CoreReplay
import CoreTime
import Foundation
import GRDB
import HasalaText
import OrderedCollections

/// One projected transaction (03c §3.9.1).
public struct TxnRow: Sendable, Equatable, Identifiable {
  public var id: String
  public var ord: Int64
  public var amountMinor: Int64
  public var currency: String
  public var direction: String
  public var postedAt: String
  public var postedMs: Int64
  public var localDate: String
  public var localMonth: String
  public var postedPrecision: String
  public var merchantRaw: String
  public var merchantKey: String
  public var displayName: String
  public var location: String?
  public var last4: String
  public var bank: String?
  public var category: String?
  public var categorySource: String
  public var categorySourceRef: String?
  public var needsReview: Bool
  public var unparsed: Bool
  public var provenance: String
  public var entryMethod: String?
  public var amountHomeMinor: Int64?
  public var split: Bool
  public var supersededBy: String?
  public var possibleDuplicateOf: String?
  public var duplicateDisposition: String?
  public var mailboxMessageID: String?
  public var note: String?
  public var archived: String?
  public var effectiveAccountID: String?
  public var projectID: String?
  public var refundState: String?
  public var transferState: String?
  public var isNewMerchant: Bool
  public var version: Int64
  public var pending: Bool
  public var reviewLane: String?

  init(_ r: Row) {
    id = r["id"]
    ord = r["ord"]
    amountMinor = r["amount_minor"]
    currency = r["currency"]
    direction = r["direction"]
    postedAt = r["posted_at"]
    postedMs = r["posted_ms"]
    localDate = r["local_date"]
    localMonth = r["local_month"]
    postedPrecision = r["posted_precision"]
    merchantRaw = r["merchant_raw"]
    merchantKey = r["merchant_key"]
    displayName = r["display_name"]
    location = r["location"]
    last4 = r["last4"]
    bank = r["bank"]
    category = r["category"]
    categorySource = r["category_source"]
    categorySourceRef = r["category_source_ref"]
    needsReview = r["needs_review"]
    unparsed = r["unparsed"]
    provenance = r["provenance"]
    entryMethod = r["entry_method"]
    amountHomeMinor = r["amount_home_minor"]
    split = r["split"]
    supersededBy = r["superseded_by"]
    possibleDuplicateOf = r["possible_duplicate_of"]
    duplicateDisposition = r["duplicate_disposition"]
    mailboxMessageID = r["mailbox_message_id"]
    note = r["note"]
    archived = r["archived"]
    effectiveAccountID = r["effective_account_id"]
    projectID = r["project_id"]
    refundState = r["refund_state"]
    transferState = r["transfer_state"]
    isNewMerchant = r["is_new_merchant"]
    version = r["version"]
    pending = r["pending"]
    reviewLane = r["review_lane"]
  }
}

public struct PartRow: Sendable, Equatable {
  public var idx: Int
  public var category: String
  public var amountMinor: Int64
  public var amountHomeMinor: Int64?
  public var note: String?
}

public struct RuleRow: Sendable, Equatable, Identifiable {
  public var id: String
  public var patterns: [String]
  public var match: String
  public var category: String
  public var priority: Int64
  public var enabled: Bool
  public var removed: Bool
  public var origin: String
  public var createdAt: String?
  public var version: Int64
  public var defect: String?
  public var matchCount: Int
}

/// Keyset position for Activity paging: `(posted_ms, id)` of the last row shown.
public struct ActivityCursor: Sendable, Equatable {
  public var postedMs: Int64
  public var id: String
  public init(postedMs: Int64, id: String) {
    self.postedMs = postedMs
    self.id = id
  }
}

public struct LedgerReader: Sendable {
  public let db: any DatabaseReader

  public init(_ db: any DatabaseReader) { self.db = db }

  // MARK: Meta

  public func meta() throws -> ProjectionMeta? {
    try db.read { db in
      guard try db.tableExists("projection_meta") else { return nil }
      var m: [String: String] = [:]
      for r in try Row.fetchAll(db, sql: "SELECT key, value FROM projection_meta") { m[r["key"]] = r["value"] }
      guard let v = m["projection_version"].flatMap(Int.init) else { return nil }
      return ProjectionMeta(
        version: v, foldPrint: m["fold_print"] ?? "", cursorHot: m["cursor_hot"].flatMap { Int64($0) } ?? 0, complete: m["complete"] == "1",
        projectedAtMs: m["projected_at"].flatMap { Int64($0) } ?? 0)
    }
  }

  /// The projection is complete, current, and from these fold semantics.
  public func isUsable() throws -> Bool {
    guard let m = try meta() else { return false }
    return m.complete && m.version == ProjectionSchema.version && m.foldPrint == FoldCanary.foldPrint
  }

  // MARK: Transactions

  public func txn(_ id: String) throws -> TxnRow? {
    try db.read { db in try Row.fetchOne(db, sql: "SELECT * FROM txn WHERE id = ?", arguments: [id]).map(TxnRow.init) }
  }

  public func parts(_ txnID: String) throws -> [PartRow] {
    try db.read { db in
      try Row.fetchAll(db, sql: "SELECT * FROM txn_part WHERE txn_id = ? ORDER BY idx", arguments: [txnID]).map {
        PartRow(idx: $0["idx"], category: $0["category"], amountMinor: $0["amount_minor"], amountHomeMinor: $0["amount_home_minor"], note: $0["note"])
      }
    }
  }

  /// Activity: live, parsed, not archived rows, newest first, keyset-paged by
  /// `(posted_ms, id)`; one month when `month` is given.
  public func activity(month: CivilMonth? = nil, after: ActivityCursor? = nil, limit: Int = 50) throws -> [TxnRow] {
    var sql = "SELECT * FROM txn WHERE superseded_by IS NULL AND unparsed = 0 AND archived IS NULL"
    var args: [(any DatabaseValueConvertible)?] = []
    if let month {
      sql += " AND local_month = ?"
      args.append(month.wire)
    }
    if let after {
      sql += " AND (posted_ms < ? OR (posted_ms = ? AND id < ?))"
      args += [after.postedMs, after.postedMs, after.id]
    }
    sql += " ORDER BY posted_ms DESC, id DESC LIMIT ?"
    args.append(limit)
    let a = args
    return try db.read { db in try Row.fetchAll(db, sql: sql, arguments: StatementArguments(a)).map(TxnRow.init) }
  }

  /// Archived rows (Activity › Archived), newest first.
  public func archived(limit: Int = 200) throws -> [TxnRow] {
    try db.read { db in
      try Row.fetchAll(
        db, sql: "SELECT * FROM txn WHERE superseded_by IS NULL AND archived IS NOT NULL ORDER BY posted_ms DESC, id DESC LIMIT ?",
        arguments: [limit]
      ).map(TxnRow.init)
    }
  }

  /// The review queue in deck order (newest first), for the given lanes.
  public func review(lanes: [ReviewLane] = ReviewLane.allCases.filter(\.inDeck), limit: Int = 500) throws -> [TxnRow] {
    let marks = lanes.map { _ in "?" }.joined(separator: ",")
    var args: [(any DatabaseValueConvertible)?] = lanes.map(\.rawValue)
    args.append(limit)
    let a = args
    return try db.read { db in
      try Row.fetchAll(
        db, sql: "SELECT * FROM txn WHERE review_lane IN (\(marks)) ORDER BY posted_ms DESC, id DESC LIMIT ?",
        arguments: StatementArguments(a)
      ).map(TxnRow.init)
    }
  }

  /// Counts per review lane.
  public func reviewCounts() throws -> [ReviewLane: Int] {
    try db.read { db in
      var out: [ReviewLane: Int] = [:]
      for r in try Row.fetchAll(db, sql: "SELECT review_lane, COUNT(*) AS n FROM txn WHERE review_lane IS NOT NULL GROUP BY review_lane") {
        if let lane = ReviewLane(rawValue: r["review_lane"]) { out[lane] = r["n"] }
      }
      return out
    }
  }

  /// Which of `ids` already have a projected row (the Gmail lane's dedup before download).
  public func knownMailboxMessageIDs(_ ids: [String]) throws -> Set<String> {
    guard !ids.isEmpty else { return [] }
    return try db.read { db in
      var out: Set<String> = []
      for chunk in stride(from: 0, to: ids.count, by: 500).map({ Array(ids[$0..<min($0 + 500, ids.count)]) }) {
        let marks = chunk.map { _ in "?" }.joined(separator: ",")
        for s in try String.fetchAll(db, sql: "SELECT mailbox_message_id FROM txn WHERE mailbox_message_id IN (\(marks))", arguments: StatementArguments(chunk)) {
          out.insert(s)
        }
      }
      return out
    }
  }

  /// The sweep's view of every row (03c §8.4).
  public func sweepRows() throws -> [SweepRow] {
    try db.read { db in
      try Row.fetchAll(db, sql: "SELECT * FROM txn WHERE superseded_by IS NULL ORDER BY posted_ms DESC, id DESC").map { r in
        let t = TxnRow(r)
        return SweepRow(
          id: t.id, merchantRaw: t.merchantRaw, direction: Direction(rawValue: t.direction), category: t.category,
          sourceKind: SweepRow.SourceKind(rawValue: t.categorySource) ?? .none, sourceRef: t.categorySourceRef, needsReview: t.needsReview,
          candidate: !t.unparsed && t.archived == nil && !t.split)
      }
    }
  }

  // MARK: Categories, rules, merchants, trust

  public func taxonomy() throws -> TaxonomyView {
    try db.read { db in
      TaxonomyView(
        try Row.fetchAll(db, sql: "SELECT * FROM category").map { r in
          CategoryInfo(
            id: r["id"], name: r["name"], kind: CategoryKind(rawValue: r["kind"]) ?? .excluded,
            bucket: (r["bucket"] as String?).flatMap(Bucket.init(rawValue:)), icon: r["icon"], active: r["active"], builtin: r["builtin"],
            sortKey: r["ord"])
        })
    }
  }

  public func rules() throws -> [RuleRow] {
    try db.read { db in
      var patterns: [String: [String]] = [:]
      for r in try Row.fetchAll(db, sql: "SELECT rule_id, pattern FROM rule_pattern ORDER BY rule_id, idx") {
        patterns[r["rule_id"], default: []].append(r["pattern"])
      }
      return try Row.fetchAll(
        db,
        sql: """
          SELECT r.*, COALESCE(s.match_count, 0) AS match_count FROM rule r LEFT JOIN rule_stats s ON s.rule_id = r.id
          WHERE r.removed = 0 ORDER BY match_count DESC, r.created_ms DESC, r.id
          """
      ).map { r in
        let id: String = r["id"]
        return RuleRow(
          id: id, patterns: patterns[id] ?? [], match: r["match"], category: r["category"], priority: r["priority"], enabled: r["enabled"],
          removed: r["removed"], origin: r["origin"], createdAt: r["created_at"], version: r["version"], defect: r["defect"],
          matchCount: r["match_count"])
      }
    }
  }

  /// Trusted domains the Gmail lane may list (03c §7.2 `queryDomains`).
  public func queryDomains() throws -> [String] {
    try db.read { db in
      try String.fetchAll(db, sql: "SELECT domain FROM sender_trust WHERE trusted = 1 AND ignored IS NULL").sorted { compareUTF8($0, $1) < 0 }
    }
  }

  public func homeCurrency() throws -> String? {
    try db.read { db in try String.fetchOne(db, sql: "SELECT currency FROM rate WHERE home = 1") }
  }

  // MARK: Plan inputs

  /// `money_line` rows with `local_date` in `[from, to]`.
  public func moneyLines(from: CivilDate, to: CivilDate) throws -> [MoneyLine] {
    try db.read { db in
      try Row.fetchAll(
        db, sql: "SELECT * FROM money_line WHERE local_date BETWEEN ? AND ? ORDER BY posted_ms, txn_id, part_idx",
        arguments: [from.wire, to.wire]
      ).compactMap { r in
        guard let day = CivilDate(wire: r["local_date"]), let flow = MoneyLine.Flow(rawValue: r["flow"]) else { return nil }
        return MoneyLine(
          txnID: r["txn_id"], partIdx: r["part_idx"], category: r["category"], direction: r["direction"], localDate: day,
          signedHome: r["signed_home_minor"], flow: flow, confirmed: r["confirmed"], inPlan: r["in_plan"], projectID: r["project_id"],
          displayName: r["display_name"], postedMs: r["posted_ms"])
      }
    }
  }

  /// The plan records, rebuilt from the plan tables.
  public func planState() throws -> PlanState {
    try db.read { db in
      var p = PlanState()
      let none = PlanWrite(opID: "", writerID: "", atMs: 0)
      for r in try Row.fetchAll(db, sql: "SELECT * FROM plan_cell ORDER BY category_id, month") {
        var cell = PlanCell()
        cell.latestSet = r["latest_set_minor"]
        cell.onwardSet = r["onward_set_minor"]
        cell.movesAll = r["moves_all_minor"]
        cell.movesSinceSet = r["moves_since_set_minor"]
        p.cells[r["category_id"] as String, default: [:]][r["month"] as String] = cell
      }
      for r in try Row.fetchAll(db, sql: "SELECT * FROM income_source ORDER BY id") {
        let id: String = r["id"]
        p.incomeSources[id] = IncomeSource(
          id: id, name: r["name"], categoryID: r["category_id"], amountMinor: r["amount_minor"], payday: r["payday"], active: r["active"],
          write: none)
      }
      for r in try Row.fetchAll(db, sql: "SELECT * FROM category_plan_role ORDER BY category_id") {
        p.roles[r["category_id"] as String] = PlanRoleRecord(role: r["role"], write: none)
      }
      for r in try Row.fetchAll(db, sql: "SELECT * FROM plan_move ORDER BY seq, idx") {
        let id: String = r["op_id"]
        p.moves[id] = MoveRecord(
          opID: id, position: OpPosition(seq: r["seq"], index: r["idx"]), month: r["month"], from: r["from_category_id"],
          to: r["to_category_id"], amount: r["amount_minor"], reason: r["reason"], batchID: r["batch_id"], undoes: r["undoes"],
          undone: r["undone"])
      }
      return p
    }
  }

  public func budgetTemplate() throws -> BudgetSplit? {
    try db.read { db in
      try Row.fetchOne(db, sql: "SELECT need, want, saving FROM budget_split WHERE id = 1").map {
        BudgetSplit(need: $0["need"], want: $0["want"], saving: $0["saving"])
      }
    }
  }

  /// A `PlanEngine` for the months around `today` (lines from 2 months before
  /// `month` to the month after, for payday attribution and the September
  /// comparison chips).
  public func planEngine(month: CivilMonth, today: CivilDate, bills: [BillExpectation] = []) throws -> PlanEngine {
    let from = (month.adding(months: -2) ?? month).firstDay
    let to = (month.adding(months: 1) ?? month).lastDay
    return PlanEngine(
      plan: try planState(), taxonomy: try taxonomy(), lines: try moneyLines(from: from, to: to), bills: bills,
      template: try budgetTemplate(), today: today)
  }

  /// A goal's lines need its whole window: a `PlanEngine` over all lines from `since`.
  public func goals() throws -> [(id: String, goal: Goal)] {
    try db.read { db in
      try Row.fetchAll(db, sql: "SELECT * FROM goal WHERE status <> 'removed' ORDER BY target_month IS NULL, target_month, name").map { r in
        let src = GoalSource(kind: r["source_kind"], categoryID: r["category_id"], since: r["since"], accountID: r["account_id"])
        return (
          r["id"],
          Goal(
            name: r["name"], targetMinor: r["target_minor"], targetMonth: r["target_month"], source: src, startingMinor: r["starting_minor"],
            status: r["status"], completedOn: r["completed_on"], icon: r["icon"], createdAt: r["created_at"], version: r["version"])
        )
      }
    }
  }

  // MARK: Observation

  /// A stream of `fetch`'s answer, re-run after every write to the tables it reads.
  public func observe<T: Sendable>(_ fetch: @escaping @Sendable (Database) throws -> T) -> AsyncValueObservation<T> {
    ValueObservation.tracking(fetch).values(in: db)
  }
}
