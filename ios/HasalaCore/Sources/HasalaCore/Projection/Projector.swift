// `Projector` (spec 04 §4.3): writes a folded `State` into `projection.sqlite`,
// as a full replace inside one transaction, setting `complete = '1'` only after
// everything committed.
//
// The pending overlay: the ops still in this device's outbox are folded on a
// COPY of the confirmed state at synthetic seqs above `cursor_hot`; every
// transaction whose record they change is marked `pending = 1`. The overlay is
// rebuilt on every projection, so an acknowledged op simply stops being pending.
//
// Derived, device-local columns (03c §3.9.1-§3.9.2): local date and month at
// +04:00, merchant key and display name (rename > dictionary > prettify),
// effective account (03b §4.5), refund and transfer link states, the
// new-merchant flag, split home apportioning (03c §1.3) and the review lane.
import CoreCategorize
import CoreDomain
import CoreJSON
import CoreMoney
import CoreReplay
import CoreTime
import CoreWire
import Foundation
import GRDB
import HasalaText
import OrderedCollections

public struct ProjectionMeta: Sendable, Equatable {
  public var version: Int
  public var foldPrint: String
  public var cursorHot: Int64
  public var complete: Bool
  public var projectedAtMs: Int64
  /// Outbox ops overlaid on this projection (0: it shows only folded rows).
  public var pendingOps: Int = 0
}

public enum Projector {
  /// Opens (or creates) the projection database and makes sure its schema is current.
  public static func open(path: String?) throws -> DatabaseQueue {
    let q = try path.map { try DatabaseQueue(path: $0) } ?? DatabaseQueue()
    try q.write { db in try ensureSchema(db) }
    return q
  }

  static func ensureSchema(_ db: Database) throws {
    var current: Int?
    if try db.tableExists("projection_meta") {
      current = try String.fetchOne(db, sql: "SELECT value FROM projection_meta WHERE key = 'projection_version'").flatMap { Int($0) }
    }
    if current != ProjectionSchema.version {
      try ProjectionSchema.create(db)
      try db.execute(
        sql: "INSERT INTO projection_meta (key, value) VALUES ('projection_version', ?), ('complete', '0')",
        arguments: [String(ProjectionSchema.version)])
    }
  }

  /// Folds `pending` (the outbox's blobs, in order) on a copy of `state`; returns
  /// the overlaid state and the txn ids the overlay changed.
  public static func overlay(_ state: State, pending: [[Op]], writerID: String) -> (State, Set<String>) {
    guard !pending.isEmpty else { return (state, []) }
    var s = state
    var seq = state.cursors.hot
    // The outbox's ops are this device's; a missing writer id still overlays.
    let writer = writerID.isEmpty ? "pending-overlay" : writerID
    for ops in pending {
      seq += 1
      try? Replay.foldOps(ops, seq: seq, writerID: writer, into: &s)
    }
    var touched: Set<String> = []
    for (id, t) in s.txns where state.txns[id] != t { touched.insert(id) }
    return (s, touched)
  }

  /// Replaces the whole projection with `state` (plus the pending overlay).
  public static func project(
    _ confirmed: State, pending: [[Op]] = [], writerID: String = "", dictionary: MerchantDictionary, projectedAtMs: Int64,
    into db: DatabaseQueue
  ) throws {
    let (state, pendingIDs) = overlay(confirmed, pending: pending, writerID: writerID)
    let taxonomy = TaxonomyView(state: state)
    let rules = state.rules.map { id, r in RuleInput(id: id, patterns: r.patterns, match: r.match, category: r.category, priority: r.priority, enabled: r.enabled, removed: r.removed) }
    let categorizer = Categorizer(rules: rules, dictionary: dictionary, categories: taxonomy)
    try db.write { db in
      try ensureSchema(db)
      try db.execute(sql: "UPDATE projection_meta SET value = '0' WHERE key = 'complete'")
      // Children before parents: `txn_part` and `rule_pattern` reference `txn` and `rule`.
      for t in ProjectionSchema.tables.reversed() where t != "projection_meta" { try db.execute(sql: "DELETE FROM \(t)") }
      try writeTxns(db, state, categorizer: categorizer, pending: pendingIDs)
      try writeCategories(db, taxonomy)
      try writeRules(db, state, taxonomy: taxonomy)
      try writeConfig(db, state)
      try writePlan(db, state.plan)
      try write03b(db, state)
      try writeNotices(db, state)
      let meta: [(String, String)] = [
        ("projection_version", String(ProjectionSchema.version)), ("fold_print", FoldCanary.foldPrint),
        ("cursor_hot", String(confirmed.cursors.hot)), ("projected_at", String(projectedAtMs)),
        ("pending_ops", String(pending.reduce(0) { $0 + $1.count })), ("complete", "1"),
      ]
      for (k, v) in meta {
        try db.execute(sql: "INSERT OR REPLACE INTO projection_meta (key, value) VALUES (?, ?)", arguments: [k, v])
      }
    }
  }

