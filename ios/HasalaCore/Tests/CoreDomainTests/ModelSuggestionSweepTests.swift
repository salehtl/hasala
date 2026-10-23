import CoreCategorize
import CoreJSON
import CoreReplay
import CoreTestSupport
import CoreWire
import Foundation
import Synchronization
import Testing

@testable import CoreDomain

final class SweepModel: CategoryModel, Sendable {
  let modelTag: String
  let answers: [String: ModelAnswer]
  let fallback: ModelAnswer
  let log = Mutex<[String]>([])

  init(_ tag: String, answers: [String: ModelAnswer] = [:], fallback: ModelAnswer = .unknown) {
    modelTag = tag
    self.answers = answers
    self.fallback = fallback
  }

  func availability() -> ModelAvailability { .available }

  func suggest(subject: String, allowed: [AllowedCategory]) async -> ModelAnswer {
    log.withLock { $0.append(subject) }
    return answers[subject] ?? fallback
  }

  var calls: [String] { log.withLock { $0 } }
}

final class MemoryCache: ModelAnswerCache, Sendable {
  let rows = Mutex<[String: (expires: Int64, answer: CachedAnswer)]>([:])

  func answer(subject: String, taxonomyHash: String, modelTag: String, now: Int64) throws -> CachedAnswer? {
    let key = ModelTier.cacheKey(subject: subject, taxonomyHash: taxonomyHash, modelTag: modelTag)
    return rows.withLock { r in r[key].flatMap { $0.expires > now ? $0.answer : nil } }
  }

  func recordUnknown(_ entries: [(subject: String, modelTag: String)], taxonomyHash: String, now: Int64) throws {
    rows.withLock { r in
      for e in entries {
        r[ModelTier.cacheKey(subject: e.subject, taxonomyHash: taxonomyHash, modelTag: e.modelTag)] = (now + 30 * 86_400_000, .unknown)
      }
    }
  }

  func recordAnswers(_ entries: [ModelTier.StagedSuggestion], taxonomyHash: String, now: Int64) throws {
    rows.withLock { r in
      for e in entries {
        r[ModelTier.cacheKey(subject: e.subject, taxonomyHash: taxonomyHash, modelTag: e.modelTag)] =
          (now + 30 * 86_400_000, .category(e.category, autoFile: e.autoFile))
      }
    }
  }

  let kept = Mutex<[String: String]>([:])

  func keptAnswer(subject: String, modelTag: String) throws -> String? {
    kept.withLock { $0[ModelTier.keptKey(subject: subject, modelTag: modelTag)] }
  }

  func keepAnswers(_ entries: [ModelTier.StagedSuggestion]) throws {
    kept.withLock { k in
      for e in entries { k[ModelTier.keptKey(subject: e.subject, modelTag: e.modelTag)] = e.category }
    }
  }

  func dropKept(_ entries: [(subject: String, modelTag: String)]) throws {
    kept.withLock { k in
      for e in entries { k[ModelTier.keptKey(subject: e.subject, modelTag: e.modelTag)] = nil }
    }
  }

  func purgeExpired(now: Int64) {
    rows.withLock { r in r = r.filter { $0.value.expires > now } }
  }
}

@Suite("ModelSuggestionSweep")
struct ModelSuggestionSweepTests {
  static let dictionary = try! MerchantDictionary.bundled().get()
  static let taxonomy = TaxonomyView(TaxonomyV1.builtins)
  static let allowed = ModelTier.allowed(TaxonomyV1.builtins)
  static let categorizer = Categorizer(rules: [], dictionary: dictionary, categories: taxonomy)
  static let latin = "CAFE EXAMPLE JBR"
  static let arabic = "مطعم الياسمين الشعبي"

  struct Ledger {
    var state = State()
    var seq: Int64 = 0
    var own: Int64?
    var ingested = 0
    var templates: [String: String] = [:]
    let random = SeededRandom(seed: "model-sweep")

    func context() -> AuthorContext { AuthorContext(writerID: w, nowMs: now, ownLastMs: own, maxAuthored: [:], random: random) }

