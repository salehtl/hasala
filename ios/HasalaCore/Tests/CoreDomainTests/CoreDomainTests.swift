// Unit tests for CoreDomain: the author rule (03c §13 base-10), ULIDs, the
// trust author (trust-author.json, trust-06), prettify (merch-04 subset),
// Setup 2 seeding (03a §7.6, F5), payday attribution (03a §6.3), review lanes
// and OpAuthor's refusals. Plan figures are pinned end to end by the Maya
// scenario in CoreProjectionTests.
import CoreCategorize
import CoreJSON
import CorePrimitives
import CoreReplay
import CoreTime
import CoreWire
import Foundation
import HasalaText
import Testing

@testable import CoreDomain

final class Counter: RandomSource, @unchecked Sendable {
  private let lock = NSLock()
  private var n: UInt8 = 0
  func fill(_ buffer: UnsafeMutableRawBufferPointer) throws(PrimitivesError) {
    lock.lock()
    defer { lock.unlock() }
    for i in 0..<buffer.count {
      n &+= 1
      buffer[i] = n
    }
  }
}

let w = "ios-0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"
let now: Int64 = 1_791_625_200_000
let hour: Int64 = 3_600_000

func ctx(own: Int64? = nil, seen: [String: Int64] = [:]) -> AuthorContext {
  AuthorContext(writerID: w, nowMs: now, ownLastMs: own, maxAuthored: seen, random: Counter())
}

@Suite("CoreDomain")
struct CoreDomainTests {
  @Test("base-10: the authored_at rule")
  func authoredAt() throws {
    #expect(ctx().baseMs == now)
    #expect(ctx(seen: ["ios-b": now + 5_000]).baseMs == now + 5_001)
    #expect(ctx(own: now + 7_000).baseMs == now + 7_001)
    #expect(ctx(seen: ["ios-b": now + 25 * hour]).baseMs == now)
    #expect(ctx(seen: ["ios-b": now + 25 * hour]).clockAheadWriters == 1)
    #expect(ctx(seen: ["ios-b": now + 23 * hour]).baseMs == now + 23 * hour + 1)
    #expect(ctx(own: now + 72 * hour).baseMs == now + 24 * hour + 1)
    #expect(ctx(own: now + 72 * hour, seen: [w: now + 72 * hour]).clockAheadWriters == 1)
    #expect(ctx(own: now + 23 * hour).baseMs == now + 23 * hour + 1)
    var a = OpAuthor(ctx())
    a.renameMerchant(raw: "A", to: "B")
    a.renameMerchant(raw: "C", to: "D")
    a.renameMerchant(raw: "E", to: "F")
    let blob = try a.build()
    #expect(blob.ops.map(\.authoredAt) == (0..<3).map { Instant.iso(now + $0)! })
    #expect(blob.lastAuthoredMs == now + 2)
    #expect(blob.ops.allSatisfy { $0.v == 4 && Grammar.isULID($0.opID) })
  }

  @Test("ULIDs: 26 Crockford digits, time first")
  func ulid() throws {
    let a = try Ulid.mint(ms: 1, random: Counter())
    let b = try Ulid.mint(ms: now, random: Counter())
    #expect(Grammar.isULID(a) && Grammar.isULID(b))
    #expect(compareUTF8(a, b) < 0)
    #expect(try Ulid.mint(ms: 0, random: Counter()).hasPrefix("0000000000"))
  }

