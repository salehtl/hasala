import CoreCategorize
import CoreReplay
import CoreTestSupport
import Foundation
import Synchronization
import Testing

@testable import CoreDomain

final class RecordingModel: CategoryModel, Sendable {
  let modelTag: String
  let reply: ModelAnswer
  let seen = Mutex<[(subject: String, allowed: [String])]>([])

  init(_ tag: String, reply: ModelAnswer) {
    modelTag = tag
    self.reply = reply
  }

  func availability() -> ModelAvailability { .available }

  func suggest(subject: String, allowed: [AllowedCategory]) async -> ModelAnswer {
    seen.withLock { $0.append((subject, allowed.map(\.id))) }
    return reply
  }

  var calls: [(subject: String, allowed: [String])] { seen.withLock { $0 } }
}

@Suite("Not this in the model sweep and the bulk sort")
struct RejectionSweepTests {
  typealias T = ModelSuggestionSweepTests

  static func rejecting(_ rows: [SweepRow], _ categories: Set<String>) -> [SweepRow] {
    rows.map { r in
      SweepRow(
        id: r.id, merchantRaw: r.merchantRaw, direction: r.direction, category: r.category, sourceKind: r.sourceKind,
        sourceRef: r.sourceRef, needsReview: r.needsReview, candidate: r.candidate, version: r.version, template: r.template,
        merchantGroup: r.merchantGroup, categorizedMs: r.categorizedMs, rejected: categories)
    }
  }

  @Test("a rejected cloud answer reads as unknown, so Apple's model is asked next")
  func nextStage() async throws {
    var l = T.Ledger()
    let ids = try l.ingest([("CAFE EXAMPLE JBR", "debit")])
    let cloud = RecordingModel("cf-clef/1", reply: .category("shopping"))
    let device = RecordingModel("apple-fm/26.1", reply: .category("dining"))
    let cache = MemoryCache()
    let s = try await ModelSuggestionSweep.suggest(
      rows: Self.rejecting(l.rows(), ["shopping"]), categorizer: T.categorizer, allowed: T.allowed,
      stages: [.cloud(cloud), .onDevice(device)], context: .foreground, cache: cache, now: { now })
    #expect(s.map(\.txnID) == ids && s.map(\.category) == ["dining"] && s.map(\.modelTag) == ["apple-fm/26.1"])
    #expect(cloud.calls.count == 1 && device.calls.count == 1)
    let hash = ModelTier.taxonomyHash(T.allowed)
    #expect(try cache.answer(subject: "cafe example jbr", taxonomyHash: hash, modelTag: "cf-clef/1", now: now) == .category("shopping", autoFile: false))
  }

  @Test("a cached cloud answer that was rejected is never sent to Cloudflare again")
  func cachedRejection() async throws {
    var l = T.Ledger()
    _ = try l.ingest([("CAFE EXAMPLE JBR", "debit"), ("CAFE EXAMPLE JBR", "debit")])
    let cache = MemoryCache()
    let hash = ModelTier.taxonomyHash(T.allowed)
    try cache.recordAnswers(
      [ModelTier.StagedSuggestion(subject: "cafe example jbr", category: "shopping", modelTag: "cf-clef/1", autoFile: true)],
      taxonomyHash: hash, now: now)
    let cloud = RecordingModel("cf-clef/1", reply: .category("shopping"))
    let device = RecordingModel("apple-fm/26.1", reply: .unknown)
    for _ in 0..<2 {
      let s = try await ModelSuggestionSweep.suggest(
        rows: Self.rejecting(l.rows(), ["shopping"]), categorizer: T.categorizer, allowed: T.allowed,
        stages: [.cloud(cloud), .onDevice(device)], context: .foreground, cache: cache, now: { now })
      #expect(s.isEmpty)
    }
    #expect(cloud.calls.isEmpty)
    #expect(device.calls.count == 1)
    let accepted = try await ModelSuggestionSweep.suggest(
      rows: l.rows(), categorizer: T.categorizer, allowed: T.allowed, stages: [.cloud(cloud), .onDevice(device)],
      context: .foreground, cache: cache, now: { now })
    #expect(accepted.count == 2 && accepted.allSatisfy { $0.category == "shopping" && $0.autoFile })
  }