  // MARK: Transactions

  private static func writeTxns(_ db: Database, _ s: State, categorizer: Categorizer, pending: Set<String>) throws {
    let txnView = OrderedDictionaryView(s)
    let cards = Array(s.cards.values)
    // is_new_merchant: no earlier live row (by posted instant, then fold order) with the same key.
    var firstByKey: [String: (Int64, Int)] = [:]
    var keys: [String: String] = [:]
    for (i, (id, t)) in s.txns.enumerated() {
      let key = Canon.merchantKey(t.merchantRaw)
      keys[id] = key
      guard t.isLive, !t.unparsed else { continue }
      let ms = (try? parseInstantMs(t.postedAt)) ?? 0
      if let f = firstByKey[key], f <= (ms, i) { continue }
      firstByKey[key] = (ms, i)
    }
    let insert = try db.makeStatement(
      sql: """
        INSERT INTO txn (ord, id, ingest_id, amount_minor, currency, direction, posted_at, posted_ms, local_date, local_month,
          posted_precision, merchant_raw, merchant_key, display_name, location, last4, bank, gates_json, category, category_source,
          category_source_ref, needs_review, unparsed, tier, provenance, entry_method, amount_home_minor, home_source, home_rate_micro, split, superseded_by,
          successor_id, possible_duplicate_of, duplicate_disposition, mailbox_message_id, note, archived, account_id,
          effective_account_id, counter_account_id, project_id, refund_of, refund_target, refund_state, transfer_peer,
          transfer_target, transfer_state, is_new_merchant, version, pending, review_lane, source_mailbox, source_provider,
          user_touched, copy_of, copy_decision, held_copy)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        """)
    let part = try db.makeStatement(
      sql: "INSERT INTO txn_part (txn_id, idx, category, amount_minor, amount_home_minor, note) VALUES (?,?,?,?,?,?)")
    let retiredIngests = Set(s.txns.values.filter { $0.retiredBy != nil }.map(\.ingestID))
    let alias = try db.makeStatement(
      sql: "INSERT INTO txn_alias (txn_id, idx, alias_txn_id, ingest_id, source_mailbox, source_provider, mailbox_message_id, kind) VALUES (?,?,?,?,?,?,?,?)")
    for (i, (id, t)) in s.txns.enumerated()
    where t.mergedInto == nil && (t.isLive || !retiredIngests.contains(t.ingestID)) {
      let ms = (try? parseInstantMs(t.postedAt)) ?? 0
      let local = LocalClock.localDate(ms)
      let key = keys[id] ?? ""
      let display = MerchantDisplay.name(
        raw: t.merchantRaw, renamed: s.merchantNames[key]?.value ?? nil, dictionary: categorizer.dictionaryDisplay(merchantRaw: t.merchantRaw))
      let source = t.categorySource ?? (t.category == nil ? .none : .user)
      let refundOf = t.annotation("refund_of")
      let refundTarget = refundOf.flatMap { Attribution.resolve($0, in: txnView) }
      let peer = t.annotation("transfer_peer")
      let peerTarget = peer.flatMap { Attribution.resolve($0, in: txnView) }
      let peerBack = peerTarget.flatMap { s.txns[$0]?.annotation("transfer_peer") }.flatMap { Attribution.resolve($0, in: txnView) }
      let isNew = firstByKey[key].map { $0 == (ms, i) } ?? false
      let args: [(any DatabaseValueConvertible)?] = [
        i + 1, id, t.ingestID, t.amountMinor, t.currency, t.direction, t.postedAt, ms, local?.wire ?? "", local?.yearMonth.wire ?? "",
        t.postedPrecision ?? "time", t.merchantRaw, key, display, t.location, t.last4, t.bank, t.gates.map(gatesJSON),
        t.category, source.kind.rawValue, source.ref, t.needsReview, t.unparsed, t.tier, t.provenance, t.entryMethod,
        t.amountHomeMinor, t.amountHomeMinor == nil ? nil : t.homeSource?.rawValue,
        t.amountHomeMinor == nil ? nil : t.homeRateMicro, !t.splits.isEmpty, t.supersededBy, t.successorID, t.possibleDuplicateOf, t.duplicateDisposition,
        t.mailboxMessageID, t.annotation("note"), t.annotation("archived"), t.annotation("account_id"),
        Attribution.accountOf(t, cards: cards).account, t.annotation("counter_account_id"), t.annotation("project_id"), refundOf,
        refundTarget, refundOf == nil ? nil : Attribution.refundState(t, target: refundTarget.flatMap { s.txns[$0] }), peer, peerTarget,
        peer == nil ? nil : Attribution.transferState(t, target: peerTarget.flatMap { s.txns[$0] }, targetPeer: peerBack),
        isNew, t.version, pending.contains(id), ReviewQueue.lane(t)?.rawValue, t.sourceMailbox, t.sourceProvider,
        userTouched(t), t.copyOf, t.copyDecision, t.isHeldCopy,
      ]
      try insert.execute(arguments: StatementArguments(args))
      for (k, a) in t.aliases.enumerated() {
        let aa: [(any DatabaseValueConvertible)?] = [id, k, a.txnID, a.ingestID, a.sourceMailbox, a.sourceProvider, a.mailboxMessageID, a.kind]
        try alias.execute(arguments: StatementArguments(aa))
      }
      if !t.splits.isEmpty {
        let homes = MoneyMath.apportion(home: t.amountHomeMinor, parts: t.splits.map(\.amountMinor))
        for (k, p) in t.splits.enumerated() {
          let pa: [(any DatabaseValueConvertible)?] = [id, k, p.category, p.amountMinor, homes?[k], p.note]
          try part.execute(arguments: StatementArguments(pa))
        }
      }
    }
  }

