import CoreCategorize
import CoreDomain
import CoreProjection
import CoreReplay
import CoreStore
import CoreWire
import Foundation
import HasalaCloud
import HasalaModels

nonisolated extension SortMemory {
  var priors: [String: Prior] {
    var out: [String: Prior] = [:]
    for b in batches { out.merge(b.prior) { _, new in new } }
    return out
  }
}

nonisolated extension LedgerEditAuthor {
  static let rerunWindowMs: Int64 = 86_400_000

  func reach() throws -> (rows: [RuleReach.Row], home: String) {
    (try reader.reachRows(), try reader.homeCurrency() ?? "AED")
  }

  static func source(kind: String, ref: String?) -> CoreReplay.CategorySource {
    switch kind {
    case "rule": return CoreReplay.CategorySource(kind: .rule, ruleID: ref)
    case "held": return CoreReplay.CategorySource(kind: .held, ruleID: ref)
    case "model": return CoreReplay.CategorySource(kind: .model, model: ref)
    case "user": return .user
    case "dictionary":
      guard let ref, let bar = ref.firstIndex(of: "|") else { return .none }
      return CoreReplay.CategorySource(
        kind: .dictionary, bundle: String(ref[..<bar]), entry: String(ref[ref.index(after: bar)...]))
    default: return .none
    }
  }

  static func source(_ r: RuleReach.Row) -> CoreReplay.CategorySource { source(kind: r.sourceKind.rawValue, ref: r.sourceRef) }

  static func refile(_ row: TxnRow, written: Int64) -> Inverse {
    .refile(
      txn: row.id, writtenVersion: written, category: row.category, needsReview: row.needsReview,
      source: source(kind: row.categorySource, ref: row.categorySourceRef))
  }

  static func refile(_ r: RuleReach.Row) -> Inverse {
    .refile(txn: r.id, writtenVersion: r.version + 1, category: r.category, needsReview: r.needsReview, source: source(r))
  }

  static func restored(_ r: RuleReach.Row, to p: SortMemory.Prior) -> Bool {
    p.restored(version: r.version, category: r.category, needsReview: r.needsReview, kind: r.sourceKind.rawValue, ref: r.sourceRef)
  }

  static func prior(_ r: RuleReach.Row, after kept: SortMemory.Prior?) -> SortMemory.Prior {
    let at = if let kept, restored(r, to: kept) { kept.categorizedMs } else { r.categorizedMs }
    return SortMemory.Prior(
      category: r.category, needsReview: r.needsReview, source: source(r), written: r.version + 1, categorizedMs: at)
  }

  static func direction(_ ref: MerchantGroupRef) -> String { ref.direction == .in ? "credit" : "debit" }

  var nowMs: Int64 { observer.context.clock.nowMs() }

  func noteCorrection(_ row: TxnRow, to category: String) -> [Inverse] {
    guard row.categorySource == "model", !row.needsReview, let old = row.category, old != category else { return [] }
    guard trust.corrected(old, modelTag: row.categorySourceRef) else { return [] }
    return [.trust(category: old, modelTag: row.categorySourceRef, corrections: 1)]
  }

  func enqueueAll(_ blobs: [AuthoredBlob], auto: Bool = false) async throws {
    let ops = blobs.flatMap(\.ops)
    guard !ops.isEmpty else { return }
    try await outbox.enqueue(ops)
    if auto { memory.update { $0.noteAuto(ops) } }
    try await observer.reproject()
  }

  func displayName(group: String, ids: Set<String>) throws -> String {
    var counts: [String: Int] = [:]
    var newest: (Int64, String)?
    for t in try reader.group(group) where ids.contains(t.id) {
      counts[t.displayName, default: 0] += 1
      if newest == nil || t.postedMs > newest!.0 { newest = (t.postedMs, t.displayName) }
    }
    let ranked = counts.sorted { a, b in
      if a.value != b.value { return a.value > b.value }
      if (a.key == newest?.1) != (b.key == newest?.1) { return a.key == newest?.1 }
      return a.key < b.key
    }
    return ranked.first?.key ?? newest?.1 ?? ""
  }

  private func ruleInput(_ id: String, _ draft: OpAuthor.RuleDraft) -> RuleInput {
    RuleInput(id: id, patterns: draft.patterns, match: draft.match.rawValue, category: draft.category, priority: draft.priority)
  }

  private func ruleInverses(_ plan: OpAuthor.GroupRulePlan, id: String, existing: [OpAuthor.RuleSnapshot]) -> [Inverse] {
    var out: [Inverse] = []
    if !plan.unchanged {
      if let old = existing.first(where: { $0.id == id }) {
        out.append(.rule(id: id, restore: old.draft))
      } else {
        var gone = plan.draft
        gone.removed = true
        out.append(.rule(id: id, restore: gone))
      }
    }
    for t in plan.trims {
      if let old = existing.first(where: { $0.id == t.id }) { out.append(.rule(id: t.id, restore: old.draft)) }
    }
    return out
  }

  private static func authorRules(_ plan: OpAuthor.GroupRulePlan, _ a: inout OpAuthor) throws(AuthorError) -> String {
    let id = plan.unchanged ? (plan.id ?? "") : try a.rule(id: plan.id, parentVersion: plan.parentVersion, plan.draft)
    for t in plan.trims { try a.rule(id: t.id, parentVersion: t.version, t.draft) }
    return id
  }

  private func remember(
    ruleID: String?, group: String, direction: String, category: String, rows: [RuleReach.Row], filed: [RuleReach.Row],
    receipt: SortMemory.Receipt?, autoOps: [Op]
  ) throws {
    let cursor = try reader.meta()?.cursorHot ?? 0
    let now = nowMs
    let seen = Set(rows.filter { $0.merchantGroup == group }.map(\.id))
    memory.update { m in
      m.noteAuto(autoOps)
      if let ruleID {
        var prior: [String: SortMemory.Prior] = [:]
        for r in filed { prior[r.id] = Self.prior(r, after: m.prior(of: r.id)) }
        m.add(
          SortMemory.Batch(
            id: "\(ruleID).\(now)", ruleID: ruleID, group: group, direction: direction, category: category, seen: seen,
            prior: prior, rerun: true, cursor: cursor, atMs: now), nowMs: now)
      }
      if let receipt { m.receipt = receipt }
    }
  }

  func categorizeReaching(_ row: TxnRow, category c: String, project: ProjectID?, receiptID: Int?) async throws -> [Inverse] {
    guard let group = row.merchantGroup else { return [] }
    let (rows, home) = try reach()
    let pool = RuleReach.eligible(rows: rows, group: group, direction: row.direction, home: home).filter { $0.id != row.id }
    let existing = try ruleSnapshots()
    let plan = OpAuthor.groupRule(
      patterns: RuleReach.patterns(filed: row.merchantRaw, members: pool, filing: c), category: c, existing: existing)
    let ctx = try await observer.authorContext()
    var ruleID: String?
    var targets: [RuleReach.Target] = []
    var reachOps: [Op] = []
    let blobs = try observer.stamps.authoring {
      (floor: Int64?) throws(AuthorError) -> (value: [AuthoredBlob], lastMs: Int64?) in
      var cx = ctx.raised(to: floor)
      var a = OpAuthor(cx)
      a.categorize(txnID: row.id, parentVersion: row.version, category: c, needsReview: false)
      if let project { a.annotate(txnID: row.id, set: [("project_id", project)]) }
      var rest: [AuthoredBlob] = []
      if let plan {
        let id = try Self.authorRules(plan, &a)
        ruleID = id
        targets = RuleReach.plan(
          rows: rows, rule: ruleInput(id, plan.draft), group: group, direction: row.direction, home: home, except: [row.id])
        let first = try a.build()
        cx.ownLastMs = first.lastAuthoredMs
        if !targets.isEmpty {
          rest = try OpAuthor.categorizations(RuleReach.items(targets, ruleID: id, category: c), context: cx)
          reachOps = rest.flatMap(\.ops)
        }
        let all = [first] + rest
        return (all, all.last?.lastAuthoredMs)
      }
      let first = try a.build()
      return ([first], first.lastAuthoredMs)
    }
    try await enqueueAll(blobs)
    var inverses: [Inverse] = [Self.refile(row, written: row.version + 1)]
    guard let ruleID, let plan else { return inverses }
    let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    let filed = targets.compactMap { byID[$0.txnID] }
    var receipt: SortMemory.Receipt?
    if !filed.isEmpty {
      let ids = (RuleReach.settled(row.reachRow, in: c) ? [] : [row.id]) + filed.map(\.id)
      receipt = SortMemory.Receipt(
        id: receiptID ?? Int(nowMs), group: group, direction: row.direction,
        merchant: try displayName(group: group, ids: Set([row.id] + filed.map(\.id))), category: c, txnIDs: ids, ruleID: ruleID,
        atMs: nowMs)
      inverses.append(.receipt(id: receipt!.id))
    }
    try remember(
      ruleID: ruleID, group: group, direction: row.direction, category: c, rows: rows, filed: filed, receipt: receipt, autoOps: reachOps)
    inverses += filed.map(Self.refile)
    inverses += ruleInverses(plan, id: ruleID, existing: existing)
    return inverses
  }

  func sortGroup(
    _ ref: MerchantGroupRef, category c: String, alwaysUse: Bool, project: ProjectID?, skipped: Set<TxnID>, receiptID: Int?
  ) async throws -> [Inverse] {
    let direction = Self.direction(ref)
    let (rows, home) = try reach()
    let members = RuleReach.members(rows: rows, group: ref.key, direction: direction, home: home).filter { !skipped.contains($0.id) }
    guard !members.isEmpty else { throw Failure.notFound }
    let existing = alwaysUse ? try ruleSnapshots() : []
    let plan = alwaysUse ? OpAuthor.groupRule(patterns: RuleReach.patterns(filed: nil, members: members), category: c, existing: existing) : nil
    let memberIDs = Set(members.map(\.id))
    let ctx = try await observer.authorContext()
    var ruleID: String?
    var targets: [RuleReach.Target] = []
    var reachOps: [Op] = []
    let blobs = try observer.stamps.authoring {
      (floor: Int64?) throws(AuthorError) -> (value: [AuthoredBlob], lastMs: Int64?) in
      var cx = ctx.raised(to: floor)
      var out: [AuthoredBlob] = []
      var a = OpAuthor(cx)
      func roll() throws(AuthorError) {
        guard a.count >= Sweep.maxOpsPerBlob else { return }
        let b = try a.build()
        out.append(b)
        cx.ownLastMs = b.lastAuthoredMs
        a = OpAuthor(cx)
      }
      if let plan {
        ruleID = try Self.authorRules(plan, &a)
      }
      for m in members {
        try roll()
        a.categorize(txnID: m.id, parentVersion: m.version, category: c, needsReview: false)
        if let project {
          try roll()
          a.annotate(txnID: m.id, set: [("project_id", project)])
        }
      }
      if a.count > 0 {
        let b = try a.build()
        out.append(b)
        cx.ownLastMs = b.lastAuthoredMs
      }
      if let plan, let id = ruleID {
        targets = RuleReach.plan(
          rows: rows, rule: ruleInput(id, plan.draft), group: ref.key, direction: direction, home: home,
          except: memberIDs.union(skipped), scope: .waiting)
        if !targets.isEmpty {
          let rest = try OpAuthor.categorizations(RuleReach.items(targets, ruleID: id, category: c), context: cx)
          reachOps = rest.flatMap(\.ops)
          out += rest
        }
      }
      return (out, out.last?.lastAuthoredMs)
    }
    try await enqueueAll(blobs)
    for m in members where m.sourceKind == .model && m.category == c { trust.accepted(c, modelTag: m.sourceRef) }
    let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    let reached = targets.compactMap { byID[$0.txnID] }
    let filed = members + reached
    let ids = filed.map(\.id)
    let receipt = SortMemory.Receipt(
      id: receiptID ?? Int(nowMs), group: ref.key, direction: direction, merchant: try displayName(group: ref.key, ids: Set(ids)),
      category: c, txnIDs: ids, ruleID: ruleID, atMs: nowMs)
    try remember(
      ruleID: ruleID, group: ref.key, direction: direction, category: c, rows: rows, filed: filed, receipt: receipt, autoOps: reachOps)
    var inverses: [Inverse] = [.receipt(id: receipt.id)] + filed.map(Self.refile)
    if let plan, let ruleID { inverses += ruleInverses(plan, id: ruleID, existing: existing) }
    return inverses
  }

  func notThis(_ ref: MerchantGroupRef, category c: String) async throws -> [Inverse] {
    let keys = try reader.memberKeys(group: ref.key)
    let already = Set(try reader.rejectedKeys(group: ref.key, category: c))
    let fresh = keys.filter { !already.contains($0) }
    let (rows, _) = try reach()
    let resets = rows.filter { r in
      r.merchantGroup == ref.key && r.sourceKind == .model && r.category == c && !r.split && !r.archived
    }
    guard !fresh.isEmpty || !resets.isEmpty else { throw Failure.notFound }
    let ctx = try await observer.authorContext()
    let blobs = try observer.stamps.authoring {
      (floor: Int64?) throws(AuthorError) -> (value: [AuthoredBlob], lastMs: Int64?) in
      var cx = ctx.raised(to: floor)
      var out: [AuthoredBlob] = []
      if !fresh.isEmpty {
        var a = OpAuthor(cx)
        a.reject(keys: fresh, category: c, rejected: true)
        let b = try a.build()
        out.append(b)
        cx.ownLastMs = b.lastAuthoredMs
      }
      var a = OpAuthor(cx)
      for r in resets {
        if a.count >= Sweep.maxOpsPerBlob {
          let b = try a.build()
          out.append(b)
          cx.ownLastMs = b.lastAuthoredMs
          a = OpAuthor(cx)
        }
        a.categorize(txnID: r.id, parentVersion: r.version, category: nil, needsReview: true, source: .none)
      }
      if a.count > 0 { out.append(try a.build()) }
      return (out, out.last?.lastAuthoredMs)
    }
    try await enqueueAll(blobs, auto: true)
    keepRejected(rows, group: ref.key, category: c, resets: resets)
    var counted: [String?: Int] = [:]
    for r in resets where !r.needsReview && trust.corrected(c, modelTag: r.sourceRef) { counted[r.sourceRef, default: 0] += 1 }
    var inverses: [Inverse] = fresh.isEmpty ? [] : [.rejection(keys: fresh, category: c, rejected: false)]
    inverses += resets.map(Self.refile)
    inverses += counted.sorted { ($0.key ?? "") < ($1.key ?? "") }.map { .trust(category: c, modelTag: $0.key, corrections: $0.value) }
    return inverses
  }

  func keepRejected(_ rows: [RuleReach.Row], group: String, category c: String, resets: [RuleReach.Row]) {
    let cache = FMCache(observer.context.store)
    var keep: [ModelTier.StagedSuggestion] = []
    var seen: Set<[String]> = []
    func add(_ raw: String, _ tag: String) {
      let s = Canon.subject(raw)
      guard !s.isEmpty, seen.insert([s, tag]).inserted else { return }
      keep.append(ModelTier.StagedSuggestion(subject: s, category: c, modelTag: tag, autoFile: false))
    }
    for r in resets { if let tag = r.sourceRef, TrustCounts.cloud(tag) { add(r.merchantRaw, tag) } }
    if let taxonomy = try? reader.taxonomy() {
      let hash = ModelTier.taxonomyHash(ModelTier.allowed(taxonomy.ordered))
      let tag = CloudCategoryModel.defaultTag
      let now = nowMs
      for r in rows where r.merchantGroup == group && r.category == nil {
        guard
          case .category(let answer, _)? = try? cache.answer(
            subject: Canon.subject(r.merchantRaw), taxonomyHash: hash, modelTag: tag, now: now),
          answer == c
        else { continue }
        add(r.merchantRaw, tag)
      }
    }
    try? cache.keepAnswers(keep)
  }

  func returnToReview(_ ids: [TxnID]) async throws -> [Inverse] {
    var seen: Set<String> = []
    var items: [(txnID: String, version: Int64, category: String?, needsReview: Bool, source: CoreReplay.CategorySource)] = []
    var inverses: [Inverse] = []
    let mem = memory.value
    for id in ids where seen.insert(id).inserted {
      guard let row = try reader.txn(id), !row.split, !row.needsReview, let category = row.category else { continue }
      let byRule = row.categorySource == "rule"
      let byCloud = row.categorySource == "model" && TrustCounts.cloud(row.categorySourceRef)
      guard byRule || byCloud else { continue }
      if let p = mem.prior(of: id), p.written == row.version {
        items.append((id, row.version, p.category, p.needsReview, p.source))
        inverses.append(.prior(txn: id, prior: p))
      } else if byRule {
        items.append((id, row.version, nil, true, .none))
      } else {
        items.append((id, row.version, category, true, Self.source(kind: row.categorySource, ref: row.categorySourceRef)))
      }
      inverses.append(Self.refile(row, written: row.version + 1))
    }
    guard !items.isEmpty else { throw Failure.notFound }
    let ctx = try await observer.authorContext()
    let blobs = try observer.stamps.authoring {
      (floor: Int64?) throws(AuthorError) -> (value: [AuthoredBlob], lastMs: Int64?) in
      var cx = ctx.raised(to: floor)
      var out: [AuthoredBlob] = []
      var a = OpAuthor(cx)
      for it in items {
        if a.count >= Sweep.maxOpsPerBlob {
          let b = try a.build()
          out.append(b)
          cx.ownLastMs = b.lastAuthoredMs
          a = OpAuthor(cx)
        }
        a.categorize(txnID: it.txnID, parentVersion: it.version, category: it.category, needsReview: it.needsReview, source: it.source)
      }
      if a.count > 0 { out.append(try a.build()) }
      return (out, out.last?.lastAuthoredMs)
    }
    try await enqueueAll(blobs, auto: true)
    memory.update { $0.settle(items.map(\.txnID)) }
    return inverses
  }

  func stopRule(_ id: RuleID) async throws -> [Inverse] {
    guard let r = try reader.rules().first(where: { $0.id == id }), let snapshot = Self.snapshot(r) else {
      throw Failure.notFound
    }
    var d = snapshot.draft
    d.removed = true
    let draft = d
    try await build { a throws(AuthorError) in try a.rule(id: id, parentVersion: snapshot.version, draft) }
    memory.update { m in for i in m.batches.indices where m.batches[i].ruleID == id { m.batches[i].rerun = false } }
    return [.rule(id: id, restore: snapshot.draft)]
  }

  func followUp() async -> Bool {
    let m = memory.value
    guard m.batches.contains(where: \.rerun) || !m.autoOps.isEmpty else { return false }
    do {
      return try await observer.writes.run { try await followUpNow() }
    } catch {
      return false
    }
  }

  private func followUpNow() async throws -> Bool {
    let reran = try await rerun()
    let repaired = try await repairForks()
    return reran || repaired
  }

  private func rerun() async throws -> Bool {
    let now = nowMs
    let cursor = try reader.meta()?.cursorHot ?? 0
    memory.update { m in for i in m.batches.indices where now - m.batches[i].atMs > Self.rerunWindowMs { m.batches[i].rerun = false } }
    let due = memory.value.batches.filter { $0.rerun && cursor > $0.cursor }
    guard !due.isEmpty else { return false }
    let rules = try reader.rules()
    let (rows, home) = try reach()
    var items: [(txnID: String, version: Int64, category: String, needsReview: Bool, source: CoreReplay.CategorySource)] = []
    var filedBy: [String: [RuleReach.Row]] = [:]
    var taken: Set<String> = []
    let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    for b in due {
      guard let ruleID = b.ruleID, let r = rules.first(where: { $0.id == ruleID }), r.enabled, !r.removed else { continue }
      let input = RuleInput(id: r.id, patterns: r.patterns, match: r.match, category: r.category, priority: r.priority)
      let targets = RuleReach.plan(rows: rows, rule: input, group: b.group, direction: b.direction, home: home, except: b.seen.union(taken))
      for t in targets {
        taken.insert(t.txnID)
        items += RuleReach.items([t], ruleID: r.id, category: r.category)
        if let row = byID[t.txnID] { filedBy[b.id, default: []].append(row) }
      }
    }
    var ops: [Op] = []
    if !items.isEmpty {
      let ctx = try await observer.authorContext()
      let list = items
      let blobs = try observer.stamps.authoring {
        (floor: Int64?) throws(AuthorError) -> (value: [AuthoredBlob], lastMs: Int64?) in
        let b = try OpAuthor.categorizations(list, context: ctx.raised(to: floor))
        return (b, b.last?.lastAuthoredMs)
      }
      ops = blobs.flatMap(\.ops)
      try await enqueueAll(blobs)
    }
    let groupIDs = Dictionary(grouping: rows.filter { $0.merchantGroup != nil }, by: { $0.merchantGroup! }).mapValues { Set($0.map(\.id)) }
    let dueIDs = Set(due.map(\.id))
    memory.update { m in
      m.noteAuto(ops)
      for i in m.batches.indices where dueIDs.contains(m.batches[i].id) {
        m.batches[i].cursor = cursor
        m.batches[i].seen.formUnion(groupIDs[m.batches[i].group] ?? [])
        for r in filedBy[m.batches[i].id] ?? [] {
          let p = Self.prior(r, after: m.prior(of: r.id))
          m.batches[i].prior[r.id] = p
        }
      }
    }
    return !ops.isEmpty
  }

  private func repairForks() async throws -> Bool {
    let mem = memory.value
    let own = mem.ownOps
    guard !own.isEmpty else { return false }
    let forks = try reader.forkNotices(kind: "txn").filter { own.contains($0.winnerOp) && !mem.repaired.contains($0.loserOp) }
    guard !forks.isEmpty else { return false }
    let lookup = await observer.ops(Set(forks.flatMap { [$0.winnerOp, $0.loserOp] }))
    var settled: Set<String> = []
    var items: [(txnID: String, version: Int64, category: String?, needsReview: Bool, source: CoreReplay.CategorySource)] = []
    var touched: Set<String> = []
    for f in forks.reversed() {
      guard let loser = lookup.found[f.loserOp], let winner = lookup.found[f.winnerOp] else {
        if lookup.missing.contains(f.loserOp) || lookup.missing.contains(f.winnerOp) { settled.insert(f.loserOp) }
        continue
      }
      settled.insert(f.loserOp)
      guard loser.type == .txnCategorized, winner.type == .txnCategorized, Self.kind(loser) == "user",
        touched.insert(f.entityID).inserted, let row = try reader.txn(f.entityID), !row.split
      else { continue }
      guard row.category == Self.category(winner), row.categorySource == Self.kind(winner) else { continue }
      items.append((row.id, row.version, Self.category(loser), loser.payload["needs_review"]?.boolValue ?? false, .user))
    }
    if !items.isEmpty {
      let ctx = try await observer.authorContext()
      let list = items
      let blobs = try observer.stamps.authoring {
        (floor: Int64?) throws(AuthorError) -> (value: [AuthoredBlob], lastMs: Int64?) in
        var a = OpAuthor(ctx.raised(to: floor))
        for it in list {
          a.categorize(txnID: it.txnID, parentVersion: it.version, category: it.category, needsReview: it.needsReview, source: it.source)
        }
        let b = try a.build()
        return ([b], b.lastAuthoredMs)
      }
      try await enqueueAll(blobs)
    }
    if !settled.isEmpty { memory.update { $0.repaired.formUnion(settled) } }
    return !items.isEmpty
  }

  static func kind(_ op: Op) -> String? { op.payload["source"]?.objectValue?["kind"]?.stringValue ?? (category(op) == nil ? "none" : "user") }

  static func category(_ op: Op) -> String? { op.payload["category"]?.stringValue }
}
