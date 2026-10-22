import CoreCategorize
import CoreDomain
import CoreMailbox
import CoreProjection
import CoreReplay
import CoreTime
import CoreWire
import Foundation
import HasalaModels

nonisolated extension LedgerStateMapper {
  typealias BillRecord = CoreReplay.Bill

  struct BillFeed: Sendable {
    var taxonomy: TaxonomyView
    var records: [(id: String, bill: CoreReplay.Bill)]
    var resolutions: [BillResolution]
    var derived: Derived
    var expectations: [BillExpectation]
    var billOfTxn: [String: String]
    var candidates: [BillCandidate]
  }

  static func billFeed(_ r: LedgerReader, rows: [TxnRow], today: CivilDate) throws -> BillFeed {
    let taxonomy = try r.taxonomy()
    let records = try r.bills()
    let resolutions = try r.billResolutions()
    let home = try r.homeCurrency() ?? "AED"
    let derived = derive(records, resolutions: resolutions, rows: rows, today: today)
    let roles = CoreDomain.PlanEngine(plan: try r.planState(), taxonomy: taxonomy, lines: [], today: today)
    let expectations = expectations(
      records, derived: derived, month: today.yearMonth, today: today, home: home, role: { roles.role($0) })
    return BillFeed(
      taxonomy: taxonomy, records: records, resolutions: resolutions, derived: derived, expectations: expectations,
      billOfTxn: billOfTxn(records, resolutions: resolutions, matched: derived.matched),
      candidates: candidates(derived.candidates, taxonomy: taxonomy))
  }

  static func liveBills(
    _ feed: BillFeed, r: LedgerReader, context c: Context, txns: [HasalaModels.Txn],
    income sources: some Sequence<IncomeSource>
  ) throws -> [HasalaModels.Bill] {
    var bills: [HasalaModels.Bill] = []
    let paidAmount = Dictionary(txns.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    var byBill: [String: [BillResolution]] = [:]
    for res in feed.resolutions { byBill[res.bill, default: []].append(res) }
    let current = Dictionary(feed.records.map { ($0.id, $0.bill) }, uniquingKeysWith: { a, _ in a })
    let forks = forkNotices(try r.forkNotices(kind: "bill"), records: current, losers: c.forkOps)
    for (id, b) in feed.records {
      if var mapped = bill(
        id: id, b, resolutions: byBill[id] ?? [], matched: feed.derived.matched[id] ?? [], result: feed.derived.result,
        notices: feed.derived.notices[id] ?? [], today: c.today, taxonomy: feed.taxonomy, paidAmount: paidAmount)
      {
        mapped.notices += forks[id] ?? []
        mapped.notices = notices(mapped.notices, dismissed: c.dismissedNotices, salt: c.digestSalt)
        if let usual = mapped.priceChangeFrom, let txn = mapped.payments.first?.txnID,
          !mapped.notices.contains(where: { $0.id == "priceChange.\(txn)" })
        {
          mapped.amount = usual
          mapped.priceChangeFrom = nil
        }
        bills.append(mapped)
      }
    }
    for s in sources {
      bills.append(income(s, today: c.today, taxonomy: feed.taxonomy))
    }
    return bills
  }

  struct DerivedMatch: Sendable, Equatable {
    var due: CivilDate
    var txnID: String
  }

  struct Derived: Sendable {
    var result: BillMatcherResult
    var matched: [String: [DerivedMatch]]
    var notices: [String: [BillNoticeCore]]
    var days: [String: CivilDate]
    var candidates: [BillCandidateCore]
  }

  static func billEligible(_ row: TxnRow) -> Bool {
    row.direction == "debit" && BillEdits.linkable(row, direction: "debit")
  }

  struct DeriveRows {
    var match: [MatchRow] = []
    var detect: [DetectRow] = []
    var days: [String: CivilDate] = [:]
  }

  static func deriveRows(_ rows: [TxnRow], match wantMatch: Bool = true) -> DeriveRows {
    var out = DeriveRows()
    if wantMatch { out.match.reserveCapacity(rows.count) }
    out.detect.reserveCapacity(rows.count)
    for row in rows {
      guard let day = CivilDate(wire: row.localDate) else { continue }
      let eligible = billEligible(row)
      if wantMatch {
        out.days[row.id] = day
        out.match.append(
          MatchRow(
            txnID: row.id, merchantKey: row.merchantKey, direction: row.direction, amountMinor: row.amountMinor,
            currency: row.currency, homeMinor: row.amountHomeMinor, day: day, eligible: eligible))
      }
      out.detect.append(
        DetectRow(
          txnID: row.id, merchantKey: row.merchantKey, merchantName: row.displayName, direction: row.direction,
          amountMinor: row.amountMinor, currency: row.currency, day: day, category: row.category,
          eligible: eligible && Grammar.isBillKey(row.merchantKey)))
    }
    return out
  }

  static func derive(
    _ records: [(id: String, bill: CoreReplay.Bill)], resolutions: [BillResolution], rows: [TxnRow], today: CivilDate
  ) -> Derived {
    let built = deriveRows(rows)
    let result = BillMatcher.run(
      bills: records.map { BillMatchInput(id: $0.id, bill: $0.bill) }, resolutions: resolutions, rows: built.match,
      today: today)
    var matched: [String: [DerivedMatch]] = [:]
    for m in result.matches where !m.explicit {
      matched[m.bill, default: []].append(DerivedMatch(due: m.due, txnID: m.txnID))
    }
    var notices: [String: [BillNoticeCore]] = [:]
    for n in result.notices { notices[n.bill, default: []].append(n) }
    let candidates = detect(records, built.detect, today: today)
    return Derived(result: result, matched: matched, notices: notices, days: built.days, candidates: candidates)
  }

  static func detect(_ records: [(id: String, bill: CoreReplay.Bill)], _ rows: [DetectRow], today: CivilDate)
    -> [BillCandidateCore]
  {
    BillDetector.run(rows: rows, coveredKeys: Set(records.flatMap(\.bill.keys)), today: today)
  }

  static func detect(_ records: [(id: String, bill: CoreReplay.Bill)], rows: [TxnRow], today: CivilDate)
    -> [BillCandidateCore]
  {
    detect(records, deriveRows(rows, match: false).detect, today: today)
  }

  static func candidates(_ found: [BillCandidateCore], taxonomy: TaxonomyView) -> [BillCandidate] {
    found.map { c in
      let category = c.category.flatMap { id in taxonomy.info(id).flatMap { $0.kind == .spending ? id : nil } }
      return BillCandidate(
        id: c.id, name: c.name, categoryID: category ?? "subscriptions",
        amount: Money(minor: c.amountMinor, currency: c.currency), seenCount: c.seen,
        everyDays: everyDays(c.unit, every: Int(c.every)), last: local(c.last))
    }
  }

  static func everyDays(_ unit: String, every: Int) -> Int {
    switch unit {
    case "day": every
    case "week": 7 * every
    case "year": 365 * every
    default: 30 * every
    }
  }

  static func expectations(
    _ records: [(id: String, bill: CoreReplay.Bill)], derived: Derived, month: CivilMonth, today: CivilDate, home: String,
    role: (String) -> String?
  ) -> [BillExpectation] {
    var out: [BillExpectation] = []
    for (id, b) in records where b.status == "active" && b.direction == "debit" && b.currency == home {
      let category = b.category ?? "utilities"
      guard role(category) == "bills", let v = BillScheduleView(b) else { continue }
      for d in v.dues(from: month.firstDay, through: month.lastDay) {
        let status: BillExpectation.Status
        var paidDay: CivilDate?
        switch derived.result.status(bill: id, due: d, today: today) {
        case .paid(let txn, _):
          status = .paid
          paidDay = txn.flatMap { derived.days[$0] }
        case .skipped: status = .skipped
        case .snoozed(let until): status = until > today ? .upcoming : until == today ? .due : .late
        case .paused, .notTracked: continue
        case .upcoming: status = .upcoming
        case .due: status = .due
        case .late: status = .late
        }
        let terms = v.terms(at: d)
        out.append(
          BillExpectation(
            billID: id, categoryID: category, payee: b.name, expectedDay: d, amount: terms.amountMinor,
            isEstimate: terms.variable, status: status, paidDay: paidDay,
            usualDayOfMonth: v.unit == "month" ? v.anchor.day : nil))
      }
    }
    return out
  }

  static func kitNotices(_ core: [BillNoticeCore], currency: String, paidAmount: [String: HasalaModels.Txn])
    -> [BillNotice]
  {
    var out: [BillNotice] = []
    var latestPrice: (due: CivilDate, notice: BillNotice)?
    for n in core {
      switch n.kind {
      case .priceChange(let due, let usual, let charged):
        let notice = BillNotice(
          id: "priceChange.\(n.txnID)",
          kind: .priceChange(
            usual: Money(minor: usual, currency: currency), charged: Money(minor: charged, currency: currency),
            from: local(due)), txnID: n.txnID)
        if latestPrice.map({ due > $0.due }) ?? true { latestPrice = (due, notice) }
      case .chargedWhilePaused(let due):
        let t = paidAmount[n.txnID]
        let charged = t.flatMap { Self.charged($0, in: currency) } ?? Money(minor: 0, currency: currency)
        out.append(
          BillNotice(
            id: "chargedWhilePaused.\(n.txnID)", kind: .chargedWhilePaused(charged: charged, on: t?.postedAt.date ?? local(due)),
            txnID: n.txnID))
      case .chargedAfterEnd(let day, let chargedMinor):
        out.append(
          BillNotice(
            id: "chargedAfterEnd.\(n.txnID)",
            kind: .chargedAfterEnd(charged: Money(minor: chargedMinor, currency: currency), on: local(day)), txnID: n.txnID))
      }
    }
    if let p = latestPrice { out.insert(p.notice, at: 0) }
    return out
  }

  static func forkNotices(_ forks: [ForkNotice], records: [String: CoreReplay.Bill], losers: [String: Op])
    -> [String: [BillNotice]]
  {
    var out: [String: [BillNotice]] = [:]
    var seen = Set<String>()
    for f in forks where f.entityKind == "bill" && seen.insert(f.loserOp).inserted {
      guard let current = records[f.entityID] else { continue }
      let record = losers[f.loserOp].flatMap { Replay.billRecord($0, inheritingFrom: current) }
      guard current.status != "dismissed" || record != nil else { continue }
      let summary: String
      if let loser = record {
        guard let s = forkSummary(loser: loser, current: current) else { continue }
        summary = s
      } else {
        summary = "A change made on your other iPhone was replaced"
      }
      out[f.entityID, default: []].append(BillNotice(id: "fork.\(f.loserOp)", kind: .changedOnTwoDevices(summary: summary)))
    }
    return out
  }

  static func forkSummary(loser l: CoreReplay.Bill, current c: CoreReplay.Bill) -> String? {
    func day(_ wire: String?) -> String { wire.flatMap(CivilDate.init(wire:)).map { local($0).dayMonth } ?? "" }
    func amount(_ minor: Int64, _ mode: String) -> String { (mode == "variable" ? "~" : "") + MoneyFormat.string(minor) }
    if l.status != c.status {
      switch l.status {
      case "dismissed": return "Deleted"
      case "cancelled": return "Ended \(day(l.end))"
      default: return "Tracking again"
      }
    }
    var parts: [String] = []
    if l.name != c.name { parts.append("Name \(l.name)") }
    if l.amountMinor != c.amountMinor || l.amountMode != c.amountMode { parts.append("Amount \(amount(l.amountMinor, l.amountMode))") }
    for ch in l.changes where !c.changes.contains(ch) {
      parts.append("Amount \(amount(ch.amountMinor, ch.amountMode)) from \(day(ch.from))")
    }
    for p in l.pauses where !c.pauses.contains(p) {
      if p.until == nil {
        parts.append("Paused")
      } else if c.pauses.contains(where: { $0.from == p.from }) {
        parts.append("Resumed \(day(p.until))")
      } else {
        parts.append("Paused until \(day(p.until))")
      }
    }
    if l.cadence != c.cadence || l.anchor != c.anchor || l.start != c.start { parts.append("Schedule") }
    if l.status == "cancelled", l.end != c.end { parts.append("Ended \(day(l.end))") }
    if parts.isEmpty {
      var a = l
      a.createdAt = c.createdAt
      a.firstSeq = c.firstSeq
      a.version = c.version
      if a != c { parts.append("Other details") }
    }
    return parts.isEmpty ? nil : parts.joined(separator: ", ")
  }

  static func billOfTxn(
    _ records: [(id: String, bill: CoreReplay.Bill)], resolutions: [BillResolution], matched: [String: [DerivedMatch]]
  ) -> [String: String] {
    let live = Set(records.filter { $0.bill.status != "dismissed" }.map(\.id))
    var out: [String: String] = [:]
    for (bill, list) in matched where live.contains(bill) {
      for m in list { out[m.txnID] = bill }
    }
    for res in resolutions where res.resolution == "paid" && live.contains(res.bill) {
      if let t = res.txn { out[t] = res.bill }
    }
    return out
  }

  static func notices(_ list: [BillNotice], dismissed: Set<String>, salt: String) -> [BillNotice] {
    guard !dismissed.isEmpty else { return list }
    return list.filter { !dismissed.contains(LocalAccountData.digest($0.id, salt: salt)) }
  }

  static func payments(
    explicit resolutions: [BillResolution], matched: [DerivedMatch], paidAmount: [String: HasalaModels.Txn],
    currency: String
  ) -> [BillPayment] {
    var out: [BillPayment] = []
    var dues = Set<String>()
    for r in resolutions where r.resolution == "paid" {
      guard let due = CivilDate(wire: r.due), dues.insert(r.due).inserted else { continue }
      let amount = r.txn.flatMap { paidAmount[$0] }.flatMap { Self.charged($0, in: currency) }
      out.append(BillPayment(due: local(due), txnID: r.txn, amount: amount, link: r.txn == nil ? .marked : .linked))
    }
    let decided = Set(resolutions.filter { $0.resolution != "clear" }.map(\.due))
    for m in matched where !decided.contains(m.due.wire) && dues.insert(m.due.wire).inserted {
      let amount = paidAmount[m.txnID].flatMap { Self.charged($0, in: currency) }
      out.append(BillPayment(due: local(m.due), txnID: m.txnID, amount: amount, link: .matched))
    }
    return out.sorted { $0.due > $1.due }
  }

  static func cadence(_ unit: String, every: Int) -> (HasalaModels.BillCadence, Int) {
    switch unit {
    case "week": (.weekly, every)
    case "year": (.yearly, every)
    case "day": (.weekly, max(1, every / 7))
    default: (.monthly, every)
    }
  }

  static func bill(
    id: String, _ b: CoreReplay.Bill, resolutions: [BillResolution], matched: [DerivedMatch] = [],
    result: BillMatcherResult? = nil, notices core: [BillNoticeCore] = [], today: LocalDate,
    taxonomy: TaxonomyView, paidAmount: [String: HasalaModels.Txn]
  ) -> HasalaModels.Bill? {
    guard b.direction == "debit", let v = BillScheduleView(b),
      let t = CivilDate(year: today.year, month: today.month, day: today.day)
    else { return nil }
    let payments = payments(explicit: resolutions, matched: matched, paidAmount: paidAmount, currency: b.currency)
    let paidDues = Set(payments.map(\.due))
    let statuses = result ?? BillMatcher.run(bills: [BillMatchInput(id: id, bill: b)], resolutions: resolutions, rows: [], today: t)
    func open(_ d: CivilDate) -> Bool {
      if paidDues.contains(local(d)) { return false }
      switch statuses.status(bill: id, due: d, today: t) {
      case .upcoming, .due, .late: return true
      case .snoozed(let until): return until < t
      case .paid, .skipped, .paused, .notTracked: return false
      }
    }
    var next: CivilDate?
    var cursor = v.due(onOrAfter: v.trackingSince)
    var steps = 0
    while let d = cursor, steps < 5_000 {
      if open(d) {
        next = d
        break
      }
      steps += 1
      cursor = d.adding(days: 1).flatMap { v.due(onOrAfter: $0) }
    }
    let fallback = next ?? v.end.flatMap { e in e.adding(days: 1).flatMap { v.due(before: $0) } } ?? v.due(onOrAfter: t)
      ?? v.anchor
    let shownDue = next ?? fallback
    let terms = v.terms(at: shownDue)
    var amount = Money(minor: terms.amountMinor, currency: b.currency)
    let history = payments.map(\.due)
    var priceChangeFrom: Money?
    if !terms.variable, let last = payments.first, let txn = last.txnID,
      let lastDue = CivilDate(year: last.due.year, month: last.due.month, day: last.due.day),
      v.terms(at: lastDue) == terms, let charged = paidAmount[txn].flatMap({ Self.charged($0, in: b.currency) })
    {
      let tolerance = Fils.mulDiv(terms.amountMinor, terms.toleranceBp, 10_000)
      if charged.minor.minus(terms.amountMinor).magnitude > tolerance.magnitude {
        priceChangeFrom = amount
        amount = charged
      }
    }
    let state: HasalaModels.Bill.State
    var pausedSince: LocalDate?
    var pausedUntil: LocalDate?
    switch b.status {
    case "active":
      if let p = v.pauses.last(where: { $0.from <= t && ($0.until.map { t < $0 } ?? true) }) {
        state = .paused
        pausedSince = local(p.from)
        pausedUntil = p.until.map(local)
      } else if let p = v.pauses.last, p.from > t, next.map({ $0 >= p.from }) ?? true {
        state = .paused
        pausedSince = local(p.from)
        pausedUntil = p.until.map(local)
      } else {
        state = .tracked
      }
    case "cancelled": state = .ended
    default: state = .dismissed
    }
    let upcoming = v.changes.first { $0.from > t }
    let (cadence, every) = cadence(v.unit, every: v.every)
    let category = b.category ?? "utilities"
    return HasalaModels.Bill(
      id: id, name: b.name, kind: taxonomy.info(category)?.name ?? "Bill", categoryID: category, amount: amount,
      approximate: terms.variable, isIncome: false, usualDay: v.anchor.day, nextDue: local(shownDue),
      accountID: b.account, state: state, priceChangeFrom: priceChangeFrom, history: history,
      source: b.source == "manual" ? .manual : .detected, cadence: cadence, every: every, pausedSince: pausedSince,
      pausedUntil: pausedUntil, endedOn: b.status == "cancelled" ? v.end.map(local) : nil,
      trackingSince: local(v.trackingSince), nextAmount: upcoming.map { Money(minor: $0.terms.amountMinor, currency: b.currency) },
      nextAmountFrom: upcoming.map { local($0.from) }, payments: payments,
      notices: kitNotices(core, currency: b.currency, paidAmount: paidAmount), keys: b.keys)
  }

  static func income(_ s: IncomeSource, today: LocalDate, taxonomy: TaxonomyView) -> HasalaModels.Bill {
    HasalaModels.Bill(
      id: LedgerEditAuthor.incomePrefix + s.id, name: s.name, kind: taxonomy.info(s.categoryID)?.name ?? "Income",
      categoryID: s.categoryID, amount: .aed(s.amountMinor), isIncome: true, usualDay: Int(s.payday),
      nextDue: nextPayday(Int(s.payday), after: today), state: s.active ? .tracked : .ended)
  }
}
