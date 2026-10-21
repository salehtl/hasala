import CoreDomain
import CoreInvariants
import CoreReplay
import CoreTime
import CoreWire
import Foundation
import Testing

@testable import CoreProjection

struct SplitMix64 {
  var state: UInt64

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }

  mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }

  mutating func pick<T>(_ a: [T]) -> T { a[below(a.count)] }
}

enum SyntheticLog {
  typealias M = MailboxRetireProjectionTests
  typealias Blob = (seq: Int64, writerID: String, ops: [Op])

  static let seeds: [UInt64] = [1, 2, 3, 5, 8, 13, 21, 34, 55, 89, 144, 233, 377, 610, 987, 1597, 2584, 4181, 6765, 10946]
  static let writers = ["ios-0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d", "ios-1b2c3d4e-5f60-4b7c-8d9e-0f1a2b3c4d5e"]
  static let grants = ["u1/mbx-0000000000000000000000000000000a", "u1/mbx-0000000000000000000000000000000b"]
  static let merchants = ["CARREFOUR MOE", "STARBUCKS DIFC", "ENOC 1043", "AMAZON"]
  static let categories = ["groceries", "dining", "shopping"]
  static let extremes: [Int64] = [.max, .max - 1, (1 << 53) + 1, 1 << 62]

  struct Purchase {
    var amount: Int64
    var currency: String
    var merchant: String
    var last4: String
    var day: Int
    var minute: Int
    var grant: Int
  }

  static func two(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }

