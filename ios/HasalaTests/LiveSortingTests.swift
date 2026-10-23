import CoreCategorize
import CoreDomain
import CoreInvariants
import CoreJSON
import CorePrimitives
import CoreProjection
import CoreReplay
import CoreStore
import CoreWire
import Foundation
import HasalaMocks
import HasalaModels
import Synchronization
import Testing

@testable import Hasala

@MainActor
@Suite("Live sorting: groups, reach-back, Not this and undo")
struct LiveSortingTests {
  typealias Mapper = LiveLedgerMapperTests

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

  static func ledger(suite: String, rows: [(String, Row)], guesses: [String: String] = [:]) async throws -> Ledger {
    let a = try Mapper.account()
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

  @Test func theMapperFillsGroupsReachAndTheGroupCard() async throws {
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
    let card = try #require(ReviewEngine.groupCard(Self.tailscaleRef, s))
    #expect(card.total == 5 && Set(card.spellings) == ["TAILSCALE.COM", "TAILSCALE INC", "PAYPAL *TAILSCALE"])
    #expect(card.leftOut.map(\.txnID) == l.ids["unverified"])
    let items = ReviewEngine.items(s)
    #expect(items.contains { if case .group(let g) = $0 { g.group == Self.tailscaleRef } else { false } })
  }

  @Test func theJourneySortsAGroupRejectsAGuessUndoesAndASecondDeviceAgrees() async throws {
    let l = try await Self.ledger(suite: "sorting.journey", rows: Self.tailscale, guesses: ["bright": "shopping"])
    let ts = (l.ids["com"] ?? []) + (l.ids["inc"] ?? []) + (l.ids["paypal"] ?? [])
    let before = try ts.map { try #require(try l.row($0)) }
    let sort = try #require(try l.store.apply(.sortGroup(Self.tailscaleRef, "subscriptions", alwaysUse: true, project: nil)))
    #expect(sort.title == "Sorted 5 Tailscale.com as Subscriptions" || sort.title.hasPrefix("Sorted 5 "))
    try await Mapper.eventually { try ts.allSatisfy { try l.row($0)?.category == "subscriptions" } }
    for id in ts {
      let r = try #require(try l.row(id))
      #expect(r.categorySource == "user" && !r.needsReview && r.reviewLane == nil)
    }
    #expect(try l.row(l.ids["unverified"]![0])?.category == nil)
    #expect(try l.row(l.ids["unverified"]![0])?.needsReview == true)
    #expect(try l.row(l.ids["refund"]![0])?.category == nil)
    let rule = try #require(try l.reader.rules().first { $0.origin == "learned" })
    #expect(rule.match == "exact" && Set(rule.patterns) == ["tailscale.com", "tailscale inc", "paypal *tailscale"])
    try await Mapper.eventually { l.store.state.sortReceipt?.ruleID == rule.id }
    let receipt = try #require(l.store.state.sortReceipt)
    #expect(receipt.count == 5 && receipt.undo == sort && receipt.categoryID == "subscriptions")
    let row = try #require(SortResultEngine.row(l.store.state, in: .month(MayaLedger.october)))
    #expect(row.otherMonths == 2 && row.canStopRule && row.detail == "Including 2 from other months")

    let bright = l.ids["bright"] ?? []
    let notThis = try #require(try l.store.apply(.notThis(Self.brightwellRef, "shopping")))
    try await Mapper.eventually { try bright.allSatisfy { try l.row($0)?.category == nil } }
    #expect(try l.reader.rejections()["n:brightwell academy"] == ["shopping"])
    #expect(try bright.allSatisfy { try l.row($0)?.categorySource == "none" && l.row($0)?.needsReview == true })
    try await Mapper.eventually { l.store.state.txn(bright[0])?.rejectedCategories == ["shopping"] }
    #expect(l.store.state.txn(bright[0])?.reviewSuggestion == nil)
    let pending = try l.a.context.store.pendingOps()
    #expect(pending.filter { $0.opType == "merchant_category_rejected" }.count == 1)

    l.store.undo(notThis)
    try await Mapper.eventually { try bright.allSatisfy { try l.row($0)?.category == "shopping" } }
    for id in bright {
      let r = try #require(try l.row(id))
      #expect(r.categorySource == "model" && r.categorySourceRef == "cf-clef/1" && r.needsReview)
    }
    #expect(try l.reader.rejections().isEmpty)

    l.store.undo(sort)
    try await Mapper.eventually { try ts.allSatisfy { try l.row($0)?.category == nil } }
    for (id, old) in zip(ts, before) {
      let r = try #require(try l.row(id))
      #expect(r.categorySource == old.categorySource && r.needsReview == old.needsReview && r.reviewLane == old.reviewLane)
    }
    try await Mapper.eventually { try l.reader.rules().isEmpty }
    try await Mapper.eventually { l.store.state.sortReceipt == nil }

    let ops = try l.a.context.store.pendingOps().map { try Self.decode($0) }
    let other = try Mapper.account()
    var rows: [FoldRow] = []
    var seq: Int64 = 0
    var blob: [Op] = []
    for op in ops {
      if op.type.travelsAlone || blob.contains(where: { $0.type.travelsAlone }) {
        if !blob.isEmpty {
          seq += 1
          rows.append(FoldRow(seq: seq, writerID: Mapper.writer.string, counter: seq, outcome: .opened(plaintext: Data(try OpCodec.encodeBlobOps(blob)), ops: blob)))
        }
        blob = []
      }
      blob.append(op)
    }
    if !blob.isEmpty {
      seq += 1
      rows.append(FoldRow(seq: seq, writerID: Mapper.writer.string, counter: seq, outcome: .opened(plaintext: Data(try OpCodec.encodeBlobOps(blob)), ops: blob)))
    }
    let state = try LedgerFold.page(rows, onto: State())
    #expect(state.anomalies.isEmpty)
    try other.projection.project(state, pending: [], writerID: Mapper.writer.string, dictionary: AccountRuntime.dictionary, projectedAtMs: Mapper.anchor)
    let mapped = try LedgerStateMapper.map(other.projection.reader, context: Mapper.context())
    for id in ts + bright + (l.ids["unverified"] ?? []) {
      #expect(mapped.txn(id)?.categoryID == l.store.state.txn(id)?.categoryID)
      #expect(mapped.txn(id)?.needsReview == l.store.state.txn(id)?.needsReview)
      #expect(mapped.txn(id)?.reachable == l.store.state.txn(id)?.reachable)
    }
    #expect(try other.projection.reader.rejections().isEmpty)
    #expect(state.merchantRejections.values.allSatisfy { !$0.rejected })
  }

  @Test func alwaysUseItFromOneRowReachesTheGroupWithExactPatternsAndUndoesExactly() async throws {
    let l = try await Self.ledger(suite: "sorting.learn", rows: Self.tailscale, guesses: ["paypal": "shopping"])
    let paypal = try #require(l.ids["paypal"]?.first)
    let com = l.ids["com"] ?? []
    let inc = l.ids["inc"] ?? []
    let token = try #require(try l.store.apply(.categorize(com[0], "subscriptions", learnRule: true, project: nil)))
    #expect(token.title == "Sorted 5 Tailscale as Subscriptions" || token.title.hasPrefix("Sorted 5 "))
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
    try await Mapper.eventually { l.store.state.sortReceipt?.count == 5 }

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
    let ref = MerchantGroupRef(key: "n:some shop", direction: .out)
    let token = try #require(try l.store.apply(.sortGroup(ref, "shopping", alwaysUse: true, project: nil)))
    try await Mapper.eventually { try (l.ids["shop"] ?? []).allSatisfy { try l.row($0)?.category == "shopping" } }
    let rule = try #require(try l.reader.rules().first)
    #expect(rule.patterns.count == 8 && rule.defect == nil)
    #expect(try l.reader.forkNotices(kind: "rule").isEmpty)
    #expect(token.title.hasPrefix("Sorted 45 "))
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

  @Test func theResultRowSurvivesARelaunchWithoutUndoAndCanBeDismissed() async throws {
    let l = try await Self.ledger(suite: "sorting.relaunch", rows: Self.tailscale)
    let token = try #require(try l.store.apply(.sortGroup(Self.tailscaleRef, "subscriptions", alwaysUse: true, project: nil)))
    try await Mapper.eventually { l.store.state.sortReceipt?.ruleID != nil }
    #expect(l.store.state.sortReceipt?.undo == token)
    let relaunched = LiveLedgerStore(
      reader: l.a.projection.reader,
      author: LedgerEditAuthor(observer: l.a.observer, outbox: l.a.outbox, memory: SortKeeper(store: SortMemoryStore(l.a.context.store)), trust: l.trust),
      profile: Mapper.context().profile, prefs: DevicePrefsStore(defaults: UserDefaults(suiteName: "sorting.relaunch")!), clock: { MayaLedger.now })
    await relaunched.reload()
    let receipt = try #require(relaunched.state.sortReceipt)
    #expect(receipt.undo == nil && receipt.ruleID != nil && receipt.count == 5)
    let row = try #require(SortResultEngine.row(relaunched.state))
    #expect(row.undo == nil && row.canStopRule)
    try relaunched.apply(.dismissSortReceipt)
    #expect(relaunched.state.sortReceipt == nil)
    try await Mapper.eventually { SortKeeper(store: SortMemoryStore(l.a.context.store)).value.receipt == nil }
    await relaunched.reload()
    #expect(relaunched.state.sortReceipt == nil)
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

  @Test func undoingAGroupSortWithAProjectTakesTheProjectOffEveryPayment() async throws {
    let l = try await Self.ledger(suite: "sorting.project", rows: Self.tailscale)
    let project = l.store.newProjectID()
    try l.store.apply(.saveProject(project, ProjectDraft(name: "Home lab")))
    try await Mapper.eventually { try l.reader.projects().contains { $0.id == project } }
    await l.store.reload()
    let ts = (l.ids["com"] ?? []) + (l.ids["inc"] ?? []) + (l.ids["paypal"] ?? [])
    let token = try #require(try l.store.apply(.sortGroup(Self.tailscaleRef, "subscriptions", alwaysUse: false, project: project)))
    #expect(ts.allSatisfy { l.store.state.txn($0)?.projectID == project })
    try await Mapper.eventually { try ts.allSatisfy { try l.row($0)?.projectID == project && l.row($0)?.category == "subscriptions" } }
    l.store.undo(token)
    try await Mapper.eventually { try ts.allSatisfy { try l.row($0)?.projectID == nil && l.row($0)?.category == nil } }
    await l.store.reload()
    #expect(ts.allSatisfy { l.store.state.txn($0)?.projectID == nil })
  }

  @Test func alwaysUseItOnANineSpellingGroupCountsOnlyWhatItsEightPatternsFile() async throws {
    let rows: [(String, Row)] = (1...9).flatMap { n in
      (0..<(10 - n)).map { k in ("shop\(n)", Row(raw: "SOME SHOP*REF \(n)", minor: Int64(1_000 + n * 10 + k), currency: "AED", day: 1 + (k % 9))) }
    }
    let l = try await Self.ledger(suite: "sorting.nine.learn", rows: rows)
    let filed = try #require(l.ids["shop9"]?.first)
    let token = try #require(try l.store.apply(.categorize(filed, "shopping", learnRule: true, project: nil)))
    #expect(token.title.hasPrefix("Sorted 43 "), "\(token.title)")
    #expect(l.store.state.sortReceipt?.count == 43)
    let left = l.ids["shop8"] ?? []
    #expect(left.count == 2 && left.allSatisfy { l.store.state.txn($0)?.needsReview == true })
    try await Mapper.eventually { try (l.ids["shop1"] ?? []).allSatisfy { try l.row($0)?.category == "shopping" } }
    try await Mapper.eventually { l.store.state.sortReceipt?.ruleID != nil }
    #expect(l.store.state.sortReceipt?.count == 43)
    #expect(try left.allSatisfy { try l.row($0)?.category == nil })
  }

  @Test func undoingANotThisTakesBackTheCorrectionsItCounted() async throws {
    let l = try await Self.ledger(suite: "sorting.trust.undo", rows: Self.tailscale)
    let bright = l.ids["bright"] ?? []
    let reader = l.reader
    let filed = try l.a.observer.stamps.build(try await l.a.observer.authorContext()) { o throws(AuthorError) in
      for id in bright {
        guard let v = try? reader.txn(id)?.version else { continue }
        o.categorize(txnID: id, parentVersion: v, category: "shopping", needsReview: false, source: CategorySource(kind: .model, model: "cf-clef/1"))
      }
    }
    try await l.a.outbox.enqueue(try #require(filed).ops)
    try await l.a.observer.reproject()
    await l.store.reload()
    #expect(l.trust.autoFiles("shopping"))
    let token = try #require(try l.store.apply(.notThis(Self.brightwellRef, "shopping")))
    try await Mapper.eventually { try bright.allSatisfy { try l.row($0)?.category == nil } }
    #expect(!l.trust.autoFiles("shopping"))
    l.store.undo(token)
    try await Mapper.eventually { try bright.allSatisfy { try l.row($0)?.category == "shopping" } }
    try await Mapper.eventually { l.trust.autoFiles("shopping") }
    #expect(l.trust.counts.corrections["shopping"] == nil)
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
      nowMs: { anchor })
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

  @Test func aNotThisKeepsTheRejectedCloudflareGuessSoNoSweepSendsTheNameAgain() async throws {
    let l = try await Self.ledger(suite: "sorting.kept", rows: Self.tailscale, guesses: ["bright": "shopping"])
    let bright = l.ids["bright"] ?? []
    let cache = FMCache(l.a.context.store)
    let subject = Canon.subject("BRIGHTWELL ACADEMY FZE")
    #expect(try cache.keptAnswer(subject: subject, modelTag: "cf-clef/1") == nil)
    _ = try #require(try l.store.apply(.notThis(Self.brightwellRef, "shopping")))
    try await Mapper.eventually { try bright.allSatisfy { try l.row($0)?.category == nil } }
    try await Mapper.eventually { try cache.keptAnswer(subject: subject, modelTag: "cf-clef/1") == "shopping" }
    let cloud = ModelSuggestionStageTests.Counting("cf-clef/1", answer: .category("shopping"))
    let device = ModelSuggestionStageTests.Counting("apple-fm/27.1", answer: .unknown)
    let anchor = Mapper.anchor
    let stage = ModelSuggestionStage(
      observer: l.a.observer, outbox: l.a.outbox, cache: cache, dictionary: AccountRuntime.dictionary, onDevice: device, cloud: cloud,
      onDeviceAlone: false, nowMs: { anchor + 400 * 86_400_000 })
    _ = await stage.run(.foreground)
    #expect(!cloud.calls.contains(subject))
    #expect(device.calls.contains(subject))
    _ = await stage.backlogPass(BacklogSort.Memo(), dayLeft: 100)
    #expect(!cloud.calls.contains(subject))
    #expect(try bright.allSatisfy { try l.row($0)?.category == nil })
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