  @Test("trust-author: normalization and refusals; trust-06 query domains")
  func trust() throws {
    #expect(try SenderTrust.normalize(" Alerts@EmiratesNBD.com. ").get() == "emiratesnbd.com")
    var a = OpAuthor(ctx())
    for (d, reason) in [("gmail.com", "forwarder_domain"), ("googlemail.com", "forwarder_domain"), ("co.ae", "shared_suffix"), ("bänk.ae", "non_ascii_domain")] {
      #expect(throws: AuthorError.refused(reason)) { try a.setSenderTrust(typed: d, trusted: true, currentTrusted: []) }
    }
    let hundred = (0..<100).map { "bank\($0).ae" }
    #expect(throws: AuthorError.refused("too_many_senders")) { try a.setSenderTrust(typed: "more.ae", trusted: true, currentTrusted: hundred) }
    try a.setSenderTrust(typed: "gmail.com", trusted: false, currentTrusted: [])

    var s = State()
    var b = OpAuthor(ctx())
    for d in ["emiratesnbd.com", "mail.emiratesnbd.com", "dib.ae", "bank.co.ae"] { try b.setSenderTrust(typed: d, trusted: true, currentTrusted: []) }
    try Replay.foldOps(try b.build().ops, seq: 1, writerID: w, into: &s)
    // A forwarder written by hand folds, but is not effective (trust-03).
    let hand = #"{"v":4,"kind":"ops","ops":[{"v":4,"type":"sender_trust_set","op_id":"01JC0000000000000000000001","authored_at":"2026-10-01T00:00:00.000Z","parent_version":null,"payload":{"domain":"gmail.com","trusted":true}}]}"#
    try Replay.foldOps(try OpCodec.decodeBlobOps(Array(hand.utf8)), seq: 2, writerID: w, into: &s)
    #expect(SenderTrust.queryDomains(s) == ["bank.co.ae", "dib.ae", "emiratesnbd.com", "mail.emiratesnbd.com"])
    #expect(SenderTrust.isTrusted("alerts.dib.ae", SenderTrust.queryDomains(s)))
    #expect(!SenderTrust.isTrusted("evil-dib.ae", SenderTrust.queryDomains(s)))
  }

