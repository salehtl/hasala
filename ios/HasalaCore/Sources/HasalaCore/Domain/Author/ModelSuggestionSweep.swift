import CoreCategorize
import CoreReplay

public enum ModelSuggestionSweep {
  public struct Suggestion: Sendable, Equatable {
    public let txnID: String
    public let version: Int64
    public let category: String
    public let modelTag: String
    public let autoFile: Bool

    public init(txnID: String, version: Int64, category: String, modelTag: String, autoFile: Bool = false) {
      self.txnID = txnID
      self.version = version
      self.category = category
      self.modelTag = modelTag
      self.autoFile = autoFile
    }

    public var needsReview: Bool { !(autoFile && ModelTier.mayAutoFile(modelTag: modelTag)) }
  }

  public static func eligible(_ r: SweepRow) -> Bool {
    guard r.candidate, r.direction == .debit, r.category == nil, r.version != nil else { return false }
    switch r.sourceKind {
    case .user, .held: return false
    default: return true
    }
  }

  public static let cloudTemplates: Set<String> = ["adib.alert.v1", "dib.card.v1", "enbd.alert.v1"]

  public static func mayLeaveDevice(_ r: SweepRow) -> Bool {
    guard let t = r.template else { return false }
    return cloudTemplates.contains(String(t.prefix { $0 != "@" }))
  }

  public static func queue(rows: [SweepRow], categorizer: Categorizer) -> [SweepRow] {
    Sweep.plan(rows, categorizer).modelQueue.filter(eligible)
  }

  public static func suggest(
    rows: [SweepRow], categorizer: Categorizer, allowed: [AllowedCategory], stages: [ModelStage], context: ModelTier.Context,
    cache: any ModelAnswerCache, now: @Sendable () -> Int64, callTimeout: Duration? = nil, autoFile: Bool = true,
    maxCloudCalls: Int? = nil, spent: @Sendable (Int) -> Void = { _ in }, trusts: @Sendable (String) -> Bool = { _ in true }
  ) async throws -> [Suggestion] {
    guard context.budget.calls > 0, !allowed.isEmpty, !stages.isEmpty else { return [] }
    let queued = queue(rows: rows, categorizer: categorizer).map { (row: $0, subject: Canon.subject($0.merchantRaw)) }
      .filter { !$0.subject.isEmpty }
    guard !queued.isEmpty else { return [] }
    let taxonomy = ModelTier.taxonomyHash(allowed)
    let started = now()
    var subjects: [String] = []
    var seen: Set<String> = []
    for q in queued where seen.insert(q.subject).inserted { subjects.append(q.subject) }
    var blocked: Set<String> = []
    for q in queued where !mayLeaveDevice(q.row) { blocked.insert(q.subject) }
    let held = blocked
    var refused: [String: Set<String>] = [:]
    for q in queued where !q.row.rejected.isEmpty { refused[q.subject, default: []].formUnion(q.row.rejected) }
    let rejected = refused
    let rejects: @Sendable (String, String) -> Bool = { s, c in rejected[s]?.contains(c) == true }
    var cached: Set<[String]> = []
    var keep: [ModelTier.StagedSuggestion] = []
    var answer: [String: ModelTier.StagedSuggestion] = [:]
    subjects: for s in subjects {
      for stage in stages where stage.accepts(s) && !(stage.leavesDevice && held.contains(s)) {
        let tag = stage.model.modelTag
        switch try cache.answer(subject: s, taxonomyHash: taxonomy, modelTag: tag, now: started) {
        case .unknown?:
          cached.insert([s, tag])
        case .category(let c, let a)? where rejects(s, c):
          cached.insert([s, tag])
          if stage.leavesDevice { keep.append(ModelTier.StagedSuggestion(subject: s, category: c, modelTag: tag, autoFile: a)) }
        case .category(let c, let a)? where allowed.contains(where: { $0.id == c }):
          answer[s] = ModelTier.StagedSuggestion(subject: s, category: c, modelTag: tag, autoFile: a)
          continue subjects
        case .category?:
          cached.insert([s, tag])
        case nil:
          continue subjects
        }
      }
    }
    let hits = cached
    let r = await ModelTier.run(
      subjects: subjects.filter { answer[$0] == nil }, stages: stages, allowed: allowed, context: context, now: now,
      callTimeout: callTimeout, isCached: { hits.contains([$0, $1]) }, mayLeaveDevice: { !held.contains($0) },
      maxCloudCalls: maxCloudCalls, rejects: rejects)
    if r.cloudRequests > 0 { spent(r.cloudRequests) }
    try cache.recordUnknown(r.unknown, taxonomyHash: taxonomy, now: now())
    try cache.recordAnswers(r.suggestions, taxonomyHash: taxonomy, now: now())
    let cloudTags = Set(stages.filter(\.leavesDevice).map(\.model.modelTag))
    keep += r.suggestions.filter { cloudTags.contains($0.modelTag) && rejects($0.subject, $0.category) }
    try cache.keepAnswers(keep, taxonomyHash: taxonomy)
    for s in r.suggestions where answer[s.subject] == nil && !rejects(s.subject, s.category) { answer[s.subject] = s }
    return queued.compactMap { q in
      guard let a = answer[q.subject], let v = q.row.version, !q.row.rejects(a.category) else { return nil }
      return Suggestion(
        txnID: q.row.id, version: v, category: a.category, modelTag: a.modelTag, autoFile: a.autoFile && autoFile && trusts(a.category))
    }
  }

