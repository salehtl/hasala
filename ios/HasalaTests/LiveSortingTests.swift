import CoreCategorize
import CoreDomain
import CoreInvariants
import CoreJSON
import CorePrimitives
import CoreProjection
import CoreReplay
import CoreStore
import CoreTime
import CoreWire
import Foundation
import HasalaMocks
import HasalaModels
import Synchronization
import Testing

@testable import Hasala

@MainActor
@Suite("Live sorting: merchant groups, reach-back and undo")
struct LiveSortingTests {
  typealias Mapper = LiveLedgerMapperTests

  nonisolated final class MovableClock: CoreTime.Clock, Sendable {
    private let ms: Mutex<Int64>
    init(ms: Int64) { self.ms = Mutex(ms) }
    func set(_ value: Int64) { ms.withLock { $0 = value } }
    func nowMs() -> Int64 { ms.withLock { $0 } }
  }

  static let weeksAgo = Mapper.anchor - 20 * 86_400_000

  struct Row {
    var raw: String
    var minor: Int64
    var currency = "USD"
    var month = 10
    var day: Int
    var direction = "debit"
    var verified = true
  }

  struct Ledger {
    let a: Mapper.Account
    let store: LiveLedgerStore
    let author: LedgerEditAuthor
    let memory: SortKeeper
    let trust: TrustCounts
    var ids: [String: [String]] = [:]

    var reader: LedgerReader { a.projection.reader }
    func row(_ id: String) throws -> TxnRow? { try reader.txn(id) }
  }

  static func payload(_ r: Row, n: Int) -> JSONObject {
    let gates: JSONObject = JSONObject([
      ("ar", .string(r.verified ? "pass" : "fail")), ("sender", .string(r.verified ? "trusted" : "untrusted")),
      ("template", .string("dib.card.v1@1")), ("card", .string("known")), ("forwarded", .bool(false)),
    ])
    return JSONObject([
      ("amount_minor", .string(String(r.minor))), ("currency", .string(r.currency)), ("direction", .string(r.direction)),
      ("posted_at", .string(String(format: "2026-%02d-%02dT0%d:%02d:00.000Z", r.month, r.day, n % 9, n % 60))),
      ("posted_precision", .string("time")), ("merchant_raw", .string(r.raw)), ("last4", .string("8891")),
      ("needs_review", .bool(true)), ("tier", .string("template")), ("entry_method", .string("mailbox")),
      ("bank", .string("dib")), ("gates", .object(gates)),
      ("provenance", .object(JSONObject([
        ("provider", .string("gmail")), ("grant_id", .string("g1/mbx-0011")), ("message_id", .string("sort-\(n)")),
      ]))),
    ])
  }

  static func ledger(
    suite: String, rows: [(String, Row)], guesses: [String: String] = [:],
    clock: any CoreTime.Clock = Mapper.FixedClock(ms: Mapper.anchor)
  ) async throws -> Ledger {
    let a = try Mapper.account(clock: clock)
    let ctx = try await a.observer.authorContext()
    var ids: [String: [String]] = [:]
    var n = 0
    let opening = try a.observer.stamps.build(ctx) { o throws(AuthorError) in
      o.setHomeCurrency("AED")
      try o.setRate(currency: "USD", rateMicro: 3_672_500)
      for (name, r) in rows {
        n += 1
        let hex = String(n, radix: 16)
        ids[name, default: []].append(
          try o.ingest(payload: Self.payload(r, n: n), ingestID: String(repeating: "e", count: 64 - hex.count) + hex))
      }
    }
    if let opening { try await a.outbox.enqueue(opening.ops) }
    try await a.observer.reproject()
    if !guesses.isEmpty {
      let reader = a.projection.reader
      let guessed = try a.observer.stamps.build(try await a.observer.authorContext()) { o throws(AuthorError) in
        for (name, category) in guesses {
          for id in ids[name] ?? [] {
            guard let v = try? reader.txn(id)?.version else { continue }
            o.categorize(txnID: id, parentVersion: v, category: category, needsReview: true, source: CategorySource(kind: .model, model: "cf-clef/1"))
          }
        }
      }
      if let guessed { try await a.outbox.enqueue(guessed.ops) }
      try await a.observer.reproject()
    }
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    let memory = SortKeeper(store: SortMemoryStore(a.context.store))
    let trust = TrustCounts(defaults: { UserDefaults(suiteName: suite)! })
    let author = LedgerEditAuthor(observer: a.observer, outbox: a.outbox, memory: memory, trust: trust)
    let store = LiveLedgerStore(
      reader: a.projection.reader, author: author, profile: Mapper.context().profile, prefs: DevicePrefsStore(defaults: defaults),
      clock: { MayaLedger.now })
    await store.reload()
    return Ledger(a: a, store: store, author: author, memory: memory, trust: trust, ids: ids)
  }

  static let tailscale: [(String, Row)] = [
    ("com", Row(raw: "TAILSCALE.COM", minor: 6_00, day: 1)), ("com", Row(raw: "TAILSCALE.COM", minor: 6_00, month: 9, day: 1)),
    ("inc", Row(raw: "TAILSCALE INC", minor: 18_00, day: 2)), ("inc", Row(raw: "TAILSCALE INC", minor: 18_00, month: 8, day: 2)),
    ("paypal", Row(raw: "PAYPAL *TAILSCALE", minor: 12_00, day: 3)),
    ("unverified", Row(raw: "TAILSCALE.COM", minor: 6_00, day: 5, verified: false)),
    ("refund", Row(raw: "TAILSCALE.COM", minor: 6_00, day: 7, direction: "credit")),
    ("bright", Row(raw: "BRIGHTWELL ACADEMY FZE", minor: 450_00, currency: "AED", day: 3)),
    ("bright", Row(raw: "BRIGHTWELL ACADEMY FZE", minor: 450_00, currency: "AED", month: 9, day: 3)),
    ("alnoorT", Row(raw: "AL NOOR TRADING LLC", minor: 120_00, currency: "AED", day: 4)),
    ("alnoorP", Row(raw: "AL NOOR PHARMACY", minor: 38_75, currency: "AED", day: 4)),
  ]

