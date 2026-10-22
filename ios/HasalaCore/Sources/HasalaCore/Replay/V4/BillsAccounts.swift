// 03b §3.2-§4.4: bills and accounts, folded so a v4 log carrying them folds
// without anomalies and the records reach the projection.
//
// Beta scope (TODO(03b parity)): the payload grammars of 03b §3.2-§4.4 and the
// fold rules (head check, `forget`/`clear` removals, check-in account pinning)
// are implemented; 03b §1.5's write memory and `RecordOverwrite` notices are
// not yet (they never change an installed value, only add a notice), and the
// derived engines (detector, matcher, balance) live above the fold and are not
// part of this lane.
import CoreJSON
import CoreTime
import CoreWire
import HasalaText

extension Replay {
  public static func billRecord(_ op: Op) -> Bill? {
    guard op.type == .billSet, let p = op.payload.objectValue else { return nil }
    return try? State.decodeBill(p)
  }

  public static func billRecord(_ op: Op, inheritingFrom current: Bill?) -> Bill? {
    guard op.type == .billSet, let p = op.payload.objectValue, let decoded = try? State.decodeBillPayload(p) else {
      return nil
    }
    let (b, inherit) = decoded
    guard op.parentVersion != nil, inherit != .none else { return b }
    guard let current else { return nil }
    return try? State.inheritBillLists(b, from: current, inherit)
  }
}

struct BillInherit: Equatable {
  var changes: Bool
  var pauses: Bool

  static let none = BillInherit(changes: false, pauses: false)
}

extension State {
  static func billCreatedAt(_ op: Op) -> String {
    guard let s = op.payload.objectValue?["created_at"]?.stringValue, let ms = try? parseInstantMs(s),
      let authored = try? parseInstantMs(op.authoredAt), ms <= authored, let iso = Instant.iso(ms)
    else { return op.authoredAt }
    return iso
  }

  static func decodeBill(_ p: JSONObject) throws(PayloadError) -> Bill {
    let name = try P.label(p["name"], "name")
    guard let list = p["keys"]?.arrayValue, (1...8).contains(list.count) else { throw PayloadError("keys must hold 1-8 keys") }
    var keys: [String] = []
    for (i, k) in list.enumerated() {
      guard let s = k.stringValue, Grammar.isBillKey(s) else { throw PayloadError("keys[\(i)] is not a Key") }
      if keys.contains(where: { utf8Equal($0, s) }) { throw PayloadError("keys[\(i)] repeats an earlier key") }
      keys.append(s)
    }
    let direction = try P.direction(p["direction"])
    let currency = try P.currency(p, "currency", v: 4)
    let mode = try P.oneOf(p["amount_mode"], "amount_mode", ["fixed", "variable"])
    let amount = try P.minorV4(p["amount_minor"], "amount_minor", positive: true)
    guard p["tolerance_bp"] != nil else { throw PayloadError("tolerance_bp is required") }
    var tolerance: Int64?
    if mode == "fixed" {
      tolerance = try P.intV4(p["tolerance_bp"], "tolerance_bp", 0...5000)
    } else if P.present(p["tolerance_bp"]) != nil {
      throw PayloadError("a variable bill carries no tolerance_bp")
    }
    let co = try P.object(p["cadence"], "cadence")
    let unit = try P.oneOf(co["unit"], "cadence.unit", ["day", "week", "month", "year"])
    let maxEvery: Int64 = ["day": 365, "week": 52, "month": 24, "year": 10][unit] ?? 1
    let every = try P.intV4(co["every"], "cadence.every", 1...maxEvery)
    let anchor = try P.civilDate(p["anchor"], "anchor")
    let start = try P.civilDate(p["start"], "start")
    guard p["end"] != nil else { throw PayloadError("end is required (null for none)") }
    let end = P.present(p["end"]) == nil ? nil : try P.civilDate(p["end"], "end")
    if let end, let e = CivilDate(wire: end), let s = CivilDate(wire: start), !(s < e) {
      throw PayloadError("end must be after start")
    }
    guard p["category"] != nil, p["account"] != nil else { throw PayloadError("category and account are required (nullable)") }
    let category = P.present(p["category"]) == nil ? nil : try P.categoryID(p["category"], "category")
    let account = P.present(p["account"]) == nil ? nil : try P.id03b(p["account"], "account")
    let source = try P.oneOf(p["source"], "source", ["manual", "detected"])
    let status = try P.oneOf(p["status"], "status", ["active", "cancelled", "dismissed"])
    if status == "cancelled" && end == nil { throw PayloadError("a cancelled bill needs an end") }
    let startDate = CivilDate(wire: start)!
    let endDate = end.flatMap(CivilDate.init(wire:))
    let changes = try decodeBillChanges(p["changes"], start: startDate, end: endDate)
    let pauses = try decodeBillPauses(p["pauses"], start: startDate)
    return Bill(
      name: name, keys: keys, direction: direction, currency: currency, amountMode: mode, amountMinor: amount,
      toleranceBp: tolerance, cadence: BillCadence(unit: unit, every: every), anchor: anchor, start: start, end: end,
      category: category, account: account, source: source, status: status, changes: changes, pauses: pauses,
      firstSeq: 0, version: 0)
  }

