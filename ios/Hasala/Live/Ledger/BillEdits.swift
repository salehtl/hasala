import CoreCategorize
import CoreDomain
import CoreProjection
import CoreReplay
import CoreTime
import Foundation
import HasalaModels

nonisolated enum BillEdits {
  typealias Draft = OpAuthor.BillDraft
  typealias Failure = LedgerEditAuthor.Failure

  static let defaultToleranceBp: Int64 = 200

  static func record(_ d: Draft) -> CoreReplay.Bill {
    let (mode, tolerance) = wireMode(d.mode)
    return CoreReplay.Bill(
      name: d.name, keys: d.keys, direction: d.direction, currency: d.currency, amountMode: mode,
      amountMinor: d.amountMinor, toleranceBp: tolerance,
      cadence: CoreReplay.BillCadence(unit: d.cadenceUnit.rawValue, every: d.cadenceEvery), anchor: d.anchor.wire,
      start: d.start.wire, end: d.end?.wire, category: d.category, account: d.account, source: d.source.rawValue,
      status: d.status.rawValue,
      changes: d.changes.map {
        let (m, t) = wireMode($0.terms.mode)
        return BillChange(from: $0.from.wire, amountMode: m, amountMinor: $0.terms.amountMinor, toleranceBp: t)
      },
      pauses: d.pauses.map { BillPause(from: $0.from.wire, until: $0.until?.wire) }, firstSeq: 0, version: 0)
  }

  static func wireMode(_ m: OpAuthor.AmountMode) -> (String, Int64?) {
    switch m {
    case .fixed(let bp): ("fixed", bp)
    case .variable: ("variable", nil)
    }
  }

  static func view(_ d: Draft) -> BillScheduleView? { BillScheduleView(record(d)) }

  static func nearestDue(_ v: BillScheduleView, to day: CivilDate) -> CivilDate? {
    let before = day.adding(days: 1).flatMap { v.due(before: $0) }
    let after = v.due(onOrAfter: day)
    switch (before, after) {
    case (let b?, let a?):
      return day.daysSinceEpoch - b.daysSinceEpoch <= a.daysSinceEpoch - day.daysSinceEpoch ? b : a
    case (let b?, nil): return b
    case (nil, let a?): return a
    default: return nil
    }
  }

  static func spanDays(_ d: Draft) -> Int {
    let every = Int(max(1, d.cadenceEvery))
    switch d.cadenceUnit {
    case .day: return every
    case .week: return 7 * every
    case .month: return 31 * every
    case .year: return 366 * every
    }
  }

  static func nearestUnbounded(_ d: Draft, to day: CivilDate) -> CivilDate? {
    var wide = d
    wide.end = nil
    guard let early = day.adding(days: -(spanDays(d) + 1)) else { return nil }
    wide.start = min(d.start, early)
    guard let v = view(wide) else { return nil }
    return nearestDue(v, to: day)
  }

  static func covers(_ p: OpAuthor.BillPauseDraft, _ day: CivilDate) -> Bool {
    p.from <= day && (p.until.map { day < $0 } ?? true)
  }

  static func isPaused(_ d: Draft, on day: CivilDate) -> Bool {
    d.pauses.contains { covers($0, day) }
  }

  static func terms(_ d: Draft, at due: CivilDate) -> OpAuthor.BillTermsDraft {
    d.changes.last { $0.from <= due }?.terms ?? OpAuthor.BillTermsDraft(mode: d.mode, amountMinor: d.amountMinor)
  }

  static func isDue(_ d: Draft, _ day: CivilDate) -> Bool {
    view(d)?.due(onOrAfter: day) == day
  }

  static func editAmount(_ d: inout Draft, amountMinor: Int64, currency: String, variable: Bool, from: CivilDate) throws {
    guard d.status != .dismissed else { throw Failure.notFound }
    guard amountMinor > 0, amountMinor <= ManualEntryDraft.maxMinor, currency == d.currency else {
      throw Failure.refused("amount")
    }
    guard from >= d.start, isDue(d, from) else { throw Failure.refused("not a due date") }
    if let end = d.end, from > end { throw Failure.refused("after the end") }
    let bp: Int64
    if case .fixed(let t) = terms(d, at: from).mode { bp = t } else { bp = defaultToleranceBp }
    let mode: OpAuthor.AmountMode = variable ? .variable : .fixed(toleranceBp: bp)
    if from <= d.start {
      d.mode = mode
      d.amountMinor = amountMinor
      d.changes.removeAll { $0.from <= from }
    } else {
      d.changes.removeAll { $0.from == from }
      d.changes.append(OpAuthor.BillChangeDraft(from: from, terms: OpAuthor.BillTermsDraft(mode: mode, amountMinor: amountMinor)))
      d.changes.sort { $0.from < $1.from }
    }
  }

  static func firstUnpaidDue(_ v: BillScheduleView, onOrAfter day: CivilDate, paid: Set<CivilDate>) -> CivilDate? {
    var cursor = v.due(onOrAfter: day)
    var steps = 0
    while let c = cursor, paid.contains(c), steps < 5_000 {
      cursor = c.adding(days: 1).flatMap { v.due(onOrAfter: $0) }
      steps += 1
    }
    return cursor
  }

  static func pause(_ d: inout Draft, today: CivilDate, until: CivilDate?, paid: Set<CivilDate> = []) throws {
    guard d.status == .active, !isPaused(d, on: today) else { throw Failure.refused("not running") }
    var from = max(today, d.start)
    if let v = view(d), let first = v.due(onOrAfter: from), paid.contains(first) {
      guard let unpaid = firstUnpaidDue(v, onOrAfter: first, paid: paid) else { throw Failure.refused("no later due") }
      from = unpaid
    }
    if let until, until <= from { throw Failure.refused("until") }
    if let last = d.pauses.last {
      guard let lastUntil = last.until, lastUntil <= from else { throw Failure.refused("pauses overlap") }
    }
    d.pauses.append(OpAuthor.BillPauseDraft(from: from, until: until))
  }

  static func resume(_ d: inout Draft, today: CivilDate) throws {
    guard d.status == .active else { throw Failure.refused("not paused") }
    if let i = d.pauses.lastIndex(where: { covers($0, today) }) {
      if d.pauses[i].from < today {
        d.pauses[i].until = today
      } else {
        d.pauses.remove(at: i)
      }
    } else if let last = d.pauses.last, last.from > today {
      d.pauses.removeLast()
    } else {
      throw Failure.refused("not paused")
    }
  }

  static func end(_ d: inout Draft, lastPayment: CivilDate) throws {
    guard d.status == .active else { throw Failure.refused("not running") }
    guard lastPayment >= d.start else { throw Failure.refused("before the start") }
    let end = d.start < lastPayment ? lastPayment : (d.start.adding(days: 1) ?? lastPayment)
    d.status = .cancelled
    d.end = end
    d.changes.removeAll { $0.from > end }
    d.pauses.removeAll { $0.from >= end }
    for i in d.pauses.indices where d.pauses[i].until.map({ $0 > end }) ?? true {
      d.pauses[i].until = end
    }
  }

  static func reactivate(_ d: inout Draft, today: CivilDate, paid: Set<CivilDate> = []) throws {
    guard d.status == .cancelled, let old = d.end else { throw Failure.refused("not ended") }
    d.status = .active
    d.end = nil
    guard old < today, let v = view(d), let next = old.adding(days: 1),
      let first = firstUnpaidDue(v, onOrAfter: next, paid: paid)
    else { return }
    let from = max(first, d.pauses.last?.until ?? first)
    if from < today { d.pauses.append(OpAuthor.BillPauseDraft(from: from, until: today)) }
  }

  static func delete(_ d: inout Draft) throws {
    guard d.status != .dismissed else { throw Failure.notFound }
    d.status = .dismissed
  }

  static func linkable(_ row: TxnRow, direction: String) -> Bool {
    row.archived == nil && row.supersededBy == nil && !row.heldCopy && !row.unparsed && row.category != "transfer"
      && row.transferState == nil && row.category != "refunds" && row.refundState == nil && row.direction == direction
  }

  static func cadence(_ c: HasalaModels.BillCadence) -> OpAuthor.CadenceUnit {
    switch c {
    case .weekly: .week
    case .monthly: .month
    case .yearly: .year
    }
  }

  static func keys(name: String, given: [String]) -> [String] {
    var out: [String] = []
    for k in given.map({ Canon.merchantKey($0.trimmingCharacters(in: .whitespacesAndNewlines)) }) where !k.isEmpty {
      if !out.contains(k) { out.append(k) }
    }
    if out.isEmpty { out = [Canon.merchantKey(name)] }
    return Array(out.prefix(8))
  }
}