  @Test("a rejected cloud answer outlives the cache's 30 days, so the name never goes to Cloudflare again")
  func keptPastExpiry() async throws {
    var l = T.Ledger()
    _ = try l.ingest([("CAFE EXAMPLE JBR", "debit"), ("SECOND SHOP DXB", "debit")])
    let hash = ModelTier.taxonomyHash(T.allowed)
    let later = now + 61 * 86_400_000
    let cache = MemoryCache()
    try cache.recordAnswers(
      [ModelTier.StagedSuggestion(subject: "cafe example jbr", category: "shopping", modelTag: "cf-clef/1", autoFile: true)],
      taxonomyHash: hash, now: now)
    let rows = Self.rejecting(l.rows(), ["shopping", "dining"])
    let cloud = RecordingModel("cf-clef/1", reply: .category("dining"))
    let device = RecordingModel("apple-fm/26.1", reply: .unknown)
    let first = try await ModelSuggestionSweep.suggest(
      rows: rows, categorizer: T.categorizer, allowed: T.allowed, stages: [.cloud(cloud), .onDevice(device)], context: .foreground,
      cache: cache, now: { now })
    #expect(first.isEmpty && cloud.calls.map(\.subject) == ["second shop dxb"])
    let again = try await ModelSuggestionSweep.suggest(
      rows: rows, categorizer: T.categorizer, allowed: T.allowed, stages: [.cloud(cloud), .onDevice(device)], context: .foreground,
      cache: cache, now: { later })
    #expect(again.isEmpty && cloud.calls.count == 1)
    #expect(try cache.answer(subject: "cafe example jbr", taxonomyHash: hash, modelTag: "cf-clef/1", now: later) == nil)
    #expect(try cache.keptAnswer(subject: "cafe example jbr", modelTag: "cf-clef/1") == "shopping")
    #expect(try cache.keptAnswer(subject: "second shop dxb", modelTag: "cf-clef/1") == "dining")

    let backlogCache = MemoryCache()
    try backlogCache.recordAnswers(
      [ModelTier.StagedSuggestion(subject: "cafe example jbr", category: "shopping", modelTag: "cf-clef/1", autoFile: true)],
      taxonomyHash: hash, now: now)
    let backlog = BacklogCloud(["second shop dxb": (.category("dining"), true)])
    let p = try await BacklogSort.pass(
      rows: rows, categorizer: T.categorizer, allowed: T.allowed, cloud: backlog, memo: .init(), cache: backlogCache, now: { now },
      autoFile: true)
    #expect(p.suggestions.isEmpty && backlog.calls == ["second shop dxb"])
    let counts = try BacklogSort.counts(
      rows: rows, categorizer: T.categorizer, allowed: T.allowed, modelTag: "cf-clef/1", cache: backlogCache, now: later)
    #expect(counts.waitingNames == 0)
    let next = try await BacklogSort.pass(
      rows: rows, categorizer: T.categorizer, allowed: T.allowed, cloud: backlog, memo: .init(), cache: backlogCache, now: { later },
      autoFile: true)
    #expect(next.suggestions.isEmpty && next.calls == 0 && backlog.calls == ["second shop dxb"])
  }

  static let customWant = ModelTier.allowed(
    TaxonomyV1.builtins + [
      CategoryInfo(
        id: "c_tea_rooms", name: "Tea rooms", kind: .spending, bucket: .want, icon: "cup", active: true, builtin: false, sortKey: 100,
        parent: "dining")
    ])