  static func decodeBillPayload(_ p: JSONObject) throws(PayloadError) -> (Bill, BillInherit) {
    (try decodeBill(p), BillInherit(changes: p["changes"] == nil, pauses: p["pauses"] == nil))
  }

  static func inheritBillLists(_ b: Bill, from old: Bill, _ inherit: BillInherit) throws(PayloadError) -> Bill {
    guard let start = CivilDate(wire: b.start) else { throw PayloadError("start is not a LocalDay") }
    let end = b.end.flatMap(CivilDate.init(wire:))
    var out = b
    if inherit.changes {
      for (i, c) in old.changes.enumerated() {
        guard let from = CivilDate(wire: c.from) else { throw PayloadError("inherited changes[\(i)].from is not a LocalDay") }
        if from < start { throw PayloadError("inherited changes[\(i)].from is before start") }
        if let end, end < from { throw PayloadError("inherited changes[\(i)].from is after end") }
      }
      out.changes = old.changes
    }
    if inherit.pauses {
      for (i, p) in old.pauses.enumerated() {
        guard let from = CivilDate(wire: p.from) else { throw PayloadError("inherited pauses[\(i)].from is not a LocalDay") }
        if from < start { throw PayloadError("inherited pauses[\(i)].from is before start") }
      }
      out.pauses = old.pauses
    }
    return out
  }

  static let maxBillChanges = 24
  static let maxBillPauses = 24

  static func decodeBillChanges(_ v: JSONValue?, start: CivilDate, end: CivilDate?) throws(PayloadError) -> [BillChange] {
    guard let v = P.present(v) else { return [] }
    guard let list = v.arrayValue else { throw PayloadError("changes must be an array") }
    guard list.count <= maxBillChanges else { throw PayloadError("changes holds at most \(maxBillChanges) entries") }
    var out: [BillChange] = []
    var last: CivilDate?
    for (i, item) in list.enumerated() {
      let o = try P.object(item, "changes[\(i)]")
      let from = try P.civilDate(o["from"], "changes[\(i)].from")
      let date = CivilDate(wire: from)!
      if date < start { throw PayloadError("changes[\(i)].from is before start") }
      if let end, end < date { throw PayloadError("changes[\(i)].from is after end") }
      if let last, !(last < date) { throw PayloadError("changes[\(i)].from must be after the previous change") }
      last = date
      let mode = try P.oneOf(o["amount_mode"], "changes[\(i)].amount_mode", ["fixed", "variable"])
      let amount = try P.minorV4(o["amount_minor"], "changes[\(i)].amount_minor", positive: true)
      guard o["tolerance_bp"] != nil else { throw PayloadError("changes[\(i)].tolerance_bp is required") }
      var tolerance: Int64?
      if mode == "fixed" {
        tolerance = try P.intV4(o["tolerance_bp"], "changes[\(i)].tolerance_bp", 0...5000)
      } else if P.present(o["tolerance_bp"]) != nil {
        throw PayloadError("changes[\(i)]: a variable change carries no tolerance_bp")
      }
      out.append(BillChange(from: from, amountMode: mode, amountMinor: amount, toleranceBp: tolerance))
    }
    return out
  }

