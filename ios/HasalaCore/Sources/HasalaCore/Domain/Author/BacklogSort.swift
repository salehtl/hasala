import CoreCategorize
import CorePrimitives
import CoreReplay
import CoreWire

public enum BacklogSort {
  public static let concurrency = 3
  public static let passNames = 12
  public static let passSpacingMs: Int64 = 30_000
  public static let dayNames = 400
  public static let dayWindowMs: Int64 = 86_400_000
  public static let maxTries = 3
  public static let backoffMs: [Int64] = [60_000, 180_000, 600_000]
  public static let busyPauseMs: Int64 = 15 * 60_000

  public struct Answer: Sendable, Equatable {
    public let category: String
    public let modelTag: String
    public let autoFile: Bool

    public init(category: String, modelTag: String, autoFile: Bool) {
      self.category = category
      self.modelTag = modelTag
      self.autoFile = autoFile
    }
  }

  public struct Memo: Sendable, Equatable {
    public var asked: Set<String> = []
    public var answers: [String: Answer] = [:]
    public var tries: [String: Int] = [:]

    public init() {}

    public func keeping(_ allowed: [AllowedCategory]) -> Memo {
      let ids = Set(allowed.map(\.id))
      var m = self
      for (s, a) in answers where !ids.contains(a.category) {
        m.answers[s] = nil
        m.asked.remove(s)
        m.tries[s] = nil
      }
      return m
    }
  }

  public struct Interrupted: Error, Sendable {
    public let memo: Memo
    public let calls: Int

    public init(memo: Memo, calls: Int = 0) {
      self.memo = memo
      self.calls = calls
    }
  }

  public enum Stop: String, Sendable, Equatable, Codable {
    case off, refused, rateLimited, busy, dayCap
  }

  public struct Pass: Sendable {
    public var suggestions: [ModelSuggestionSweep.Suggestion]
    public var memo: Memo
    public var pending: Int
    public var calls: Int
    public var stop: Stop?
    public var failed: Bool
    public var settled: Int

    public init(
      suggestions: [ModelSuggestionSweep.Suggestion], memo: Memo, pending: Int, calls: Int, stop: Stop?, failed: Bool = false,
      settled: Int = 0
    ) {
      self.suggestions = suggestions
      self.memo = memo
      self.pending = pending
      self.calls = calls
      self.stop = stop
      self.failed = failed
      self.settled = settled
    }

    public static func failed(_ memo: Memo, calls: Int = 0) -> Pass {
      Pass(suggestions: [], memo: memo, pending: 0, calls: calls, stop: nil, failed: true)
    }
  }

  public struct Filing: Sendable, Equatable {
    public var filed: [String: Int64] = [:]
    public var suggested: Set<String> = []

    public init(filed: [String: Int64] = [:], suggested: Set<String> = []) {
      self.filed = filed
      self.suggested = suggested
    }

    init(_ items: [OpAuthor.Categorization]) {
      for it in items {
        if it.needsReview {
          suggested.insert(it.txnID)
        } else {
          filed[it.txnID] = it.version + 1
        }
      }
    }

    public func only(_ blobs: [AuthoredBlob]) -> Filing {
      var ids: Set<String> = []
      for b in blobs { for op in b.ops { if let id = op.entity?.id { ids.insert(id) } } }
      return Filing(filed: filed.filter { ids.contains($0.key) }, suggested: suggested.filter { ids.contains($0) })
    }
  }

  public enum Next: Sendable, Equatable {
    case pass(afterMs: Int64)
    case waitForRows
    case pause(Stop, untilMs: Int64?)
    case done(Stop?)
  }

  public struct Plan: Sendable, Equatable {
    public let queued: [Queued]
    public let pending: [String]
    public let blocked: Set<String>
    public let cached: [String: Answer]
    public var rejected: [String: Set<String>] = [:]
    public var kept: [String: Answer] = [:]
    public var stale: [String] = []