  static func userTouched(_ t: Txn) -> Bool {
    !t.annotations.isEmpty || !t.splits.isEmpty || (t.version > 1 && t.categorySource?.kind == .user)
  }

  static func gatesJSON(_ g: TxnGates) -> String {
    var o: [(String, JSONValue)] = []
    if let v = g.ar { o.append(("ar", .string(v))) }
    if let v = g.sender { o.append(("sender", .string(v))) }
    if let v = g.template { o.append(("template", .string(v))) }
    if let v = g.card { o.append(("card", .string(v))) }
    if let v = g.forwarded { o.append(("forwarded", .bool(v))) }
    return JSONWriter().string(.object(JSONObject(o)))
  }

  // MARK: Categories and rules

  private static func writeCategories(_ db: Database, _ taxonomy: TaxonomyView) throws {
    let st = try db.makeStatement(sql: "INSERT INTO category (id, ord, name, kind, bucket, hue, icon, active, builtin) VALUES (?,?,?,?,?,?,?,?,?)")
    for c in taxonomy.ordered {
      let args: [(any DatabaseValueConvertible)?] = [
        c.id, c.sortKey, c.name, c.kind.rawValue, c.bucket?.rawValue, c.hue.rawValue, c.icon, c.active, c.builtin,
      ]
      try st.execute(arguments: StatementArguments(args))
    }
  }

  private static func writeRules(_ db: Database, _ s: State, taxonomy: TaxonomyView) throws {
    let st = try db.makeStatement(
      sql: "INSERT INTO rule (id, match, category, priority, enabled, removed, origin, created_at, created_ms, version, defect) VALUES (?,?,?,?,?,?,?,?,?,?,?)")
    let pat = try db.makeStatement(sql: "INSERT INTO rule_pattern (rule_id, idx, pattern) VALUES (?,?,?)")
    for (id, r) in s.rules {
      let input = RuleInput(id: id, patterns: r.patterns, match: r.match, category: r.category, priority: r.priority)
      let defect = Matcher.prepare(rules: [input], entries: [], categories: taxonomy).defects.first?.code
      let createdMs = r.createdAt.flatMap { try? parseInstantMs($0) }
      let args: [(any DatabaseValueConvertible)?] = [
        id, r.match, r.category, r.priority, r.enabled, r.removed, r.origin, r.createdAt, createdMs, r.version, defect,
      ]
      try st.execute(arguments: StatementArguments(args))
      for (k, p) in r.patterns.enumerated() { try pat.execute(arguments: [id, k, p]) }
    }
  }