  public static func items(_ suggestions: [Suggestion], current: [SweepRow])
    -> [(txnID: String, version: Int64, category: String, needsReview: Bool, source: CategorySource)]
  {
    var now: [String: SweepRow] = [:]
    for r in current { now[r.id] = r }
    var done: Set<String> = []
    var items: [(txnID: String, version: Int64, category: String, needsReview: Bool, source: CategorySource)] = []
    for s in suggestions {
      guard let r = now[s.txnID], eligible(r), r.version == s.version, !r.rejects(s.category), done.insert(s.txnID).inserted
      else { continue }
      items.append(
        (s.txnID, s.version, s.category, r.needsReview || s.needsReview, CategorySource(kind: .model, model: s.modelTag)))
    }
    return items
  }

  public static func author(_ suggestions: [Suggestion], current: [SweepRow], context: AuthorContext) throws(AuthorError)
    -> [AuthoredBlob]
  {
    let items = items(suggestions, current: current)
    guard !items.isEmpty else { return [] }
    return try OpAuthor.categorizations(items, context: context)
  }

  public static func run(
    rows: [SweepRow], categorizer: Categorizer, allowed: [AllowedCategory], stages: [ModelStage], context: ModelTier.Context,
    cache: any ModelAnswerCache, now: @Sendable () -> Int64, callTimeout: Duration? = nil, autoFile: Bool = true,
    maxCloudCalls: Int? = nil, spent: @Sendable (Int) -> Void = { _ in }, trusts: @Sendable (String) -> Bool = { _ in true },
    stamps: AuthorStamps, serial: WriteSerial = WriteSerial(),
    reread: @Sendable () async throws -> (rows: [SweepRow], context: AuthorContext),
    commit: @Sendable ([AuthoredBlob]) async throws -> Void = { _ in }
  ) async throws -> [AuthoredBlob] {
    let suggestions = try await suggest(
      rows: rows, categorizer: categorizer, allowed: allowed, stages: stages, context: context, cache: cache, now: now,
      callTimeout: callTimeout, autoFile: autoFile, maxCloudCalls: maxCloudCalls, spent: spent, trusts: trusts)
    guard !suggestions.isEmpty else { return [] }
    try Task.checkCancellation()
    return try await serial.run {
      let fresh = try await reread()
      let blobs = try stamps.authoring { (floor: Int64?) throws(AuthorError) -> (value: [AuthoredBlob], lastMs: Int64?) in
        let blobs = try author(suggestions, current: fresh.rows, context: fresh.context.raised(to: floor))
        return (blobs, blobs.last?.lastAuthoredMs)
      }
      if !blobs.isEmpty { try await commit(blobs) }
      return blobs
    }
  }
}