    public struct Queued: Sendable, Equatable {
      public let row: SweepRow
      public let subject: String
    }
  }

  public struct Counts: Sendable, Equatable {
    public var waitingNames: Int
    public var pendingTxnIDs: Set<String>

    public init(waitingNames: Int = 0, pendingTxnIDs: Set<String> = []) {
      self.waitingNames = waitingNames
      self.pendingTxnIDs = pendingTxnIDs
    }
  }

  public static func stop(for failure: ModelFailure) -> Stop {
    switch failure {
    case .rateLimited: .rateLimited
    case .busy: .busy
    case .notEnabled: .off
    default: .refused
    }
  }

  static func inDay(_ ledger: [Int64], nowMs: Int64) -> [Int64] {
    ledger.filter { $0 > nowMs - dayWindowMs && $0 <= nowMs }
  }

  public static func dayUsed(_ ledger: [Int64], nowMs: Int64) -> Int {
    inDay(ledger, nowMs: nowMs).count
  }

  public static func dayLeft(_ ledger: [Int64], nowMs: Int64) -> Int {
    max(0, dayNames - dayUsed(ledger, nowMs: nowMs))
  }

  public static func dayReopensMs(_ ledger: [Int64], nowMs: Int64) -> Int64? {
    let live = inDay(ledger, nowMs: nowMs).sorted()
    guard live.count >= dayNames else { return nil }
    return live[live.count - dayNames] + dayWindowMs
  }

  public static func shuffled(_ items: [String], random: any RandomSource) -> [String] {
    var out = items
    guard out.count > 1 else { return out }
    for i in stride(from: out.count - 1, to: 0, by: -1) {
      guard let b = try? random.bytes(8) else { return items }
      let n = b.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
      out.swapAt(i, Int(n % UInt64(i + 1)))
    }
    return out
  }

  public static func plan(
    rows: [SweepRow], categorizer: Categorizer, memo: Memo, kept keptAnswer: (String) throws -> String? = { _ in nil },
    cached: (String) throws -> CachedAnswer?
  ) rethrows -> Plan {
    let queued = ModelSuggestionSweep.queue(rows: rows, categorizer: categorizer)
      .map { Plan.Queued(row: $0, subject: Canon.subject($0.merchantRaw)) }
      .filter { !$0.subject.isEmpty }
    var blocked: Set<String> = []
    for q in queued where !ModelSuggestionSweep.mayLeaveDevice(q.row) { blocked.insert(q.subject) }
    var rejected: [String: Set<String>] = [:]
    for q in queued where !q.row.rejected.isEmpty { rejected[q.subject, default: []].formUnion(q.row.rejected) }
    var seen: Set<String> = []
    var pending: [String] = []
    var hits: [String: Answer] = [:]
    var kept: [String: Answer] = [:]
    var stale: [String] = []
    for q in queued where seen.insert(q.subject).inserted {
      let s = q.subject
      guard !blocked.contains(s), ModelStage.cloudAccepts(s), !memo.asked.contains(s), memo.answers[s] == nil else { continue }
      if let k = try keptAnswer(s) {
        if rejected[s]?.contains(k) == true { continue }
        stale.append(s)
      }
      switch try cached(s) {
      case .unknown?: continue
      case .category(let c, let autoFile)? where rejected[s]?.contains(c) == true:
        kept[s] = Answer(category: c, modelTag: "", autoFile: autoFile)
      case .category(let c, let autoFile)?:
        hits[s] = Answer(category: c, modelTag: "", autoFile: autoFile)
      case nil:
        pending.append(s)
      }
    }
    return Plan(queued: queued, pending: pending, blocked: blocked, cached: hits, rejected: rejected, kept: kept, stale: stale)
  }