  @Test("a kept rejection outlives a change of the category list, so no new taxonomy sends the name again")
  func keptPastTaxonomy() async throws {
    var l = T.Ledger()
    _ = try l.ingest([("CAFE EXAMPLE JBR", "debit")])
    let cache = MemoryCache()
    try cache.recordAnswers(
      [ModelTier.StagedSuggestion(subject: "cafe example jbr", category: "shopping", modelTag: "cf-clef/1", autoFile: true)],
      taxonomyHash: ModelTier.taxonomyHash(T.allowed), now: now)
    let rows = Self.rejecting(l.rows(), ["shopping"])
    let cloud = RecordingModel("cf-clef/1", reply: .category("shopping"))
    let device = RecordingModel("apple-fm/26.1", reply: .unknown)
    let first = try await ModelSuggestionSweep.suggest(
      rows: rows, categorizer: T.categorizer, allowed: T.allowed, stages: [.cloud(cloud), .onDevice(device)], context: .foreground,
      cache: cache, now: { now })
    #expect(first.isEmpty && cloud.calls.isEmpty)
    #expect(ModelTier.taxonomyHash(Self.customWant) != ModelTier.taxonomyHash(T.allowed))
    let again = try await ModelSuggestionSweep.suggest(
      rows: rows, categorizer: T.categorizer, allowed: Self.customWant, stages: [.cloud(cloud), .onDevice(device)],
      context: .foreground, cache: cache, now: { now })
    #expect(again.isEmpty && cloud.calls.isEmpty && device.calls.count == 2)
    let backlog = BacklogCloud(fallback: (.category("shopping"), true))
    let p = try await BacklogSort.pass(
      rows: rows, categorizer: T.categorizer, allowed: Self.customWant, cloud: backlog, memo: .init(), cache: cache, now: { now },
      autoFile: true)
    #expect(p.suggestions.isEmpty && p.pending == 0 && backlog.calls.isEmpty)
    let counts = try BacklogSort.counts(
      rows: rows, categorizer: T.categorizer, allowed: Self.customWant, modelTag: "cf-clef/1", cache: cache, now: now)
    #expect(counts.waitingNames == 0)
  }

  @Test("a rejection kept at Not this holds after the 30-day entry is purged before the next sweep")
  func keptBeforeFirstSweep() async throws {
    var l = T.Ledger()
    _ = try l.ingest([("CAFE EXAMPLE JBR", "debit")])
    let cache = MemoryCache()
    let hash = ModelTier.taxonomyHash(T.allowed)
    let answer = ModelTier.StagedSuggestion(subject: "cafe example jbr", category: "shopping", modelTag: "cf-clef/1", autoFile: true)
    try cache.recordAnswers([answer], taxonomyHash: hash, now: now)
    try cache.keepAnswers([answer])
    let later = now + 31 * 86_400_000
    cache.purgeExpired(now: later)
    #expect(try cache.answer(subject: "cafe example jbr", taxonomyHash: hash, modelTag: "cf-clef/1", now: later) == nil)
    let rows = Self.rejecting(l.rows(), ["shopping"])
    let cloud = RecordingModel("cf-clef/1", reply: .category("shopping"))
    let device = RecordingModel("apple-fm/26.1", reply: .category("dining"))
    let s = try await ModelSuggestionSweep.suggest(
      rows: rows, categorizer: T.categorizer, allowed: T.allowed, stages: [.cloud(cloud), .onDevice(device)], context: .foreground,
      cache: cache, now: { later })
    #expect(cloud.calls.isEmpty && s.map(\.category) == ["dining"] && s.map(\.modelTag) == ["apple-fm/26.1"])
    let backlog = BacklogCloud(fallback: (.category("shopping"), true))
    let p = try await BacklogSort.pass(
      rows: rows, categorizer: T.categorizer, allowed: T.allowed, cloud: backlog, memo: .init(), cache: cache, now: { later },
      autoFile: true)
    #expect(p.suggestions.isEmpty && backlog.calls.isEmpty)
  }

