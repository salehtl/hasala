import CoreCategorize
import CorePrimitives
import CoreReplay
import CoreTestSupport
import Foundation
import Synchronization
import Testing

@testable import CoreDomain

final class BacklogCloud: GradedCategoryModel, Sendable {
  let modelTag = "cf-clef/1"
  let answers: [String: (answer: ModelAnswer, autoFile: Bool)]
  let fallback: (answer: ModelAnswer, autoFile: Bool)
  let failAt: (call: Int, failure: ModelFailure)?
  let delay: Duration?
  let state = Mutex<(calls: [String], available: Bool, inFlight: Int, most: Int)>(([], true, 0, 0))

  init(
    _ answers: [String: (answer: ModelAnswer, autoFile: Bool)] = [:], fallback: (answer: ModelAnswer, autoFile: Bool) = (.unknown, false),
    failAt: (call: Int, failure: ModelFailure)? = nil, delay: Duration? = nil
  ) {
    self.answers = answers
    self.fallback = fallback
    self.failAt = failAt
    self.delay = delay
  }

  var calls: [String] { state.withLock { $0.calls } }
  var most: Int { state.withLock { $0.most } }
  func setAvailable(_ on: Bool) { state.withLock { $0.available = on } }

  func availability() -> ModelAvailability { state.withLock { $0.available } ? .available : .notEnabled }
  func suggest(subject: String, allowed: [AllowedCategory]) async -> ModelAnswer { .unknown }
  func suggestGraded(subject: String, allowed: [AllowedCategory]) async -> (answer: ModelAnswer, autoFile: Bool) {
    let n = state.withLock { s in
      s.calls.append(subject)
      s.inFlight += 1
      s.most = max(s.most, s.inFlight)
      return s.calls.count
    }
    if let delay { try? await Task.sleep(for: delay) }
    state.withLock { $0.inFlight -= 1 }
    if let failAt, n >= failAt.call { return (.failed(failAt.failure), false) }
    return answers[subject] ?? fallback
  }
}

@Suite("BacklogSort")
struct BacklogSortTests {
  typealias T = ModelSuggestionSweepTests

  static func pass(
    _ l: T.Ledger, _ cloud: BacklogCloud, memo: BacklogSort.Memo = .init(), cache: any ModelAnswerCache = MemoryCache(),
    autoFile: Bool = true, dayLeft: Int = .max, concurrency: Int = BacklogSort.concurrency, random: (any RandomSource)? = nil
  ) async throws -> BacklogSort.Pass {
    try await BacklogSort.pass(
      rows: l.rows(), categorizer: T.categorizer, allowed: T.allowed, cloud: cloud, memo: memo, cache: cache, now: { now },
      autoFile: autoFile, dayLeft: dayLeft, concurrency: concurrency, random: random)
  }

  static func names(_ n: Int) -> [(String, String)] {
    (0..<n).map { i in ("PLACE \(Character(UnicodeScalar(65 + i / 26)!))\(Character(UnicodeScalar(65 + i % 26)!))", "debit") }
  }