  public static func counts(
    rows: [SweepRow], categorizer: Categorizer, memo: Memo = .init(), kept: (String) throws -> String? = { _ in nil },
    cached: (String) throws -> CachedAnswer?
  ) rethrows -> Counts {
    let p = try plan(rows: rows, categorizer: categorizer, memo: memo, kept: kept, cached: cached)
    let waiting = Set(p.pending)
    var c = Counts(waitingNames: p.pending.count)
    for q in p.queued where !p.blocked.contains(q.subject) && waiting.contains(q.subject) { c.pendingTxnIDs.insert(q.row.id) }
    return c
  }

  public static func counts(
    rows: [SweepRow], categorizer: Categorizer, allowed: [AllowedCategory], modelTag: String, cache: any ModelAnswerCache, now: Int64,
    memo: Memo = .init()
  ) throws -> Counts {
    let taxonomy = ModelTier.taxonomyHash(allowed)
    return try counts(
      rows: rows, categorizer: categorizer, memo: memo.keeping(allowed), kept: { try cache.keptAnswer(subject: $0, modelTag: modelTag) }
    ) {
      try cache.answer(subject: $0, taxonomyHash: taxonomy, modelTag: modelTag, now: now)
    }
  }

  public static func pass(
    rows: [SweepRow], categorizer: Categorizer, allowed: [AllowedCategory], cloud: any CategoryModel, memo: Memo,
    cache: any ModelAnswerCache, now: @Sendable () -> Int64, autoFile: Bool, dayLeft: Int = .max,
    concurrency: Int = BacklogSort.concurrency, random: (any RandomSource)? = nil, callTimeout: Duration? = nil,
    trusts: @Sendable (String) -> Bool = { _ in true }, mayAsk: @Sendable () -> Bool = { true }
  ) async throws -> Pass {
    var memo = memo.keeping(allowed)
    guard cloud.availability() == .available else { return Pass(suggestions: [], memo: memo, pending: 0, calls: 0, stop: .off) }
    guard !allowed.isEmpty else { return Pass(suggestions: [], memo: memo, pending: 0, calls: 0, stop: nil) }
    let taxonomy = ModelTier.taxonomyHash(allowed)
    let tag = cloud.modelTag
    let started = now()
    let work = try plan(rows: rows, categorizer: categorizer, memo: memo, kept: { try cache.keptAnswer(subject: $0, modelTag: tag) }) {
      try cache.answer(subject: $0, taxonomyHash: taxonomy, modelTag: tag, now: started)
    }
    for (s, a) in work.cached { memo.answers[s] = Answer(category: a.category, modelTag: tag, autoFile: a.autoFile) }
    var stop: Stop?
    var calls = 0
    var settledCount = 0
    var keep = work.kept.sorted { $0.key < $1.key }.map {
      ModelTier.StagedSuggestion(subject: $0.key, category: $0.value.category, modelTag: tag, autoFile: $0.value.autoFile)
    }
    if !work.pending.isEmpty {
      let left = dayLeft
      if left <= 0 {
        stop = .dayCap
      } else {
        let order = random.map { shuffled(work.pending, random: $0) } ?? work.pending
        let batch = Array(order.prefix(min(passNames, left)))
        let r = await ModelTier.run(
          subjects: batch, stages: [.cloud(cloud)], allowed: allowed, context: .backlog, now: now, callTimeout: callTimeout,
          maxCalls: left, concurrency: concurrency, mayAsk: mayAsk)
        calls = r.requests
        let settled = Set(r.suggestions.map(\.subject) + r.unknown.map(\.subject))
        let halted = Set(r.failed.filter { ModelTier.stops($0.failure) }.map(\.subject))
        for a in Set(r.asked.map(\.subject)) {
          if settled.contains(a) {
            if memo.asked.insert(a).inserted { settledCount += 1 }
          } else if !halted.contains(a) {
            memo.tries[a, default: 0] += 1
            if memo.tries[a, default: 0] >= maxTries, memo.asked.insert(a).inserted { settledCount += 1 }
          }
        }
        for s in r.suggestions {
          memo.answers[s.subject] = Answer(category: s.category, modelTag: s.modelTag, autoFile: s.autoFile)
        }
        if let f = r.stoppedBy[tag] { stop = Self.stop(for: f) }
        do {
          try cache.recordUnknown(r.unknown, taxonomyHash: taxonomy, now: now())
          try cache.recordAnswers(r.suggestions, taxonomyHash: taxonomy, now: now())
        } catch {
          throw Interrupted(memo: memo, calls: calls)
        }
        keep += r.suggestions.filter { work.rejected[$0.subject]?.contains($0.category) == true }
      }
    }
    do {
      try cache.dropKept(work.stale.map { (subject: $0, modelTag: tag) })
      try cache.keepAnswers(keep)
    } catch {
      throw Interrupted(memo: memo, calls: calls)
    }
    let suggestions = work.queued.compactMap { q -> ModelSuggestionSweep.Suggestion? in
      guard !work.blocked.contains(q.subject), let a = memo.answers[q.subject], let v = q.row.version, !q.row.rejects(a.category)
      else { return nil }
      return ModelSuggestionSweep.Suggestion(
        txnID: q.row.id, version: v, category: a.category, modelTag: a.modelTag, autoFile: a.autoFile && autoFile && trusts(a.category))
    }
    let pending = work.pending.filter { !memo.asked.contains($0) && memo.answers[$0] == nil }.count
    if stop == nil, pending > 0, dayLeft != .max, dayLeft - calls <= 0 { stop = .dayCap }
    return Pass(suggestions: suggestions, memo: memo, pending: pending, calls: calls, stop: stop, settled: settledCount)
  }