    mutating func fold(_ blob: AuthoredBlob) throws {
      seq += 1
      try Replay.foldOps(blob.ops, seq: seq, writerID: w, into: &state)
      own = blob.lastAuthoredMs
      #expect(state.anomalies.isEmpty, "\(state.anomalies)")
    }

    mutating func ingest(_ merchants: [(String, String)], template: String? = "dib.card.v1@1", needsReview: Bool = true) throws
      -> [String]
    {
      var a = OpAuthor(context())
      var ids: [String] = []
      for (m, dir) in merchants {
        ingested += 1
        let p = JSONObject([
          ("amount_minor", .string(String(1500 + ingested))), ("currency", .string("AED")), ("direction", .string(dir)),
          ("posted_at", .string("2026-10-09T15:12:00.000Z")), ("merchant_raw", .string(m)), ("last4", .string("0000")),
          ("tier", .string("template")), ("needs_review", .bool(needsReview)), ("entry_method", .string("mailbox")),
        ])
        let hex = String(ingested, radix: 16)
        let id = try a.ingest(payload: p, ingestID: String(repeating: "0", count: 64 - hex.count) + hex)
        ids.append(id)
        templates[id] = template
      }
      try fold(try a.build())
      return ids
    }

    func rows() -> [SweepRow] {
      state.txns.values.map { t in
        SweepRow(
          id: t.id, merchantRaw: t.merchantRaw, direction: Direction(rawValue: t.direction), category: t.category,
          sourceKind: SweepRow.SourceKind(rawValue: t.categorySource?.kind.rawValue ?? "none") ?? .none,
          sourceRef: t.categorySource?.model,
          needsReview: t.needsReview, candidate: !t.unparsed && t.splits.isEmpty, version: t.version, template: templates[t.id])
      }.sorted { $0.id < $1.id }
    }
  }

  static func stages(_ device: SweepModel, _ cloud: SweepModel) -> [ModelStage] { [.onDevice(device), .cloud(cloud)] }

  @Test("the model tag grammar accepts cf-clef and apple-fm tags")
  func tags() {
    #expect(Grammar.isModelTag("cf-clef/1") && Grammar.isModelTag("cf-clef/2.3") && Grammar.isModelTag("apple-fm/26.1"))
    #expect(!Grammar.isModelTag("CF-Clef/1") && !Grammar.isModelTag("cf clef/1"))
  }

