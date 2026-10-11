// 03a §3-§4: the plan family's fold (`budget_set`, `budget_moved`,
// `income_source_set`, `category_plan_role_set`). Every type is parent-free;
// keyed records are last write by position (03a §3.0.1) with the P-11
// overwrite notice; moves are additive facts.
//
// Deviation (spec 04 §2.2 / 03a §4.2): the family folds here, in CoreReplay's
// V4 carve-out, rather than through a `FoldFamily` registered from CoreDomain.
// The rules and the witness shape are 03a's; only the placement differs. It
// keeps `State` a plain Codable value (the snapshot) with no existential family
// box in the hot fold path. `PlanState` is still the 03a type.
//
// The fold never consults the taxonomy, the transactions or a clock
// (03a §4.1): every cross-record rule is a read-time rule in `PlanEngine`.
import CoreJSON
import CoreTime
import CoreWire
import HasalaText
import OrderedCollections

extension State {
  private func planWrite(_ e: LogEntry) -> PlanWrite {
    PlanWrite(opID: e.op.opID, writerID: e.writerID, atMs: (try? parseInstantMs(e.op.authoredAt)) ?? 0)
  }

  /// 03a §3.0.1 rule 2: another writer replacing a value with an EARLIER stamp.
  private mutating func noteOverwrite(_ kind: String, _ key: String, _ cur: PlanWrite?, _ curValue: String?, _ w: PlanWrite, seq: Int64) {
    guard let cur, !utf8Equal(cur.writerID, w.writerID), w.atMs < cur.atMs else { return }
    plan.overwrites.append(
      PlanOverwrite(keyKind: kind, key: key, replacedOp: cur.opID, byOp: w.opID, atSeq: seq, replacedValue: curValue ?? ""))
  }

  mutating func applyBudgetSet(_ e: LogEntry) throws(PayloadError) {
    let p = try P.object(e.op)
    let c = try P.categoryID(p["category_id"], "category_id")
    let m = try P.civilMonth(p["month"], "month")
    let a = try P.planMinor(p["amount_minor"], "amount_minor")
    let scope = try P.oneOf(p["scope"], "scope", ["onward", "only"])
    let w = planWrite(e)
    var cell = plan.cells[c]?[m] ?? PlanCell()
    noteOverwrite("budget", c + "|" + m, cell.latestSetWrite, cell.latestSet.map { String($0) }, w, seq: e.seq)
    cell.latestSet = a
    cell.latestSetWrite = w
    if scope == "onward" { cell.onwardSet = a }
    cell.movesSinceSet = 0
    plan.cells[c, default: [:]][m] = cell
  }

  mutating func applyBudgetMoved(_ e: LogEntry) throws(PayloadError) {
    let p = try P.object(e.op)
    let m = try P.civilMonth(p["month"], "month")
    let from = P.present(p["from_category_id"]) == nil ? nil : try P.categoryID(p["from_category_id"], "from_category_id")
    let to = P.present(p["to_category_id"]) == nil ? nil : try P.categoryID(p["to_category_id"], "to_category_id")
    let a = try P.planMinor(p["amount_minor"], "amount_minor", positive: true)
    let reason = try P.oneOf(p["reason"], "reason", ["move", "assign", "auto_assign", "undo"])
    let batch = try optionalToken(p["batch_id"], "batch_id")
    let undoes = try optionalToken(p["undoes"], "undoes")
    if from == nil && to == nil { throw PayloadError("a move names at least one category") }
    if let f = from, let t = to, utf8Equal(f, t) { throw PayloadError("a move cannot go from a category to itself") }
    if (reason == "undo") != (undoes != nil) { throw PayloadError("reason undo goes with undoes, and only with it") }

    if let u = undoes {
      guard let rec = plan.moves[u], !rec.undone, rec.undoes == nil, utf8Equal(rec.month, m),
        rec.from == to, rec.to == from, rec.amount == a
      else {
        anomaly(e.seq, "plan_undo_mismatch", "\(e.op.opID): undoes \(u), which it does not reverse")
        return
      }
    }
    // Every new value is computed with checked arithmetic before any mutation.
    var staged: [(String, PlanCell)] = []
    for (leg, delta) in [(from, -a), (to, a)] {
      guard let leg else { continue }
      var cell = plan.cells[leg]?[m] ?? PlanCell()
      let (all, o1) = cell.movesAll.addingReportingOverflow(delta)
      let (since, o2) = cell.movesSinceSet.addingReportingOverflow(delta)
      if o1 || o2 {
        anomaly(e.seq, "money_overflow", "\(e.op.opID): the move overflows int64")
        return
      }
      cell.movesAll = all
      cell.movesSinceSet = since
      staged.append((leg, cell))
    }
    for (leg, cell) in staged { plan.cells[leg, default: [:]][m] = cell }
    plan.moves[e.op.opID] = MoveRecord(
      opID: e.op.opID, position: e.position, month: m, from: from, to: to, amount: a, reason: reason, batchID: batch,
      undoes: undoes, undone: false)
    if let u = undoes { plan.moves[u]?.undone = true }
  }

  mutating func applyIncomeSourceSet(_ e: LogEntry) throws(PayloadError) {
    let p = try P.object(e.op)
    guard let id = p["id"]?.stringValue, Grammar.isPlanRecordID(id) else {
      throw PayloadError("id must be a plan record id, got \(showValue(p["id"]))")
    }
    let name = try P.label(p["name"], "name")
    let c = try P.categoryID(p["category_id"], "category_id")
    let a = try P.planMinor(p["amount_minor"], "amount_minor")
    let payday = try P.intV4(p["payday"], "payday", 1...31)
    let active = try P.boolField(p["active"], "active")
    let w = planWrite(e)
    let cur = plan.incomeSources[id]
    noteOverwrite("income_source", id, cur?.write, cur.map { String($0.amountMinor) }, w, seq: e.seq)
    plan.incomeSources[id] = IncomeSource(id: id, name: name, categoryID: c, amountMinor: a, payday: payday, active: active, write: w)
  }

  mutating func applyCategoryPlanRoleSet(_ e: LogEntry) throws(PayloadError) {
    let p = try P.object(e.op)
    let c = try P.categoryID(p["category_id"], "category_id")
    let role = try P.oneOf(p["role"], "role", ["everyday", "bills"])
    let w = planWrite(e)
    let cur = plan.roles[c]
    noteOverwrite("plan_role", c, cur?.write, cur?.role, w, seq: e.seq)
    plan.roles[c] = PlanRoleRecord(role: role, write: w)
  }

  /// `batch_id` / `undoes`: absent and null are equivalent; otherwise a
  /// non-empty printable-ASCII string of at most 64 bytes.
  private func optionalToken(_ v: JSONValue?, _ what: String) throws(PayloadError) -> String? {
    guard let v = P.present(v) else { return nil }
    guard let s = v.stringValue, (1...64).contains(s.utf8.count), s.utf8.allSatisfy({ $0 > 0x20 && $0 < 0x7f }) else {
      throw PayloadError("\(what) must be an id, got \(showValue(v))")
    }
    return s
  }
}