  // MARK: Configuration and 03c keyed records

  private static func writeConfig(_ db: Database, _ s: State) throws {
    for (k, v) in s.merchantNames {
      let args: [(any DatabaseValueConvertible)?] = [k, v.value, v.opID]
      try db.execute(sql: "INSERT INTO merchant_name (merchant_key, display_name, op_id) VALUES (?,?,?)", arguments: StatementArguments(args))
    }
    for (d, v) in s.senderTrust {
      let args: [(any DatabaseValueConvertible)?] = [d, v.value, SenderTrust.ignored(d), v.opID]
      try db.execute(sql: "INSERT INTO sender_trust (domain, trusted, ignored, op_id) VALUES (?,?,?,?)", arguments: StatementArguments(args))
    }
    for (id, p) in s.projects {
      let args: [(any DatabaseValueConvertible)?] = [
        id, p.name, p.startsOn, p.endsOn, p.budgetMinor, p.countInPlan, p.status, p.completedOn, p.icon ?? "flag", p.createdAt, p.version,
      ]
      try db.execute(
        sql: "INSERT INTO project (id, name, starts_on, ends_on, budget_minor, count_in_plan, status, completed_on, icon, created_at, version) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
        arguments: StatementArguments(args))
    }
    for (id, g) in s.goals {
      let args: [(any DatabaseValueConvertible)?] = [
        id, g.name, g.targetMinor, g.targetMonth, g.source.kind, g.source.categoryID, g.source.since, g.source.accountID, g.startingMinor,
        g.status, g.completedOn, g.icon ?? "jar", g.createdAt, g.version,
      ]
      try db.execute(
        sql: "INSERT INTO goal (id, name, target_minor, target_month, source_kind, category_id, since, account_id, starting_minor, status, completed_on, icon, created_at, version) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        arguments: StatementArguments(args))
    }
    if let b = s.budgetSplit {
      let args: [(any DatabaseValueConvertible)?] = [b.need, b.want, b.saving, s.budgetMonthlyTotal]
      try db.execute(sql: "INSERT INTO budget_split (id, need, want, saving, monthly_total_minor) VALUES (1,?,?,?,?)", arguments: StatementArguments(args))
    }
    for (ccy, rate) in s.rates {
      let args: [(any DatabaseValueConvertible)?] = [ccy, rate, s.rateUpdatedAt[ccy], s.homeCurrency == ccy]
      try db.execute(sql: "INSERT INTO rate (currency, rate_micro, updated_at, home) VALUES (?,?,?,?)", arguments: StatementArguments(args))
    }
  }

  // MARK: Plan (03a §5)

  private static func writePlan(_ db: Database, _ p: PlanState) throws {
    for (c, months) in p.cells {
      for (m, cell) in months {
        let args: [(any DatabaseValueConvertible)?] = [c, m, cell.latestSet, cell.onwardSet, cell.movesAll, cell.movesSinceSet]
        try db.execute(
          sql: "INSERT INTO plan_cell (category_id, month, latest_set_minor, onward_set_minor, moves_all_minor, moves_since_set_minor) VALUES (?,?,?,?,?,?)",
          arguments: StatementArguments(args))
      }
    }
    for m in p.moves.values {
      let args: [(any DatabaseValueConvertible)?] = [
        m.opID, m.position.seq, m.position.index, m.month, m.from, m.to, m.amount, m.reason, m.batchID, m.undoes, m.undone,
      ]
      try db.execute(
        sql: "INSERT INTO plan_move (op_id, seq, idx, month, from_category_id, to_category_id, amount_minor, reason, batch_id, undoes, undone) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
        arguments: StatementArguments(args))
    }
    for s in p.incomeSources.values {
      let args: [(any DatabaseValueConvertible)?] = [s.id, s.name, s.categoryID, s.amountMinor, s.payday, s.active]
      try db.execute(
        sql: "INSERT INTO income_source (id, name, category_id, amount_minor, payday, active) VALUES (?,?,?,?,?,?)", arguments: StatementArguments(args))
    }
    for (c, r) in p.roles {
      try db.execute(sql: "INSERT INTO category_plan_role (category_id, role) VALUES (?,?)", arguments: [c, r.role])
    }
    for w in p.overwrites {
      try db.execute(
        sql: "INSERT OR REPLACE INTO plan_overwrite (at_seq, key_kind, key, replaced_op, by_op, replaced_value) VALUES (?,?,?,?,?,?)",
        arguments: [w.atSeq, w.keyKind, w.key, w.replacedOp, w.byOp, w.replacedValue])
    }
  }

  // MARK: 03b (beta scope) and notices

  private static func write03b(_ db: Database, _ s: State) throws {
    for a in s.accounts.values {
      let args: [(any DatabaseValueConvertible)?] = [
        a.id, a.name, a.institution, a.kind, a.inPlan, a.currency, a.statementDueDay, a.active, a.closedOn, a.color, a.firstSeq,
      ]
      try db.execute(
        sql: "INSERT INTO account (id, name, institution, kind, in_plan, currency, statement_due_day, active, closed_on, color, first_seq) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
        arguments: StatementArguments(args))
    }
    for c in s.cards.values {
      let args: [(any DatabaseValueConvertible)?] = [c.bank, c.last4, c.state, c.account, c.atSeq]
      try db.execute(sql: "INSERT INTO card (bank, last4, state, account, at_seq) VALUES (?,?,?,?,?)", arguments: StatementArguments(args))
    }
    for (id, b) in s.bills {
      let keys = JSONWriter().string(.array(b.keys.map(JSONValue.string)))
      let args: [(any DatabaseValueConvertible)?] = [
        id, b.name, keys, b.direction, b.currency, b.amountMode, b.amountMinor, b.toleranceBp, b.cadence.unit, b.cadence.every, b.anchor,
        b.start, b.end, b.category, b.account, b.source, b.status, b.firstSeq, b.version,
      ]
      try db.execute(
        sql: "INSERT INTO bill (id, name, keys_json, direction, currency, amount_mode, amount_minor, tolerance_bp, cadence_unit, cadence_every, anchor, start, end, category, account, source, status, first_seq, version) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        arguments: StatementArguments(args))
    }
    for r in s.billResolutions.values {
      let args: [(any DatabaseValueConvertible)?] = [r.bill, r.due, r.resolution, r.txn, r.until, r.atSeq]
      try db.execute(
        sql: "INSERT INTO bill_resolution (bill, due, resolution, txn, until, at_seq) VALUES (?,?,?,?,?,?)", arguments: StatementArguments(args))
    }
    for c in s.checkins.values {
      let args: [(any DatabaseValueConvertible)?] = [
        c.id, c.account, c.asOf, (try? parseInstantMs(c.asOf)) ?? 0, c.balanceMinor, c.source, c.resolution, c.adjustmentMinor,
        c.void, c.atSeq,
      ]
      try db.execute(
        sql: "INSERT INTO checkin (id, account, as_of, as_of_ms, balance_minor, source, resolution, adjustment_minor, void, at_seq) VALUES (?,?,?,?,?,?,?,?,?,?)",
        arguments: StatementArguments(args))
    }
  }

  private static func writeNotices(_ db: Database, _ s: State) throws {
    for (i, f) in s.forks.enumerated() {
      try db.execute(
        sql: "INSERT INTO fork_notice (ord, entity_kind, entity_id, winner_op, loser_op, at_seq) VALUES (?,?,?,?,?,?)",
        arguments: [i + 1, f.entityKind, f.entityID, f.winnerOp, f.loserOp, f.atSeq])
    }
    for (i, a) in s.anomalies.enumerated() {
      try db.execute(sql: "INSERT INTO anomaly (ord, kind, detail, at_seq) VALUES (?,?,?,?)", arguments: [i + 1, a.kind, a.detail, a.atSeq])
    }
  }
}
