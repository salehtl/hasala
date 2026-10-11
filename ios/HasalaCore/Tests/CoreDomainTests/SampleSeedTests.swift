// The sample-data loader (SampleSeed): the bundled seed and its manifest, the
// document format, the month shift to the latest 10th at 13:40, the dropped
// future, the fresh ids of every load, the `sample-<n>` message ids, the
// 200-op blobs, and a clean fold of the whole seed with the scenario's shape.
import CoreJSON
import CorePrimitives
import CoreReplay
import CoreResources
import CoreTestSupport
import CoreTime
import CoreWire
import Foundation
import Testing

@testable import CoreDomain

@Suite("SampleSeed")
struct SampleSeedTests {
  static let anchor: Int64 = now  // 2026-10-10T09:40:00Z, 13:40 in Dubai
  static let bootstrapWriter = "ios-1b2c3d4e-5f60-4b7c-8d9e-0f1a2b3c4d5e"

  static func context(at ms: Int64, seed: String = "sample") -> AuthorContext {
    AuthorContext(writerID: w, nowMs: ms, ownLastMs: nil, maxAuthored: [:], random: SeededRandom(seed: seed))
  }

  static func ms(_ s: String) -> Int64 { try! parseInstantMs(s) }

  /// The gate passed (a review account with an empty ledger).
  static let permit = try! SampleSeed.permit(reviewAccount: true, holdsTransactions: false, sampleLoaded: false)

  /// The account's open (04 §6.2): home currency and the USD rate, then the seed.
  static func folded(_ blobs: [AuthoredBlob]) throws -> State {
    var s = State()
    var boot = OpAuthor(AuthorContext(writerID: bootstrapWriter, nowMs: anchor - 86_400_000, ownLastMs: nil, maxAuthored: [:], random: Counter()))
    boot.setHomeCurrency("AED")
    try boot.setRate(currency: "USD", rateMicro: 3_672_500)
    try Replay.foldOps(try boot.build().ops, seq: 1, writerID: bootstrapWriter, into: &s)
    for (i, b) in blobs.enumerated() { try Replay.foldOps(b.ops, seq: Int64(i + 2), writerID: w, into: &s) }
    return s
  }

  @Test("the bundled seed is the manifest's, and its document is canonical")
  func bundled() throws {
    let data = try SampleSeed.bundled()
    #expect(Hex.encode(sha256(data)) == SampleManifest.sha256)
    let doc = try SampleSeed.Document(json: data)
    #expect(doc.name == SampleManifest.name && doc.anchor == "2026-10-10T09:40:00.000Z")
    #expect(doc.encoded() == data)
    #expect(!doc.ops.contains { $0.type == .homeCurrencySet || $0.type == .rateSet })
  }