  static func decodeBillPauses(_ v: JSONValue?, start: CivilDate) throws(PayloadError) -> [BillPause] {
    guard let v = P.present(v) else { return [] }
    guard let list = v.arrayValue else { throw PayloadError("pauses must be an array") }
    guard list.count <= maxBillPauses else { throw PayloadError("pauses holds at most \(maxBillPauses) ranges") }
    var out: [BillPause] = []
    var previousUntil: CivilDate?
    for (i, item) in list.enumerated() {
      let o = try P.object(item, "pauses[\(i)]")
      let from = try P.civilDate(o["from"], "pauses[\(i)].from")
      let fromDate = CivilDate(wire: from)!
      if fromDate < start { throw PayloadError("pauses[\(i)].from is before start") }
      if i > 0 {
        guard let previousUntil else { throw PayloadError("pauses[\(i - 1)] is open but is not the last range") }
        if fromDate < previousUntil { throw PayloadError("pauses[\(i)] overlaps the previous range") }
      }
      guard o["until"] != nil else { throw PayloadError("pauses[\(i)].until is required (null for open)") }
      var until: String?
      if P.present(o["until"]) != nil {
        let u = try P.civilDate(o["until"], "pauses[\(i)].until")
        let untilDate = CivilDate(wire: u)!
        if !(fromDate < untilDate) { throw PayloadError("pauses[\(i)].until must be after from") }
        until = u
        previousUntil = untilDate
      } else {
        previousUntil = nil
      }
      out.append(BillPause(from: from, until: until))
    }
    return out
  }

  mutating func applyBillOccurrenceSet(_ e: LogEntry) throws(PayloadError) {
    let p = try P.object(e.op)
    let bill = try P.id03b(p["bill"], "bill")
    let due = try P.civilDate(p["due"], "due")
    let resolution = try P.oneOf(p["resolution"], "resolution", ["paid", "skipped", "snoozed", "clear"])
    var txn: String?
    if let v = P.present(p["txn"]) {
      guard resolution == "paid" else { throw PayloadError("txn is allowed only on paid") }
      guard let s = v.stringValue, !s.isEmpty, s.utf8.count <= 128 else { throw PayloadError("txn must be a TxnRef") }
      txn = s
    }
    var until: String?
    if resolution == "snoozed" {
      until = try P.civilDate(p["until"], "until")
    } else if P.present(p["until"]) != nil {
      throw PayloadError("until is allowed only on snoozed")
    }
    guard heads[State.entityKey("bill", bill)] != nil else {
      anomaly(e.seq, "unknown_entity", "\(e.op.opID): resolves bill \(bill), which no create introduced")
      return
    }
    let key = bill + "\u{0}" + due
    if resolution == "clear" {
      billResolutions[key] = nil
      return
    }
    billResolutions[key] = BillResolution(bill: bill, due: due, resolution: resolution, txn: txn, until: until, atSeq: e.seq)
  }

