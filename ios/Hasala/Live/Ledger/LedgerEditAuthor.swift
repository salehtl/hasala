import CoreCategorize
import CoreDomain
import CoreOutbox
import CoreProjection
import CoreReplay
import CoreSync
import CoreTime
import CoreWire
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
    /// The merchant's name as it was shown before a rename: a user rename is put back,
    /// a name that was the dictionary's or the prettified one clears the rename.
    case displayName(txn: String, shown: String)
    case project(txn: String, project: String?)
    case archived(txn: String, archived: Bool)
    case split(txn: String, lines: [SplitLine])
    case budget(category: String, month: YearMonth, onward: Int64, assigned: Int64)
    case move(from: String?, to: String?, month: YearMonth, amount: Money, undoes: String)
    case occurrence(bill: String, due: LocalDate)
    case projectState(project: String, status: String, completedOn: String?, countInPlan: Bool)
    case samePurchase(foreign: String, previousHome: Int64, previousRateMicro: Int64?, home: String, previousNote: String)
    case samePurchaseDeclined(home: String)
    case copyReopened(txn: String)
    case copyUnmerged(txn: String, other: String, version: Int64)
    case bill(id: String, draft: OpAuthor.BillDraft)
  }

  enum Failure: Error, Equatable {
    case notFound
    case refused(String)
  }

  /// Authors `edit`. `before` is the screens' state the gesture was made on (a bill's due
  /// date, the current amount).
  @discardableResult
  func author(_ edit: LedgerEdit, before: LedgerState, today: LocalDate) async throws -> [Inverse] {
    switch edit {
    case .addTransaction(let d):
      let wall = try Self.localWallMs(d.postedAt)
      try await build { a throws(AuthorError) in
        _ = try a.manualEntry(
          amountMinor: d.amount.minor, currency: d.amount.currency, direction: d.direction == .in ? "credit" : "debit",
          localWallMs: wall, merchant: d.trimmedMerchant, category: d.categoryID, accountID: d.accountID)
      }
    case .categorize(let id, let c, let learnRule, let project):
      let row = try txn(id)
      var snapshots: [OpAuthor.RuleSnapshot] = []
      var filed: [(merchantRaw: String, category: String)] = []
      if learnRule {
        snapshots = try ruleSnapshots()
        filed = try categorizedRows(except: id)
      }
      let guardRows = filed
      try await build { a throws(AuthorError) in
        a.categorize(txnID: id, parentVersion: row.version, category: c, needsReview: false)
        if let project { a.annotate(txnID: id, set: [("project_id", project)]) }
        if learnRule {
          try a.learnRule(merchantRaw: row.merchantRaw, category: c, existing: snapshots, userRows: guardRows)
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
    case .resolveCopy(let id, let merge):
      let row = try txn(id)
      guard let other = row.copyOf else { throw Failure.notFound }
      try await build { a throws(AuthorError) in
        a.resolveCopy(txnID: id, parentVersion: row.version, otherTxnID: other, decision: merge ? .merge : .keepBoth)
      }
      if merge { return [.copyUnmerged(txn: id, other: other, version: row.version + 1)] }
    case .resolveSamePurchase(let id, let same):
      let row = try txn(id)
      guard let f = before.txn(id)?.samePurchase?.of else { throw Failure.notFound }
      let foreign = try txn(f)
      try await build { a throws(AuthorError) in
        if same {
          a.confirmSamePurchase(
            foreignID: f, foreignVersion: foreign.version, homeID: id, homeAmountMinor: row.amountMinor,
            foreignMinor: foreign.amountMinor, foreignCurrency: foreign.currency)
        } else {
          a.declineSamePurchase(homeID: id, homeVersion: row.version, foreignID: f)
        }
      }
    case .archive(let id, let archived):
      _ = try txn(id)
      try await build { a throws(AuthorError) in a.annotate(txnID: id, set: [("archived", archived ? "user" : nil)]) }
    case .setBudget(let c, let month, let amount):
      let m = try civil(month)
      let inverse = Self.budgetInverse(try reader.planState(), category: c, month: m, shown: month)
      try await build { a throws(AuthorError) in a.setBudget(category: c, month: m, amountMinor: amount.minor) }
      return [inverse]
    case .moveMoney(let from, let to, let month, let amount):
      let m = try civil(month)
      let ops = try await build { a throws(AuthorError) in
        a.moveMoney(month: m, from: from, to: to, amountMinor: amount.minor)
      }
      guard let op = ops.first(where: { $0.type == .budgetMoved }) else { return [] }
      return [.move(from: to, to: from, month: month, amount: amount, undoes: op.opID)]
    case .markBillPaid(let id):
      guard let due = before.bill(id)?.nextDue, let d = CivilDate(year: due.year, month: due.month, day: due.day) else {
        throw Failure.notFound
      }
      try await build { a throws(AuthorError) in a.setBillOccurrence(bill: id, due: d, .paid(txn: nil)) }
    case .acceptBillAmount(let id):
      guard let shown = before.bill(id)?.amount else { throw Failure.notFound }
      let old = try await editBill(id) { d in
        d.amountMinor = shown.minor
      }
      return [.bill(id: id, draft: old)]
    case .stopTrackingBill(let id):
      let old = try await editBill(id) { d in
        d.status = .cancelled
        let t = CivilDate(year: today.year, month: today.month, day: today.day) ?? d.start
        d.end = d.start < t ? t : CivilDate(daysSinceEpoch: d.start.daysSinceEpoch + 1)
      }
      return [.bill(id: id, draft: old)]
    case .setRate(let currency, let micro):
      try await build { a throws(AuthorError) in try a.setRate(currency: currency, rateMicro: micro) }
    case .unsetRate(let currency):
      try await build { a throws(AuthorError) in a.unsetRate(currency: currency) }
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
    case .saveProject(let id, let draft):
      let existing = try reader.projects().first { $0.id == id }?.project
      var d = try Self.projectDraft(draft)
      if let existing {
        d.status = OpAuthor.Status(rawValue: existing.status) ?? .active
        d.completedOn = existing.completedOn.flatMap(CivilDate.init(wire:))
      }
      let made = d
      try await build { a throws(AuthorError) in
        try a.defineProject(id: id, parentVersion: existing?.version, made)
      }
    case .setProjectCountInPlan(let id, let on):
      try await editProject(id) { $0.countInPlan = on }
    case .completeProject(let id, let done):
      let t = CivilDate(year: today.year, month: today.month, day: today.day)
      try await editProject(id) { d in
        d.status = done ? .completed : .active
        d.completedOn = done ? t : nil
      }
    case .removeProject(let id):
      try await editProject(id) { d in
        d.status = .removed
        d.completedOn = nil
      }
    case .assignProject(let ids, let project):
      for id in ids { _ = try txn(id) }
      try await build { a throws(AuthorError) in
        for id in ids { a.annotate(txnID: id, set: [("project_id", project)]) }
      }
    case .trackCandidate, .dismissCandidate, .skipReview, .setNotifications, .setFaceIDLock,
      .setDisplayName:
      break
    }
    return []
  }

  static func budgetInverse(_ plan: CoreReplay.PlanState, category c: String, month m: CivilMonth, shown: YearMonth) -> Inverse {
    let row = plan.cells[c] ?? [:]
    var inherited: Int64 = 0
    var best: CivilMonth?
    for (key, cell) in row {
      guard let km = CivilMonth(wire: key), km < m, let onward = cell.onwardSet else { continue }
      if best == nil || best! < km {
        best = km
        inherited = onward
      }
    }
    let cell = row[m.wire]
    let assigned: Int64
    if let cell, let set = cell.latestSet {
      assigned = Int64(clamping: Int128(set) + Int128(cell.movesSinceSet))
    } else {
      assigned = Int64(clamping: Int128(inherited) + Int128(cell?.movesAll ?? 0))
    }
    return .budget(category: c, month: shown, onward: cell?.onwardSet ?? inherited, assigned: max(0, assigned))
  }

  private func categorizedRows(except id: String) throws -> [(merchantRaw: String, category: String)] {
    try reader.activity(limit: 1_000_000).compactMap { r in
      guard r.id != id, !r.needsReview, let c = r.category else { return nil }
      return (r.merchantRaw, c)
    }
  }

  static func localWallMs(_ t: LocalDateTime) throws -> Int64 {
    guard let day = CivilDate(year: t.date.year, month: t.date.month, day: t.date.day), (0..<24).contains(t.hour),
      (0..<60).contains(t.minute)
    else { throw Failure.refused("date") }
    return day.daysSinceEpoch * 86_400_000 + Int64(t.hour * 60 + t.minute) * 60_000
  }

  static func projectDraft(_ d: ProjectDraft) throws -> OpAuthor.ProjectDraft {
    func civil(_ l: LocalDate?) throws -> CivilDate? {
      guard let l else { return nil }
      guard let c = CivilDate(year: l.year, month: l.month, day: l.day) else { throw Failure.refused("date") }
      return c
    }
    return OpAuthor.ProjectDraft(
      name: d.name.trimmingCharacters(in: .whitespacesAndNewlines), startsOn: try civil(d.starts),
      endsOn: try civil(d.ends), budgetMinor: d.budget?.minor, countInPlan: d.countInPlan,
      icon: LedgerStateMapper.icon(d.glyph))
  }

  static func projectDraft(_ p: CoreReplay.Project) -> OpAuthor.ProjectDraft {
    OpAuthor.ProjectDraft(
      name: p.name, startsOn: p.startsOn.flatMap(CivilDate.init(wire:)), endsOn: p.endsOn.flatMap(CivilDate.init(wire:)),
      budgetMinor: p.budgetMinor, countInPlan: p.countInPlan, status: OpAuthor.Status(rawValue: p.status) ?? .active,
      completedOn: p.completedOn.flatMap(CivilDate.init(wire:)), icon: p.icon)
  }

  private func editProject(_ id: String, _ change: (inout OpAuthor.ProjectDraft) -> Void) async throws {
    guard let p = try reader.projects().first(where: { $0.id == id })?.project else { throw Failure.notFound }
    var d = Self.projectDraft(p)
    change(&d)
    let draft = d
    try await build { a throws(AuthorError) in try a.defineProject(id: id, parentVersion: p.version, draft) }
  }

  /// Writes an undo back.
  func undo(_ inverses: [Inverse]) async throws {
    var rows: [String: TxnRow] = [:]
    var projects: [String: CoreReplay.Project] = [:]
    if inverses.contains(where: { if case .projectState = $0 { true } else { false } }) {
      for (id, p) in try reader.projects() { projects[id] = p }
    }
    for inv in inverses {
      switch inv {
      case .category(let t, _, _), .split(let t, _), .displayName(let t, _): rows[t] = try txn(t)
      case .samePurchase(let t, _, _, _, _), .samePurchaseDeclined(let t), .copyReopened(let t): rows[t] = try txn(t)
      default: break
      }
    }
    var bills: [String: Int64] = [:]
    if inverses.contains(where: { if case .bill = $0 { true } else { false } }) {
      for (id, b) in try reader.bills() { bills[id] = b.version }
    }
    var liveRates: [String: Int64] = [:]
    if inverses.contains(where: { if case .samePurchase(_, _, .some, _, _) = $0 { true } else { false } }) {
      for r in try reader.rates() { if let micro = r.rateMicro { liveRates[r.currency] = micro } }
    }
    try await build { a throws(AuthorError) in
      for inv in inverses {
        switch inv {
        case .category(let t, let c, let review):
          guard let row = rows[t] else { continue }
          a.categorize(txnID: t, parentVersion: row.version, category: c, needsReview: review)
        case .note(let t, let n):
          a.annotate(txnID: t, set: [("note", n.isEmpty ? nil : n)])
        case .displayName(let t, let shown):
          guard let row = rows[t] else { continue }
          a.renameMerchant(raw: row.merchantRaw, to: shown == Self.unrenamed(row.merchantRaw) ? nil : shown)
        case .project(let t, let project):
          a.annotate(txnID: t, set: [("project_id", project)])
        case .archived(let t, let archived):
          a.annotate(txnID: t, set: [("archived", archived ? "user" : nil)])
        case .split(let t, let lines):
          guard let row = rows[t] else { continue }
          a.split(
            txnID: t, parentVersion: row.version,
            parts: lines.map { (category: $0.categoryID, amountMinor: $0.amount.minor, note: $0.note.isEmpty ? nil : $0.note) })
        case .budget(let c, let month, let onward, let assigned):
          guard let m = CivilMonth(year: month.year, month: month.month) else { continue }
          a.setBudget(category: c, month: m, amountMinor: onward)
          if assigned != onward { a.setBudget(category: c, month: m, amountMinor: assigned, scope: "only") }
        case .move(let from, let to, let month, let amount, let undoes):
          guard let m = CivilMonth(year: month.year, month: month.month) else { continue }
          a.moveMoney(month: m, from: from, to: to, amountMinor: amount.minor, reason: "undo", undoes: undoes)
        case .occurrence(let bill, let due):
          guard let d = CivilDate(year: due.year, month: due.month, day: due.day) else { continue }
          a.setBillOccurrence(bill: bill, due: d, .clear)
        case .projectState(let id, let status, let completedOn, let countInPlan):
          guard let p = projects[id] else { continue }
          var d = Self.projectDraft(p)
          d.status = OpAuthor.Status(rawValue: status) ?? .active
          d.completedOn = completedOn.flatMap(CivilDate.init(wire:))
          d.countInPlan = countInPlan
          try a.defineProject(id: id, parentVersion: p.version, d)
        case .samePurchase(let f, let previous, let rate, let home, let note):
          guard let row = rows[f] else { continue }
          let live = rate == nil ? nil : liveRates[row.currency].map { (currency: row.currency, micro: $0) }
          a.undoSamePurchase(
            foreignID: f, foreignVersion: row.version, previousHomeMinor: live == nil ? previous : nil, homeID: home,
            previousNote: note, refreeze: live)
        case .samePurchaseDeclined(let home):
          guard let row = rows[home] else { continue }
          a.undoDeclineSamePurchase(homeID: home, homeVersion: row.version)
        case .copyReopened(let t):
          guard let row = rows[t], let other = row.copyOf else { continue }
          a.resolveCopy(txnID: t, parentVersion: row.version, otherTxnID: other, decision: nil)
        case .copyUnmerged(let t, let other, let version):
          a.resolveCopy(txnID: t, parentVersion: version, otherTxnID: other, decision: nil)
        case .bill(let id, let draft):
          guard let version = bills[id] else { continue }
          try a.setBill(id: id, parentVersion: version, draft)
        }
      }
    }
  }

  // MARK: Building

  /// One blob under the account's shared stamps; enqueued, then re-projected.
  @discardableResult
  private func build(_ body: (inout OpAuthor) throws(AuthorError) -> Void) async throws -> [Op] {
    let ctx = try await observer.authorContext()
    guard let blob = try observer.stamps.build(ctx, body) else { return [] }
    try await outbox.enqueue(blob.ops)
    try await observer.reproject()
    return blob.ops
  }

  /// The name a merchant shows with no rename (03c §3.6: the dictionary's, else the
  /// prettified raw merchant).
  static func unrenamed(_ merchantRaw: String) -> String {
    let dictionary = Categorizer(rules: [], dictionary: AccountRuntime.dictionary, categories: BuiltinCategories())
      .dictionaryDisplay(merchantRaw: merchantRaw)
    return MerchantDisplay.name(raw: merchantRaw, renamed: nil, dictionary: dictionary)
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
  private func editBill(_ id: String, _ change: (inout OpAuthor.BillDraft) -> Void) async throws -> OpAuthor.BillDraft {
    guard let (_, b) = try reader.bills().first(where: { $0.id == id }), let old = Self.draft(b) else {
      throw Failure.notFound
    }
    var d = old
    change(&d)
    let draft = d
    try await build { a throws(AuthorError) in try a.setBill(id: id, parentVersion: b.version, draft) }
    return old
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
