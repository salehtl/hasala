import CoreCategorize
import CoreReplay
import Foundation
import Synchronization
import Testing

@testable import CoreDomain

final class FirstImportCloud: GradedCategoryModel, Sendable {
  let modelTag = "cf-clef/1"
  let answers: [String: (answer: ModelAnswer, autoFile: Bool)]
  let fallback: (answer: ModelAnswer, autoFile: Bool)
  let failAt: (call: Int, failure: ModelFailure)?
  let state = Mutex<(calls: [String], available: Bool)>(([], true))

  init(
    _ answers: [String: (answer: ModelAnswer, autoFile: Bool)] = [:], fallback: (answer: ModelAnswer, autoFile: Bool) = (.unknown, false),
    failAt: (call: Int, failure: ModelFailure)? = nil
  ) {
    self.answers = answers
    self.fallback = fallback
    self.failAt = failAt
  }

  var calls: [String] { state.withLock { $0.calls } }
  func setAvailable(_ on: Bool) { state.withLock { $0.available = on } }

  func availability() -> ModelAvailability { state.withLock { $0.available } ? .available : .notEnabled }
  func suggest(subject: String, allowed: [AllowedCategory]) async -> ModelAnswer { .unknown }
  func suggestGraded(subject: String, allowed: [AllowedCategory]) async -> (answer: ModelAnswer, autoFile: Bool) {
    let n = state.withLock { s in
      s.calls.append(subject)
      return s.calls.count
    }
    if let failAt, n >= failAt.call { return (.failed(failAt.failure), false) }
    return answers[subject] ?? fallback
  }
}

@Suite("FirstImportSort")
struct FirstImportSortTests {
  typealias T = ModelSuggestionSweepTests

  static func pass(
    _ l: T.Ledger, _ cloud: FirstImportCloud, memo: FirstImportSort.Memo = .init(), cache: any ModelAnswerCache = MemoryCache(),
    autoFile: Bool = true
  ) async throws -> FirstImportSort.Pass {
    try await FirstImportSort.pass(
      rows: l.rows(), categorizer: T.categorizer, allowed: T.allowed, cloud: cloud, memo: memo, cache: cache, now: { now },
      autoFile: autoFile)
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
    let cloud = FirstImportCloud([
      "sure shop": (.category("groceries"), true), "unsure shop": (.category("dining"), false),
    ])
    let cache = MemoryCache()
    let p = try await Self.pass(l, cloud, cache: cache)
    #expect(cloud.calls.sorted() == ["mystery place 77", "sure shop", "unsure shop"])
    #expect(p.calls == 3 && p.memo.requests == 3 && p.pending == 0 && p.stop == nil)
    #expect(Set(p.suggestions.map(\.txnID)) == [ids[0], ids[1], ids[2], ids[5]])
    #expect(p.suggestions.filter { !$0.needsReview }.map(\.txnID).sorted() == [ids[0], ids[1]].sorted())
    #expect(try cache.isCached(subject: "mystery place 77", taxonomyHash: ModelTier.taxonomyHash(T.allowed), modelTag: "cf-clef/1", now: now))
  }

  @Test("rows that load later reuse the answer without a second request; answered and cached names are not sent again")
  func memo() async throws {
    var l = T.Ledger()
    _ = try l.ingest([("SURE SHOP", "debit"), ("MYSTERY PLACE 77", "debit"), ("SLOW SHOP", "debit")])
    let cloud = FirstImportCloud(["sure shop": (.category("groceries"), true), "slow shop": (.failed(.timeout), false)])
    let cache = MemoryCache()
    let first = try await Self.pass(l, cloud, cache: cache)
    #expect(first.calls == 3 && first.pending == 1)
    let later = try l.ingest([("SURE SHOP", "debit"), ("SLOW SHOP", "debit"), ("MYSTERY PLACE 77", "debit")])
    let second = try await Self.pass(l, cloud, memo: first.memo, cache: cache)
    #expect(second.calls == 1 && cloud.calls.count == 4 && cloud.calls.last == "slow shop")
    #expect(second.suggestions.contains { $0.txnID == later[0] && $0.category == "groceries" })
    #expect(!second.suggestions.contains { $0.txnID == later[1] || $0.txnID == later[2] })
  }