  @Test("a kept answer whose rejection was undone is dropped, so the name is asked again and refreshed")
  func keptAfterUndo() async throws {
    var l = T.Ledger()
    _ = try l.ingest([("CAFE EXAMPLE JBR", "debit"), ("SECOND SHOP DXB", "debit")])
    let cache = MemoryCache()
    try cache.keepAnswers([
      ModelTier.StagedSuggestion(subject: "cafe example jbr", category: "shopping", modelTag: "cf-clef/1"),
      ModelTier.StagedSuggestion(subject: "second shop dxb", category: "shopping", modelTag: "cf-clef/1"),
    ])
    let cloud = RecordingModel("cf-clef/1", reply: .category("dining"))
    let s = try await ModelSuggestionSweep.suggest(
      rows: l.rows(), categorizer: T.categorizer, allowed: T.allowed, stages: [.cloud(cloud)], context: .foreground, cache: cache,
      now: { now })
    #expect(Set(cloud.calls.map(\.subject)) == ["cafe example jbr", "second shop dxb"] && s.allSatisfy { $0.category == "dining" })
    #expect(try cache.keptAnswer(subject: "cafe example jbr", modelTag: "cf-clef/1") == nil)

    let fresh = MemoryCache()
    try fresh.keepAnswers([ModelTier.StagedSuggestion(subject: "cafe example jbr", category: "shopping", modelTag: "cf-clef/1")])
    let backlog = BacklogCloud(fallback: (.category("dining"), false))
    let counts = try BacklogSort.counts(
      rows: l.rows(), categorizer: T.categorizer, allowed: T.allowed, modelTag: "cf-clef/1", cache: fresh, now: now)
    #expect(counts.waitingNames == 2)
    let p = try await BacklogSort.pass(
      rows: l.rows(), categorizer: T.categorizer, allowed: T.allowed, cloud: backlog, memo: .init(), cache: fresh, now: { now },
      autoFile: false)
    #expect(Set(backlog.calls) == ["cafe example jbr", "second shop dxb"] && p.suggestions.count == 2)
    #expect(try fresh.keptAnswer(subject: "cafe example jbr", modelTag: "cf-clef/1") == nil)
  }

  @Test("the request and the cache key are the same with and without rejections")
  func sameRequest() async throws {
    var l = T.Ledger()
    _ = try l.ingest([("CAFE EXAMPLE JBR", "debit")])
    let plain = RecordingModel("cf-clef/1", reply: .category("dining"))
    let refusing = RecordingModel("cf-clef/1", reply: .category("dining"))
    let plainCache = MemoryCache()
    let refusingCache = MemoryCache()
    _ = try await ModelSuggestionSweep.suggest(
      rows: l.rows(), categorizer: T.categorizer, allowed: T.allowed, stages: [.cloud(plain)], context: .foreground,
      cache: plainCache, now: { now })
    _ = try await ModelSuggestionSweep.suggest(
      rows: Self.rejecting(l.rows(), ["dining", "shopping"]), categorizer: T.categorizer, allowed: T.allowed,
      stages: [.cloud(refusing)], context: .foreground, cache: refusingCache, now: { now })
    #expect(plain.calls.map(\.subject) == refusing.calls.map(\.subject))
    #expect(plain.calls.map(\.allowed) == refusing.calls.map(\.allowed))
    #expect(plain.calls.first?.allowed == T.allowed.map(\.id))
    #expect(ModelTier.prompt(subject: "cafe example jbr") == "Merchant: cafe example jbr")
    #expect(plainCache.rows.withLock { Set($0.keys) } == refusingCache.rows.withLock { Set($0.keys) })
  }

  @Test("a suggestion whose category was rejected after the read is dropped at authoring")
  func afterReread() async throws {
    var l = T.Ledger()
    _ = try l.ingest([("CAFE EXAMPLE JBR", "debit")])
    let cloud = RecordingModel("cf-clef/1", reply: .category("dining"))
    let s = try await ModelSuggestionSweep.suggest(
      rows: l.rows(), categorizer: T.categorizer, allowed: T.allowed, stages: [.cloud(cloud)], context: .foreground,
      cache: MemoryCache(), now: { now })
    #expect(s.count == 1)
    #expect(ModelSuggestionSweep.items(s, current: Self.rejecting(l.rows(), ["dining"])).isEmpty)
    #expect(ModelSuggestionSweep.items(s, current: Self.rejecting(l.rows(), ["shopping"])).count == 1)
  }