  @Test("suggestions are authored as needs-review model categorizations tagged by the stage that answered")
  func authors() async throws {
    var l = Ledger()
    let ids = try l.ingest([
      (Self.latin, "debit"), (Self.arabic, "debit"), (Self.latin, "credit"), ("CARREFOUR MOE", "debit"), ("MYSTERY PLACE 77", "debit"),
      (Self.latin, "debit"),
    ])
    let userRow = try l.ingest([("USER FILED SHOP", "debit")])[0]
    var b = OpAuthor(l.context())
    b.categorize(txnID: userRow, parentVersion: l.state.txns[userRow]!.version, category: "shopping")
    try l.fold(try b.build())

    let device = SweepModel("apple-fm/26.1", answers: ["cafe example jbr": .category("dining")])
    let cloud = SweepModel("cf-clef/1", answers: ["مطعم الياسمين الشعبي": .category("dining")])
    let cache = MemoryCache()
    let suggestions = try await ModelSuggestionSweep.suggest(
      rows: l.rows(), categorizer: Self.categorizer, allowed: Self.allowed, stages: Self.stages(device, cloud), context: .foreground,
      cache: cache, now: { now })
    #expect(device.calls.sorted() == ["cafe example jbr", "mystery place 77"])
    #expect(cloud.calls.sorted() == ["mystery place 77", "مطعم الياسمين الشعبي"])
    #expect(Set(suggestions.map(\.txnID)) == [ids[0], ids[1], ids[5]])
    #expect(try cache.isCached(subject: "mystery place 77", taxonomyHash: ModelTier.taxonomyHash(Self.allowed), modelTag: "cf-clef/1", now: now))
    #expect(try cache.isCached(subject: "mystery place 77", taxonomyHash: ModelTier.taxonomyHash(Self.allowed), modelTag: "apple-fm/26.1", now: now))

    let before = l.state.txns
    let blobs = try ModelSuggestionSweep.author(suggestions, current: l.rows(), context: l.context())
    #expect(blobs.count == 1)
    let ops = blobs[0].ops
    #expect(ops.count == 3 && ops.allSatisfy { $0.type == .txnCategorized })
    for op in ops {
      let id = try #require(op.entity?.id)
      #expect(op.parentVersion == before[id]?.version)
      #expect(op.payload["category"]?.stringValue == "dining")
      #expect(op.payload["needs_review"] == .bool(true))
      let source = op.payload["source"]?.objectValue
      #expect(source?["kind"]?.stringValue == "model")
      #expect(source?["model"]?.stringValue == (id == ids[1] ? "cf-clef/1" : "apple-fm/26.1"))
    }
    try l.fold(blobs[0])
    #expect(l.state.txns[ids[1]]?.categorySource == CategorySource(kind: .model, model: "cf-clef/1"))
    #expect(l.state.txns[ids[0]]?.categorySource == CategorySource(kind: .model, model: "apple-fm/26.1"))
    #expect(l.state.txns[ids[1]]?.category == "dining" && l.state.txns[ids[1]]?.needsReview == true)
    for untouched in [ids[2], ids[3], ids[4], userRow] {
      #expect(l.state.txns[untouched]?.version == before[untouched]?.version)
      #expect(l.state.txns[untouched]?.category == before[untouched]?.category)
    }
    #expect(l.state.txns[userRow]?.category == "shopping")
    #expect(l.state.txns[ids[2]]?.category == nil)

    let again = try await ModelSuggestionSweep.suggest(
      rows: l.rows(), categorizer: Self.categorizer, allowed: Self.allowed, stages: Self.stages(device, cloud), context: .foreground,
      cache: cache, now: { now })
    #expect(again.isEmpty)
    #expect(device.calls.count == 2 && cloud.calls.count == 2)
  }

  @Test("a row whose version or category changed after the read is not clobbered")
  func stale() async throws {
    var l = Ledger()
    let ids = try l.ingest([(Self.latin, "debit"), ("ANOTHER CAFE SPOT", "debit")])
    let device = SweepModel("apple-fm/26.1", fallback: .category("dining"))
    let cloud = SweepModel("cf-clef/1")
    let read = l.rows()
    let suggestions = try await ModelSuggestionSweep.suggest(
      rows: read, categorizer: Self.categorizer, allowed: Self.allowed, stages: Self.stages(device, cloud), context: .foreground,
      cache: MemoryCache(), now: { now })
    #expect(suggestions.count == 2)
    var a = OpAuthor(l.context())
    a.categorize(txnID: ids[0], parentVersion: l.state.txns[ids[0]]!.version, category: "groceries")
    try l.fold(try a.build())
    let blobs = try ModelSuggestionSweep.author(suggestions, current: l.rows(), context: l.context())
    #expect(blobs.flatMap(\.ops).map { $0.entity?.id } == [ids[1]])
    try l.fold(blobs[0])
    #expect(l.state.txns[ids[0]]?.category == "groceries" && l.state.txns[ids[0]]?.categorySource?.kind == .user)
    #expect(try ModelSuggestionSweep.author(suggestions, current: l.rows(), context: l.context()).isEmpty)
    #expect(try ModelSuggestionSweep.author(suggestions, current: [], context: l.context()).isEmpty)
  }