  public static func run(
    rows: [SweepRow], categorizer: Categorizer, allowed: [AllowedCategory], cloud: any CategoryModel, memo: Memo,
    cache: any ModelAnswerCache, now: @Sendable () -> Int64, autoFile: Bool, dayLeft: Int = .max,
    concurrency: Int = BacklogSort.concurrency, random: (any RandomSource)? = nil, callTimeout: Duration? = nil, stamps: AuthorStamps,
    reread: @Sendable () async throws -> (rows: [SweepRow], context: AuthorContext)
  ) async throws -> (blobs: [AuthoredBlob], pass: Pass, filing: Filing) {
    let p = try await pass(
      rows: rows, categorizer: categorizer, allowed: allowed, cloud: cloud, memo: memo, cache: cache, now: now, autoFile: autoFile,
      dayLeft: dayLeft, concurrency: concurrency, random: random, callTimeout: callTimeout)
    guard !p.suggestions.isEmpty else { return ([], p, Filing()) }
    do {
      try Task.checkCancellation()
      let fresh = try await reread()
      let items = ModelSuggestionSweep.items(p.suggestions, current: fresh.rows)
      guard !items.isEmpty else { return ([], p, Filing()) }
      let blobs = try stamps.categorizations(items, context: fresh.context)
      return (blobs, p, Filing(items))
    } catch {
      throw Interrupted(memo: p.memo, calls: p.calls)
    }
  }

  public struct Committed: Sendable {
    public var pass: Pass
    public var filing: Filing
    public var failed: Bool
    public var authored: Bool
  }