  @Test("a name that timed out is asked again on later passes, at most three times; a 429 is not a try")
  func retries() async throws {
    var l = T.Ledger()
    _ = try l.ingest([("SLOW SHOP", "debit")])
    let cloud = FirstImportCloud(["slow shop": (.failed(.timeout), false)])
    var memo = FirstImportSort.Memo()
    for n in 1...FirstImportSort.maxTries {
      let p = try await Self.pass(l, cloud, memo: memo)
      memo = p.memo
      #expect(p.calls == 1 && memo.tries["slow shop"] == n)
      #expect(p.pending == (n < FirstImportSort.maxTries ? 1 : 0))
    }
    let after = try await Self.pass(l, cloud, memo: memo)
    #expect(after.calls == 0 && after.pending == 0 && cloud.calls.count == FirstImportSort.maxTries)
    let limited = FirstImportCloud(failAt: (1, .rateLimited))
    let r = try await Self.pass(l, limited)
    #expect(r.stop == .rateLimited && r.memo.requests == 1 && r.memo.tries.isEmpty && r.memo.asked.isEmpty && r.pending == 1)
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
    _ = try l.ingest((0..<12).map { ("PLACE NUMBER \(Character(UnicodeScalar(65 + $0)!))", "debit") })
    let cloud = OverflowsOnce()
    let p = try await FirstImportSort.pass(
      rows: l.rows(), categorizer: T.categorizer, allowed: T.allowed, cloud: cloud, memo: .init(), cache: MemoryCache(), now: { now },
      autoFile: true)
    let budget = ModelTier.Context.firstImport.budget.calls
    #expect(cloud.calls.withLock { $0 } == budget)
    #expect(p.calls == budget && p.memo.requests == budget && p.memo.asked.count == budget - 1 && p.pending == 3)
  }

  @Test("a failure after the requests keeps the memo, so they are counted and the names are not asked again")
  func interrupted() async throws {
    struct Boom: Error {}
    final class FailingCache: ModelAnswerCache, Sendable {
      func isCached(subject: String, taxonomyHash: String, modelTag: String, now: Int64) throws -> Bool { false }
      func recordUnknown(_ entries: [(subject: String, modelTag: String)], taxonomyHash: String, now: Int64) throws { throw Boom() }
    }
    var l = T.Ledger()
    _ = try l.ingest([("SURE SHOP", "debit"), ("MYSTERY PLACE 77", "debit")])
    let cloud = FirstImportCloud(["sure shop": (.category("groceries"), true)])
    let rows = l.rows()
    do {
      _ = try await FirstImportSort.run(
        rows: rows, categorizer: T.categorizer, allowed: T.allowed, cloud: cloud, memo: .init(requests: 5), cache: MemoryCache(),
        now: { now }, autoFile: true, stamps: AuthorStamps(), reread: { throw Boom() })
      Issue.record("the reread failed, so the run must throw")
    } catch let e as FirstImportSort.Interrupted {
      #expect(e.memo.requests == 7 && e.memo.answers["sure shop"]?.category == "groceries")
      #expect(e.memo.asked == ["sure shop", "mystery place 77"])
    }
    do {
      _ = try await Self.pass(l, cloud, cache: FailingCache())
      Issue.record("the cache failed, so the pass must throw")
    } catch let e as FirstImportSort.Interrupted {
      #expect(e.memo.requests == 2 && e.memo.asked.count == 2)
    }
    #expect(FirstImportSort.Pass.failed(.init(requests: 3)).failed)
  }