  @Test("the bulk sort skips a rejected cached answer and never suggests a rejected fresh one")
  func backlog() async throws {
    var l = T.Ledger()
    let ids = try l.ingest([("CAFE EXAMPLE JBR", "debit"), ("SECOND SHOP DXB", "debit")])
    let cache = MemoryCache()
    let hash = ModelTier.taxonomyHash(T.allowed)
    try cache.recordAnswers(
      [ModelTier.StagedSuggestion(subject: "cafe example jbr", category: "shopping", modelTag: "cf-clef/1", autoFile: true)],
      taxonomyHash: hash, now: now)
    let rows = Self.rejecting(l.rows(), ["shopping"])
    let counts = try BacklogSort.counts(
      rows: rows, categorizer: T.categorizer, allowed: T.allowed, modelTag: "cf-clef/1", cache: cache, now: now)
    #expect(counts.waitingNames == 1)
    let cloud = BacklogCloud(["second shop dxb": (.category("shopping"), true)])
    let p = try await BacklogSort.pass(
      rows: rows, categorizer: T.categorizer, allowed: T.allowed, cloud: cloud, memo: .init(), cache: cache, now: { now },
      autoFile: true)
    #expect(cloud.calls == ["second shop dxb"])
    #expect(p.suggestions.isEmpty)
    #expect(p.pending == 0)
    let open = try await BacklogSort.pass(
      rows: l.rows(), categorizer: T.categorizer, allowed: T.allowed, cloud: cloud, memo: p.memo, cache: cache, now: { now },
      autoFile: true)
    #expect(Set(open.suggestions.map(\.txnID)) == Set(ids))
    #expect(cloud.calls == ["second shop dxb"])
  }

  @Test("a category this phone stopped trusting is still suggested, never filed")
  func trust() async throws {
    var l = T.Ledger()
    _ = try l.ingest([("CAFE EXAMPLE JBR", "debit"), ("SECOND SHOP DXB", "debit")])
    let cloud = BacklogCloud(["cafe example jbr": (.category("dining"), true), "second shop dxb": (.category("shopping"), true)])
    let p = try await BacklogSort.pass(
      rows: l.rows(), categorizer: T.categorizer, allowed: T.allowed, cloud: cloud, memo: .init(), cache: MemoryCache(),
      now: { now }, autoFile: true, trusts: { $0 != "dining" })
    #expect(Dictionary(uniqueKeysWithValues: p.suggestions.map { ($0.category, $0.autoFile) }) == ["dining": false, "shopping": true])
    let s = try await ModelSuggestionSweep.suggest(
      rows: l.rows(), categorizer: T.categorizer, allowed: T.allowed, stages: [.cloud(RecordingModel("cf-clef/1", reply: .category("dining")))],
      context: .foreground, cache: MemoryCache(), now: { now }, trusts: { $0 != "dining" })
    #expect(s.allSatisfy { !$0.autoFile } && s.count == 2)
  }

  @Test("the backlog counts each waiting merchant group once")
  func groups() throws {
    var l = T.Ledger()
    _ = try l.ingest([("TAILSCALE.COM", "debit"), ("TAILSCALE INC", "debit"), ("PAYPAL *TAILSCALE", "debit"), ("KITE STUDIO JLT", "debit")])
    let rows = l.rows().map { r in
      SweepRow(
        id: r.id, merchantRaw: r.merchantRaw, direction: r.direction, category: r.category, sourceKind: r.sourceKind,
        sourceRef: r.sourceRef, needsReview: r.needsReview, candidate: r.candidate, version: r.version, template: r.template,
        merchantGroup: RuleReachTests.groups.key(raw: r.merchantRaw))
    }
    let c = try BacklogSort.counts(rows: rows, categorizer: T.categorizer, allowed: T.allowed, modelTag: "cf-clef/1", cache: MemoryCache(), now: now)
    #expect(c.waitingNames == 4 && c.waitingGroups == 2 && c.waitingPayments == 4)
  }