  @Test("merch-04: prettify")
  func prettify() {
    let cases: [(String, String)] = [
      ("CARREFOUR MOE", "Carrefour Moe"), ("DU TELECOM 0423", "DU Telecom 0423"), ("ENOC  1043", "Enoc 1043"),
      ("Careem Hala", "Careem Hala"), ("ADCB ATM DXB", "ADCB ATM DXB"), ("STARBUCKS-DIFC", "Starbucks-difc"), ("كارفور", "كارفور"),
      ("netflix.com", "netflix.com"),
    ]
    for (raw, want) in cases { #expect(MerchantDisplay.prettify(raw) == want, "\(raw)") }
    #expect(MerchantDisplay.name(raw: "TALABAT", renamed: "Talabat (food)", dictionary: "talabat") == "Talabat (food)")
    #expect(MerchantDisplay.name(raw: "TALABAT", renamed: nil, dictionary: "talabat") == "talabat")
  }

  @Test("F5: Setup 2 seeding at 25,000 and 18,333.33")
  func seeding() {
    let a = PlanEngine.seed(income: 2_500_000, split: nil)
    #expect(a.buckets == [.need: 1_250_000, .want: 750_000, .saving: 500_000])
    #expect(a.categories.map(\.1) == [750_000, 87_500, 225_000, 87_500, 37_500, 62_500, 180_000, 67_500, 165_000, 262_500, 75_000, 300_000, 200_000])
    let b = PlanEngine.seed(income: 1_833_333, split: BudgetSplit(need: 50, want: 30, saving: 20))
    #expect(b.buckets == [.need: 916_666, .want: 550_000, .saving: 366_667])
    #expect(b.categories.map(\.1) == [549_999, 64_167, 165_000, 64_166, 27_500, 45_834, 132_000, 49_500, 121_000, 192_500, 55_000, 220_000, 146_667])
    #expect(OpAuthor.evenAmounts(10_000, 3) == [3_333, 3_333, 3_334])
  }

  @Test("03a §6.3: payday attribution")
  func payday() {
    var plan = PlanState()
    plan.incomeSources["s"] = IncomeSource(
      id: "s", name: "Salary", categoryID: "salary", amountMinor: 2_500_000, payday: 1, active: true, write: PlanWrite(opID: "", writerID: "", atMs: 0))
    let line = MoneyLine(
      txnID: "t", category: "salary", direction: "credit", localDate: CivilDate(year: 2026, month: 10, day: 30)!, signedHome: 2_500_000,
      flow: .income, confirmed: true)
    let e = PlanEngine(plan: plan, taxonomy: TaxonomyView(TaxonomyV1.builtins), lines: [line], today: CivilDate(year: 2026, month: 10, day: 31)!)
    #expect(e.attributedMonth(line) == CivilMonth(year: 2026, month: 11))
    #expect(e.received(CivilMonth(year: 2026, month: 11)!, "salary") == 2_500_000)
    plan.incomeSources["s"]!.payday = 28
    let sep = MoneyLine(
      txnID: "t", category: "salary", direction: "credit", localDate: CivilDate(year: 2026, month: 9, day: 28)!, signedHome: 2_500_000,
      flow: .income, confirmed: true)
    let e2 = PlanEngine(plan: plan, taxonomy: TaxonomyView(TaxonomyV1.builtins), lines: [sep], today: CivilDate(year: 2026, month: 10, day: 10)!)
    #expect(e2.attributedMonth(sep) == CivilMonth(year: 2026, month: 9))
    #expect(e2.income(CivilMonth(year: 2026, month: 9)!).total == 2_500_000)
  }

  @Test("OpAuthor refuses an op the fold would refuse")
  func authorRefusals() throws {
    var a = OpAuthor(ctx())
    a.categorize(txnID: "01JC0000000000000000000001", parentVersion: 1, category: "Groceries")
    #expect(throws: AuthorError.self) { try a.build() }
    var b = OpAuthor(ctx())
    #expect(throws: AuthorError.refused("the split must add up to 100")) { try b.setBudgetTemplate(need: 60, want: 30, saving: 20) }
    #expect(try b.build().ops.isEmpty)
  }

  @Test("review lanes follow 03c §3.7's precedence")
  func lanes() throws {
    var s = State()
    var a = OpAuthor(ctx())
    let id = try a.manualEntry(amountMinor: 1_000, currency: "AED", direction: "debit", localWallMs: now, merchant: "CAFE", category: nil)
    try Replay.foldOps(try a.build().ops, seq: 1, writerID: w, into: &s)
    var t = try #require(s.txns[id])
    #expect(t.entryMethod == "manual" && !t.needsReview)
    #expect(ReviewQueue.lane(t) == .uncategorized)
    t.categorySource = CategorySource(kind: .model, model: "apple-fm/26.0")
    t.category = "dining"
    #expect(ReviewQueue.lane(t) == .uncategorized)
    t.needsReview = true
    #expect(ReviewQueue.lane(t) == .needsReview)
    t.possibleDuplicateOf = "x"
    #expect(ReviewQueue.lane(t) == .duplicate)
    t.annotations["archived"] = Keyed("user", opID: "o")
    #expect(ReviewQueue.lane(t) == nil)
  }

  @Test("mailbox ingest from a whole payload, decision fields, and the writer checkpoint")
  func mailboxAndCheckpoint() throws {
    var a = OpAuthor(ctx())
    var p = CoreJSON.JSONObject([
      ("amount_minor", .string("34215")), ("currency", .string("AED")), ("direction", .string("debit")),
      ("posted_at", .string("2026-10-09T15:12:00.000Z")), ("merchant_raw", .string("CARREFOUR MOE")), ("last4", .string("4412")),
      ("tier", .string("template")), ("needs_review", .bool(false)), ("entry_method", .string("mailbox")), ("bank", .string("enbd")),
      ("posted_precision", .string("time")),
    ])
    let d = Decision(category: "groceries", source: .dictionary(bundle: "2026.10.11-1", entry: "contains:carrefour"), display: nil, suggested: nil)
    for (k, v) in OpAuthor.decisionFields(d) { p[k] = v }
    let id = try a.ingest(payload: p, ingestID: String(repeating: "a", count: 64))
    try a.writerCheckpoint([CheckpointHead(writerID: w, stream: "hot", counter: "3", hash: String(repeating: "b", count: 64))])
    let ops = try a.build().ops
    #expect(ops.map(\.type) == [.txnIngested, .writerCheckpoint])
    var s = State()
    try Replay.foldOps(ops, seq: 1, writerID: w, into: &s)
    #expect(s.anomalies.isEmpty)
    #expect(s.txns[id]?.categorySource?.kind == .dictionary && s.checkpoints.count == 1)
    var bad = OpAuthor(ctx())
    p["currency"] = .string("aed")
    try bad.ingest(payload: p, ingestID: String(repeating: "c", count: 64))
    #expect(throws: AuthorError.self) { try bad.build() }
  }
}
