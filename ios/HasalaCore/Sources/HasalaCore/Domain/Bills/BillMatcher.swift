import CoreReplay
import CoreTime

public struct BillMatchInput: Sendable {
  public var id: String
  public var bill: CoreReplay.Bill

  public init(id: String, bill: CoreReplay.Bill) {
    self.id = id
    self.bill = bill
  }
}

public struct MatchRow: Sendable {
  public var txnID: String
  public var merchantKey: String
  public var direction: String
  public var amountMinor: Int64
  public var currency: String
  public var homeMinor: Int64?
  public var day: CivilDate
  public var eligible: Bool

  public init(
    txnID: String, merchantKey: String, direction: String, amountMinor: Int64, currency: String, homeMinor: Int64?, day: CivilDate,
    eligible: Bool
  ) {
    self.txnID = txnID
    self.merchantKey = merchantKey
    self.direction = direction
    self.amountMinor = amountMinor
    self.currency = currency
    self.homeMinor = homeMinor
    self.day = day
    self.eligible = eligible
  }
}

public struct BillMatch: Sendable, Equatable {
  public var bill: String
  public var due: CivilDate
  public var txnID: String
  public var explicit: Bool

  public init(bill: String, due: CivilDate, txnID: String, explicit: Bool) {
    self.bill = bill
    self.due = due
    self.txnID = txnID
    self.explicit = explicit
  }
}

public enum DueStatus: Sendable, Equatable {
  case paid(txnID: String?, explicit: Bool)
  case skipped
  case snoozed(until: CivilDate)
  case paused
  case notTracked
  case upcoming
  case due
  case late
}

public struct BillNoticeCore: Sendable, Equatable {
  public enum Kind: Sendable, Equatable {
    case priceChange(due: CivilDate, usualMinor: Int64, chargedMinor: Int64)
    case chargedWhilePaused(due: CivilDate)
    case chargedAfterEnd(day: CivilDate, chargedMinor: Int64)

    var order: Int {
      switch self {
      case .priceChange: 0
      case .chargedWhilePaused: 1
      case .chargedAfterEnd: 2
      }
    }
  }

  public var bill: String
  public var txnID: String
  public var kind: Kind

  public init(bill: String, txnID: String, kind: Kind) {
    self.bill = bill
    self.txnID = txnID
    self.kind = kind
  }
}

public struct BillMatcherResult: Sendable {
  public var matches: [BillMatch]
  public var notices: [BillNoticeCore]
  var explicit: [String: [CivilDate: BillResolution]]
  var derived: [String: [CivilDate: String]]
  var schedules: [String: BillScheduleView]

  init(
    matches: [BillMatch], notices: [BillNoticeCore], explicit: [String: [CivilDate: BillResolution]], derived: [String: [CivilDate: String]],
    schedules: [String: BillScheduleView]
  ) {
    self.matches = matches
    self.notices = notices
    self.explicit = explicit
    self.derived = derived
    self.schedules = schedules
  }

  public func status(bill: String, due: CivilDate, today: CivilDate) -> DueStatus {
    if let r = explicit[bill]?[due] {
      switch r.resolution {
      case "paid": return .paid(txnID: r.txn, explicit: true)
      case "skipped": return .skipped
      case "snoozed": return .snoozed(until: r.until.flatMap { CivilDate(wire: $0) } ?? due)
      default: break
      }
    }
    if let txn = derived[bill]?[due] { return .paid(txnID: txn, explicit: false) }
    if let v = schedules[bill] {
      if v.isPaused(due) { return .paused }
      if due < v.trackingSince { return .notTracked }
    }
    if due < today { return .late }
    if due == today { return .due }
    return .upcoming
  }
}

public enum BillMatcher {
  static let variableBp: Int64 = 5_000
  static let maxWindow = 45

  struct Candidate {
    var row: Int
    var bill: Int
    var due: CivilDate
    var distance: Int
  }

  struct Entry {
    var id: String
    var bill: CoreReplay.Bill
    var view: BillScheduleView
    var keys: Set<String>
  }