  static func review(_ blobs: [AuthoredBlob]) throws -> [String: Bool] {
    var out: [String: Bool] = [:]
    for op in blobs.flatMap(\.ops) { out[try #require(op.entity?.id)] = op.payload["needs_review"]?.boolValue }
    return out
  }

  @Test("one request per distinct merchant; rules and the dictionary go first; credits stay out")
  func dedupe() async throws {
    var l = T.Ledger()
    let ids = try l.ingest([
      ("SURE SHOP", "debit"), ("SURE SHOP", "debit"), ("UNSURE SHOP", "debit"), ("CARREFOUR MOE", "debit"), ("SURE SHOP", "credit"),
      ("UNSURE SHOP", "debit"), ("MYSTERY PLACE 77", "debit"),
    ])
    let cloud = BacklogCloud([
      "sure shop": (.category("groceries"), true), "unsure shop": (.category("dining"), false),
    ])
    let cache = MemoryCache()
    let p = try await Self.pass(l, cloud, cache: cache)
    #expect(cloud.calls.sorted() == ["mystery place 77", "sure shop", "unsure shop"])
    #expect(p.calls == 3 && p.pending == 0 && p.stop == nil)
    #expect(Set(p.suggestions.map(\.txnID)) == [ids[0], ids[1], ids[2], ids[5]])
    #expect(p.suggestions.filter { !$0.needsReview }.map(\.txnID).sorted() == [ids[0], ids[1]].sorted())
    #expect(try cache.isCached(subject: "mystery place 77", taxonomyHash: ModelTier.taxonomyHash(T.allowed), modelTag: "cf-clef/1", now: now))
  }

  @Test("rows that load later reuse the answer without a second request; answered and cached names are not sent again")
  func memo() async throws {
    var l = T.Ledger()
    _ = try l.ingest([("SURE SHOP", "debit"), ("MYSTERY PLACE 77", "debit"), ("SLOW SHOP", "debit")])
    let cloud = BacklogCloud(["sure shop": (.category("groceries"), true), "slow shop": (.failed(.timeout), false)])
    let cache = MemoryCache()
    let first = try await Self.pass(l, cloud, cache: cache)
    #expect(first.calls == 3 && first.pending == 1)
    let later = try l.ingest([("SURE SHOP", "debit"), ("SLOW SHOP", "debit"), ("MYSTERY PLACE 77", "debit")])
    let second = try await Self.pass(l, cloud, memo: first.memo, cache: cache)
    #expect(second.calls == 1 && cloud.calls.count == 4 && cloud.calls.last == "slow shop")
    #expect(second.suggestions.contains { $0.txnID == later[0] && $0.category == "groceries" })
    #expect(!second.suggestions.contains { $0.txnID == later[1] || $0.txnID == later[2] })
  }

  @Test("an answer held from earlier in the session for a category that is gone files nothing; the name is asked again")
  func goneCategory() async throws {
    var l = T.Ledger()
    let ids = try l.ingest([("UNSURE SHOP", "debit"), ("SURE SHOP", "debit")])
    var memo = BacklogSort.Memo()
    memo.asked = ["unsure shop", "sure shop"]
    memo.answers["unsure shop"] = .init(category: "dining", modelTag: "cf-clef/1", autoFile: true)
    memo.answers["sure shop"] = .init(category: "groceries", modelTag: "cf-clef/1", autoFile: true)
    let allowed = T.allowed.filter { $0.id != "dining" }
    #expect(allowed.count == T.allowed.count - 1)
    let waiting = try BacklogSort.counts(
      rows: l.rows(), categorizer: T.categorizer, allowed: allowed, modelTag: "cf-clef/1", cache: MemoryCache(), now: now, memo: memo)
    #expect(waiting.waitingNames == 1 && waiting.pendingTxnIDs == [ids[0]])
    let quiet = BacklogCloud()
    let held = try await BacklogSort.pass(
      rows: l.rows(), categorizer: T.categorizer, allowed: allowed, cloud: quiet, memo: memo, cache: MemoryCache(), now: { now },
      autoFile: true, dayLeft: 0)
    #expect(quiet.calls.isEmpty && held.stop == .dayCap)
    #expect(held.suggestions.map(\.txnID) == [ids[1]] && held.suggestions.allSatisfy { $0.category != "dining" })
    let cloud = BacklogCloud(["unsure shop": (.category("shopping"), false)])
    let p = try await BacklogSort.pass(
      rows: l.rows(), categorizer: T.categorizer, allowed: allowed, cloud: cloud, memo: memo, cache: MemoryCache(), now: { now },
      autoFile: true)
    #expect(cloud.calls == ["unsure shop"])
    #expect(Dictionary(uniqueKeysWithValues: p.suggestions.map { ($0.txnID, $0.category) }) == [ids[0]: "shopping", ids[1]: "groceries"])
    #expect(p.memo.answers["unsure shop"]?.category == "shopping")
  }

  @Test("a name that timed out is asked again on later passes, at most three times; a 429 is not a try")
  func retries() async throws {
    var l = T.Ledger()
    _ = try l.ingest([("SLOW SHOP", "debit")])
    let cloud = BacklogCloud(["slow shop": (.failed(.timeout), false)])
    var memo = BacklogSort.Memo()
    for n in 1...BacklogSort.maxTries {
      let p = try await Self.pass(l, cloud, memo: memo)
      memo = p.memo
      #expect(p.calls == 1 && memo.tries["slow shop"] == n)
      #expect(p.pending == (n < BacklogSort.maxTries ? 1 : 0))
    }
    let after = try await Self.pass(l, cloud, memo: memo)
    #expect(after.calls == 0 && after.pending == 0 && cloud.calls.count == BacklogSort.maxTries)
    let limited = BacklogCloud(failAt: (1, .rateLimited))
    let r = try await Self.pass(l, limited)
    #expect(r.stop == .rateLimited && r.calls == 1 && r.memo.tries.isEmpty && r.memo.asked.isEmpty && r.pending == 1)
  }

  @Test("a context-overflow retry is a request: it counts toward the pass and the device budget")
  func overflowRetry() async throws {
    final class OverflowsOnce: GradedCategoryModel, Sendable {
      let modelTag = "cf-clef/1"
      let calls = Mutex(0)
      func availability() -> ModelAvailability { .available }
      func suggest(subject: String, allowed: [AllowedCategory]) async -> ModelAnswer { .unknown }
      func suggestGraded(subject: String, allowed: [AllowedCategory]) async -> (answer: ModelAnswer, autoFile: Bool) {
        let n = calls.withLock { c in
          c += 1
          return c
        }
        return n == 1 ? (.failed(.contextOverflow), false) : (.unknown, false)
      }
    }
    var l = T.Ledger()
    _ = try l.ingest(Self.names(14))
    let cloud = OverflowsOnce()
    let p = try await BacklogSort.pass(
      rows: l.rows(), categorizer: T.categorizer, allowed: T.allowed, cloud: cloud, memo: .init(), cache: MemoryCache(), now: { now },
      autoFile: true)
    let budget = ModelTier.Context.backlog.budget.calls
    #expect(budget == BacklogSort.passNames)
    #expect(cloud.calls.withLock { $0 } == budget)
    #expect(p.calls == budget && p.memo.asked.count == budget - 1 && p.pending == 14 - (budget - 1))
  }

  @Test("a failure after the requests keeps the memo, so they are counted and the names are not asked again")
  func interrupted() async throws {
    struct Boom: Error {}
    final class FailingCache: ModelAnswerCache, Sendable {
      func answer(subject: String, taxonomyHash: String, modelTag: String, now: Int64) throws -> CachedAnswer? { nil }
      func recordUnknown(_ entries: [(subject: String, modelTag: String)], taxonomyHash: String, now: Int64) throws { throw Boom() }
      func recordAnswers(_ entries: [ModelTier.StagedSuggestion], taxonomyHash: String, now: Int64) throws { throw Boom() }
      func keptAnswer(subject: String, modelTag: String) throws -> String? { nil }
      func keepAnswers(_ entries: [ModelTier.StagedSuggestion]) throws { throw Boom() }
      func dropKept(_ entries: [(subject: String, modelTag: String)]) throws { throw Boom() }
    }
    var l = T.Ledger()
    _ = try l.ingest([("SURE SHOP", "debit"), ("MYSTERY PLACE 77", "debit")])
    let cloud = BacklogCloud(["sure shop": (.category("groceries"), true)])
    let rows = l.rows()
    do {
      _ = try await BacklogSort.run(
        rows: rows, categorizer: T.categorizer, allowed: T.allowed, cloud: cloud, memo: .init(), cache: MemoryCache(),
        now: { now }, autoFile: true, stamps: AuthorStamps(), reread: { throw Boom() })
      Issue.record("the reread failed, so the run must throw")
    } catch let e as BacklogSort.Interrupted {
      #expect(e.calls == 2 && e.memo.answers["sure shop"]?.category == "groceries")
      #expect(e.memo.asked == ["sure shop", "mystery place 77"])
    }
    do {
      _ = try await Self.pass(l, cloud, cache: FailingCache())
      Issue.record("the cache failed, so the pass must throw")
    } catch let e as BacklogSort.Interrupted {
      #expect(e.calls == 2 && e.memo.asked.count == 2)
    }
    #expect(BacklogSort.Pass.failed(.init()).failed)
    let failed = BacklogSort.Pass.failed(.init(), calls: 3)
    #expect(failed.failed && failed.calls == 3)
  }

  @Test("a commit that fails part way keeps the filing of the blobs it enqueued")
  func partialCommit() async throws {
    struct Boom: Error {}
    var l = T.Ledger()
    let ids = try l.ingest([("SURE SHOP", "debit"), ("OTHER SURE SHOP", "debit"), ("THIRD SHOP", "debit")])
    var blobs: [AuthoredBlob] = []
    for id in ids.prefix(2) {
      var a = OpAuthor(l.context())
      a.categorize(
        txnID: id, parentVersion: l.state.txns[id]!.version, category: "groceries", needsReview: false,
        source: CategorySource(kind: .model, model: "cf-clef/1"))
      let b = try a.build()
      try l.fold(b)
      blobs.append(b)
    }
    let filing = BacklogSort.Filing(filed: [ids[0]: 2, ids[1]: 2], suggested: [ids[2]])
    let enqueued = Mutex(0)
    let partial = await BacklogSort.commit(blobs, filing: filing) { _ in
      let n = enqueued.withLock { n -> Int in
        n += 1
        return n
      }
      if n == 2 { throw Boom() }
    }
    #expect(partial.failed && partial.filing.filed == [ids[0]: 2] && partial.filing.suggested.isEmpty)
    let whole = await BacklogSort.commit(blobs, filing: filing) { _ in }
    #expect(!whole.failed && whole.filing == filing)
    let none = await BacklogSort.commit(blobs, filing: filing) { _ in throw Boom() }
    #expect(none.failed && none.filing == BacklogSort.Filing())
  }

  @Test("an answer kept from an earlier pass never files a row whose name may not leave the device")
  func blockedLater() async throws {
    var l = T.Ledger()
    let card = try l.ingest([("SHARED NAME", "debit")], template: "dib.card.v1@1")
    let cloud = BacklogCloud(fallback: (.category("dining"), true))
    let first = try await Self.pass(l, cloud)
    #expect(first.suggestions.map(\.txnID) == card)
    let transfer = try l.ingest([("SHARED NAME", "debit")], template: "enbd.transfer.v1@2")
    let second = try await Self.pass(l, cloud, memo: first.memo)
    #expect(second.calls == 0 && second.memo.answers["shared name"] != nil)
    #expect(!second.suggestions.contains { transfer.contains($0.txnID) })
    #expect(second.suggestions.isEmpty)
  }

  @Test("filing is idempotent: a rerun after a kill skips filed and user-edited rows and sends nothing more")
  func idempotent() async throws {
    var l = T.Ledger()
    let ids = try l.ingest([("SURE SHOP", "debit"), ("OTHER SURE SHOP", "debit"), ("MYSTERY PLACE 77", "debit")], needsReview: false)
    let cloud = BacklogCloud(["sure shop": (.category("groceries"), true), "other sure shop": (.category("dining"), true)])
    let cache = MemoryCache()
    let p = try await Self.pass(l, cloud, cache: cache)
    var u = OpAuthor(l.context())
    u.categorize(txnID: ids[1], parentVersion: l.state.txns[ids[1]]!.version, category: "shopping")
    try l.fold(try u.build())
    let blobs = try ModelSuggestionSweep.author(p.suggestions, current: l.rows(), context: l.context())
    #expect(try Self.review(blobs) == [ids[0]: false])
    for b in blobs { try l.fold(b) }
    #expect(l.state.txns[ids[1]]?.category == "shopping" && l.state.txns[ids[1]]?.categorySource?.kind == .user)
    #expect(try ModelSuggestionSweep.author(p.suggestions, current: l.rows(), context: l.context()).isEmpty)
    let again = try await Self.pass(l, cloud, memo: BacklogSort.Memo(), cache: cache)
    #expect(again.calls == 0 && again.suggestions.isEmpty && again.pending == 0)
    #expect(cloud.calls.count == 3)
  }

  @Test("a row files only with Sort automatically on and a confident graded answer")
  func threshold() async throws {
    var l = T.Ledger()
    let ids = try l.ingest([("SURE SHOP", "debit"), ("UNSURE SHOP", "debit")], needsReview: false)
    let cloud = BacklogCloud(["sure shop": (.category("groceries"), true), "unsure shop": (.category("dining"), false)])
    let on = try await Self.pass(l, cloud)
    let onBlobs = try ModelSuggestionSweep.author(on.suggestions, current: l.rows(), context: l.context())
    #expect(try Self.review(onBlobs) == [ids[0]: false, ids[1]: true])
    let off = try await Self.pass(l, cloud, memo: on.memo, autoFile: false)
    #expect(off.calls == 0)
    let offBlobs = try ModelSuggestionSweep.author(off.suggestions, current: l.rows(), context: l.context())
    #expect(try Self.review(offBlobs) == [ids[0]: true, ids[1]: true])
    let apple = ModelSuggestionSweep.Suggestion(txnID: ids[0], version: 1, category: "dining", modelTag: "apple-fm/26.1", autoFile: true)
    #expect(apple.needsReview)
  }

  @Test("a pass asks at most twelve names; the rest wait for the next pass")
  func perPass() async throws {
    var l = T.Ledger()
    _ = try l.ingest(Self.names(25))
    let cloud = BacklogCloud()
    let p = try await Self.pass(l, cloud)
    #expect(p.calls == 12 && p.pending == 13 && p.settled == 12)
    #expect(BacklogSort.next(after: p, importRunning: false, backoffs: 0, nowMs: now).next == .pass(afterMs: BacklogSort.passSpacingMs))
    let q = try await Self.pass(l, cloud, memo: p.memo)
    #expect(q.calls == 12 && q.pending == 1 && Set(cloud.calls).count == 24)
  }

  @Test("three calls at once in a backlog pass; one at a time when asked")
  func concurrency() async throws {
    var l = T.Ledger()
    _ = try l.ingest(Self.names(12))
    let wide = BacklogCloud(delay: .milliseconds(20))
    let p = try await Self.pass(l, wide)
    #expect(p.calls == 12 && wide.most == BacklogSort.concurrency)
    let narrow = BacklogCloud(delay: .milliseconds(5))
    let q = try await Self.pass(l, narrow, concurrency: 1)
    #expect(q.calls == 12 && narrow.most == 1)
  }

  @Test("the ask order is shuffled, and the same seed gives the same order")
  func shuffle() async throws {
    var l = T.Ledger()
    _ = try l.ingest(Self.names(30))
    let first = BacklogCloud()
    _ = try await Self.pass(l, first, concurrency: 1, random: SeededRandom(seed: "order"))
    let second = BacklogCloud()
    _ = try await Self.pass(l, second, concurrency: 1, random: SeededRandom(seed: "order"))
    let plain = BacklogCloud()
    _ = try await Self.pass(l, plain, concurrency: 1)
    #expect(first.calls == second.calls && first.calls.count == 12)
    #expect(first.calls != plain.calls)
    let other = BacklogCloud()
    _ = try await Self.pass(l, other, concurrency: 1, random: SeededRandom(seed: "other order"))
    #expect(other.calls != first.calls)
    let items = (0..<20).map(String.init)
    #expect(Set(BacklogSort.shuffled(items, random: SeededRandom(seed: "x"))) == Set(items))
    #expect(BacklogSort.shuffled(items, random: SeededRandom(seed: "x")) == BacklogSort.shuffled(items, random: SeededRandom(seed: "x")))
  }

  @Test("there is no cap per run: a pass asks its twelve names whatever was asked before")
  func noRunCap() async throws {
    var l = T.Ledger()
    _ = try l.ingest(Self.names(30))
    let cloud = BacklogCloud()
    let cache = MemoryCache()
    var memo = BacklogSort.Memo()
    var total = 0
    for _ in 0..<3 {
      let p = try await Self.pass(l, cloud, memo: memo, cache: cache)
      memo = p.memo
      total += p.calls
      #expect(p.stop == nil)
    }
    #expect(total == 30 && cloud.calls.count == 30)
  }

  @Test("a device asks at most 400 names in a rolling day, across runs")
  func dayCap() async throws {
    var l = T.Ledger()
    _ = try l.ingest([("PLACE ONE", "debit"), ("PLACE TWO", "debit"), ("PLACE THREE", "debit")])
    let cloud = BacklogCloud()
    let near = try await Self.pass(l, cloud, dayLeft: 2)
    #expect(near.calls == 2 && near.pending == 1 && near.stop == .dayCap)
    #expect(BacklogSort.next(after: near, importRunning: false, backoffs: 0, nowMs: now).next == .pause(.dayCap, untilMs: nil))
    let spent = try await Self.pass(l, cloud, memo: near.memo, dayLeft: 0)
    #expect(spent.calls == 0 && spent.stop == .dayCap)
    let hour: Int64 = 3_600_000
    let ledger = (0..<BacklogSort.dayNames).map { now - 20 * hour + Int64($0) }
    #expect(BacklogSort.dayLeft(ledger, nowMs: now) == 0)
    #expect(BacklogSort.dayReopensMs(ledger, nowMs: now) == now - 20 * hour + BacklogSort.dayWindowMs)
    #expect(BacklogSort.dayLeft(ledger, nowMs: now + 4 * hour + Int64(BacklogSort.dayNames)) == BacklogSort.dayNames)
    #expect(BacklogSort.dayLeft(Array(ledger.prefix(150)), nowMs: now) == 250)
    #expect(BacklogSort.dayReopensMs(Array(ledger.prefix(150)), nowMs: now) == nil)
  }

  @Test("a rate limit waits 1, 3 and 10 minutes, then pauses; a 503 pauses 15 minutes; a refusal ends the run")
  func caps() async throws {
    var l = T.Ledger()
    _ = try l.ingest([("PLACE ONE", "debit"), ("PLACE TWO", "debit"), ("PLACE THREE", "debit"), ("PLACE FOUR", "debit")])
    let limited = BacklogCloud(failAt: (2, .rateLimited))
    let p = try await Self.pass(l, limited, concurrency: 1)
    #expect(p.stop == .rateLimited && limited.calls.count == 2 && p.calls == 2 && p.memo.tries.isEmpty)
    var backoffs = 0
    var waits: [Int64] = []
    for _ in 0..<4 {
      let (next, b) = BacklogSort.next(after: p, importRunning: true, backoffs: backoffs, nowMs: now)
      backoffs = b
      if case .pass(let ms) = next {
        waits.append(ms)
      } else {
        #expect(next == .pause(.rateLimited, untilMs: now + 600_000) && b == 0)
      }
    }
    #expect(waits == [60_000, 180_000, 600_000])
    let wide = BacklogCloud(failAt: (2, .rateLimited), delay: .milliseconds(5))
    let w = try await Self.pass(l, wide)
    #expect(w.stop == .rateLimited && w.memo.tries.isEmpty && w.memo.asked.count <= 1 && w.pending >= 3)
    let busy = BacklogCloud(failAt: (1, .busy))
    let b = try await Self.pass(l, busy, concurrency: 1)
    #expect(b.stop == .busy && busy.calls.count == 1 && b.memo.tries.isEmpty)
    #expect(BacklogSort.next(after: b, importRunning: true, backoffs: 2, nowMs: now) == (.pause(.busy, untilMs: now + 15 * 60_000), 0))
    for (failure, stop) in [(ModelFailure.refused, BacklogSort.Stop.refused), (.notEnabled, .off)] {
      let cloud = BacklogCloud(failAt: (1, failure))
      let r = try await Self.pass(l, cloud, concurrency: 1)
      #expect(r.stop == stop && cloud.calls.count == 1)
      #expect(BacklogSort.next(after: r, importRunning: true, backoffs: 0, nowMs: now).next == .done(stop))
    }
  }

  @Test("a pass with no rate limit resets the backoff")
  func backoffReset() {
    let limited = BacklogSort.Pass(suggestions: [], memo: .init(), pending: 3, calls: 1, stop: .rateLimited)
    let good = BacklogSort.Pass(suggestions: [], memo: .init(), pending: 3, calls: 1, stop: nil)
    let idle = BacklogSort.Pass(suggestions: [], memo: .init(), pending: 0, calls: 1, stop: nil)
    let after = BacklogSort.next(after: limited, importRunning: true, backoffs: 2, nowMs: now)
    #expect(after == (.pass(afterMs: BacklogSort.backoffMs[2]), 3))
    #expect(BacklogSort.next(after: good, importRunning: true, backoffs: 3, nowMs: now) == (.pass(afterMs: BacklogSort.passSpacingMs), 0))
    #expect(BacklogSort.next(after: idle, importRunning: true, backoffs: 3, nowMs: now) == (.waitForRows, 0))
    #expect(BacklogSort.next(after: limited, importRunning: true, backoffs: 0, nowMs: now) == (.pass(afterMs: BacklogSort.backoffMs[0]), 1))
  }

  @Test("switched off: no request at all")
  func off() async throws {
    var l = T.Ledger()
    _ = try l.ingest([("PLACE ONE", "debit")])
    let cloud = BacklogCloud(fallback: (.category("dining"), true))
    cloud.setAvailable(false)
    let p = try await Self.pass(l, cloud)
    #expect(p.stop == .off && p.calls == 0 && p.suggestions.isEmpty && cloud.calls.isEmpty)
  }

  @Test("transfers, account alerts and manual rows never leave the device")
  func staysOnDevice() async throws {
    var l = T.Ledger()
    _ = try l.ingest([("EXAMPLE PERSON NAME", "debit")], template: "enbd.transfer.v1@2")
    _ = try l.ingest([("ACCOUNT TEXT", "debit")], template: "dib.account.v1@1")
    _ = try l.ingest([("MANUAL SHOP", "debit")], template: nil)
    _ = try l.ingest([("SHARED NAME", "debit")], template: "dib.card.v1@1")
    _ = try l.ingest([("SHARED NAME", "debit")], template: "enbd.transfer.v1@2")
    _ = try l.ingest([("CARD SHOP", "debit")], template: "enbd.alert.v1@1")
    let cloud = BacklogCloud(fallback: (.category("dining"), true))
    let p = try await Self.pass(l, cloud)
    #expect(cloud.calls == ["card shop"] && p.pending == 0)
  }

  @Test("with nothing left: wait while the import runs, done once it has finished")
  func idle() async throws {
    var l = T.Ledger()
    _ = try l.ingest([("CARREFOUR MOE", "debit")])
    let cloud = BacklogCloud()
    let p = try await Self.pass(l, cloud)
    #expect(p.calls == 0 && p.pending == 0 && cloud.calls.isEmpty)
    #expect(BacklogSort.next(after: p, importRunning: true, backoffs: 0, nowMs: now).next == .waitForRows)
    #expect(BacklogSort.next(after: p, importRunning: false, backoffs: 0, nowMs: now).next == .done(nil))
  }

  @Test("run re-reads before authoring, so an edit made during the requests wins")
  func run() async throws {
    var l = T.Ledger()
    let ids = try l.ingest([("SURE SHOP", "debit"), ("OTHER SURE SHOP", "debit")], needsReview: false)
    let cloud = BacklogCloud(fallback: (.category("groceries"), true))
    let read = l.rows()
    var u = OpAuthor(l.context())
    u.categorize(txnID: ids[1], parentVersion: l.state.txns[ids[1]]!.version, category: "shopping")
    try l.fold(try u.build())
    let snapshot = l
    let stamps = AuthorStamps()
    let r = try await BacklogSort.run(
      rows: read, categorizer: T.categorizer, allowed: T.allowed, cloud: cloud, memo: .init(), cache: MemoryCache(), now: { now },
      autoFile: true, stamps: stamps, reread: { (snapshot.rows(), snapshot.context()) })
    #expect(try Self.review(r.blobs) == [ids[0]: false])
    #expect(stamps.lastMs == r.blobs.last?.lastAuthoredMs)
    #expect(r.pass.calls == 2)
    #expect(r.filing == BacklogSort.Filing(filed: [ids[0]: snapshot.state.txns[ids[0]]!.version + 1]))
  }

  @Test("category answers are cached: a later run and the foreground sweep never ask the name again")
  func categoryCache() async throws {
    var l = T.Ledger()
    let first = try l.ingest([("SURE SHOP", "debit"), ("UNSURE SHOP", "debit")], needsReview: false)
    let cloud = BacklogCloud(["sure shop": (.category("groceries"), true), "unsure shop": (.category("dining"), false)])
    let cache = MemoryCache()
    let p = try await Self.pass(l, cloud, cache: cache)
    #expect(p.calls == 2)
    let taxonomy = ModelTier.taxonomyHash(T.allowed)
    #expect(try cache.answer(subject: "sure shop", taxonomyHash: taxonomy, modelTag: "cf-clef/1", now: now) == .category("groceries", autoFile: true))
    #expect(try cache.answer(subject: "unsure shop", taxonomyHash: taxonomy, modelTag: "cf-clef/1", now: now) == .category("dining", autoFile: false))
    let later = try l.ingest([("SURE SHOP", "debit"), ("UNSURE SHOP", "debit")], needsReview: false)
    let again = try await Self.pass(l, cloud, cache: cache)
    #expect(again.calls == 0 && cloud.calls.count == 2 && again.pending == 0)
    let byID = Dictionary(uniqueKeysWithValues: again.suggestions.map { ($0.txnID, $0) })
    #expect(byID[later[0]]?.category == "groceries" && byID[later[0]]?.needsReview == false)
    #expect(byID[later[1]]?.category == "dining" && byID[later[1]]?.needsReview == true)
    #expect(byID[first[0]] != nil)
    let device = SweepModel("apple-fm/26.1", fallback: .category("shopping"))
    let sweepCloud = SweepModel("cf-clef/1", fallback: .category("shopping"))
    let swept = try await ModelSuggestionSweep.suggest(
      rows: l.rows(), categorizer: T.categorizer, allowed: T.allowed, stages: [.cloud(sweepCloud), .onDevice(device)], context: .foreground,
      cache: cache, now: { now }, autoFile: false)
    #expect(sweepCloud.calls.isEmpty && device.calls.isEmpty)
    #expect(Set(swept.filter { $0.category == "groceries" }.map(\.txnID)) == [first[0], later[0]])
    #expect(swept.allSatisfy { $0.modelTag == "cf-clef/1" && $0.needsReview })
  }

  @Test("the sweep records its cloud answers, and a cached unknown still falls through to the next stage")
  func sweepRecords() async throws {
    var l = T.Ledger()
    _ = try l.ingest([("FRESH SHOP", "debit"), ("MYSTERY PLACE 77", "debit")])
    let cache = MemoryCache()
    let taxonomy = ModelTier.taxonomyHash(T.allowed)
    try cache.recordUnknown([(subject: "mystery place 77", modelTag: "cf-clef/1")], taxonomyHash: taxonomy, now: now)
    let device = SweepModel("apple-fm/26.1", fallback: .category("shopping"))
    let cloud = SweepModel("cf-clef/1", answers: ["fresh shop": .category("dining")])
    let swept = try await ModelSuggestionSweep.suggest(
      rows: l.rows(), categorizer: T.categorizer, allowed: T.allowed, stages: [.cloud(cloud), .onDevice(device)], context: .foreground,
      cache: cache, now: { now })
    #expect(cloud.calls == ["fresh shop"] && device.calls == ["mystery place 77"])
    #expect(Set(swept.map(\.category)) == ["dining", "shopping"])
    #expect(try cache.answer(subject: "fresh shop", taxonomyHash: taxonomy, modelTag: "cf-clef/1", now: now) == .category("dining", autoFile: false))
    #expect(try cache.answer(subject: "mystery place 77", taxonomyHash: taxonomy, modelTag: "apple-fm/26.1", now: now) == .category("shopping", autoFile: false))
  }

  @Test("the plan counts the waiting names and the payments that wait for them")
  func counts() async throws {
    var l = T.Ledger()
    let waiting = try l.ingest([("SHOP ONE", "debit"), ("SHOP ONE", "debit"), ("SHOP TWO", "debit")])
    let held = try l.ingest([("EXAMPLE PERSON NAME", "debit")], template: "enbd.transfer.v1@2")
    let shared = try l.ingest([("SHARED NAME", "debit")], template: "dib.card.v1@1")
    _ = try l.ingest([("SHARED NAME", "debit")], template: "dib.account.v1@1")
    _ = try l.ingest([("CARREFOUR MOE", "debit"), ("SHOP ONE", "credit"), ("12345", "debit")])
    let unknown = try l.ingest([("MYSTERY PLACE 77", "debit")])
    let cache = MemoryCache()
    try cache.recordUnknown([(subject: "mystery place 77", modelTag: "cf-clef/1")], taxonomyHash: ModelTier.taxonomyHash(T.allowed), now: now)
    let c = try BacklogSort.counts(
      rows: l.rows(), categorizer: T.categorizer, allowed: T.allowed, modelTag: "cf-clef/1", cache: cache, now: now)
    #expect(c.waitingNames == 2 && c.pendingTxnIDs == Set(waiting))
    var memo = BacklogSort.Memo()
    memo.asked = ["shop one"]
    let asked = try BacklogSort.counts(
      rows: l.rows(), categorizer: T.categorizer, allowed: T.allowed, modelTag: "cf-clef/1", cache: cache, now: now, memo: memo)
    #expect(asked.waitingNames == 1 && asked.pendingTxnIDs == [waiting[2]])
    #expect(!c.pendingTxnIDs.contains(held[0]) && !c.pendingTxnIDs.contains(shared[0]) && !c.pendingTxnIDs.contains(unknown[0]))
  }

  static func filed(_ l: inout T.Ledger, _ merchants: [String], tag: String = "cf-clef/1") throws -> [String] {
    let ids = try l.ingest(merchants.map { ($0, "debit") }, needsReview: false)
    let suggestions = ids.map { id in
      ModelSuggestionSweep.Suggestion(txnID: id, version: l.state.txns[id]!.version, category: "dining", modelTag: tag, autoFile: true)
    }
    for b in try ModelSuggestionSweep.author(suggestions, current: l.rows(), context: l.context()) { try l.fold(b) }
    return ids
  }

  @Test("sending back takes the rows filed here that are unchanged, as suggestions, and nothing else")
  func sendBack() async throws {
    var l = T.Ledger()
    let ids = try Self.filed(&l, ["SHOP ONE", "SHOP TWO", "SHOP THREE"])
    let outside = try Self.filed(&l, ["SHOP FOUR"])
    let apple = try Self.filed(&l, ["SHOP FIVE"], tag: "apple-fm/26.1")
    let suggested = try l.ingest([("SHOP SIX", "debit")])
    for b in try ModelSuggestionSweep.author(
      [.init(txnID: suggested[0], version: l.state.txns[suggested[0]]!.version, category: "dining", modelTag: "cf-clef/1")],
      current: l.rows(), context: l.context())
    { try l.fold(b) }
    var filed: [String: Int64] = [:]
    for id in ids + apple + suggested { filed[id] = l.state.txns[id]!.version }
    #expect(ids.allSatisfy { !l.state.txns[$0]!.needsReview && l.state.txns[$0]!.categorySource?.model == "cf-clef/1" })
    var u = OpAuthor(l.context())
    u.categorize(txnID: ids[1], parentVersion: l.state.txns[ids[1]]!.version, category: "shopping")
    try l.fold(try u.build())
    let snapshot = l
    let stamps = AuthorStamps()
    let r = try await BacklogSort.sendBack(filed: filed, stamps: stamps, reread: { (snapshot.rows(), snapshot.context()) })
    #expect(r.rows == 2 && stamps.lastMs == r.blobs.last?.lastAuthoredMs)
    #expect(try Self.review(r.blobs) == [ids[0]: true, ids[2]: true])
    for b in r.blobs { try l.fold(b) }
    for id in [ids[0], ids[2]] {
      let t = l.state.txns[id]!
      #expect(t.needsReview && t.category == "dining" && t.categorySource?.kind == .model && t.categorySource?.model == "cf-clef/1")
    }
    #expect(l.state.txns[ids[1]]?.category == "shopping" && l.state.txns[ids[1]]?.categorySource?.kind == .user)
    #expect(!l.state.txns[outside[0]]!.needsReview)
    let none = try await BacklogSort.sendBack(filed: filed, stamps: stamps, reread: { [l] in (l.rows(), l.context()) })
    #expect(none.rows == 0 && none.blobs.isEmpty)
    #expect(ModelSuggestionSweep.queue(rows: l.rows(), categorizer: T.categorizer).isEmpty)
  }
}