  @Test("the gate (AT-34): only a review account with no transaction and no sample gets a permit")
  func gate() throws {
    func refusal(_ review: Bool?, _ txns: Bool, _ sample: Bool) -> SampleSeedRefusal? {
      do {
        _ = try SampleSeed.permit(reviewAccount: review, holdsTransactions: txns, sampleLoaded: sample)
        return nil
      } catch {
        guard case .refused(let r) = error else { return nil }
        return r
      }
    }
    #expect(refusal(true, false, false) == nil)
    for review in [false, nil] as [Bool?] {
      for txns in [false, true] {
        for sample in [false, true] { #expect(refusal(review, txns, sample) == .notReviewAccount) }
      }
    }
    #expect(refusal(true, true, false) == .hasTransactions)
    #expect(refusal(true, true, true) == .alreadyLoaded)
    #expect(refusal(true, false, true) == .alreadyLoaded)
    #expect(SampleSeed.isSampleMessageID("sample-12") && SampleSeed.isSampleMessageID("sample-"))
    #expect(!SampleSeed.isSampleMessageID("18f2a3b4c5d6e7f8") && !SampleSeed.isSampleMessageID(nil) && !SampleSeed.isSampleMessageID("Sample-1"))
  }

  @Test("the target: the latest 10th at 13:40 (Dubai) at or before now, in whole months")
  func target() {
    let t = { (now: String) in SampleSeed.target(anchorMs: Self.anchor, nowMs: Self.ms(now)) }
    #expect(t("2026-10-10T09:40:00.000Z")! == (0, Self.anchor))
    #expect(t("2026-10-12T00:00:00.000Z")! == (0, Self.anchor))
    #expect(t("2026-10-10T09:39:59.999Z")! == (-1, Self.ms("2026-09-10T09:40:00.000Z")))
    #expect(t("2026-11-15T12:00:00.000Z")! == (1, Self.ms("2026-11-10T09:40:00.000Z")))
    #expect(t("2027-01-09T20:00:00.000Z")! == (2, Self.ms("2026-12-10T09:40:00.000Z")))  // 10 Jan 00:00 local
    // An anchor on the 31st clamps to a short month's last day.
    let a31 = Self.ms("2026-10-31T09:40:00.000Z")
    #expect(SampleSeed.target(anchorMs: a31, nowMs: Self.ms("2026-11-30T12:00:00.000Z"))! == (1, Self.ms("2026-11-30T09:40:00.000Z")))
  }

  @Test("at the anchor: every op authored, fresh ids, sample message ids, nothing shifted")
  func atAnchor() throws {
    let data = try SampleSeed.bundled()
    let doc = try SampleSeed.Document(json: data)
    let blobs = try SampleSeed.batches(data, nowMs: Self.anchor, context: Self.context(at: Self.anchor), permit: Self.permit)
    let ops = blobs.flatMap(\.ops)
    #expect(ops.count == doc.ops.count)
    #expect(blobs.allSatisfy { $0.ops.count <= SampleSeed.maxOpsPerBatch })
    let text = ops.map { JSONWriter().string($0.payload) + ($0.entity?.id ?? "") + ($0.ingestID ?? "") }.joined()
    #expect(!text.contains("\"@") && !ops.contains { $0.entity?.id.hasPrefix("@") == true })
    let messages = ops.compactMap { $0.payload["provenance"]?["message_id"]?.stringValue }
    #expect(!messages.isEmpty && messages == (1...messages.count).map { "sample-\($0)" })
    let posted = ops.filter { $0.type == .txnIngested }.compactMap { $0.payload["posted_at"]?.stringValue }
    let docPosted = doc.ops.filter { $0.type == .txnIngested }.compactMap { $0.payload["posted_at"]?.stringValue }
    #expect(posted == docPosted)
    // Stamps strictly increase across the blobs.
    let stamps = ops.map { Self.ms($0.authoredAt) }
    #expect(zip(stamps, stamps.dropFirst()).allSatisfy { $0 < $1 })

    // A second load (another device, another day) never collides.
    let again = try SampleSeed.batches(data, nowMs: Self.anchor, context: Self.context(at: Self.anchor, seed: "other"), permit: Self.permit)
    let ids = Set(ops.compactMap(\.entity?.id) + ops.compactMap(\.ingestID))
    let ids2 = Set(again.flatMap(\.ops).compactMap(\.entity?.id) + again.flatMap(\.ops).compactMap(\.ingestID))
    let literal = Set(ops.filter { $0.type == .billSet }.compactMap(\.entity?.id))  // bd_ ids are derived, by design
    #expect(ids.intersection(ids2) == literal)
  }

  @Test("loaded on 15 November: everything moves one month; loaded before 13:40 on the 10th: one month back")
  func shifted() throws {
    let data = try SampleSeed.bundled()
    let nov = try SampleSeed.batches(data, nowMs: Self.ms("2026-11-15T12:00:00.000Z"), context: Self.context(at: Self.ms("2026-11-15T12:00:00.000Z")), permit: Self.permit)
      .flatMap(\.ops)
    let posted = nov.filter { $0.type == .txnIngested }.compactMap { $0.payload["posted_at"]?.stringValue }
    #expect(posted.contains("2026-11-10T09:20:00.000Z"))  // Talabat, 13:20 on the 10th
    #expect(!posted.contains { $0.hasPrefix("2026-09") } && posted.contains { $0.hasPrefix("2026-10-13") })
    #expect(nov.filter { $0.type == .budgetSet }.allSatisfy { $0.payload["month"]?.stringValue == "2026-11" })
    let project = try #require(nov.first { $0.type == .projectDefined })
    #expect(project.payload["starts_on"]?.stringValue == "2027-01-14" && project.payload["ends_on"]?.stringValue == "2027-01-28")
    let goal = try #require(nov.first { $0.type == .goalDefined })
    #expect(goal.payload["target_month"]?.stringValue == "2027-02")
    #expect(goal.payload["source"]?["since"]?.stringValue == "2026-11-01")

    let early = Self.ms("2026-10-10T09:00:00.000Z")  // 13:00 local: the target is 10 September
    let sep = try SampleSeed.batches(data, nowMs: early, context: Self.context(at: early), permit: Self.permit).flatMap(\.ops)
    let sepPosted = sep.filter { $0.type == .txnIngested }.compactMap { $0.payload["posted_at"]?.stringValue }
    #expect(sepPosted.contains("2026-09-10T09:20:00.000Z"))
    #expect(sep.count == nov.count)  // nothing in the seed is after its anchor
  }

  @Test("rows after the target are dropped; placeholders, unknown members and dates are checked")
  func documentRules() throws {
    func doc(_ ops: [SampleSeed.Draft]) -> Data {
      SampleSeed.Document(name: "t", anchor: "2026-10-10T09:40:00.000Z", ops: ops).encoded()
    }
    func txn(_ name: String, _ at: String, note: String? = nil) -> [SampleSeed.Draft] {
      var out = [
        SampleSeed.Draft(
          type: .txnIngested, entity: SampleSeed.EntityRefDraft(kind: "txn", id: "@txn:\(name)"), ingestID: "@ingest:\(name)",
          payload: JSONObject([
            ("amount_minor", .string("100")), ("currency", .string("AED")), ("direction", .string("debit")), ("posted_at", .string(at)),
            ("merchant_raw", .string("@home store")), ("last4", .string("")), ("needs_review", .bool(true)),
          ]), at: at)
      ]
      if let note {
        out.append(
          SampleSeed.Draft(
            type: .txnAnnotated, payload: JSONObject([("txn_id", .string("@txn:\(name)")), ("set", .object(JSONObject([("note", .string(note))])))]),
            at: at))
      }
      return out
    }
    let data = doc(txn("a", "2026-10-10T09:00:00.000Z", note: "@not a placeholder") + txn("future", "2026-10-10T10:00:00.000Z"))
    let ops = try SampleSeed.batches(data, nowMs: Self.anchor, context: Self.context(at: Self.anchor), permit: Self.permit).flatMap(\.ops)
    #expect(ops.count == 2)
    #expect(ops[0].payload["merchant_raw"]?.stringValue == "@home store")
    #expect(ops[1].payload["txn_id"]?.stringValue == ops[0].entity?.id)
    #expect(ops[1].payload["set"]?["note"]?.stringValue == "@not a placeholder")

    var bad = txn("b", "2026-10-01T09:00:00.000Z")
    bad[0].payload["merchant_raw"] = .string("@vendor:acme")
    #expect(throws: SampleSeedError.malformed("placeholder")) {
      try SampleSeed.batches(doc(bad), nowMs: Self.anchor, context: Self.context(at: Self.anchor), permit: Self.permit)
    }
    let extra = Data(String(decoding: doc(txn("c", "2026-10-01T09:00:00.000Z")), as: UTF8.self)
      .replacingOccurrences(of: "{\"at\":", with: "{\"x\":1,\"at\":").utf8)
    #expect(throws: SampleSeedError.self) { try SampleSeed.Document(json: extra) }
    #expect(throws: SampleSeedError.self) { try SampleSeed.Document(json: Data("{}".utf8)) }
    // A shift that leaves 2000-2099 is refused, not wrapped.
    let old = doc(txn("d", "2000-01-05T09:00:00.000Z") + [
      SampleSeed.Draft(type: .budgetSet, payload: JSONObject([("category_id", .string("rent")), ("month", .string("2000-01")), ("amount_minor", .string("1")), ("scope", .string("only"))]), at: "2000-01-05T09:00:00.000Z")
    ])
    #expect(throws: SampleSeedError.self) {
      try SampleSeed.batches(old, nowMs: Self.ms("2000-01-05T09:00:00.000Z"), context: Self.context(at: Self.anchor), permit: Self.permit)
    }
  }

  @Test("at most 200 ops per blob, in order")
  func chunks() throws {
    var drafts: [SampleSeed.Draft] = []
    for i in 0..<450 {
      drafts.append(
        SampleSeed.Draft(
          type: .merchantNamed, payload: JSONObject([("merchant_key", .string("m\(i)")), ("display_name", .string("M\(i)"))]),
          at: "2026-10-01T09:00:00.000Z"))
    }
    let data = SampleSeed.Document(name: "t", anchor: "2026-10-10T09:40:00.000Z", ops: drafts).encoded()
    let blobs = try SampleSeed.batches(data, nowMs: Self.anchor, context: Self.context(at: Self.anchor), permit: Self.permit)
    #expect(blobs.map(\.ops.count) == [200, 200, 50])
    #expect(blobs.flatMap(\.ops).map { $0.payload["merchant_key"]?.stringValue } == (0..<450).map { "m\($0)" })
    #expect(Self.ms(blobs[1].ops[0].authoredAt) > blobs[0].lastAuthoredMs)
  }

  @Test("the whole seed folds clean: Maya's month, bills, accounts and plan")
  func folds() throws {
    let data = try SampleSeed.bundled()
    let s = try Self.folded(try SampleSeed.batches(data, nowMs: Self.anchor, context: Self.context(at: Self.anchor), permit: Self.permit))
    #expect(s.anomalies.isEmpty, "\(s.anomalies)")
    #expect(s.unreadable.isEmpty)
    let live = s.txns.values.filter(\.isLive)
    #expect(live.count == 30)
    #expect(live.filter { $0.postedAt.hasPrefix("2026-10") || $0.postedAt.hasPrefix("2026-09-30T2") }.count == 26)
    #expect(live.filter(\.needsReview).count == 6)
    #expect(live.allSatisfy { $0.amountHomeMinor != nil })
    #expect(s.bills.count == 8 && s.bills.values.allSatisfy { $0.status == "active" })
    #expect(s.accounts.count == 4 && s.cards.count == 2 && s.checkins.count == 4)
    #expect(s.cards["enbd\u{0}4412"]?.account == "ac_57aa6a554d52afd8222b3922452ddf79")
    #expect(s.projects.values.map(\.name) == ["Japan trip"])
    #expect(s.goals.values.map(\.name) == ["Emergency fund"])
    #expect(s.plan.incomeSources.count == 1 && s.plan.incomeSources.values.first?.amountMinor == 2_500_000)
    let assigned = s.plan.cells.values.compactMap { $0["2026-10"]?.latestSet }.reduce(0, +)
    #expect(assigned == 2_400_000)
    #expect(s.rules.count == 6)
    #expect(s.billResolutions.values.allSatisfy { $0.resolution == "paid" })
  }
}