  public static func run(bills: [BillMatchInput], resolutions: [BillResolution], rows: [MatchRow], today: CivilDate) -> BillMatcherResult {
    var seenIDs = Set<String>()
    let ordered = bills.sorted { ($0.bill.firstSeq, $0.id) < ($1.bill.firstSeq, $1.id) }.filter { seenIDs.insert($0.id).inserted }
    var rank: [String: Int] = [:]
    var schedules: [String: BillScheduleView] = [:]
    var entries: [Entry] = []
    for (i, b) in ordered.enumerated() {
      rank[b.id] = i
      guard let v = BillScheduleView(b.bill) else { continue }
      schedules[b.id] = v
      if b.bill.status != "dismissed" { entries.append(Entry(id: b.id, bill: b.bill, view: v, keys: Set(b.bill.keys))) }
    }

    var explicit: [String: [CivilDate: BillResolution]] = [:]
    let sortedResolutions = resolutions.sorted { ($0.atSeq, $0.bill, $0.due) < ($1.atSeq, $1.bill, $1.due) }
    for r in sortedResolutions {
      guard let due = CivilDate(wire: r.due) else { continue }
      if r.resolution == "clear" {
        explicit[r.bill]?[due] = nil
      } else {
        explicit[r.bill, default: [:]][due] = r
      }
    }
    var named = Set<String>()
    for byDue in explicit.values {
      for r in byDue.values where r.resolution == "paid" {
        if let t = r.txn { named.insert(t) }
      }
    }

    var seenRows = Set<String>()
    let allRows = rows.sorted { ($0.day, $0.txnID) < ($1.day, $1.txnID) }.filter { seenRows.insert($0.txnID).inserted }
    let byTxn = Dictionary(allRows.map { ($0.txnID, $0) }, uniquingKeysWith: { a, _ in a })
    let open = allRows.filter { $0.eligible && $0.amountMinor > 0 && !named.contains($0.txnID) }

    var candidates: [Candidate] = []
    for (ri, row) in open.enumerated() {
      var best: (diff: Int64, bill: Int, pairs: [Candidate])?
      for (bi, e) in entries.enumerated() where e.keys.contains(row.merchantKey) && e.bill.direction == row.direction {
        guard let amount = chargedAmount(row, currency: e.bill.currency) else { continue }
        let lo = row.day.adding(days: -maxWindow) ?? row.day
        let hi = row.day.adding(days: maxWindow) ?? row.day
        var pairs: [Candidate] = []
        for d in e.view.dues(from: lo, through: hi) where explicit[e.id]?[d] == nil {
          let distance = Int(abs(row.day.daysSinceEpoch - d.daysSinceEpoch))
          guard distance <= e.view.halfWindowDays(at: d), within(amount, e.view.terms(at: d).amountMinor, bp: variableBp) else { continue }
          pairs.append(Candidate(row: ri, bill: bi, due: d, distance: distance))
        }
        guard let first = pairs.min(by: { ($0.distance, $0.due) < ($1.distance, $1.due) }) else { continue }
        let diff = gap(amount, e.view.terms(at: first.due).amountMinor)
        if best == nil || diff < best!.diff { best = (diff, bi, pairs) }
      }
      if let best { candidates.append(contentsOf: best.pairs) }
    }
    candidates.sort { ($0.distance, $0.due, $0.row, $0.bill) < ($1.distance, $1.due, $1.row, $1.bill) }

    var takenRows = Set<Int>()
    var takenDues = Set<String>()
    var derived: [String: [CivilDate: String]] = [:]
    var matches: [BillMatch] = []
    var notices: [BillNoticeCore] = []
    for c in candidates {
      let e = entries[c.bill]
      let dueKey = "\(c.bill)|\(c.due.wire)"
      guard !takenRows.contains(c.row), !takenDues.contains(dueKey) else { continue }
      takenRows.insert(c.row)
      takenDues.insert(dueKey)
      let row = open[c.row]
      derived[e.id, default: [:]][c.due] = row.txnID
      matches.append(BillMatch(bill: e.id, due: c.due, txnID: row.txnID, explicit: false))
      if let n = priceNotice(e, due: c.due, row: row) { notices.append(n) }
      if e.view.isPaused(c.due) { notices.append(BillNoticeCore(bill: e.id, txnID: row.txnID, kind: .chargedWhilePaused(due: c.due))) }
    }

    for e in entries {
      for (due, r) in explicit[e.id] ?? [:] where r.resolution == "paid" {
        guard let txn = r.txn else { continue }
        matches.append(BillMatch(bill: e.id, due: due, txnID: txn, explicit: true))
        if let row = byTxn[txn], row.eligible, let n = priceNotice(e, due: due, row: row) { notices.append(n) }
      }
    }

    let ended = entries.compactMap { e -> (Entry, CivilDate, CivilDate)? in
      guard let end = e.view.end, let after = end.adding(days: 1) else { return nil }
      var unbounded = e.bill
      unbounded.end = nil
      unbounded.status = "active"
      guard let v = BillScheduleView(unbounded), let next = v.due(onOrAfter: after),
        let limit = next.adding(days: v.halfWindowDays(at: next))
      else { return nil }
      return (e, end, limit)
    }
    if !ended.isEmpty {
      for (ri, row) in open.enumerated() where !takenRows.contains(ri) {
        var best: (diff: Int64, entry: Entry, amount: Int64)?
        for (e, end, limit) in ended where e.keys.contains(row.merchantKey) && e.bill.direction == row.direction {
          guard row.day > end, row.day <= limit, let amount = chargedAmount(row, currency: e.bill.currency) else { continue }
          let usual = e.view.terms(at: end).amountMinor
          guard within(amount, usual, bp: variableBp) else { continue }
          let diff = gap(amount, usual)
          if best == nil || diff < best!.diff { best = (diff, e, amount) }
        }
        if let best {
          notices.append(BillNoticeCore(bill: best.entry.id, txnID: row.txnID, kind: .chargedAfterEnd(day: row.day, chargedMinor: best.amount)))
        }
      }
    }

    let rk = { (id: String) in rank[id] ?? Int.max }
    matches.sort { (rk($0.bill), $0.bill, $0.due, $0.txnID) < (rk($1.bill), $1.bill, $1.due, $1.txnID) }
    notices.sort { (rk($0.bill), $0.bill, $0.txnID, $0.kind.order) < (rk($1.bill), $1.bill, $1.txnID, $1.kind.order) }
    return BillMatcherResult(matches: matches, notices: notices, explicit: explicit, derived: derived, schedules: schedules)
  }