  static func op(_ type: String, _ payload: String, id: Int, entity: String? = nil, parent: Int64? = nil, ingest: Int? = nil) -> String {
    var s = #"{"v":4,"type":"\#(type)","op_id":"p-\#(id)","authored_at":"2026-10-01T08:00:00.000Z""#
    if let e = entity { s += #","entity":{"kind":"txn","id":"\#(e)"}"# }
    s += #","parent_version":\#(parent.map(String.init) ?? "null")"#
    if let i = ingest { s += #","ingest_id":"\#(M.ingestID(i))""# }
    return s + #","payload":\#(payload)}"#
  }

  static func ingest(_ n: Int, _ p: Purchase, category: String?, id: Int) -> String {
    let cat = category.map { #""\#($0)","category_source":{"kind":"user"}"# } ?? "null"
    let payload =
      #"{"amount_minor":"\#(p.amount)","currency":"\#(p.currency)","direction":"debit","posted_at":"2026-10-\#(two(p.day))T09:\#(two(p.minute)):00.000Z","posted_precision":"time","merchant_raw":"\#(p.merchant)","last4":"\#(p.last4)","needs_review":\#(category == nil),"tier":"template","category":\#(cat),"entry_method":"mailbox","bank":"enbd","provenance":{"provider":"gmail","grant_id":"\#(grants[p.grant])","message_id":"m\#(n)"}}"#
    return op("txn_ingested", payload, id: id, entity: M.ulid(n), ingest: n)
  }

  static func log(seed: UInt64, extreme: Bool, blobs: Int = 48) -> [Blob] {
    var rng = SplitMix64(state: seed)
    var s = State()
    var out: [Blob] = []
    var purchases: [Purchase] = []
    var moves: [(id: String, from: String?, to: String?, amount: Int64)] = []
    var ids = 0
    var n = 0
    func next() -> Int {
      ids += 1
      return ids
    }
    func amount() -> Int64 {
      if extreme && rng.below(3) == 0 { return rng.pick(extremes) }
      return Int64(100 + rng.below(500_000))
    }
    for seq in 1...blobs {
      var ops: [String] = []
      if seq == 1 && rng.below(4) > 0 || seq == blobs / 2 {
        ops.append(op("home_currency_set", #"{"currency":"AED"}"#, id: next()))
      }
      let live = s.txns.values.filter { $0.isLive }.map(\.id)
      for _ in 0..<(1 + rng.below(3)) {
        switch rng.below(100) {
        case 0..<35:
          n += 1
          let p = Purchase(
            amount: amount(), currency: rng.pick(["AED", "AED", "AED", "USD", "EUR"]), merchant: rng.pick(merchants),
            last4: rng.pick(["4412", "0606"]), day: 1 + rng.below(28), minute: rng.below(50), grant: rng.below(2))
          purchases.append(p)
          ops.append(ingest(n, p, category: rng.below(3) == 0 ? nil : rng.pick(categories), id: next()))
        case 35..<47 where !purchases.isEmpty:
          n += 1
          var p = rng.pick(purchases)
          p.grant = 1 - p.grant
          p.minute += rng.below(5)
          ops.append(ingest(n, p, category: nil, id: next()))
        case 47..<57 where !live.isEmpty:
          let t = s.txns[rng.pick(live)]!
          ops.append(
            op(
              "txn_categorized", #"{"category":"\#(rng.pick(categories))","needs_review":false,"source":{"kind":"user"}}"#, id: next(),
              entity: t.id, parent: t.version))
        case 57..<67 where !live.isEmpty:
          let set = rng.below(3) == 0 ? #"{"archived":null}"# : #"{"archived":"user"}"#
          ops.append(op("txn_annotated", #"{"txn_id":"\#(rng.pick(live))","set":\#(set)}"#, id: next()))
        case 67..<75:
          let held = s.txns.values.filter { $0.isHeldCopy }
          guard let t = held.isEmpty ? nil : rng.pick(held), let other = t.copyOf else { continue }
          let d = rng.pick([#""keep_both""#, #""merge""#, "null"])
          ops.append(op("txn_copy_resolved", #"{"other_txn_id":"\#(other)","decision":\#(d)}"#, id: next(), entity: t.id, parent: t.version))
        case 75..<83:
          let micro = rng.pick(["3672500", "4000000", "1000000", "2000000"])
          ops.append(op("rate_set", #"{"currency":"\#(rng.pick(["USD", "EUR"]))","rate_micro":"\#(micro)"}"#, id: next()))
        case 83..<85:
          ops.append(op("rate_unset", #"{"currency":"\#(rng.pick(["USD", "EUR"]))"}"#, id: next()))
        case 85..<89:
          let a = Int64(rng.below(2_000_000))
          ops.append(
            op(
              "budget_set", #"{"category_id":"\#(rng.pick(categories))","month":"2026-10","amount_minor":"\#(a)","scope":"onward"}"#,
              id: next()))
        case 89..<95:
          let from: String? = rng.below(3) == 0 ? nil : rng.pick(categories)
          let to = rng.pick(categories.filter { $0 != from })
          let a = Int64(1 + rng.below(100_000))
          let id = next()
          moves.append(("p-\(id)", from, to, a))
          ops.append(
            op(
              "budget_moved",
              #"{"month":"2026-10","from_category_id":\#(from.map { "\"\($0)\"" } ?? "null"),"to_category_id":"\#(to)","amount_minor":"\#(a)","reason":"move","batch_id":null,"undoes":null}"#,
              id: id))
        case 95..<100 where !moves.isEmpty:
          let m = rng.pick(moves)
          ops.append(
            op(
              "budget_moved",
              #"{"month":"2026-10","from_category_id":"\#(m.to!)","to_category_id":\#(m.from.map { "\"\($0)\"" } ?? "null"),"amount_minor":"\#(m.amount)","reason":"undo","batch_id":null,"undoes":"\#(m.id)"}"#,
              id: next()))
        default:
          continue
        }
      }
      let body = Array(#"{"v":4,"kind":"ops","ops":[\#(ops.joined(separator: ","))]}"#.utf8)
      let decoded = try! OpCodec.decodeBlobOps(body)
      let writer = rng.pick(writers)
      try! Replay.foldOps(decoded, seq: Int64(seq), writerID: writer, into: &s)
      out.append((Int64(seq), writer, decoded))
    }
    return out
  }

  static func fold(_ blobs: some Sequence<Blob>, onto state: State = State()) throws -> State {
    var s = state
    for b in blobs { try Replay.foldOps(b.ops, seq: b.seq, writerID: b.writerID, into: &s) }
    return s
  }

  static func lines(_ s: State) throws -> [MoneyLine] {
    try M.reader(s).moneyLines(from: CivilDate(wire: "2026-01-01")!, to: CivilDate(wire: "2026-12-31")!)
  }
}

@Suite("fold properties over seeded synthetic logs")
struct FoldPropertyTests {
  typealias L = SyntheticLog

  @Test("the generator is deterministic and reaches held copies, archived rows, overflow and undo")
  func generatorCoverage() throws {
    #expect(L.log(seed: 7, extreme: true).map(\.ops) == L.log(seed: 7, extreme: true).map(\.ops))
    var held = 0
    var archived = 0
    var overflow = 0
    var undone = 0
    for seed in L.seeds {
      let s = try L.fold(L.log(seed: seed, extreme: true))
      held += s.txns.values.filter(\.isHeldCopy).count
      archived += s.txns.values.filter { $0.isLive && $0.annotation("archived") != nil }.count
      overflow += s.anomalies.filter { $0.kind == "money_overflow" }.count
      undone += s.plan.moves.values.filter(\.undone).count
    }
    #expect(held > 0 && archived > 0 && overflow > 0 && undone > 0, "held \(held) archived \(archived) overflow \(overflow) undone \(undone)")
  }

  @Test("folding the same log twice gives the same state, and it passes the invariants", arguments: L.seeds)
  func deterministic(_ seed: UInt64) throws {
    let log = L.log(seed: seed, extreme: seed % 2 == 0)
    let a = try L.fold(log)
    let b = try L.fold(log)
    #expect(a.serialized() == b.serialized())
    #expect(Invariants.audit(kept: a, refolded: b) == nil)
    let hard = Invariants.check(a).filter { $0.severity == .hardStop }
    #expect(hard.isEmpty, "\(hard)")
  }

  @Test("a snapshot followed by the log tail folds to the full fold", arguments: L.seeds)
  func snapshotThenTail(_ seed: UInt64) throws {
    let log = L.log(seed: seed, extreme: seed % 2 == 1)
    let full = try L.fold(log).serialized()
    for cut in stride(from: 0, through: log.count, by: 7) {
      let prefix = try L.fold(log.prefix(cut))
      let restored = try SnapshotCodec.decode(try SnapshotCodec.encode(StateSnapshot(state: prefix))).state
      #expect(try L.fold(log.dropFirst(cut), onto: restored).serialized() == full, "cut at \(cut)")
    }
  }

  @Test("totals are integer fils and never overflow", arguments: L.seeds)
  func totals(_ seed: UInt64) throws {
    let s = try L.fold(L.log(seed: seed, extreme: true))
    for t in s.txns.values where !t.unparsed {
      #expect(t.amountMinor > 0)
      #expect((t.amountHomeMinor ?? 0) >= 0)
      for p in t.splits { #expect(p.amountMinor > 0) }
      if t.isLive, t.amountHomeMinor == nil, case .some(.some(let rate)) = s.rates[t.currency] {
        #expect(FX.convert(t.amountMinor, rate) == nil, "\(t.id) waits although its rate converts it")
        #expect(s.anomalies.contains { $0.kind == "money_overflow" }, "\(t.id) waits with no money_overflow recorded")
      }
    }
    let r = try L.M.reader(s)
    let lines = try L.lines(s)
    let e = try r.planEngine(month: CivilMonth(wire: "2026-10")!, today: CivilDate(wire: "2026-10-31")!, bills: [])
    for c in L.categories {
      let exact = lines.filter { $0.category == c && $0.localMonth.wire == "2026-10" && $0.countsInPlan }.reduce(Int128(0)) {
        $0 + Int128($1.signedHome!)
      }
      #expect(e.spent(CivilMonth(wire: "2026-10")!, c) == Int64(clamping: exact), "\(c)")
    }
  }

  @Test("held copies and archived rows never count as spending", arguments: L.seeds)
  func heldAndArchivedNeverCount(_ seed: UInt64) throws {
    let s = try L.fold(L.log(seed: seed, extreme: false))
    let excluded = Set(s.txns.values.filter { $0.isHeldCopy || $0.annotation("archived") != nil }.map(\.id))
    let lines = try L.lines(s)
    #expect(lines.allSatisfy { !excluded.contains($0.txnID) })
    let counted = Set(lines.filter(\.countsInPlan).map(\.txnID))
    for t in s.txns.values where t.isLive && !t.unparsed && !excluded.contains(t.id) && !t.needsReview && t.amountHomeMinor != nil
      && t.category != nil && t.possibleDuplicateOf == nil
    {
      #expect(counted.contains(t.id), "\(t.id) is live, sorted and valued but does not count")
    }
  }
}