  static func decode(_ p: PendingOp) throws -> Op {
    var blob = Data(#"{"v":4,"kind":"ops","ops":["#.utf8)
    blob.append(p.opJSON)
    blob.append(contentsOf: Array("]}".utf8))
    return try OpCodec.decodeBlobOps(blob)[0]
  }

  static let tailscaleRef = MerchantGroupRef(key: "n:tailscale", direction: .out)
  static let brightwellRef = MerchantGroupRef(key: "n:brightwell academy", direction: .out)

  @Test func theMapperFillsGroupsAndReachAndEachPaymentIsItsOwnCard() async throws {
    let l = try await Self.ledger(suite: "sorting.map", rows: Self.tailscale, guesses: ["bright": "shopping"])
    let s = l.store.state
    let ts = Set((l.ids["com"] ?? []) + (l.ids["inc"] ?? []) + (l.ids["paypal"] ?? []))
    for id in ts {
      let t = try #require(s.txn(id))
      #expect(t.merchantGroup == "n:tailscale" && t.reachable)
    }
    #expect(s.txn(l.ids["unverified"]![0])?.reachable == false)
    #expect(s.txn(l.ids["refund"]![0])?.groupRef == MerchantGroupRef(key: "n:tailscale", direction: .in))
    #expect(s.txn(l.ids["alnoorT"]![0])?.merchantGroup == "n:al noor trading")
    #expect(s.txn(l.ids["alnoorP"]![0])?.merchantGroup == "n:al noor pharmacy")
    let cards = ReviewEngine.cards(s)
    #expect(Set(cards.map(\.id)).isSuperset(of: ts) && cards.count == Set(cards.map(\.id)).count)
    #expect(cards.filter { ts.contains($0.id) }.allSatisfy { s.txn($0.id)?.groupRef == Self.tailscaleRef && $0.canAlwaysUse })
  }

  @Test func alwaysUseItFromOneRowReachesTheGroupWithExactPatternsAndUndoesExactly() async throws {
    let l = try await Self.ledger(suite: "sorting.learn", rows: Self.tailscale, guesses: ["paypal": "shopping"])
    let paypal = try #require(l.ids["paypal"]?.first)
    let com = l.ids["com"] ?? []
    let inc = l.ids["inc"] ?? []
    let token = try #require(try l.store.apply(.categorize(com[0], "subscriptions", learnRule: true, project: nil)))
    #expect(token.title.hasPrefix("Subscriptions for all 5 ") && token.title.hasSuffix(" payments"), "\(token.title)")
    try await Mapper.eventually { try (com + inc + [paypal]).allSatisfy { try l.row($0)?.category == "subscriptions" } }
    let rule = try #require(try l.reader.rules().first { $0.origin == "learned" })
    #expect(rule.match == "exact" && rule.patterns.first == "tailscale.com" && rule.patterns.count == 3)
    #expect(!rule.patterns.contains("paypal"))
    for id in com.dropFirst() + inc + [paypal] {
      let r = try #require(try l.row(id))
      #expect(r.categorySource == "rule" && r.categorySourceRef == rule.id && !r.needsReview)
    }
    #expect(try l.row(com[0])?.categorySource == "user")
    #expect(try l.row(l.ids["alnoorT"]![0])?.category == nil)
    #expect(token.batch)

    l.store.undo(token)
    try await Mapper.eventually { try l.row(paypal)?.category == "shopping" }
    #expect(try l.row(paypal)?.categorySource == "model" && l.row(paypal)?.needsReview == true)
    #expect(try (com + inc).allSatisfy { try l.row($0)?.category == nil && l.row($0)?.categorySource == "none" })
    try await Mapper.eventually { try l.reader.rules().isEmpty }
    try await Mapper.eventually { l.store.state.txn(paypal)?.reviewSuggestion == "shopping" }
  }

  @Test func aNineSpellingGroupMakesARuleOfEightPatternsThatTheFoldAccepts() async throws {
    let rows: [(String, Row)] = (1...9).flatMap { n in
      (0..<(10 - n)).map { k in ("shop", Row(raw: "SOME SHOP*REF \(n)", minor: Int64(1_000 + n * 10 + k), currency: "AED", day: 1 + (k % 9))) }
    }
    let l = try await Self.ledger(suite: "sorting.nine", rows: rows)
    let first = try #require(l.ids["shop"]?.first)
    let token = try #require(try l.store.apply(.categorize(first, "shopping", learnRule: true, project: nil)))
    try await Mapper.eventually { try (l.ids["shop"] ?? []).filter { try l.row($0)?.category == "shopping" }.count == 44 }
    let rule = try #require(try l.reader.rules().first)
    #expect(rule.patterns.count == 8 && rule.defect == nil)
    #expect(try l.reader.forkNotices(kind: "rule").isEmpty)
    #expect(token.title.hasPrefix("Shopping for 44 ") && token.batch, "\(token.title)")
  }

  @Test func stopThisRuleRemovesTheRuleAndKeepsWhatItSorted() async throws {
    let l = try await Self.ledger(suite: "sorting.stop", rows: Self.tailscale)
    try l.store.apply(.categorize(l.ids["com"]![0], "subscriptions", learnRule: true, project: nil))
    try await Mapper.eventually { try l.reader.rules().count == 1 }
    let rule = try #require(try l.reader.rules().first)
    let reached = l.ids["inc"]! + l.ids["paypal"]!
    try await Mapper.eventually { try reached.allSatisfy { try l.row($0)?.categorySource == "rule" } }
    try await Mapper.eventually { l.store.state.rules.contains { $0.id == rule.id } }
    let stop = try #require(try l.store.apply(.stopRule(rule.id)))
    try await Mapper.eventually { try l.reader.rules().isEmpty }
    #expect(try l.reader.rulesIncludingRemoved().first { $0.id == rule.id }?.removed == true)
    for id in reached {
      let r = try #require(try l.row(id))
      #expect(r.categorySource == "rule" && r.category == "subscriptions" && !r.needsReview)
    }
    l.store.undo(stop)
    try await Mapper.eventually { try l.reader.rules().count == 1 }
    #expect(try l.reader.rules().first?.enabled == true)
  }

  @Test func undoAllInSortedForYouKeepsRowsInReviewAfterTheNextPull() async throws {
    let l = try await Self.ledger(suite: "sorting.undoall", rows: Self.tailscale, guesses: ["paypal": "shopping"])
    try l.store.apply(.categorize(l.ids["com"]![0], "subscriptions", learnRule: true, project: nil))
    let reached = Array(l.ids["com"]!.dropFirst()) + l.ids["inc"]! + l.ids["paypal"]!
    try await Mapper.eventually { try reached.allSatisfy { try l.row($0)?.categorySource == "rule" } }
    try await Mapper.eventually {
      SortedForYouEngine.snapshot(l.store.state, now: MayaLedger.now).items.first.map { Set($0.txnIDs) == Set(reached) } == true
    }
    let snapshot = SortedForYouEngine.snapshot(l.store.state, now: MayaLedger.now)
    let item = try #require(snapshot.items.first)
    #expect(Set(item.txnIDs) == Set(reached) && item.canStopRule)
    _ = try #require(try l.store.apply(item.undoAll))
    try await Mapper.eventually { try reached.allSatisfy { try l.row($0)?.categorySource != "rule" } }
    #expect(try l.row(l.ids["paypal"]![0])?.categorySource == "model")
    #expect(try l.row(l.ids["paypal"]![0])?.category == "shopping")
    #expect(try reached.allSatisfy { try l.row($0)?.needsReview == true })
    _ = await l.author.followUp()
    #expect(try reached.allSatisfy { try l.row($0)?.needsReview == true })
    #expect(try l.reader.rules().count == 1)
  }

  @Test func aRuleReachesARowThatArrivesAfterItOnTheNextPull() async throws {
    var l = try await Self.ledger(suite: "sorting.rerun", rows: Self.tailscale)
    try l.store.apply(.categorize(l.ids["com"]![0], "subscriptions", learnRule: true, project: nil))
    try await Mapper.eventually { try l.reader.rules().count == 1 }
    try await Mapper.eventually { l.memory.value.batches.count == 1 }
    let ctx = try await l.a.observer.authorContext()
    var late = ""
    let blob = try l.a.observer.stamps.build(ctx) { o throws(AuthorError) in
      late = try o.ingest(payload: Self.payload(Row(raw: "TAILSCALE INC", minor: 18_00, day: 9), n: 77), ingestID: String(repeating: "f", count: 64))
    }
    try await l.a.outbox.enqueue(try #require(blob).ops)
    try await l.a.observer.reproject()
    l.memory.update { m in m.batches[0].cursor = -1 }
    #expect(try l.row(late)?.category == nil)
    #expect(await l.author.followUp())
    #expect(try l.row(late)?.categorySource == "rule")
    #expect(try l.row(late)?.category == "subscriptions")
    l.ids["late"] = [late]
    #expect(await l.author.followUp() == false)
  }

  @Test func aPersonsFilingThatLostAForkToReachBackIsWrittenAgain() async throws {
    let l = try await Self.ledger(suite: "sorting.fork", rows: Self.tailscale)
    let inc = try #require(l.ids["inc"]?.first)
    let parent = try #require(try l.row(inc)).version
    try l.store.apply(.categorize(l.ids["com"]![0], "subscriptions", learnRule: true, project: nil))
    try await Mapper.eventually { try l.row(inc)?.categorySource == "rule" }
    var stale = OpAuthor(
      AuthorContext(
        writerID: Mapper.writer.string, nowMs: Mapper.anchor - 3_600_000, ownLastMs: nil, maxAuthored: [:], random: SystemRandom()))
    stale.categorize(txnID: inc, parentVersion: parent, category: "dining", needsReview: false)
    try await l.a.outbox.enqueue(try stale.build().ops)
    try await l.a.observer.reproject()
    #expect(try l.row(inc)?.categorySource == "rule")
    #expect(try l.reader.forkNotices(kind: "txn").contains { $0.entityID == inc })
    #expect(await l.author.followUp())
    #expect(try l.row(inc)?.category == "dining" && l.row(inc)?.categorySource == "user")
    #expect(await l.author.followUp() == false)
  }

  @Test func twoCorrectionsOfACloudflareFilingStopItAutoFilingThatCategoryHere() async throws {
    let suite = "sorting.trust"
    let l = try await Self.ledger(suite: suite, rows: [
      ("a", Row(raw: "LANTERN FILM CLUB", minor: 40_00, currency: "AED", day: 1)), ("b", Row(raw: "KITE STUDIO JLT", minor: 75_00, currency: "AED", day: 2)),
      ("c", Row(raw: "PALM ROW CINEMA", minor: 55_00, currency: "AED", day: 3)),
    ])
    let ids = (l.ids["a"] ?? []) + (l.ids["b"] ?? []) + (l.ids["c"] ?? [])
    let reader = l.reader
    let filed = try l.a.observer.stamps.build(try await l.a.observer.authorContext()) { o throws(AuthorError) in
      for id in ids {
        guard let v = try? reader.txn(id)?.version else { continue }
        o.categorize(txnID: id, parentVersion: v, category: "entertainment", needsReview: false, source: CategorySource(kind: .model, model: "cf-clef/1"))
      }
    }
    try await l.a.outbox.enqueue(try #require(filed).ops)
    try await l.a.observer.reproject()
    await l.store.reload()
    let lanes = try ids.map { try l.row($0)?.reviewLane }
    #expect(l.trust.autoFiles("entertainment"))
    try l.store.apply(.categorize(ids[0], "dining", learnRule: false, project: nil))
    try await Mapper.eventually { try l.row(ids[0])?.category == "dining" }
    #expect(l.trust.autoFiles("entertainment"))
    try l.store.apply(.categorize(ids[1], "shopping", learnRule: false, project: nil))
    try await Mapper.eventually { try l.row(ids[1])?.category == "shopping" }
    #expect(!l.trust.autoFiles("entertainment") && l.trust.autoFiles("dining"))
    #expect(lanes.allSatisfy { $0 == nil })
    let kept = try #require(try l.row(ids[2]))
    #expect(kept.reviewLane == nil && kept.categorySource == "model" && !kept.needsReview && kept.category == "entertainment")
    #expect(l.store.state.txn(ids[2])?.inReview == false)
    let custom = TrustCounts(defaults: { UserDefaults(suiteName: suite)! }, builtins: ["entertainment"])
    custom.corrected("c_01jcustom", modelTag: "cf-clef/1")
    custom.corrected("entertainment", modelTag: "apple-fm/26.1")
    #expect(custom.counts.corrections.keys.allSatisfy { $0 == "entertainment" })
    LocalAccountData.forget(defaults: UserDefaults(suiteName: suite)!)
    #expect(UserDefaults(suiteName: suite)!.data(forKey: TrustCounts.key) == nil)
  }

  @Test func reFilingOnePaymentOfARuledGroupMovesItsRuleSoTheNextPaymentFollows() async throws {
    let l = try await Self.ledger(suite: "sorting.refile", rows: Self.tailscale)
    let com = l.ids["com"] ?? []
    let inc = l.ids["inc"] ?? []
    try l.store.apply(.categorize(com[0], "shopping", learnRule: true, project: nil))
    try await Mapper.eventually { try (com + inc).allSatisfy { try l.row($0)?.category == "shopping" } }
    let first = try #require(try l.reader.rules().first)
    let changed = try #require(try l.store.apply(.categorize(com[1], "subscriptions", learnRule: true, project: nil)))
    try await Mapper.eventually { try l.reader.rules().first?.category == "subscriptions" }
    let rules = try l.reader.rules()
    let hitting = rules.filter { $0.enabled && !$0.removed && $0.match == "exact" && $0.patterns.contains("tailscale.com") }
    #expect(rules.count == 1 && hitting.count == 1 && hitting.first?.id == first.id)
    let ctx = try await l.a.observer.authorContext()
    var late = ""
    let blob = try l.a.observer.stamps.build(ctx) { o throws(AuthorError) in
      late = try o.ingest(payload: Self.payload(Row(raw: "TAILSCALE.COM", minor: 6_00, day: 9), n: 78), ingestID: String(repeating: "f", count: 64))
    }
    try await l.a.outbox.enqueue(try #require(blob).ops)
    try await l.a.observer.reproject()
    let inputs = try l.reader.rules().map {
      RuleInput(id: $0.id, patterns: $0.patterns, match: $0.match, category: $0.category, priority: $0.priority, enabled: $0.enabled, removed: $0.removed)
    }
    let categorizer = Categorizer(rules: inputs, dictionary: AccountRuntime.dictionary, categories: BuiltinCategories())
    #expect(categorizer.decide(merchantRaw: "TAILSCALE.COM", direction: .debit).category == "subscriptions")
    l.memory.update { m in for i in m.batches.indices { m.batches[i].cursor = -1 } }
    #expect(await l.author.followUp())
    #expect(try l.row(late)?.category == "subscriptions" && l.row(late)?.categorySourceRef == first.id)

    l.store.undo(changed)
    try await Mapper.eventually { try l.reader.rules().first?.category == "shopping" }
    #expect(try l.reader.rules().count == 1)
  }

  @Test func alwaysUseItOnANineSpellingGroupCountsOnlyWhatItsEightPatternsFile() async throws {
    let rows: [(String, Row)] = (1...9).flatMap { n in
      (0..<(10 - n)).map { k in ("shop\(n)", Row(raw: "SOME SHOP*REF \(n)", minor: Int64(1_000 + n * 10 + k), currency: "AED", day: 1 + (k % 9))) }
    }
    let l = try await Self.ledger(suite: "sorting.nine.learn", rows: rows)
    let filed = try #require(l.ids["shop9"]?.first)
    let token = try #require(try l.store.apply(.categorize(filed, "shopping", learnRule: true, project: nil)))
    #expect(token.title.hasPrefix("Shopping for 43 ") && token.title.hasSuffix(" payments") && token.batch, "\(token.title)")
    let left = l.ids["shop8"] ?? []
    #expect(left.count == 2 && left.allSatisfy { l.store.state.txn($0)?.needsReview == true })
    try await Mapper.eventually { try (l.ids["shop1"] ?? []).allSatisfy { try l.row($0)?.category == "shopping" } }
    try await Mapper.eventually { try l.reader.rules().count == 1 }
    #expect(try left.allSatisfy { try l.row($0)?.category == nil })
  }

  @Test func pausingARuleThatReachedBackHoldsEveryRowItFiled() async throws {
    let l = try await Self.ledger(suite: "sorting.pause", rows: Self.tailscale)
    let filed = try #require(l.ids["com"]?.first)
    try l.store.apply(.categorize(filed, "subscriptions", learnRule: true, project: nil))
    try await Mapper.eventually { try l.reader.rules().count == 1 }
    let rule = try #require(try l.reader.rules().first)
    let reached = Array(l.ids["com"]!.dropFirst()) + l.ids["inc"]! + l.ids["paypal"]!
    try await Mapper.eventually { try reached.allSatisfy { try l.row($0)?.categorySourceRef == rule.id } }
    #expect(try reached.allSatisfy { try l.row($0)?.categorySource == "rule" && l.row($0)?.needsReview == false })
    try await Mapper.eventually { l.store.state.rules.contains { $0.id == rule.id } }
    try l.store.apply(.setRuleEnabled(rule.id, false))
    try await Mapper.eventually { try reached.allSatisfy { try l.row($0)?.categorySource == "held" } }
    for id in reached {
      let r = try #require(try l.row(id))
      #expect(r.needsReview && r.categorySourceRef == rule.id && r.category == "subscriptions")
    }
    #expect(try l.row(filed)?.categorySource == "user" && l.row(filed)?.needsReview == false)
    try l.store.apply(.setRuleEnabled(rule.id, true))
    try await Mapper.eventually { try l.reader.rules().first?.enabled == true }
    _ = await l.author.followUp()
    #expect(try reached.allSatisfy { try l.row($0)?.categorySource == "held" && l.row($0)?.needsReview == true })
  }

  @Test func aBulkSortReprojectsBeforeAWaitingCategorizeReadsTheRow() async throws {
    let l = try await Self.ledger(
      suite: "sorting.serial", rows: [("a", Row(raw: "LANTERN FILM CLUB", minor: 40_00, currency: "AED", day: 1))])
    let id = try #require(l.ids["a"]?.first)
    let cloud = ModelSuggestionStageTests.Counting("cf-clef/1", answer: .category("entertainment"))
    let anchor = Mapper.anchor
    let stage = ModelSuggestionStage(
      observer: l.a.observer, outbox: l.a.outbox, cache: FMCache(l.a.context.store), dictionary: AccountRuntime.dictionary,
      onDevice: ModelSuggestionStageTests.Counting("apple-fm/27.1", answer: .unknown), cloud: cloud, onDeviceAlone: false,
      nowMs: { anchor }, appActive: { true })
    let hold = Hold()
    let serial = l.a.observer.writes
    let held = Task { try await hold.keep(serial) }
    try await Mapper.eventually { serial.isBusy }
    let pass = Task { await stage.backlogPass(BacklogSort.Memo(), dayLeft: 100) }
    try await Mapper.eventually { !cloud.calls.isEmpty }
    try await Task.sleep(for: .milliseconds(200))
    let token = try #require(try l.store.apply(.categorize(id, "dining", learnRule: false, project: nil)))
    try await Task.sleep(for: .milliseconds(100))
    hold.open()
    try await held.value
    let result = await pass.value
    #expect(result?.pass.failed == false)
    try await Mapper.eventually { try l.row(id)?.category == "dining" }
    #expect(try l.row(id)?.categorySource == "user")
    #expect(try l.reader.forkNotices(kind: "txn").isEmpty)
    l.store.undo(token)
    try await Mapper.eventually { try l.row(id)?.category == "entertainment" }
    #expect(try l.row(id)?.categorySource == "model" && l.row(id)?.needsReview == true)
  }

  static let wide: [(String, Row)] = [
    ("pick", Row(raw: "TAILSCALE.COM", minor: 6_00, day: 1)),
    ("waiting", Row(raw: "TAILSCALE INC", minor: 18_00, month: 6, day: 2)),
    ("dict", Row(raw: "TAILSCALE.COM", minor: 6_00, month: 8, day: 1)),
    ("ruled", Row(raw: "TAILSCALE INC", minor: 18_00, month: 7, day: 2)),
    ("auto", Row(raw: "PAYPAL *TAILSCALE", minor: 12_00, month: 9, day: 3)),
    ("mine", Row(raw: "TAILSCALE INC", minor: 18_00, month: 9, day: 4)),
    ("already", Row(raw: "TAILSCALE.COM", minor: 6_00, month: 5, day: 1)),
    ("split", Row(raw: "TAILSCALE.COM", minor: 6_00, month: 9, day: 5)),
    ("unverified", Row(raw: "TAILSCALE.COM", minor: 6_00, day: 5, verified: false)),
    ("refund", Row(raw: "TAILSCALE.COM", minor: 6_00, day: 7, direction: "credit")),
  ]

  static func wideLedger(suite: String, clock: MovableClock? = nil) async throws -> (Ledger, oldRule: String) {
    let l = try await Self.ledger(suite: suite, rows: Self.wide, clock: clock ?? MovableClock(ms: Mapper.anchor))
    let reader = l.reader
    let ids = l.ids
    var old = ""
    let filed = try l.a.observer.stamps.build(try await l.a.observer.authorContext()) { o throws(AuthorError) in
      old = try o.rule(OpAuthor.RuleDraft(patterns: ["tailscale"], match: .contains, category: "dining", priority: 100, origin: "manual"))
      func file(_ name: String, _ category: String, _ source: CoreReplay.CategorySource) {
        for id in ids[name] ?? [] {
          guard let v = try? reader.txn(id)?.version else { continue }
          o.categorize(txnID: id, parentVersion: v, category: category, needsReview: false, source: source)
        }
      }
      let dictionary = CoreReplay.CategorySource(kind: .dictionary, bundle: "2026.10.21-1", entry: "contains:tailscale")
      file("dict", "shopping", dictionary)
      file("ruled", "dining", CategorySource(kind: .rule, ruleID: old))
      file("auto", "shopping", CategorySource(kind: .model, model: "cf-clef/1"))
      file("mine", "dining", .user)
      file("already", "subscriptions", dictionary)
      for id in ids["split"] ?? [] {
        guard let v = try? reader.txn(id)?.version else { continue }
        o.split(txnID: id, parentVersion: v, parts: [(category: "shopping", amountMinor: 300, note: nil), (category: "dining", amountMinor: 300, note: nil)])
      }
    }
    try await l.a.outbox.enqueue(try #require(filed).ops)
    try await l.a.observer.reproject()
    clock?.set(Mapper.anchor)
    await l.store.reload()
    return (l, old)
  }

  static func sortedForYou(_ l: Ledger, _ ids: [String]) -> [SortedForYouItem] {
    SortedForYouEngine.snapshot(l.store.state, now: MayaLedger.now).items.filter { !Set($0.txnIDs).isDisjoint(with: ids) }
  }

  @Test func alwaysUseReFilesEveryEligiblePaymentOfTheMerchantInOneBatchButNotThePersonsOwn() async throws {
    let (l, old) = try await Self.wideLedger(suite: "sorting.wide", clock: MovableClock(ms: Self.weeksAgo))
    let id = { (name: String) in l.ids[name]![0] }
    let names = ["pick", "waiting", "dict", "ruled", "auto", "mine", "already", "split", "unverified", "refund"]
    let before = try Dictionary(uniqueKeysWithValues: names.map { (id($0), try #require(try l.row(id($0)))) })
    #expect(before[id("split")]?.split == true && before[id("auto")]?.categorySource == "model")
    #expect(l.store.state.txn(id("dict"))?.ruled == true && l.store.state.txn(id("mine"))?.ruled == false)
    #expect(l.store.state.txn(id("split"))?.ruled == false && l.store.state.txn(id("unverified"))?.ruled == false)
    let pending = try l.a.context.store.pendingOps().count
    let corrections = l.trust.counts.corrections

    let token = try #require(try l.store.apply(.categorize(id("pick"), "subscriptions", learnRule: true, project: nil)))
    #expect(token.title.hasPrefix("Subscriptions for all 5 ") && token.title.hasSuffix(" payments"), "\(token.title)")
    let reached = ["waiting", "dict", "ruled", "auto"].map(id)
    #expect(reached.allSatisfy { l.store.state.txn($0)?.categoryID == "subscriptions" && l.store.state.txn($0)?.filedByRule == true })
    try await Mapper.eventually { try reached.allSatisfy { try l.row($0)?.categorySource == "rule" } }
    let rule = try #require(try l.reader.rules().first { $0.origin == "learned" })
    #expect(try l.a.context.store.pendingOps().count == pending + 6)
    for r in reached {
      let row = try #require(try l.row(r))
      #expect(row.category == "subscriptions" && row.categorySourceRef == rule.id && !row.needsReview && row.reviewLane == nil)
    }
    #expect(try l.row(id("pick"))?.categorySource == "user")
    for name in ["mine", "already", "split", "unverified", "refund"] {
      let now = try #require(try l.row(id(name)))
      let was = try #require(before[id(name)])
      #expect(now.version == was.version && now.category == was.category && now.categorySource == was.categorySource, "\(name)")
    }
    #expect(token.batch)
    try await Mapper.eventually { l.memory.value.batches.last?.ruleID == rule.id }
    #expect(Set(try #require(l.memory.value.batches.last).prior.keys) == Set(reached))
    #expect(l.trust.counts.corrections == corrections && l.trust.autoFiles("shopping"))

    l.store.undo(token)
    try await Mapper.eventually { try l.row(id("dict"))?.categorySource == "dictionary" }
    try await Mapper.eventually { try (reached + [id("pick")]).allSatisfy { try l.row($0)?.categorySource != "rule" || l.row($0)?.categorySourceRef == old } }
    for name in names {
      let now = try #require(try l.row(id(name)))
      let was = try #require(before[id(name)])
      #expect(now.category == was.category && now.categorySource == was.categorySource, "\(name)")
      #expect(now.categorySourceRef == was.categorySourceRef && now.needsReview == was.needsReview, "\(name)")
    }
    try await Mapper.eventually { try l.reader.rules().allSatisfy { $0.id == old } }
    await l.store.reload()
    #expect(Self.sortedForYou(l, reached).isEmpty, "\(Self.sortedForYou(l, reached).map(\.title))")
  }

  @Test func undoAllPutsEachReachedPaymentBackExactlyAsItWas() async throws {
    let (l, old) = try await Self.wideLedger(suite: "sorting.wide.undoall", clock: MovableClock(ms: Self.weeksAgo))
    let id = { (name: String) in l.ids[name]![0] }
    let reached = ["waiting", "dict", "ruled", "auto"].map(id)
    let before = try Dictionary(uniqueKeysWithValues: reached.map { ($0, try #require(try l.row($0))) })
    #expect(Self.sortedForYou(l, reached).isEmpty)
    try l.store.apply(.categorize(id("pick"), "subscriptions", learnRule: true, project: nil))
    try await Mapper.eventually { try l.reader.rules().contains { $0.origin == "learned" } }
    let rule = try #require(try l.reader.rules().first { $0.origin == "learned" })
    try await Mapper.eventually {
      reached.allSatisfy { l.store.state.txn($0)?.ruleID == rule.id && l.store.state.txn($0)?.priorFiling != nil }
    }
    let item = try #require(SortedForYouEngine.snapshot(l.store.state, now: MayaLedger.now).items.first { $0.ruleID == rule.id })
    #expect(Set(item.txnIDs) == Set(reached))
    let token = try #require(try l.store.apply(item.undoAll))
    #expect(token.title == "4 payments put back as they were")
    let shown = l.store.state
    #expect(shown.txn(id("dict"))?.categoryID == "shopping" && shown.txn(id("dict"))?.categorySource == .dictionary)
    #expect(shown.txn(id("dict"))?.inReview == false && shown.txn(id("auto"))?.inReview == false)
    #expect(shown.txn(id("ruled"))?.ruleID == old && shown.txn(id("ruled"))?.categoryID == "dining")
    #expect(shown.txn(id("waiting"))?.inReview == true && shown.txn(id("waiting"))?.categoryID == nil)
    #expect(shown.txn(id("waiting"))?.reachable == true)
    #expect(Self.sortedForYou(l, reached).isEmpty, "\(Self.sortedForYou(l, reached).map(\.title))")
    try await Mapper.eventually { try reached.allSatisfy { try l.row($0)?.categorySourceRef != rule.id } }
    for r in reached {
      let now = try #require(try l.row(r))
      let was = try #require(before[r])
      #expect(now.category == was.category && now.categorySource == was.categorySource, "\(r)")
      #expect(now.categorySourceRef == was.categorySourceRef && now.needsReview == was.needsReview, "\(r)")
    }
    await l.store.reload()
    #expect(Self.sortedForYou(l, reached).isEmpty, "\(Self.sortedForYou(l, reached).map(\.title))")
    _ = await l.author.followUp()
    #expect(try reached.allSatisfy { try l.row($0)?.categorySourceRef != rule.id })
    l.store.undo(token)
    try await Mapper.eventually { try reached.allSatisfy { try l.row($0)?.categorySourceRef == rule.id } }
  }

  static func undoAll(_ l: Ledger, _ rule: String, _ reached: [String]) async throws -> UndoToken {
    try await Mapper.eventually {
      reached.allSatisfy { l.store.state.txn($0)?.ruleID == rule && l.store.state.txn($0)?.priorFiling != nil }
    }
    let item = try #require(SortedForYouEngine.snapshot(l.store.state, now: MayaLedger.now).items.first { $0.ruleID == rule })
    #expect(Set(reached).isSubset(of: Set(item.txnIDs)))
    let token = try #require(try l.store.apply(item.undoAll))
    #expect(token.title.hasSuffix(" put back as they were"), "\(token.title)")
    try await Mapper.eventually { try reached.allSatisfy { try l.row($0)?.categorySourceRef != rule } }
    await l.store.reload()
    return token
  }

  @Test func undoAllAfterUndoingAnUndoAllPutsEachPaymentBackAgain() async throws {
    let (l, old) = try await Self.wideLedger(suite: "sorting.wide.undoall.twice", clock: MovableClock(ms: Self.weeksAgo))
    let id = { (name: String) in l.ids[name]![0] }
    let reached = ["waiting", "dict", "ruled", "auto"].map(id)
    let before = try Dictionary(uniqueKeysWithValues: reached.map { ($0, try #require(try l.row($0))) })
    try l.store.apply(.categorize(id("pick"), "subscriptions", learnRule: true, project: nil))
    try await Mapper.eventually { try l.reader.rules().contains { $0.origin == "learned" } }
    let rule = try #require(try l.reader.rules().first { $0.origin == "learned" })
    let first = try await Self.undoAll(l, rule.id, reached)
    l.store.undo(first)
    try await Mapper.eventually { try reached.allSatisfy { try l.row($0)?.categorySourceRef == rule.id } }
    await l.store.reload()
    _ = try await Self.undoAll(l, rule.id, reached)
    for r in reached {
      let now = try #require(try l.row(r))
      let was = try #require(before[r])
      #expect(now.category == was.category && now.categorySource == was.categorySource, "\(r)")
      #expect(now.categorySourceRef == was.categorySourceRef && now.needsReview == was.needsReview, "\(r)")
    }
    let shown = l.store.state
    #expect(shown.txn(id("dict"))?.inReview == false && shown.txn(id("auto"))?.inReview == false)
    #expect(shown.txn(id("ruled"))?.ruleID == old && shown.txn(id("ruled"))?.inReview == false)
    #expect(shown.txn(id("waiting"))?.inReview == true && shown.txn(id("waiting"))?.reachable == true)
    #expect(Self.sortedForYou(l, reached).isEmpty, "\(Self.sortedForYou(l, reached).map(\.title))")
  }

  @Test func aSecondAlwaysUseAfterUndoAllKeepsEachPaymentsEarlierFilingTime() async throws {
    let (l, old) = try await Self.wideLedger(suite: "sorting.wide.again", clock: MovableClock(ms: Self.weeksAgo))
    let id = { (name: String) in l.ids[name]![0] }
    let reached = ["waiting", "dict", "ruled", "auto"].map(id)
    try l.store.apply(.categorize(id("pick"), "subscriptions", learnRule: true, project: nil))
    try await Mapper.eventually { try l.reader.rules().contains { $0.origin == "learned" } }
    let rule = try #require(try l.reader.rules().first { $0.origin == "learned" })
    _ = try await Self.undoAll(l, rule.id, reached)
    try l.store.apply(.categorize(id("pick"), "entertainment", learnRule: true, project: nil))
    try await Mapper.eventually { try reached.allSatisfy { try l.row($0)?.category == "entertainment" } }
    let again = try #require(try l.reader.rules().first { $0.category == "entertainment" })
    await l.store.reload()
    _ = try await Self.undoAll(l, again.id, reached)
    #expect(try l.row(id("dict"))?.categorySource == "dictionary" && l.row(id("auto"))?.categorySource == "model")
    #expect(try l.row(id("ruled"))?.categorySourceRef == old)
    #expect(Self.sortedForYou(l, reached).isEmpty, "\(Self.sortedForYou(l, reached).map(\.title))")
  }

  @Test func aTalabatRuleNeverReachesTalabatMart() async throws {
    let l = try await Self.ledger(suite: "sorting.talabat", rows: [
      ("talabat", Row(raw: "TALABAT DUBAI", minor: 64_50, currency: "AED", day: 1)),
      ("talabat", Row(raw: "TALABAT DUBAI", minor: 58_25, currency: "AED", month: 8, day: 3)),
      ("mart", Row(raw: "TALABAT MART DUBAI", minor: 120_00, currency: "AED", day: 2)),
      ("mart", Row(raw: "TALABAT MART", minor: 88_00, currency: "AED", month: 9, day: 4)),
    ])
    let talabat = l.ids["talabat"] ?? []
    let mart = l.ids["mart"] ?? []
    #expect(try talabat.allSatisfy { try l.row($0)?.merchantGroup == "d:talabat" })
    #expect(try mart.allSatisfy { try l.row($0)?.merchantGroup == "d:talabat mart" })
    try l.store.apply(.categorize(talabat[0], "dining", learnRule: true, project: nil))
    try await Mapper.eventually { try l.row(talabat[1])?.categorySource == "rule" }
    #expect(try l.row(talabat[1])?.category == "dining")
    #expect(try mart.allSatisfy { try l.row($0)?.category == nil && l.row($0)?.needsReview == true })
    #expect(mart.allSatisfy { l.store.state.txn($0)?.categoryID == nil })
    let inputs = try l.reader.rules().map {
      RuleInput(id: $0.id, patterns: $0.patterns, match: $0.match, category: $0.category, priority: $0.priority, enabled: $0.enabled, removed: $0.removed)
    }
    let categorizer = Categorizer(rules: inputs, dictionary: AccountRuntime.dictionary, categories: BuiltinCategories())
    #expect(categorizer.decide(merchantRaw: "TALABAT MART DUBAI", direction: .debit).category == "groceries")
  }

  @Test func aRowWithoutAGroupOrASplitRowHasNoAlwaysUseAndMakesNoRule() async throws {
    let l = try await Self.ledger(suite: "sorting.nogroup", rows: [
      ("none", Row(raw: "***", minor: 20_00, currency: "AED", day: 1)),
      ("split", Row(raw: "KITE STUDIO JLT", minor: 600, currency: "AED", day: 2)),
    ])
    let none = try #require(l.ids["none"]?.first)
    let split = try #require(l.ids["split"]?.first)
    #expect(try l.row(none)?.merchantGroup == nil)
    #expect(TransactionEngine.detail(none, l.store.state, now: MayaLedger.now)?.canAlwaysUse == false)
    #expect(TransactionEngine.detail(split, l.store.state, now: MayaLedger.now)?.canAlwaysUse == true)
    try l.store.apply(.split(split, [
      SplitLine(id: 0, categoryID: "shopping", amount: .aed(3_00)), SplitLine(id: 1, categoryID: "dining", amount: .aed(3_00)),
    ]))
    try await Mapper.eventually { try l.row(split)?.split == true }
    await l.store.reload()
    #expect(TransactionEngine.detail(split, l.store.state, now: MayaLedger.now)?.canAlwaysUse == false)
    try l.store.apply(.categorize(none, "dining", learnRule: true, project: nil))
    try await Mapper.eventually { try l.row(none)?.category == "dining" }
    #expect(try l.row(none)?.categorySource == "user")
    #expect(try l.reader.rules().isEmpty)
  }

  @Test func theBacklogMocksSpellingsAreOffTheDictionaryAndKeyAsCoreKeysThem() {
    let groups = MerchantGroup(dictionary: AccountRuntime.dictionary)
    let categorizer = Categorizer(rules: [], dictionary: AccountRuntime.dictionary, categories: BuiltinCategories())
    for s in MayaBacklog.spellings {
      #expect(categorizer.decide(merchantRaw: s.raw, direction: .debit).category == nil, "\(s.raw) is on the dictionary")
      #expect(groups.key(raw: s.raw) == s.group, "\(s.raw)")
      #expect(Canon.merchantKey(s.raw) == s.merchantKey, "\(s.raw)")
    }
  }
}


nonisolated final class Hold: Sendable {
  private let state = Mutex<(open: Bool, waiter: CheckedContinuation<Void, Never>?)>((false, nil))

  func wait() async {
    await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
      let now = state.withLock { s -> Bool in
        if s.open { return true }
        s.waiter = k
        return false
      }
      if now { k.resume() }
    }
  }

  func keep(_ serial: WriteSerial) async throws {
    try await serial.run { await wait() }
  }

  func open() {
    let k = state.withLock { s -> CheckedContinuation<Void, Never>? in
      s.open = true
      defer { s.waiter = nil }
      return s.waiter
    }
    k?.resume()
  }
}