  public static func suggestions(
    keys: [String], terms: BillTerms, currency: String, rows: [MatchRow], taken: Set<String>, limit: Int
  ) -> [MatchRow] {
    guard limit > 0 else { return [] }
    let keySet = Set(keys)
    let bp = terms.variable ? variableBp : terms.toleranceBp
    var seen = Set<String>()
    let picked = rows.filter { row in
      guard row.eligible, row.direction == "debit", keySet.contains(row.merchantKey), !taken.contains(row.txnID),
        let amount = chargedAmount(row, currency: currency)
      else { return false }
      return within(amount, terms.amountMinor, bp: bp)
    }
    .sorted { $0.day != $1.day ? $0.day > $1.day : $0.txnID < $1.txnID }
    .filter { seen.insert($0.txnID).inserted }
    return Array(picked.prefix(limit))
  }

  static func chargedAmount(_ row: MatchRow, currency: String) -> Int64? {
    let amount: Int64?
    if row.currency == currency {
      amount = row.amountMinor
    } else if currency == "AED" {
      amount = row.homeMinor
    } else {
      amount = nil
    }
    guard let amount, amount > 0 else { return nil }
    return amount
  }

  static func gap(_ a: Int64, _ b: Int64) -> Int64 {
    let (d, o) = a.subtractingReportingOverflow(b)
    if o { return Int64.max }
    return d == Int64.min ? Int64.max : abs(d)
  }

  static func within(_ amount: Int64, _ usual: Int64, bp: Int64) -> Bool {
    guard amount > 0, usual > 0, bp >= 0 else { return false }
    let l = gap(amount, usual).multipliedFullWidth(by: 10_000)
    let r = usual.multipliedFullWidth(by: bp)
    return (l.high, l.low) <= (r.high, r.low)
  }

  static func priceNotice(_ e: Entry, due: CivilDate, row: MatchRow) -> BillNoticeCore? {
    let terms = e.view.terms(at: due)
    guard !terms.variable, let amount = chargedAmount(row, currency: e.bill.currency),
      !within(amount, terms.amountMinor, bp: terms.toleranceBp)
    else { return nil }
    return BillNoticeCore(bill: e.id, txnID: row.txnID, kind: .priceChange(due: due, usualMinor: terms.amountMinor, chargedMinor: amount))
  }
}