  @Test("refresh context, no stages or rows without a version author nothing")
  func nothing() async throws {
    var l = Ledger()
    _ = try l.ingest([(Self.latin, "debit")])
    let device = SweepModel("apple-fm/26.1", fallback: .category("dining"))
    let cloud = SweepModel("cf-clef/1", fallback: .category("dining"))
    let r = try await ModelSuggestionSweep.suggest(
      rows: l.rows(), categorizer: Self.categorizer, allowed: Self.allowed, stages: Self.stages(device, cloud), context: .refresh,
      cache: MemoryCache(), now: { now })
    #expect(r.isEmpty && device.calls.isEmpty && cloud.calls.isEmpty)
    let unversioned = l.rows().map {
      SweepRow(
        id: $0.id, merchantRaw: $0.merchantRaw, direction: $0.direction, category: $0.category, sourceKind: $0.sourceKind, sourceRef: nil,
        needsReview: $0.needsReview, candidate: true)
    }
    let u = try await ModelSuggestionSweep.suggest(
      rows: unversioned, categorizer: Self.categorizer, allowed: Self.allowed, stages: Self.stages(device, cloud), context: .foreground,
      cache: MemoryCache(), now: { now })
    #expect(u.isEmpty && device.calls.isEmpty)
    let none = try await ModelSuggestionSweep.suggest(
      rows: l.rows(), categorizer: Self.categorizer, allowed: Self.allowed, stages: [], context: .foreground, cache: MemoryCache(), now: { now })
    #expect(none.isEmpty)
  }

  @Test("run suggests, re-reads, and authors under the shared stamps")
  func run() async throws {
    var l = Ledger()
    let ids = try l.ingest([(Self.arabic, "debit"), (Self.latin, "debit")])
    let device = SweepModel("apple-fm/26.1")
    let cloud = SweepModel("cf-clef/1", fallback: .category("dining"))
    let stamps = AuthorStamps()
    let snapshot = l
    let blobs = try await ModelSuggestionSweep.run(
      rows: l.rows(), categorizer: Self.categorizer, allowed: Self.allowed, stages: Self.stages(device, cloud), context: .foreground,
      cache: MemoryCache(), now: { now }, stamps: stamps, reread: { (snapshot.rows(), snapshot.context()) })
    #expect(blobs.flatMap(\.ops).count == 2)
    #expect(stamps.lastMs == blobs.last?.lastAuthoredMs)
    try l.fold(blobs[0])
    #expect(ids.allSatisfy { l.state.txns[$0]?.categorySource == CategorySource(kind: .model, model: "cf-clef/1") })
    #expect(device.calls == ["cafe example jbr"])
  }

  @Test("the sweep reports its cloud calls even when the run fails after them, and keeps within its cloud cap")
  func cloudSpend() async throws {
    struct Boom: Error {}
    var l = Ledger()
    _ = try l.ingest([(Self.arabic, "debit"), ("ANOTHER CAFE SPOT", "debit"), ("THIRD CAFE SPOT", "debit")])
    let device = SweepModel("apple-fm/26.1")
    let cloud = SweepModel("cf-clef/1", fallback: .category("dining"))
    let spent = Mutex<[Int]>([])
    do {
      _ = try await ModelSuggestionSweep.run(
        rows: l.rows(), categorizer: Self.categorizer, allowed: Self.allowed, stages: [.cloud(cloud), .onDevice(device)],
        context: .foreground, cache: MemoryCache(), now: { now }, maxCloudCalls: 2, spent: { n in spent.withLock { $0.append(n) } },
        stamps: AuthorStamps(), reread: { throw Boom() })
      Issue.record("the reread failed, so the run must throw")
    } catch is Boom {}
    #expect(spent.withLock { $0 } == [2] && cloud.calls.count == 2)
    #expect(device.calls.count == 1 && !cloud.calls.contains(device.calls[0]))
    let quiet = SweepModel("cf-clef/1", fallback: .category("dining"))
    let none = Mutex<[Int]>([])
    _ = try await ModelSuggestionSweep.suggest(
      rows: l.rows(), categorizer: Self.categorizer, allowed: Self.allowed, stages: [.cloud(quiet)], context: .foreground,
      cache: MemoryCache(), now: { now }, maxCloudCalls: 0, spent: { n in none.withLock { $0.append(n) } })
    #expect(quiet.calls.isEmpty && none.withLock { $0 }.isEmpty)
  }

