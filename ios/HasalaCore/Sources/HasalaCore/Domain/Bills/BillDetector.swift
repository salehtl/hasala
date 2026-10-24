import CoreTime

public struct DetectRow: Sendable {
  public var txnID: String
  public var merchantKey: String
  public var merchantName: String
  public var direction: String
  public var amountMinor: Int64
  public var currency: String
  public var day: CivilDate
  public var category: String?
  public var eligible: Bool

  public init(
    txnID: String, merchantKey: String, merchantName: String, direction: String, amountMinor: Int64, currency: String,
    day: CivilDate, category: String?, eligible: Bool
  ) {
    self.txnID = txnID
    self.merchantKey = merchantKey
    self.merchantName = merchantName
    self.direction = direction
    self.amountMinor = amountMinor
    self.currency = currency
    self.day = day
    self.category = category
    self.eligible = eligible
  }
}

public struct BillCandidateCore: Sendable, Equatable {
  public var id: String
  public var key: String
  public var name: String
  public var currency: String
  public var unit: String
  public var every: Int64
  public var anchor: CivilDate
  public var start: CivilDate
  public var variable: Bool
  public var amountMinor: Int64
  public var seen: Int
  public var last: CivilDate
  public var category: String?

  public init(
    id: String, key: String, name: String, currency: String, unit: String, every: Int64, anchor: CivilDate,
    start: CivilDate, variable: Bool, amountMinor: Int64, seen: Int, last: CivilDate, category: String?
  ) {
    self.id = id
    self.key = key
    self.name = name
    self.currency = currency
    self.unit = unit
    self.every = every
    self.anchor = anchor
    self.start = start
    self.variable = variable
    self.amountMinor = amountMinor
    self.seen = seen
    self.last = last
    self.category = category
  }
}

public enum BillDetector {
  public static let minimumSeries = 3
  public static let bandBp: Int64 = 2_000

  struct Cadence {
    var unit: String
    var minGap: Int64
    var maxGap: Int64
    var nominal: Int64
  }

  static let cadences: [Cadence] = [
    Cadence(unit: "month", minGap: 26, maxGap: 35, nominal: 30),
    Cadence(unit: "week", minGap: 6, maxGap: 8, nominal: 7),
    Cadence(unit: "year", minGap: 350, maxGap: 380, nominal: 365),
  ]

  struct GroupKey: Hashable {
    var key: String
    var currency: String
  }

  struct Series {
    var indices: [Int]
    var deviation: Int64
  }

  public static func run(rows: [DetectRow], coveredKeys: Set<String>, today: CivilDate) -> [BillCandidateCore] {
    var groups: [GroupKey: [DetectRow]] = [:]
    for r in rows where r.eligible && r.direction == "debit" && r.amountMinor > 0 && !r.merchantKey.isEmpty && r.day <= today {
      guard !coveredKeys.contains(r.merchantKey) else { continue }
      groups[GroupKey(key: r.merchantKey, currency: r.currency), default: []].append(r)
    }
    var out: [BillCandidateCore] = []
    for (g, list) in groups {
      if let c = candidate(g, sorted(list), today: today) { out.append(c) }
    }
    return out.sorted { a, b in
      if a.last != b.last { return a.last > b.last }
      return a.id.utf8.lexicographicallyPrecedes(b.id.utf8)
    }
  }

  static func sorted(_ list: [DetectRow]) -> [DetectRow] {
    list.sorted { a, b in
      if a.day != b.day { return a.day < b.day }
      if a.txnID != b.txnID { return a.txnID.utf8.lexicographicallyPrecedes(b.txnID.utf8) }
      if a.amountMinor != b.amountMinor { return a.amountMinor < b.amountMinor }
      if a.merchantName != b.merchantName { return a.merchantName.utf8.lexicographicallyPrecedes(b.merchantName.utf8) }
      return (a.category ?? "").utf8.lexicographicallyPrecedes((b.category ?? "").utf8)
    }
  }