  @Test("an answer kept from an earlier pass never files a row whose name may not leave the device")
  func blockedLater() async throws {
    var l = T.Ledger()
    let card = try l.ingest([("SHARED NAME", "debit")], template: "dib.card.v1@1")
    let cloud = FirstImportCloud(fallback: (.category("dining"), true))
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
    let ids = try l.ingest([("SURE SHOP", "debit"), ("OTHER SURE SHOP", "debit"), ("MYSTERY PLACE 77", "debit")])
    let cloud = FirstImportCloud(["sure shop": (.category("groceries"), true), "other sure shop": (.category("dining"), true)])
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
    let again = try await Self.pass(l, cloud, memo: FirstImportSort.Memo(requests: p.memo.requests), cache: cache)
    #expect(again.calls == 0 && again.suggestions.isEmpty && again.pending == 0)
    #expect(cloud.calls.count == 3)
  }

  @Test("a row files only with Sort automatically on and a confident graded answer")
  func threshold() async throws {
    var l = T.Ledger()
    let ids = try l.ingest([("SURE SHOP", "debit"), ("UNSURE SHOP", "debit")])
    let cloud = FirstImportCloud(["sure shop": (.category("groceries"), true), "unsure shop": (.category("dining"), false)])
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

  @Test("a pass asks at most ten names; the rest wait for the next pass")
  func perPass() async throws {
    var l = T.Ledger()
    _ = try l.ingest((0..<25).map { ("PLACE NUMBER \(Character(UnicodeScalar(65 + $0)!))", "debit") })
    let cloud = FirstImportCloud()
    let p = try await Self.pass(l, cloud)
    #expect(p.calls == 10 && p.pending == 15)
    #expect(FirstImportSort.next(after: p, importRunning: false, backoffs: 0).next == .pass(afterMs: FirstImportSort.passSpacingMs))
    let q = try await Self.pass(l, cloud, memo: p.memo)
    #expect(q.calls == 10 && q.pending == 5 && Set(cloud.calls).count == 20)
  }

  @Test("the device's request budget stops the sort; the rest stay in review")
  func budget() async throws {
    var l = T.Ledger()
    _ = try l.ingest([("PLACE ONE", "debit"), ("PLACE TWO", "debit"), ("PLACE THREE", "debit")])
    let cloud = FirstImportCloud()
    let near = try await Self.pass(l, cloud, memo: FirstImportSort.Memo(requests: FirstImportSort.maxRequests - 2))
    #expect(near.calls == 2 && near.pending == 1 && near.memo.requests == FirstImportSort.maxRequests && near.stop == nil)
    let spent = try await Self.pass(l, cloud, memo: near.memo)
    #expect(spent.calls == 0 && spent.stop == .budgetSpent && cloud.calls.count == 2)
    #expect(FirstImportSort.next(after: spent, importRunning: true, backoffs: 0).next == .done(.budgetSpent))
  }

  @Test("a rate limit backs off three times, then stops; a spend cap or refusal stops at once")
  func caps() async throws {
    var l = T.Ledger()
    _ = try l.ingest([("PLACE ONE", "debit"), ("PLACE TWO", "debit"), ("PLACE THREE", "debit"), ("PLACE FOUR", "debit")])
    let limited = FirstImportCloud(failAt: (2, .rateLimited))
    let p = try await Self.pass(l, limited)
    #expect(p.stop == .rateLimited && limited.calls.count == 2 && p.memo.requests == 2)
    var backoffs = 0
    var waits: [Int64] = []
    for _ in 0..<4 {
      let (next, b) = FirstImportSort.next(after: p, importRunning: true, backoffs: backoffs)
      backoffs = b
      if case .pass(let ms) = next { waits.append(ms) } else { #expect(next == .done(.rateLimited)) }
    }
    #expect(waits == FirstImportSort.backoffMs)
    for (failure, stop) in [(ModelFailure.busy, FirstImportSort.Stop.capped), (.refused, .refused), (.notEnabled, .off)] {
      let cloud = FirstImportCloud(failAt: (1, failure))
      let r = try await Self.pass(l, cloud)
      #expect(r.stop == stop && cloud.calls.count == 1)
      #expect(FirstImportSort.next(after: r, importRunning: true, backoffs: 0).next == .done(stop))
    }
  }

  @Test("a pass with no rate limit resets the backoff")
  func backoffReset() {
    let limited = FirstImportSort.Pass(suggestions: [], memo: .init(), pending: 3, calls: 1, stop: .rateLimited)
    let good = FirstImportSort.Pass(suggestions: [], memo: .init(), pending: 3, calls: 1, stop: nil)
    let idle = FirstImportSort.Pass(suggestions: [], memo: .init(), pending: 0, calls: 1, stop: nil)
    let after = FirstImportSort.next(after: limited, importRunning: true, backoffs: 2)
    #expect(after == (.pass(afterMs: FirstImportSort.backoffMs[2]), 3))
    #expect(FirstImportSort.next(after: good, importRunning: true, backoffs: 3) == (.pass(afterMs: FirstImportSort.passSpacingMs), 0))
    #expect(FirstImportSort.next(after: idle, importRunning: true, backoffs: 3) == (.waitForRows, 0))
    #expect(FirstImportSort.next(after: limited, importRunning: true, backoffs: 0) == (.pass(afterMs: FirstImportSort.backoffMs[0]), 1))
  }

  @Test("switched off: no request at all")
  func off() async throws {
    var l = T.Ledger()
    _ = try l.ingest([("PLACE ONE", "debit")])
    let cloud = FirstImportCloud(fallback: (.category("dining"), true))
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
    let cloud = FirstImportCloud(fallback: (.category("dining"), true))
    let p = try await Self.pass(l, cloud)
    #expect(cloud.calls == ["card shop"] && p.pending == 0)
  }

  @Test("with nothing left: wait while the import runs, done once it has finished")
  func idle() async throws {
    var l = T.Ledger()
    _ = try l.ingest([("CARREFOUR MOE", "debit")])
    let cloud = FirstImportCloud()
    let p = try await Self.pass(l, cloud)
    #expect(p.calls == 0 && p.pending == 0 && cloud.calls.isEmpty)
    #expect(FirstImportSort.next(after: p, importRunning: true, backoffs: 0).next == .waitForRows)
    #expect(FirstImportSort.next(after: p, importRunning: false, backoffs: 0).next == .done(nil))
  }

  @Test("the sort ends three days after it started, or when the clock went back")
  func lifetime() {
    #expect(!FirstImportSort.expired(startedMs: now, nowMs: now + FirstImportSort.lifetimeMs - 1))
    #expect(FirstImportSort.expired(startedMs: now, nowMs: now + FirstImportSort.lifetimeMs))
    #expect(FirstImportSort.expired(startedMs: now, nowMs: now - 1))
  }

  @Test("run re-reads before authoring, so an edit made during the requests wins")
  func run() async throws {
    var l = T.Ledger()
    let ids = try l.ingest([("SURE SHOP", "debit"), ("OTHER SURE SHOP", "debit")])
    let cloud = FirstImportCloud(fallback: (.category("groceries"), true))
    let read = l.rows()
    var u = OpAuthor(l.context())
    u.categorize(txnID: ids[1], parentVersion: l.state.txns[ids[1]]!.version, category: "shopping")
    try l.fold(try u.build())
    let snapshot = l
    let stamps = AuthorStamps()
    let r = try await FirstImportSort.run(
      rows: read, categorizer: T.categorizer, allowed: T.allowed, cloud: cloud, memo: .init(), cache: MemoryCache(), now: { now },
      autoFile: true, stamps: stamps, reread: { (snapshot.rows(), snapshot.context()) })
    #expect(try Self.review(r.blobs) == [ids[0]: false])
    #expect(stamps.lastMs == r.blobs.last?.lastAuthoredMs)
    #expect(r.pass.calls == 2)
  }
}