  @Test("more than 500 suggestions split into blobs that each fold clean")
  func chunks() async throws {
    var l = Ledger()
    var ids: [String] = []
    for n in [100, 100, 100, 100, 101] { ids += try l.ingest((0..<n).map { _ in (Self.latin, "debit") }) }
    let device = SweepModel("apple-fm/26.1", fallback: .category("dining"))
    let suggestions = try await ModelSuggestionSweep.suggest(
      rows: l.rows(), categorizer: Self.categorizer, allowed: Self.allowed, stages: [.onDevice(device)], context: .foreground,
      cache: MemoryCache(), now: { now })
    #expect(suggestions.count == 501 && device.calls.count == 1)
    let blobs = try ModelSuggestionSweep.author(suggestions, current: l.rows(), context: l.context())
    #expect(blobs.map(\.ops.count) == [500, 1])
    for b in blobs { try l.fold(b) }
    #expect(ids.allSatisfy { l.state.txns[$0]?.category == "dining" })
  }

  @Test("only card-payment alert templates may leave the device")
  func cloudTemplates() {
    func row(_ t: String?) -> SweepRow {
      SweepRow(
        id: "x", merchantRaw: "SHOP", direction: .debit, category: nil, sourceKind: .none, sourceRef: nil, needsReview: true, candidate: true,
        version: 1, template: t)
    }
    for t in ["adib.alert.v1@1", "dib.card.v1@3", "enbd.alert.v1@2", "enbd.alert.v1"] { #expect(ModelSuggestionSweep.mayLeaveDevice(row(t)), "\(t)") }
    for t in [nil, "", "none", "enbd.transfer.v1@2", "dib.account.v1@1", "adib.account.v1@1", "enbd.alert.v2@1", "enbd.alert.v1x@1", "@1"] {
      #expect(!ModelSuggestionSweep.mayLeaveDevice(row(t)), "\(t ?? "nil")")
    }
  }

  @Test("a transfer's beneficiary goes to the on-device model but never to the cloud")
  func transferStaysOnDevice() async throws {
    var l = Ledger()
    let ids = try l.ingest([("EXAMPLE PERSON NAME", "debit"), ("محمد مثال", "debit")], template: "enbd.transfer.v1@2")
    let device = SweepModel("apple-fm/26.1", fallback: .category("shopping"))
    let cloud = SweepModel("cf-clef/1", fallback: .category("dining"))
    let suggestions = try await ModelSuggestionSweep.suggest(
      rows: l.rows(), categorizer: Self.categorizer, allowed: Self.allowed, stages: Self.stages(device, cloud), context: .foreground,
      cache: MemoryCache(), now: { now })
    #expect(cloud.calls.isEmpty)
    #expect(device.calls == ["example person name"])
    #expect(suggestions.map(\.txnID) == [ids[0]])
    #expect(suggestions.allSatisfy { $0.modelTag == "apple-fm/26.1" })
  }

  @Test("manual rows, account alerts and a subject shared with a transfer stay on the device")
  func otherRowsStayOnDevice() async throws {
    var l = Ledger()
    _ = try l.ingest([("MANUAL SHOP ONE", "debit")], template: nil)
    _ = try l.ingest([("ACCOUNT TEXT TWO", "debit")], template: "dib.account.v1@1")
    _ = try l.ingest([("ADIB ACCOUNT THREE", "debit")], template: "adib.account.v1@1")
    _ = try l.ingest([("SHARED NAME FOUR", "debit")], template: "dib.card.v1@1")
    _ = try l.ingest([("SHARED NAME FOUR", "debit")], template: "enbd.transfer.v1@2")
    _ = try l.ingest([("CARD SHOP FIVE", "debit")], template: "enbd.alert.v1@1")
    _ = try l.ingest([("CARD SHOP SIX", "debit")], template: "adib.alert.v1@1")
    let device = SweepModel("apple-fm/26.1")
    let cloud = SweepModel("cf-clef/1")
    _ = try await ModelSuggestionSweep.suggest(
      rows: l.rows(), categorizer: Self.categorizer, allowed: Self.allowed, stages: Self.stages(device, cloud), context: .foreground,
      cache: MemoryCache(), now: { now })
    #expect(cloud.calls.sorted() == ["card shop five", "card shop six"])
    #expect(
      device.calls.sorted() == ["account text two", "adib account three", "card shop five", "card shop six", "manual shop one", "shared name four"])
  }
}