  static func candidate(_ g: GroupKey, _ rows: [DetectRow], today: CivilDate) -> BillCandidateCore? {
    guard rows.count >= minimumSeries else { return nil }
    var best: (cadence: Cadence, series: Series)?
    for cadence in cadences {
      let first = longest(rows, cadence, today: today, reference: median(rows.map(\.amountMinor)))
      guard let first else { continue }
      let refined = longest(rows, cadence, today: today, reference: median(first.indices.map { rows[$0].amountMinor })) ?? first
      guard refined.indices.count >= minimumSeries else { continue }
      if let b = best, b.series.indices.count >= refined.indices.count { continue }
      best = (cadence, refined)
    }
    guard let (cadence, series) = best else { return nil }
    let picked = series.indices.map { rows[$0] }
    let amounts = picked.map(\.amountMinor)
    let med = median(amounts)
    let variable = amounts.contains { !withinBand($0, med) }
    let lastRow = picked[picked.count - 1]
    let anchor = lastRow.day
    guard let start = nearestDue(cadence.unit, anchor: anchor, steps: picked.count - 1, to: picked[0].day) else { return nil }
    return BillCandidateCore(
      id: OpAuthor.detectedBillID(key: g.key, direction: "debit", currency: g.currency), key: g.key,
      name: mostFrequent(picked.map(\.merchantName)) ?? lastRow.merchantName, currency: g.currency, unit: cadence.unit,
      every: 1, anchor: anchor, start: start, variable: variable, amountMinor: variable ? med : lastRow.amountMinor,
      seen: picked.count, last: anchor,
      category: mostFrequent(picked.compactMap(\.category)))
  }

  static func longest(_ rows: [DetectRow], _ cadence: Cadence, today: CivilDate, reference: Int64) -> Series? {
    var chains: [Series] = []
    chains.reserveCapacity(rows.count)
    for i in rows.indices {
      let dev = BillMatcher.gap(rows[i].amountMinor, reference)
      var bestPrev: Series?
      for j in stride(from: i - 1, through: 0, by: -1) {
        let gap = rows[i].day.daysSinceEpoch - rows[j].day.daysSinceEpoch
        if gap > cadence.maxGap { break }
        guard gap >= cadence.minGap else { continue }
        if let b = bestPrev, !better(chains[j], than: b) { continue }
        bestPrev = chains[j]
      }
      if let p = bestPrev {
        chains.append(Series(indices: p.indices + [i], deviation: sum(p.deviation, dev)))
      } else {
        chains.append(Series(indices: [i], deviation: dev))
      }
    }
    let limit = cadence.nominal * 3 / 2
    var best: Series?
    for i in rows.indices.reversed() {
      guard today.daysSinceEpoch - rows[i].day.daysSinceEpoch <= limit else { break }
      if let b = best, !better(chains[i], than: b) { continue }
      best = chains[i]
    }
    return best
  }

  static func better(_ a: Series, than b: Series) -> Bool {
    if a.indices.count != b.indices.count { return a.indices.count > b.indices.count }
    return a.deviation < b.deviation
  }

  static func sum(_ a: Int64, _ b: Int64) -> Int64 {
    let (s, o) = a.addingReportingOverflow(b)
    return o ? .max : s
  }

  static func median(_ values: [Int64]) -> Int64 {
    let s = values.sorted()
    guard !s.isEmpty else { return 0 }
    let mid = s.count / 2
    if s.count % 2 == 1 { return s[mid] }
    let lo = s[mid - 1]
    return lo + (s[mid] - lo) / 2
  }

  static func withinBand(_ amount: Int64, _ med: Int64) -> Bool {
    let d = BillMatcher.gap(amount, med)
    let (lhs, o1) = d.multipliedReportingOverflow(by: 10_000)
    let (rhs, o2) = med.multipliedReportingOverflow(by: bandBp)
    if o1 || o2 { return d <= med / 10_000 * bandBp }
    return lhs <= rhs
  }

  static func mostFrequent(_ values: [String]) -> String? {
    var counts: [String: Int] = [:]
    var best: (value: String, count: Int)?
    for v in values {
      let c = (counts[v] ?? 0) + 1
      counts[v] = c
      if let b = best, b.count > c { continue }
      best = (v, c)
    }
    return best?.value
  }

  static func occurrence(_ unit: String, anchor: CivilDate, _ k: Int) -> CivilDate? {
    switch unit {
    case "week": return anchor.adding(days: 7 * k)
    case "year": return BillScheduleView.clamp(anchor.year + k, anchor.month, anchor.day)
    default:
      guard let m = anchor.yearMonth.adding(months: k) else { return nil }
      return BillScheduleView.clamp(m.year, m.month, anchor.day)
    }
  }

  static func nearestDue(_ unit: String, anchor: CivilDate, steps: Int, to day: CivilDate) -> CivilDate? {
    var best: (date: CivilDate, gap: Int64)?
    for k in [-steps - 1, -steps, -steps + 1] where k <= 0 {
      guard let d = occurrence(unit, anchor: anchor, k) else { continue }
      let gap = abs(d.daysSinceEpoch - day.daysSinceEpoch)
      if let b = best, b.gap <= gap { continue }
      best = (d, gap)
    }
    return best?.date
  }
}