  public static func run(
    rows: [SweepRow], categorizer: Categorizer, allowed: [AllowedCategory], cloud: any CategoryModel, memo: Memo,
    cache: any ModelAnswerCache, now: @Sendable () -> Int64, autoFile: Bool, dayLeft: Int = .max,
    concurrency: Int = BacklogSort.concurrency, random: (any RandomSource)? = nil, callTimeout: Duration? = nil,
    trusts: @Sendable (String) -> Bool = { _ in true }, mayAsk: @Sendable () -> Bool = { true }, stamps: AuthorStamps,
    serial: WriteSerial, reread: @Sendable () async throws -> (rows: [SweepRow], context: AuthorContext),
    enqueue: @Sendable (AuthoredBlob) async throws -> Void, reproject: @Sendable () async throws -> Void = {}
  ) async throws -> Committed {
    let p = try await pass(
      rows: rows, categorizer: categorizer, allowed: allowed, cloud: cloud, memo: memo, cache: cache, now: now, autoFile: autoFile,
      dayLeft: dayLeft, concurrency: concurrency, random: random, callTimeout: callTimeout, trusts: trusts, mayAsk: mayAsk)
    guard !p.suggestions.isEmpty else { return Committed(pass: p, filing: Filing(), failed: false, authored: false) }
    do {
      try Task.checkCancellation()
      return try await serial.run {
        let fresh = try await reread()
        let items = ModelSuggestionSweep.items(p.suggestions, current: fresh.rows)
        guard !items.isEmpty else { return Committed(pass: p, filing: Filing(), failed: false, authored: false) }
        let blobs = try stamps.categorizations(items, context: fresh.context)
        let c = await commit(blobs, filing: Filing(items), enqueue: enqueue)
        var failed = c.failed
        if !blobs.isEmpty {
          do { try await reproject() } catch { failed = true }
        }
        return Committed(pass: p, filing: c.filing, failed: failed, authored: !blobs.isEmpty)
      }
    } catch {
      throw Interrupted(memo: p.memo, calls: p.calls)
    }
  }

  public static func commit(
    _ blobs: [AuthoredBlob], filing: Filing, enqueue: (AuthoredBlob) async throws -> Void
  ) async -> (filing: Filing, failed: Bool) {
    var done: [AuthoredBlob] = []
    for b in blobs {
      do {
        try await enqueue(b)
      } catch {
        return (filing.only(done), true)
      }
      done.append(b)
    }
    return (filing, false)
  }

  public static func next(after p: Pass, importRunning: Bool, backoffs: Int, nowMs: Int64) -> (next: Next, backoffs: Int) {
    switch p.stop {
    case .rateLimited?:
      guard backoffs < backoffMs.count else {
        return (.pause(.rateLimited, untilMs: nowMs + (backoffMs.last ?? 0)), 0)
      }
      return (.pass(afterMs: backoffMs[backoffs]), backoffs + 1)
    case .busy?:
      return (.pause(.busy, untilMs: nowMs + busyPauseMs), 0)
    case .dayCap?:
      return (.pause(.dayCap, untilMs: nil), 0)
    case let stop?:
      return (.done(stop), backoffs)
    case nil:
      if p.pending > 0 { return (.pass(afterMs: passSpacingMs), 0) }
      return (importRunning ? .waitForRows : .done(nil), 0)
    }
  }

  public static func isCloudFiled(_ r: SweepRow) -> Bool {
    r.candidate && r.sourceKind == .model && !r.needsReview && r.category != nil && r.version != nil
      && (r.sourceRef.map(ModelTier.mayAutoFile(modelTag:)) ?? false)
  }

  public static func sendBackItems(filed: [String: Int64], current: [SweepRow]) -> [OpAuthor.Categorization] {
    current.compactMap { r in
      guard isCloudFiled(r), let v = r.version, filed[r.id] == v, let c = r.category, let tag = r.sourceRef else { return nil }
      return (r.id, v, c, true, CategorySource(kind: .model, model: tag))
    }
  }

  public static func sendBack(
    filed: [String: Int64], stamps: AuthorStamps, reread: @Sendable () async throws -> (rows: [SweepRow], context: AuthorContext)
  ) async throws -> (blobs: [AuthoredBlob], rows: Int) {
    let fresh = try await reread()
    let items = sendBackItems(filed: filed, current: fresh.rows)
    guard !items.isEmpty else { return ([], 0) }
    return (try stamps.categorizations(items, context: fresh.context), items.count)
  }
}
