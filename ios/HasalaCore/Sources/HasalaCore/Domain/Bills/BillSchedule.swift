import CoreReplay
import CoreTime

public struct BillTerms: Sendable, Equatable {
  public var variable: Bool
  public var amountMinor: Int64
  public var toleranceBp: Int64

  public init(variable: Bool, amountMinor: Int64, toleranceBp: Int64) {
    self.variable = variable
    self.amountMinor = amountMinor
    self.toleranceBp = toleranceBp
  }

  init(mode: String, amountMinor: Int64, toleranceBp: Int64?) {
    self.init(variable: mode == "variable", amountMinor: amountMinor, toleranceBp: mode == "variable" ? 0 : toleranceBp ?? 0)
  }
}

public struct BillScheduleView: Sendable {
  public var start: CivilDate
  public var end: CivilDate?
  public var anchor: CivilDate
  public var trackingSince: CivilDate
  public var unit: String
  public var every: Int
  public var original: BillTerms
  public var changes: [(from: CivilDate, terms: BillTerms)]
  public var pauses: [(from: CivilDate, until: CivilDate?)]

  public init?(_ bill: CoreReplay.Bill) {
    guard let anchor = CivilDate(wire: bill.anchor), let start = CivilDate(wire: bill.start) else { return nil }
    var end: CivilDate?
    if let e = bill.end {
      guard let d = CivilDate(wire: e) else { return nil }
      end = d
    }
    var changes: [(from: CivilDate, terms: BillTerms)] = []
    for c in bill.changes {
      guard let from = CivilDate(wire: c.from) else { return nil }
      changes.append((from, BillTerms(mode: c.amountMode, amountMinor: c.amountMinor, toleranceBp: c.toleranceBp)))
    }
    var pauses: [(from: CivilDate, until: CivilDate?)] = []
    for p in bill.pauses {
      guard let from = CivilDate(wire: p.from) else { return nil }
      var until: CivilDate?
      if let u = p.until {
        guard let d = CivilDate(wire: u) else { return nil }
        until = d
      }
      pauses.append((from, until))
    }
    self.start = start
    self.end = end
    self.anchor = anchor
    self.unit = bill.cadence.unit
    self.every = Int(max(1, bill.cadence.every))
    self.original = BillTerms(mode: bill.amountMode, amountMinor: bill.amountMinor, toleranceBp: bill.toleranceBp)
    self.changes = changes
    self.pauses = pauses
    if let c = bill.createdAt, let ms = try? Instant.parseMs(c), let day = LocalClock.localDate(ms) {
      trackingSince = max(start, day)
    } else {
      trackingSince = start
    }
  }

  public func dues(from: CivilDate, through: CivilDate) -> [CivilDate] {
    let lo = max(from, start)
    let hi = end.map { min(through, $0) } ?? through
    guard lo <= hi, var k = index(onOrAfter: lo) else { return [] }
    var out: [CivilDate] = []
    while let d = occurrence(k), d <= hi {
      out.append(d)
      k += 1
    }
    return out
  }

  public func due(onOrAfter day: CivilDate) -> CivilDate? {
    let lo = max(day, start)
    guard let k = index(onOrAfter: lo), let d = occurrence(k) else { return nil }
    if let end, end < d { return nil }
    return d
  }

  public func due(before day: CivilDate) -> CivilDate? {
    var limit = day
    if let end, let next = end.adding(days: 1), next < limit { limit = next }
    guard let k = index(onOrAfter: limit), let d = occurrence(k - 1), d >= start, d < limit else { return nil }
    return d
  }

  public func terms(at due: CivilDate) -> BillTerms {
    changes.last { $0.from <= due }?.terms ?? original
  }

  public func isPaused(_ due: CivilDate) -> Bool {
    pauses.contains { p in p.from <= due && (p.until.map { due < $0 } ?? true) }
  }

  public var openPause: (from: CivilDate, until: CivilDate?)? { pauses.last }

  public func halfWindowDays(at due: CivilDate) -> Int {
    let days: Int
    switch unit {
    case "day": days = every / 2
    case "week": days = 3 * every
    case "year": days = 30 * every
    default: days = 15 * every
    }
    return min(days, 45)
  }

  func occurrence(_ k: Int) -> CivilDate? {
    let (step, o) = k.multipliedReportingOverflow(by: every)
    guard !o else { return nil }
    switch unit {
    case "day": return anchor.adding(days: step)
    case "week":
      let (weeks, o) = step.multipliedReportingOverflow(by: 7)
      return o ? nil : anchor.adding(days: weeks)
    case "year":
      let (year, o) = anchor.year.addingReportingOverflow(step)
      return o ? nil : Self.clamp(year, anchor.month, anchor.day)
    default:
      guard let m = anchor.yearMonth.adding(months: step) else { return nil }
      return Self.clamp(m.year, m.month, anchor.day)
    }
  }

  func index(onOrAfter day: CivilDate) -> Int? {
    var k: Int
    switch unit {
    case "day", "week":
      let span = (unit == "week" ? 7 : 1) * every
      let diff = Int(day.daysSinceEpoch - anchor.daysSinceEpoch)
      k = Int(Civil.floorDiv(Int64(diff), Int64(span)))
    case "year":
      k = Int(Civil.floorDiv(Int64(day.year - anchor.year), Int64(every)))
    default:
      k = Int(Civil.floorDiv(Int64(monthsBetween(anchor.yearMonth, day.yearMonth)), Int64(every)))
    }
    for _ in 0..<4 {
      guard let d = occurrence(k) else { return nil }
      if d >= day { break }
      k += 1
    }
    while let d = occurrence(k - 1), d >= day { k -= 1 }
    guard let d = occurrence(k), d >= day else { return nil }
    return k
  }

  static func clamp(_ year: Int, _ month: Int, _ day: Int) -> CivilDate? {
    guard let m = CivilMonth(year: year, month: month) else { return nil }
    return CivilDate(year: year, month: month, day: min(day, m.daysInMonth))
  }
}