  mutating func applyAccountSet(_ e: LogEntry) throws(PayloadError) {
    let p = try P.object(e.op)
    let id = try P.id03b(p["id"], "id")
    let name = try P.label(p["name"], "name")
    var institution: String?
    if let v = P.present(p["institution"]) {
      guard let s = v.stringValue, Grammar.isBank(s) else { throw PayloadError("institution must be a Bank") }
      institution = s
    }
    let kind = try P.oneOf(
      p["kind"], "kind", ["current", "savings", "credit_card", "cash", "loan", "investment", "property", "other"])
    let inPlan = try P.boolField(p["in_plan"], "in_plan")
    let currency = try P.currency(p, "currency", v: 4)
    var due: Int64?
    if let v = P.present(p["statement_due_day"]) {
      guard kind == "credit_card" else { throw PayloadError("statement_due_day is only for credit cards") }
      due = try P.intV4(v, "statement_due_day", 1...31)
    }
    let active = try P.boolField(p["active"], "active")
    let closed = P.present(p["closed_on"]) == nil ? nil : try P.civilDate(p["closed_on"], "closed_on")
    if active == (closed != nil) { throw PayloadError("closed_on is present iff the account is inactive") }
    var color: String?
    if let v = P.present(p["color"]) {
      guard let s = v.stringValue, (1...32).contains(s.utf8.count) else { throw PayloadError("color must be 1-32 bytes") }
      color = s
    }
    let firstSeq = accounts[id]?.firstSeq ?? e.seq
    accounts[id] = Account(
      id: id, name: name, institution: institution, kind: kind, inPlan: inPlan, currency: currency, statementDueDay: due,
      active: active, closedOn: closed, color: color, firstSeq: firstSeq)
  }

  mutating func applyCardLinked(_ e: LogEntry) throws(PayloadError) {
    let p = try P.object(e.op)
    var bank: String?
    if let v = P.present(p["bank"]) {
      guard let s = v.stringValue, Grammar.isBank(s) else { throw PayloadError("bank must be a Bank") }
      bank = s
    }
    guard let last4 = p["last4"]?.stringValue, Grammar.isLast4(last4) else { throw PayloadError("last4 must be four digits") }
    let state = try P.oneOf(p["state"], "state", ["mine", "not_mine", "forget"])
    var account: String?
    if state == "mine" {
      account = try P.id03b(p["account"], "account")
    } else if P.present(p["account"]) != nil {
      throw PayloadError("account is allowed only when the card is mine")
    }
    let key = (bank ?? "") + "\u{0}" + last4
    switch state {
    case "forget":
      cards[key] = nil
    case "mine":
      guard accounts[account!] != nil else {
        anomaly(e.seq, "unknown_entity", "\(e.op.opID): links a card to account \(account!), which no account_set introduced")
        return
      }
      cards[key] = CardLink(bank: bank, last4: last4, state: state, account: account, atSeq: e.seq)
    default:
      cards[key] = CardLink(bank: bank, last4: last4, state: state, account: nil, atSeq: e.seq)
    }
  }

  mutating func applyAccountCheckin(_ e: LogEntry) throws(PayloadError) {
    let p = try P.object(e.op)
    let id = try P.id03b(p["id"], "id")
    let account = try P.id03b(p["account"], "account")
    let asOf = try P.instant(p["as_of"], "as_of")
    let balance = try P.minorV4(p["balance_minor"], "balance_minor", signed: true)
    let source = try P.oneOf(p["source"], "source", ["checkin", "update"])
    var resolution: String?
    if let v = P.present(p["resolution"]) {
      guard source == "checkin" else { throw PayloadError("an update carries no resolution") }
      resolution = try P.oneOf(v, "resolution", ["add_txn", "adjusted", "kept"])
    }
    var adjustment: Int64?
    if resolution == "adjusted" {
      adjustment = try P.minorV4(p["adjustment_minor"], "adjustment_minor", signed: true)
      if adjustment == 0 { throw PayloadError("adjustment_minor must not be zero") }
    } else if P.present(p["adjustment_minor"]) != nil {
      throw PayloadError("adjustment_minor is only for an adjusted check-in")
    }
    let void = P.present(p["void"]) == nil ? false : try P.boolField(p["void"], "void")
    guard accounts[account] != nil else {
      anomaly(e.seq, "unknown_entity", "\(e.op.opID): checks in account \(account), which no account_set introduced")
      return
    }
    if let existing = checkins[id], !utf8Equal(existing.account, account) {
      throw PayloadError("check-in \(id) belongs to another account")
    }
    checkins[id] = Checkin(
      id: id, account: account, asOf: asOf, balanceMinor: balance, source: source, resolution: resolution,
      adjustmentMinor: adjustment, void: void, atSeq: e.seq)
  }
}
