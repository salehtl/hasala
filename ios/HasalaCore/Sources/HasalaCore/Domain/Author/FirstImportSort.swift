import CoreCategorize
import CoreReplay

public enum FirstImportSort {
  public static let passSpacingMs: Int64 = 30_000
  public static let maxRequests = 400
  public static let backoffMs: [Int64] = [60_000, 180_000, 600_000]
  public static let lifetimeMs: Int64 = 3 * 86_400_000
  public static let maxTries = 3

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
    public var requests: Int

    public init(requests: Int = 0) {
      self.requests = requests
    }
  }

  public struct Interrupted: Error, Sendable {
    public let memo: Memo
  }

  public enum Stop: String, Sendable, Equatable {
    case off, refused, capped, rateLimited, budgetSpent, expired
  }

  public struct Pass: Sendable {
    public var suggestions: [ModelSuggestionSweep.Suggestion]
    public var memo: Memo
    public var pending: Int
    public var calls: Int
    public var stop: Stop?
    public var failed: Bool

    public init(
      suggestions: [ModelSuggestionSweep.Suggestion], memo: Memo, pending: Int, calls: Int, stop: Stop?, failed: Bool = false
    ) {
      self.suggestions = suggestions
      self.memo = memo
      self.pending = pending
      self.calls = calls
      self.stop = stop
      self.failed = failed
    }

    public static func failed(_ memo: Memo) -> Pass {
      Pass(suggestions: [], memo: memo, pending: 0, calls: 0, stop: nil, failed: true)
    }
  }

  public enum Next: Sendable, Equatable {
    case pass(afterMs: Int64)
    case waitForRows
    case done(Stop?)
  }

  public struct Plan: Sendable, Equatable {
    public let queued: [Queued]
    public let pending: [String]
    public let blocked: Set<String>

    public struct Queued: Sendable, Equatable {
      public let row: SweepRow
      public let subject: String
    }
  }

  public static func stop(for failure: ModelFailure) -> Stop {
    switch failure {
    case .rateLimited: .rateLimited
    case .busy: .capped
    case .notEnabled: .off
    default: .refused
    }
  }

  public static func expired(startedMs: Int64, nowMs: Int64) -> Bool {
    nowMs - startedMs >= lifetimeMs || nowMs < startedMs
  }

  public static func plan(
    rows: [SweepRow], categorizer: Categorizer, memo: Memo, isCached: (String) throws -> Bool
  ) rethrows -> Plan {
    let queued = ModelSuggestionSweep.queue(rows: rows, categorizer: categorizer)
      .map { Plan.Queued(row: $0, subject: Canon.subject($0.merchantRaw)) }
      .filter { !$0.subject.isEmpty }
    var blocked: Set<String> = []
    for q in queued where !ModelSuggestionSweep.mayLeaveDevice(q.row) { blocked.insert(q.subject) }
    var seen: Set<String> = []
    var pending: [String] = []
    for q in queued where seen.insert(q.subject).inserted {
      let s = q.subject
      guard !blocked.contains(s), ModelStage.hasLetter(s), !memo.asked.contains(s), memo.answers[s] == nil else { continue }
      guard try !isCached(s) else { continue }
      pending.append(s)
    }
    return Plan(queued: queued, pending: pending, blocked: blocked)
  }

  public static func pass(
    rows: [SweepRow], categorizer: Categorizer, allowed: [AllowedCategory], cloud: any CategoryModel, memo: Memo,
    cache: any ModelAnswerCache, now: @Sendable () -> Int64, autoFile: Bool, callTimeout: Duration? = nil
  ) async throws -> Pass {
    var memo = memo
    guard cloud.availability() == .available else { return Pass(suggestions: [], memo: memo, pending: 0, calls: 0, stop: .off) }
    guard !allowed.isEmpty else { return Pass(suggestions: [], memo: memo, pending: 0, calls: 0, stop: nil) }
    let taxonomy = ModelTier.taxonomyHash(allowed)
    let tag = cloud.modelTag
    let started = now()
    let work = try plan(rows: rows, categorizer: categorizer, memo: memo) {
      try cache.isCached(subject: $0, taxonomyHash: taxonomy, modelTag: tag, now: started)
    }
    var stop: Stop?
    var calls = 0
    if !work.pending.isEmpty {
      let left = maxRequests - memo.requests
      if left <= 0 {
        stop = .budgetSpent
      } else {
        let batch = Array(work.pending.prefix(min(ModelTier.Context.firstImport.budget.calls, left)))
        let r = await ModelTier.run(
          subjects: batch, stages: [.cloud(cloud)], allowed: allowed, context: .firstImport, now: now, callTimeout: callTimeout)
        calls = r.requests
        memo.requests += calls
        let settled = Set(r.suggestions.map(\.subject) + r.unknown.map(\.subject))
        let halted = r.stoppedBy[tag] == nil ? nil : r.asked.last?.subject
        for a in r.asked {
          if settled.contains(a.subject) {
            memo.asked.insert(a.subject)
          } else if a.subject != halted {
            memo.tries[a.subject, default: 0] += 1
            if memo.tries[a.subject, default: 0] >= maxTries { memo.asked.insert(a.subject) }
          }
        }
        for s in r.suggestions {
          memo.answers[s.subject] = Answer(category: s.category, modelTag: s.modelTag, autoFile: s.autoFile)
        }
        if let f = r.stoppedBy[tag] { stop = Self.stop(for: f) }
        do {
          try cache.recordUnknown(r.unknown, taxonomyHash: taxonomy, now: now())
        } catch {
          throw Interrupted(memo: memo)
        }
      }
    }
    let suggestions = work.queued.compactMap { q -> ModelSuggestionSweep.Suggestion? in
      guard !work.blocked.contains(q.subject), let a = memo.answers[q.subject], let v = q.row.version else { return nil }
      return ModelSuggestionSweep.Suggestion(
        txnID: q.row.id, version: v, category: a.category, modelTag: a.modelTag, autoFile: a.autoFile && autoFile)
    }
    let pending = work.pending.filter { !memo.asked.contains($0) && memo.answers[$0] == nil }.count
    return Pass(suggestions: suggestions, memo: memo, pending: pending, calls: calls, stop: stop)
  }

  public static func run(
    rows: [SweepRow], categorizer: Categorizer, allowed: [AllowedCategory], cloud: any CategoryModel, memo: Memo,
    cache: any ModelAnswerCache, now: @Sendable () -> Int64, autoFile: Bool, callTimeout: Duration? = nil, stamps: AuthorStamps,
    reread: @Sendable () async throws -> (rows: [SweepRow], context: AuthorContext)
  ) async throws -> (blobs: [AuthoredBlob], pass: Pass) {
    let p = try await pass(
      rows: rows, categorizer: categorizer, allowed: allowed, cloud: cloud, memo: memo, cache: cache, now: now, autoFile: autoFile,
      callTimeout: callTimeout)
    guard !p.suggestions.isEmpty else { return ([], p) }
    do {
      try Task.checkCancellation()
      let fresh = try await reread()
      let blobs = try stamps.authoring { (floor: Int64?) throws(AuthorError) -> (value: [AuthoredBlob], lastMs: Int64?) in
        let blobs = try ModelSuggestionSweep.author(p.suggestions, current: fresh.rows, context: fresh.context.raised(to: floor))
        return (blobs, blobs.last?.lastAuthoredMs)
      }
      return (blobs, p)
    } catch {
      throw Interrupted(memo: p.memo)
    }
  }

  public static func next(after p: Pass, importRunning: Bool, backoffs: Int) -> (next: Next, backoffs: Int) {
    switch p.stop {
    case .rateLimited?:
      guard backoffs < backoffMs.count else { return (.done(.rateLimited), backoffs) }
      return (.pass(afterMs: backoffMs[backoffs]), backoffs + 1)
    case let stop?:
      return (.done(stop), backoffs)
    case nil:
      if p.pending > 0 { return (.pass(afterMs: passSpacingMs), 0) }
      return (importRunning ? .waitForRows : .done(nil), 0)
    }
  }
}