  @Test("the sweep commits under the write serial, after a write already in it")
  func serial() async throws {
    var l = T.Ledger()
    _ = try l.ingest([("CAFE EXAMPLE JBR", "debit")])
    let cloud = RecordingModel("cf-clef/1", reply: .category("dining"))
    let serial = WriteSerial()
    let order = Mutex<[String]>([])
    let snapshot = l
    let gate = AsyncGate()
    let held = Task {
      try await serial.run {
        order.withLock { $0.append("edit-start") }
        await gate.wait()
        order.withLock { $0.append("edit-end") }
      }
    }
    while !serial.isBusy { await Task.yield() }
    let sweep = Task {
      try await ModelSuggestionSweep.run(
        rows: snapshot.rows(), categorizer: T.categorizer, allowed: T.allowed, stages: [.cloud(cloud)], context: .foreground,
        cache: MemoryCache(), now: { now }, stamps: AuthorStamps(), serial: serial,
        reread: {
          order.withLock { $0.append("reread") }
          return (snapshot.rows(), snapshot.context())
        },
        commit: { _ in order.withLock { $0.append("commit") } })
    }
    try await Task.sleep(for: .milliseconds(50))
    #expect(order.withLock { $0 } == ["edit-start"])
    gate.open()
    try await held.value
    let blobs = try await sweep.value
    #expect(blobs.count == 1)
    #expect(order.withLock { $0 } == ["edit-start", "edit-end", "reread", "commit"])
  }
}

extension RejectionSweepTests {
  @Test("the bulk sort reprojects before it lets the next write in")
  func backlogReprojectsInsideTheSerial() async throws {
    var l = T.Ledger()
    _ = try l.ingest([("CAFE EXAMPLE JBR", "debit")])
    let snapshot = l
    let serial = WriteSerial()
    let order = Mutex<[String]>([])
    let cloud = BacklogCloud(fallback: (.category("dining"), false))
    let waiter = Mutex<Task<Void, Error>?>(nil)
    let r = try await BacklogSort.run(
      rows: snapshot.rows(), categorizer: T.categorizer, allowed: T.allowed, cloud: cloud, memo: .init(), cache: MemoryCache(),
      now: { now }, autoFile: false, stamps: AuthorStamps(), serial: serial,
      reread: { (snapshot.rows(), snapshot.context()) },
      enqueue: { _ in
        order.withLock { $0.append("enqueue") }
        waiter.withLock { $0 = Task { try await serial.run { order.withLock { $0.append("next write") } } } }
        try await Task.sleep(for: .milliseconds(50))
      },
      reproject: { order.withLock { $0.append("reproject") } })
    try await waiter.withLock { $0 }?.value
    #expect(r.authored && !r.failed)
    #expect(order.withLock { $0 } == ["enqueue", "reproject", "next write"])
  }

  @Test("a bulk sort whose reproject fails reports the pass as failed")
  func backlogReprojectFailure() async throws {
    struct Boom: Error {}
    var l = T.Ledger()
    _ = try l.ingest([("CAFE EXAMPLE JBR", "debit")])
    let snapshot = l
    let r = try await BacklogSort.run(
      rows: snapshot.rows(), categorizer: T.categorizer, allowed: T.allowed, cloud: BacklogCloud(fallback: (.category("dining"), false)),
      memo: .init(), cache: MemoryCache(), now: { now }, autoFile: false, stamps: AuthorStamps(), serial: WriteSerial(),
      reread: { (snapshot.rows(), snapshot.context()) }, enqueue: { _ in }, reproject: { throw Boom() })
    #expect(r.authored && r.failed)
  }
}

final class AsyncGate: Sendable {
  private let state = Mutex<(open: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))

  func wait() async {
    await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
      let now = state.withLock { s -> Bool in
        if s.open { return true }
        s.waiters.append(k)
        return false
      }
      if now { k.resume() }
    }
  }

  func open() {
    let waiters = state.withLock { s -> [CheckedContinuation<Void, Never>] in
      s.open = true
      defer { s.waiters = [] }
      return s.waiters
    }
    for k in waiters { k.resume() }
  }
}
