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
import Synchronization

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
  let candidates = CandidateCache()
  let memory: SortKeeper
  let trust: TrustCounts

  init(
    observer: LedgerPageObserver, outbox: Outbox, memory: SortKeeper? = nil, trust: TrustCounts = .shared,
    undoChunkSize: Int = LedgerEditAuthor.undoChunk
  ) {
    self.observer = observer
    self.outbox = outbox
    self.memory = memory ?? SortKeeper(store: SortMemoryStore(observer.context.store))
    self.trust = trust
    self.undoChunkSize = undoChunkSize
  }

  final class CandidateCache: Sendable {
    private struct Entry {
      var generation: UInt64
      var today: CivilDate
      var list: [BillCandidateCore]
    }

    private let slot = Mutex<Entry?>(nil)

    func put(_ list: [BillCandidateCore], generation: UInt64, today: CivilDate) {
      slot.withLock { $0 = Entry(generation: generation, today: today, list: list) }
    }

    func get(generation: UInt64, today: CivilDate) -> [BillCandidateCore]? {
      slot.withLock { e in
        guard let e, e.generation == generation, e.today == today else { return nil }
        return e.list
      }
    }
  }

  func map(_ reader: LedgerReader, context: LedgerStateMapper.Context) throws -> LedgerState {
    let projection = observer.projection
    let generation = projection.generation
    let kept = memory.value
    var c = context
    c.priors = kept.priors
    var m = try LedgerStateMapper.mapped(reader, context: c)
    m.state.sortReceipt = kept.kitReceipt(undo: nil)
    if projection.generation == generation,
      let t = CivilDate(year: context.today.year, month: context.today.month, day: context.today.day)
    {
      candidates.put(m.candidates, generation: generation, today: t)
    }
    return m.state
  }

  var undoChunkSize: Int

  var reader: LedgerReader { observer.reader }

  /// What an undo writes back: the fields an edit changed, as they were (03c §3.8
  /// "Undo (toast)": inverse ops that touch only those fields).
  enum Inverse: Sendable, Equatable {
    case category(txn: String, category: String?, needsReview: Bool)
    case suggestion(txn: String, category: String?, needsReview: Bool, modelTag: String?, used: String)
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
    case resolution(bill: String, due: String, resolution: String, txn: String?, until: String?)
    case income(id: String, name: String, category: String, amountMinor: Int64, payday: Int64, active: Bool)
    case refile(txn: String, writtenVersion: Int64, category: String?, needsReview: Bool, source: CoreReplay.CategorySource)
    case prior(txn: String, prior: SortMemory.Prior)
    case rule(id: String, restore: OpAuthor.RuleDraft)
    case rejection(keys: [String], category: String, rejected: Bool)
    case receipt(id: Int)
    case trust(category: String, modelTag: String?, corrections: Int)
  }

  enum Failure: Error, Equatable {
    case notFound
    case refused(String)
  }

  /// Authors `edit`. `before` is the screens' state the gesture was made on (a bill's due
  /// date, the current amount).
  @discardableResult
  func author(_ edit: LedgerEdit, before: LedgerState, today: LocalDate, receiptID: Int? = nil) async throws -> [Inverse] {
    try await observer.writes.run { try await authorNow(edit, before: before, today: today, receiptID: receiptID) }
  }

  private func authorNow(_ edit: LedgerEdit, before: LedgerState, today: LocalDate, receiptID: Int?) async throws -> [Inverse] {
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
      if learnRule, Self.reaches(row) {
        let inverses = try await categorizeReaching(row, category: c, project: project, receiptID: receiptID)
        return inverses + noteCorrection(row, to: c)
      }
      try await build { a throws(AuthorError) in
        a.categorize(txnID: id, parentVersion: row.version, category: c, needsReview: false)
        if let project { a.annotate(txnID: id, set: [("project_id", project)]) }
      }
      return (row.split ? [] : [Self.refile(row, written: row.version + 1)]) + noteCorrection(row, to: c)
    case .useSuggestions(let uses):
      try await useSuggestions(uses)
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
      guard let shownBill = before.bill(id) else { throw Failure.notFound }
      for n in shownBill.notices {
        guard case .priceChange(_, let charged, let from) = n.kind else { continue }
        let f = try civil(from)
        let old = try await editBill(id) { d throws in
          try BillEdits.editAmount(&d, amountMinor: charged.minor, currency: charged.currency, variable: false, from: f)
        }
        return [.bill(id: id, draft: old)]
      }
      throw Failure.refused("no price change")
    case .stopTrackingBill(let id):
      let t = try civil(today)
      let old = try await editBill(id) { d throws in try BillEdits.end(&d, lastPayment: t) }
      return [.bill(id: id, draft: old)]
    case .addBill(let d):
      return try await addBill(d)
    case .editBillAmount(let id, let amount, let approximate, let from):
      let f = try civil(from)
      let old = try await editBill(id) { d throws in
        try BillEdits.editAmount(&d, amountMinor: amount.minor, currency: amount.currency, variable: approximate, from: f)
      }
      return [.bill(id: id, draft: old)]
    case .pauseBill(let id, let until):
      let t = try civil(today)
      let u = try until.map { try civil($0) }
      let paid = Self.paidDues(before, id)
      let old = try await editBill(id) { d throws in try BillEdits.pause(&d, today: t, until: u, paid: paid) }
      return [.bill(id: id, draft: old)]
    case .resumeBill(let id):
      let t = try civil(today)
      let old = try await editBill(id) { d throws in try BillEdits.resume(&d, today: t) }
      return [.bill(id: id, draft: old)]
    case .endBill(let id, let lastPayment):
      let l = try civil(lastPayment)
      let old = try await editBill(id) { d throws in try BillEdits.end(&d, lastPayment: l) }
      return [.bill(id: id, draft: old)]
    case .reactivateBill(let id):
      let t = try civil(today)
      let paid = Self.paidDues(before, id)
      let old = try await editBill(id) { d throws in try BillEdits.reactivate(&d, today: t, paid: paid) }
      return [.bill(id: id, draft: old)]
    case .deleteBill(let id):
      let old = try await editBill(id) { d throws in try BillEdits.delete(&d) }
      return [.bill(id: id, draft: old)]
    case .linkBillPayments(let id, let txns):
      return try await linkPayments(id, txns)
    case .reapplyBill(let id):
      return try await reapply(id)
    case .trackCandidate(let id):
      return try await candidate(id, track: true, today: today)
    case .dismissCandidate(let id):
      return try await candidate(id, track: false, today: today)
    case .editIncome(let id, let amount, let payday, let active):
      return try await editIncome(id, amount: amount, payday: payday, active: active)
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
      try await enqueueAll(blobs)
      if !enabled { memory.update { m in for i in m.batches.indices where m.batches[i].ruleID == id { m.batches[i].rerun = false } } }
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
    case .addCategory, .editCategory, .archiveCategory, .restoreCategory:
      try await authorCategory(edit, today: today)
    case .addCategoryAndSort(let d, let id, let alwaysUse, let project):
      return try await addCategoryAndSort(d, txn: id, alwaysUse: alwaysUse, project: project, receiptID: receiptID)
    case .skipReview, .setNotifications, .setFaceIDLock,
      .setDisplayName, .dismissBillNotice:
      break
    case .sortGroup(let ref, let c, let alwaysUse, let project):
      return try await sortGroup(ref, category: c, alwaysUse: alwaysUse, project: project, skipped: before.skippedReview, receiptID: receiptID)
    case .notThis(let ref, let c):
      return try await notThis(ref, category: c)
    case .returnToReview(let ids):
      return try await returnToReview(ids)
    case .stopRule(let id):
      return try await stopRule(id)
    case .dismissSortReceipt:
      memory.update { $0.receipt = nil }
    }
    return []
  }

  static func paidDues(_ s: LedgerState, _ id: String) -> Set<CivilDate> {
    Set((s.bill(id)?.payments ?? []).compactMap { CivilDate(year: $0.due.year, month: $0.due.month, day: $0.due.day) })
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

  private func useSuggestions(_ uses: [SuggestionUse]) async throws {
    var items: [(txnID: String, version: Int64, category: String, needsReview: Bool, source: CoreReplay.CategorySource)] = []
    var seen: Set<String> = []
    for u in uses where seen.insert(u.txn).inserted {
      guard let row = try reader.txn(u.txn), row.needsReview, row.categorySource == "model", row.category == u.category
      else { continue }
      items.append((u.txn, row.version, u.category, false, .user))
      trust.accepted(u.category, modelTag: row.categorySourceRef)
    }
    guard !items.isEmpty else { return }
    let ctx = try await observer.authorContext()
    let blobs = try observer.stamps.authoring {
      (floor: Int64?) throws(AuthorError) -> (value: [AuthoredBlob], lastMs: Int64?) in
      let b = try OpAuthor.categorizations(items, context: ctx.raised(to: floor))
      return (b, b.last?.lastAuthoredMs)
    }
    try await enqueueAll(blobs)
  }

  static let undoChunk = Sweep.maxOpsPerBlob / 2

  /// Writes an undo back.
  func undo(_ inverses: [Inverse]) async throws {
    try await observer.writes.run {
      let size = max(1, undoChunkSize)
      var blobs: [AuthoredBlob] = []
      var i = 0
      while i < inverses.count {
        if let b = try await undoBlob(Array(inverses[i..<min(i + size, inverses.count)])) { blobs.append(b) }
        i += size
      }
      let ops = blobs.flatMap(\.ops)
      if !ops.isEmpty {
        try await outbox.enqueue(ops)
        memory.update { $0.noteAuto(ops) }
        try await observer.reproject()
      }
      for inv in inverses {
        if case .trust(let c, let tag, let n) = inv { trust.uncorrected(c, modelTag: tag, by: n) }
      }
      let receipts = inverses.compactMap { if case .receipt(let id) = $0 { id } else { nil } }
      if !receipts.isEmpty { memory.update { m in if let r = m.receipt, receipts.contains(r.id) { m.receipt = nil } } }
      try keepPriors(inverses)
    }
  }

  private func keepPriors(_ inverses: [Inverse]) throws {
    var refiles: [String: SortMemory.Prior] = [:]
    var priors: [(txn: String, prior: SortMemory.Prior)] = []
    for inv in inverses {
      switch inv {
      case .refile(let t, let w, let c, let review, let source):
        refiles[t] = SortMemory.Prior(category: c, needsReview: review, source: source, written: w)
      case .prior(let t, let p): priors.append((t, p))
      default: continue
      }
    }
    var back: [(txn: String, prior: SortMemory.Prior, written: Int64)] = []
    for (t, p) in priors {
      guard let refile = refiles[t], let row = try reader.txn(t), LedgerStateMapper.restored(row, to: refile) else { continue }
      back.append((t, p, row.version))
    }
    guard !back.isEmpty else { return }
    memory.update { m in for b in back { m.refiled(b.txn, from: b.prior, written: b.written) } }
  }

  private func undoBlob(_ inverses: [Inverse]) async throws -> AuthoredBlob? {
    var rows: [String: TxnRow] = [:]
    var projects: [String: CoreReplay.Project] = [:]
    if inverses.contains(where: { if case .projectState = $0 { true } else { false } }) {
      for (id, p) in try reader.projects() { projects[id] = p }
    }
    for inv in inverses {
      switch inv {
      case .category(let t, _, _), .split(let t, _), .displayName(let t, _): rows[t] = try txn(t)
      case .suggestion(let t, _, _, _, _), .note(let t, _), .project(let t, _), .archived(let t, _): rows[t] = try reader.txn(t)
      case .samePurchase(let t, _, _, _, _), .samePurchaseDeclined(let t), .copyReopened(let t): rows[t] = try txn(t)
      case .refile(let t, _, _, _, _): rows[t] = try reader.txn(t)
      default: break
      }
    }
    var ruleVersions: [String: Int64] = [:]
    if inverses.contains(where: { if case .rule = $0 { true } else { false } }) {
      for r in try reader.rulesIncludingRemoved() { ruleVersions[r.id] = r.version }
    }
    var bills: [String: Int64] = [:]
    if inverses.contains(where: { if case .bill = $0 { true } else { false } }) {
      for (id, b) in try reader.bills() { bills[id] = b.version }
    }
    var liveRates: [String: Int64] = [:]
    if inverses.contains(where: { if case .samePurchase(_, _, .some, _, _) = $0 { true } else { false } }) {
      for r in try reader.rates() { if let micro = r.rateMicro { liveRates[r.currency] = micro } }
    }
    let ctx = try await observer.authorContext()
    return try observer.stamps.build(ctx) { a throws(AuthorError) in
      for inv in inverses {
        switch inv {
        case .refile(let t, let written, let c, let review, let source):
          guard let row = rows[t], row.version == written else { continue }
          a.categorize(txnID: t, parentVersion: row.version, category: c, needsReview: review, source: source)
        case .rule(let id, let restore):
          guard let version = ruleVersions[id] else { continue }
          try a.rule(id: id, parentVersion: version, restore)
        case .rejection(let keys, let c, let rejected):
          a.reject(keys: keys, category: c, rejected: rejected)
        case .receipt, .trust, .prior:
          continue
        case .category(let t, let c, let review):
          guard let row = rows[t], row.category != c || row.needsReview != review || row.split else { continue }
          a.categorize(txnID: t, parentVersion: row.version, category: c, needsReview: review)
        case .suggestion(let t, let c, let review, let tag, let used):
          guard let row = rows[t], row.category == used, row.categorySource == "user", !row.needsReview else { continue }
          a.categorize(
            txnID: t, parentVersion: row.version, category: c, needsReview: review,
            source: CoreReplay.CategorySource(kind: .model, model: tag))
        case .note(let t, let n):
          if let row = rows[t], (row.note ?? "") == n { continue }
          a.annotate(txnID: t, set: [("note", n.isEmpty ? nil : n)])
        case .displayName(let t, let shown):
          guard let row = rows[t] else { continue }
          a.renameMerchant(raw: row.merchantRaw, to: shown == Self.unrenamed(row.merchantRaw) ? nil : shown)
        case .project(let t, let project):
          if let row = rows[t], row.projectID == project { continue }
          a.annotate(txnID: t, set: [("project_id", project)])
        case .archived(let t, let archived):
          if let row = rows[t], (row.archived != nil) == archived { continue }
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
        case .resolution(let bill, let due, let resolution, let txn, let until):
          guard let d = CivilDate(wire: due) else { continue }
          a.setBillOccurrence(bill: bill, due: d, Self.occurrence(resolution, txn: txn, until: until))
        case .income(let id, let name, let category, let amount, let payday, let active):
          a.setIncomeSource(id: id, name: name, category: category, amountMinor: amount, payday: payday, active: active)
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
  func build(_ body: (inout OpAuthor) throws(AuthorError) -> Void) async throws -> [Op] {
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
  private func editBill(_ id: String, _ change: (inout OpAuthor.BillDraft) throws -> Void) async throws
    -> OpAuthor.BillDraft
  {
    guard let (_, b) = try reader.bills().first(where: { $0.id == id }), b.status != "dismissed",
      let old = Self.draft(b)
    else {
      throw Failure.notFound
    }
    var d = old
    try change(&d)
    let draft = d
    try await build { a throws(AuthorError) in try a.setBill(id: id, parentVersion: b.version, draft) }
    return old
  }

  static func draft(_ b: CoreReplay.Bill) -> OpAuthor.BillDraft? {
    guard let anchor = CivilDate(wire: b.anchor), let start = CivilDate(wire: b.start),
      let unit = OpAuthor.CadenceUnit(rawValue: b.cadence.unit), let cs = try? Self.changes(b.changes),
      let ps = try? Self.pauses(b.pauses)
    else { return nil }
    var end: CivilDate?
    if let e = b.end {
      guard let d = CivilDate(wire: e) else { return nil }
      end = d
    }
    return OpAuthor.BillDraft(
      name: b.name, keys: b.keys, direction: b.direction, currency: b.currency,
      mode: b.amountMode == "variable" ? .variable : .fixed(toleranceBp: b.toleranceBp ?? 0), amountMinor: b.amountMinor,
      cadenceUnit: unit, cadenceEvery: b.cadence.every, anchor: anchor, start: start,
      end: end, category: b.category, account: b.account,
      source: OpAuthor.BillSource(rawValue: b.source) ?? .manual, status: OpAuthor.BillStatus(rawValue: b.status) ?? .active,
      changes: cs, pauses: ps)
  }

  static func changes(_ list: [BillChange]) throws -> [OpAuthor.BillChangeDraft] {
    try list.map { c in
      guard let from = CivilDate(wire: c.from) else { throw Failure.refused("date") }
      return OpAuthor.BillChangeDraft(
        from: from,
        terms: OpAuthor.BillTermsDraft(
          mode: c.amountMode == "variable" ? .variable : .fixed(toleranceBp: c.toleranceBp ?? 0), amountMinor: c.amountMinor))
    }
  }

  static func pauses(_ list: [BillPause]) throws -> [OpAuthor.BillPauseDraft] {
    try list.map { p in
      guard let from = CivilDate(wire: p.from) else { throw Failure.refused("date") }
      var until: CivilDate?
      if let u = p.until {
        guard let d = CivilDate(wire: u) else { throw Failure.refused("date") }
        until = d
      }
      return OpAuthor.BillPauseDraft(from: from, until: until)
    }
  }

  static func occurrence(_ resolution: String, txn: String?, until: String?) -> OpAuthor.OccurrenceResolution {
    switch resolution {
    case "paid": return .paid(txn: txn)
    case "skipped": return .skipped
    case "snoozed":
      guard let u = until.flatMap(CivilDate.init(wire:)) else { return .clear }
      return .snoozed(until: u)
    default: return .clear
    }
  }

  private func civil(_ d: LocalDate) throws -> CivilDate {
    guard let c = CivilDate(year: d.year, month: d.month, day: d.day) else { throw Failure.refused("date") }
    return c
  }

  private struct Link {
    var txn: String
    var due: CivilDate
  }

  private func plannedLinks(_ ids: [String], billID: String?, draft d: OpAuthor.BillDraft) throws -> [Link] {
    guard !ids.isEmpty, Set(ids).count == ids.count else { throw Failure.refused("payments") }
    let live = Set(try reader.bills().filter { $0.bill.status != "dismissed" }.map(\.id))
    let resolutions = try reader.billResolutions()
    var dues = Set<CivilDate>()
    var out: [Link] = []
    for id in ids {
      let row = try txn(id)
      guard BillEdits.linkable(row, direction: d.direction) else { throw Failure.refused("payment") }
      if resolutions.contains(where: { $0.resolution == "paid" && $0.txn == id && $0.bill != billID && live.contains($0.bill) }) {
        throw Failure.refused("linked elsewhere")
      }
      guard let day = CivilDate(wire: row.localDate), let due = BillEdits.nearestUnbounded(d, to: day) else {
        throw Failure.refused("date")
      }
      if let end = d.end, due > end { throw Failure.refused("after the end") }
      guard dues.insert(due).inserted else { throw Failure.refused("one payment per due") }
      if let billID,
        resolutions.contains(where: {
          $0.bill == billID && $0.due == due.wire && $0.resolution == "paid" && $0.txn != nil && $0.txn != id
        })
      {
        throw Failure.refused("due already linked")
      }
      out.append(Link(txn: id, due: due))
    }
    return out
  }

  private func addBill(_ k: HasalaModels.BillDraft) async throws -> [Inverse] {
    if k.refusal != nil { throw Failure.refused("draft") }
    guard try reader.taxonomy().info(k.categoryID) != nil else { throw Failure.notFound }
    if let a = k.accountID, !(try reader.accounts().contains { $0.id == a }) { throw Failure.notFound }
    let first = try civil(k.firstDue)
    let name = k.trimmedName
    var d = OpAuthor.BillDraft(
      name: name, keys: BillEdits.keys(name: name, given: k.keys), currency: k.amount.currency,
      mode: k.approximate ? .variable : .fixed(toleranceBp: BillEdits.defaultToleranceBp), amountMinor: k.amount.minor,
      cadenceUnit: BillEdits.cadence(k.cadence), cadenceEvery: Int64(k.every), anchor: first, start: first,
      category: k.categoryID, account: k.accountID, source: .manual, status: .active)
    let links = k.linkTxns.isEmpty ? [] : try plannedLinks(k.linkTxns, billID: nil, draft: d)
    if let earliest = links.map(\.due).min(), earliest < d.start { d.start = earliest }
    let draft = d
    var minted = ""
    try await build { a throws(AuthorError) in
      let id = try a.newManualBillID()
      minted = id
      try a.setBill(id: id, draft)
      for l in links { a.setBillOccurrence(bill: id, due: l.due, .paid(txn: l.txn)) }
    }
    guard !minted.isEmpty else { return [] }
    var gone = draft
    gone.status = .dismissed
    return [.bill(id: minted, draft: gone)]
      + links.map { .resolution(bill: minted, due: $0.due.wire, resolution: "clear", txn: nil, until: nil) }
  }

  private func linkPayments(_ id: String, _ ids: [String]) async throws -> [Inverse] {
    guard let (_, b) = try reader.bills().first(where: { $0.id == id }), b.status != "dismissed",
      let old = Self.draft(b)
    else { throw Failure.notFound }
    let links = try plannedLinks(ids, billID: id, draft: old)
    var d = old
    if let earliest = links.map(\.due).min(), earliest < d.start { d.start = earliest }
    let moved = d.start != old.start
    let draft = d
    let own = try reader.billResolutions(bill: id)
    let linked = Set(links.map(\.txn))
    let dues = Set(links.map(\.due.wire))
    let stale = own.filter { r in
      r.resolution == "paid" && r.txn.map(linked.contains) == true && !dues.contains(r.due)
    }
    var inverses: [Inverse] = moved ? [.bill(id: id, draft: old)] : []
    for l in links {
      let prev = own.first { $0.due == l.due.wire }
      inverses.append(
        .resolution(bill: id, due: l.due.wire, resolution: prev?.resolution ?? "clear", txn: prev?.txn, until: prev?.until))
    }
    for r in stale {
      inverses.append(.resolution(bill: id, due: r.due, resolution: r.resolution, txn: r.txn, until: r.until))
    }
    try await build { a throws(AuthorError) in
      if moved { try a.setBill(id: id, parentVersion: b.version, draft) }
      for r in stale {
        if let due = CivilDate(wire: r.due) { a.setBillOccurrence(bill: id, due: due, .clear) }
      }
      for l in links { a.setBillOccurrence(bill: id, due: l.due, .paid(txn: l.txn)) }
    }
    return inverses
  }

  static func candidateDraft(_ c: BillCandidateCore) -> OpAuthor.BillDraft {
    OpAuthor.BillDraft(
      name: c.name, keys: [c.key], direction: "debit", currency: c.currency,
      mode: c.variable ? .variable : .fixed(toleranceBp: BillEdits.defaultToleranceBp), amountMinor: c.amountMinor,
      cadenceUnit: OpAuthor.CadenceUnit(rawValue: c.unit) ?? .month, cadenceEvery: c.every, anchor: c.anchor, start: c.start,
      category: c.category, account: nil, source: .detected, status: .active)
  }

  static func withdrawn(_ d: OpAuthor.BillDraft, id: String) -> OpAuthor.BillDraft {
    var w = d
    w.status = .dismissed
    w.keys = [id]
    w.end = nil
    w.changes = []
    w.pauses = []
    return w
  }

  private func candidate(_ id: String, track: Bool, today: LocalDate) async throws -> [Inverse] {
    let t = try civil(today)
    let generation = observer.projection.generation
    let records = try reader.bills()
    let found: [BillCandidateCore]
    if let cached = candidates.get(generation: generation, today: t) {
      found = cached
    } else {
      var rows = try reader.activity(limit: 1_000_000)
      rows += try reader.archived(limit: 1_000_000)
      found = LedgerStateMapper.detect(records, rows: rows, today: t)
    }
    guard let c = found.first(where: { $0.id == id }) else { throw Failure.notFound }
    var d = Self.candidateDraft(c)
    let taxonomy = try reader.taxonomy()
    if d.category.flatMap({ taxonomy.info($0)?.kind }) != .spending {
      d.category = taxonomy.info("subscriptions") == nil ? nil : "subscriptions"
    }
    if !track { d.status = .dismissed }
    let existing = records.first { $0.id == id }?.bill
    let draft = d
    try await build { a throws(AuthorError) in try a.setBill(id: id, parentVersion: existing?.version, draft) }
    if let existing, let old = Self.draft(existing) { return [.bill(id: id, draft: old)] }
    return [.bill(id: id, draft: Self.withdrawn(draft, id: id))]
  }

  private func reapply(_ id: String) async throws -> [Inverse] {
    guard let (_, current) = try reader.bills().first(where: { $0.id == id }), let old = Self.draft(current) else {
      throw Failure.notFound
    }
    let forks = try reader.forkNotices(kind: "bill").filter { $0.entityID == id }
    let ops = await observer.ops(Set(forks.map(\.loserOp))).found
    for f in forks.reversed() {
      guard let op = ops[f.loserOp], let loser = Replay.billRecord(op, inheritingFrom: current),
        LedgerStateMapper.forkSummary(loser: loser, current: current) != nil, let draft = Self.draft(loser)
      else { continue }
      try await build { a throws(AuthorError) in try a.setBill(id: id, parentVersion: current.version, draft) }
      return [.bill(id: id, draft: old)]
    }
    throw Failure.notFound
  }

  struct ForkLookup: Sendable {
    var ops: [String: Op] = [:]
    var settled: Set<String> = []
  }

  func forkLookup(_ ids: Set<String>) async -> ForkLookup {
    guard !ids.isEmpty else { return ForkLookup() }
    let lookup = await observer.ops(ids)
    return ForkLookup(ops: lookup.found, settled: Set(lookup.found.keys).union(lookup.missing))
  }

  static let incomePrefix = "income."

  private func editIncome(_ billID: String, amount: Money, payday: Int, active: Bool) async throws -> [Inverse] {
    guard billID.hasPrefix(Self.incomePrefix) else { throw Failure.notFound }
    let id = String(billID.dropFirst(Self.incomePrefix.count))
    guard let s = try reader.incomeSources().first(where: { $0.id == id }) else { throw Failure.notFound }
    guard amount.minor > 0, amount.minor <= ManualEntryDraft.maxMinor else { throw Failure.refused("amount") }
    guard (1...31).contains(payday) else { throw Failure.refused("payday") }
    try await build { a throws(AuthorError) in
      a.setIncomeSource(
        id: id, name: s.name, category: s.categoryID, amountMinor: amount.minor, payday: Int64(payday), active: active)
    }
    return [
      .income(id: id, name: s.name, category: s.categoryID, amountMinor: s.amountMinor, payday: s.payday, active: s.active)
    ]
  }

  func ruleSnapshots() throws -> [OpAuthor.RuleSnapshot] {
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
