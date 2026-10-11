import CoreCategorize
import CoreDomain
import CoreOutbox
import CoreProjection
import CoreReplay
import CoreSync
import CoreTime
import Foundation
import HasalaModels

/// One screen gesture (`LedgerEdit`) as ops (spec 04 §15.1 `LedgerActions`; 03a/03b/03c):
/// one blob per edit through CoreDomain's `OpAuthor`, built under the account's shared
/// stamps, made durable by `Outbox.enqueue`, then re-projected so the screens read it at
/// once. The outbox's debounced trigger uploads it (`WorkCoordinator`'s `authored` run).
///
/// Device-local edits (skip review, notifications, Face ID lock, dismissing a proposal)
/// author nothing: `LiveLedgerStore` keeps them in the device's preferences.
nonisolated struct LedgerEditAuthor: Sendable {
  let observer: LedgerPageObserver
  let outbox: Outbox

  var reader: LedgerReader { observer.reader }

  /// What an undo writes back: the fields an edit changed, as they were (03c §3.8
  /// "Undo (toast)": inverse ops that touch only those fields).
  enum Inverse: Sendable, Equatable {
    case category(txn: String, category: String?, needsReview: Bool)
    case note(txn: String, note: String)
    case displayName(txn: String, name: String?)
    case archived(txn: String, archived: Bool)
    case split(txn: String, lines: [SplitLine])
    case budget(category: String, month: YearMonth, amount: Money)
    case move(from: String?, to: String?, month: YearMonth, amount: Money)
    case occurrence(bill: String, due: LocalDate)
  }

  enum Failure: Error, Equatable {
    case notFound
    case refused(String)
  }

  /// Authors `edit`. `before` is the screens' state the gesture was made on (a bill's due
  /// date, the current amount).
  func author(_ edit: LedgerEdit, before: LedgerState, today: LocalDate) async throws {
    switch edit {
    case .categorize(let id, let c, let learnRule, let project):
      let row = try txn(id)
      var snapshots: [OpAuthor.RuleSnapshot] = []
      if learnRule { snapshots = try ruleSnapshots() }
      try await build { a throws(AuthorError) in
        a.categorize(txnID: id, parentVersion: row.version, category: c, needsReview: false)
        if let project { a.annotate(txnID: id, set: [("project_id", project)]) }
        if learnRule {
          try a.learnRule(merchantRaw: row.merchantRaw, category: c, existing: snapshots, userRows: [])
        }
      }
    case .markTransfer(let id):
      let row = try txn(id)
      try await build { a throws(AuthorError) in
        a.categorize(txnID: id, parentVersion: row.version, category: "transfer", needsReview: false)
      }
    case .markRefund(let id):
      let row = try txn(id)
      let undo = row.category == "refunds"
      try await build { a throws(AuthorError) in
        a.categorize(txnID: id, parentVersion: row.version, category: undo ? nil : "refunds", needsReview: undo)
      }
    case .setNote(let id, let note):
      _ = try txn(id)
      let n = note.trimmingCharacters(in: .whitespacesAndNewlines)
      try await build { a throws(AuthorError) in a.annotate(txnID: id, set: [("note", n.isEmpty ? nil : n)]) }
    case .renameMerchant(let id, let name):
      let row = try txn(id)
      try await build { a throws(AuthorError) in a.renameMerchant(raw: row.merchantRaw, to: name) }
    case .split(let id, let lines):
      let row = try txn(id)
      try await build { a throws(AuthorError) in
        a.split(
          txnID: id, parentVersion: row.version,
          parts: lines.map { (category: $0.categoryID, amountMinor: $0.amount.minor, note: $0.note.isEmpty ? nil : $0.note) })
      }
    case .archive(let id, let archived):
      _ = try txn(id)
      try await build { a throws(AuthorError) in a.annotate(txnID: id, set: [("archived", archived ? "user" : nil)]) }
    case .setBudget(let c, let month, let amount):
      let m = try civil(month)
      try await build { a throws(AuthorError) in a.setBudget(category: c, month: m, amountMinor: amount.minor) }
    case .moveMoney(let from, let to, let month, let amount):
      let m = try civil(month)
      try await build { a throws(AuthorError) in a.moveMoney(month: m, from: from, to: to, amountMinor: amount.minor) }
    case .markBillPaid(let id):
      guard let due = before.bill(id)?.nextDue, let d = CivilDate(year: due.year, month: due.month, day: due.day) else {
        throw Failure.notFound
      }
      try await build { a throws(AuthorError) in a.setBillOccurrence(bill: id, due: d, .paid(txn: nil)) }
    case .acceptBillAmount(let id):
      guard let shown = before.bill(id)?.amount else { throw Failure.notFound }
      try await editBill(id) { d in
        d.amountMinor = shown.minor
      }
    case .stopTrackingBill(let id):
      try await editBill(id) { d in
        d.status = .cancelled
        let t = CivilDate(year: today.year, month: today.month, day: today.day) ?? d.start
        d.end = d.start < t ? t : CivilDate(daysSinceEpoch: d.start.daysSinceEpoch + 1)
      }
    case .setRuleEnabled(let id, let enabled):
      guard let r = try reader.rules().first(where: { $0.id == id }), let snapshot = Self.snapshot(r) else {
        throw Failure.notFound
      }
      let held = try reader.activity(limit: 1_000_000).filter {
        $0.categorySource == "rule" && $0.categorySourceRef == id && !$0.needsReview && $0.category != nil
      }.map { (id: $0.id, version: $0.version, category: $0.category ?? "") }
      let ctx = try await observer.authorContext()
      let blobs = try observer.stamps.authoring {
        (floor: Int64?) throws(AuthorError) -> (value: [AuthoredBlob], lastMs: Int64?) in
        let b = try OpAuthor.setRule(snapshot, enabled: enabled, heldRows: held, context: ctx.raised(to: floor))
        return (b, b.last?.lastAuthoredMs)
      }
      for b in blobs { try await outbox.enqueue(b.ops) }
      try await observer.reproject()
    case .trackCandidate, .dismissCandidate, .skipReview, .setNotifications, .setFaceIDLock:
      break
    }
  }

  /// Writes an undo back.
  func undo(_ inverses: [Inverse]) async throws {
    var rows: [String: TxnRow] = [:]
    for inv in inverses {
      switch inv {
      case .category(let t, _, _), .split(let t, _), .displayName(let t, _): rows[t] = try txn(t)
      default: break
      }
    }
    try await build { a throws(AuthorError) in
      for inv in inverses {
        switch inv {
        case .category(let t, let c, let review):
          guard let row = rows[t] else { continue }
          a.categorize(txnID: t, parentVersion: row.version, category: c, needsReview: review)
        case .note(let t, let n):
          a.annotate(txnID: t, set: [("note", n.isEmpty ? nil : n)])
        case .displayName(let t, let name):
          guard let row = rows[t] else { continue }
          a.renameMerchant(raw: row.merchantRaw, to: name)
        case .archived(let t, let archived):
          a.annotate(txnID: t, set: [("archived", archived ? "user" : nil)])
        case .split(let t, let lines):
          guard let row = rows[t] else { continue }
          a.split(
            txnID: t, parentVersion: row.version,
            parts: lines.map { (category: $0.categoryID, amountMinor: $0.amount.minor, note: $0.note.isEmpty ? nil : $0.note) })
        case .budget(let c, let month, let amount):
          guard let m = CivilMonth(year: month.year, month: month.month) else { continue }
          a.setBudget(category: c, month: m, amountMinor: amount.minor)
        case .move(let from, let to, let month, let amount):
          guard let m = CivilMonth(year: month.year, month: month.month) else { continue }
          a.moveMoney(month: m, from: from, to: to, amountMinor: amount.minor, reason: "undo")
        case .occurrence(let bill, let due):
          guard let d = CivilDate(year: due.year, month: due.month, day: due.day) else { continue }
          a.setBillOccurrence(bill: bill, due: d, .clear)
        }
      }
    }
  }

  // MARK: Building

  /// One blob under the account's shared stamps; enqueued, then re-projected.
  private func build(_ body: (inout OpAuthor) throws(AuthorError) -> Void) async throws {
    let ctx = try await observer.authorContext()
    guard let blob = try observer.stamps.build(ctx, body) else { return }
    try await outbox.enqueue(blob.ops)
    try await observer.reproject()
  }

  private func txn(_ id: String) throws -> TxnRow {
    guard let row = try reader.txn(id) else { throw Failure.notFound }
    return row
  }

  private func civil(_ m: YearMonth) throws -> CivilMonth {
    guard let c = CivilMonth(year: m.year, month: m.month) else { throw Failure.refused("month") }
    return c
  }

  /// A whole-record bill edit from the projected record.
  private func editBill(_ id: String, _ change: (inout OpAuthor.BillDraft) -> Void) async throws {
    guard let (_, b) = try reader.bills().first(where: { $0.id == id }), var d = Self.draft(b) else {
      throw Failure.notFound
    }
    change(&d)
    let draft = d
    try await build { a throws(AuthorError) in try a.setBill(id: id, parentVersion: b.version, draft) }
  }

  static func draft(_ b: CoreReplay.Bill) -> OpAuthor.BillDraft? {
    guard let anchor = CivilDate(wire: b.anchor), let start = CivilDate(wire: b.start),
      let unit = OpAuthor.CadenceUnit(rawValue: b.cadence.unit)
    else { return nil }
    return OpAuthor.BillDraft(
      name: b.name, keys: b.keys, direction: b.direction, currency: b.currency,
      mode: b.amountMode == "variable" ? .variable : .fixed(toleranceBp: b.toleranceBp ?? 0), amountMinor: b.amountMinor,
      cadenceUnit: unit, cadenceEvery: b.cadence.every, anchor: anchor, start: start,
      end: b.end.flatMap(CivilDate.init(wire:)), category: b.category, account: b.account,
      source: OpAuthor.BillSource(rawValue: b.source) ?? .manual, status: OpAuthor.BillStatus(rawValue: b.status) ?? .active)
  }

  private func ruleSnapshots() throws -> [OpAuthor.RuleSnapshot] {
    try reader.rules().compactMap(Self.snapshot)
  }

  static func snapshot(_ r: RuleRow) -> OpAuthor.RuleSnapshot? {
    guard let match = MatchKind(rawValue: r.match) else { return nil }
    return OpAuthor.RuleSnapshot(
      id: r.id, version: r.version,
      draft: OpAuthor.RuleDraft(
        patterns: r.patterns, match: match, category: r.category, priority: r.priority, enabled: r.enabled,
        removed: r.removed, origin: r.origin))
  }
}
