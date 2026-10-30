// Unit tests for CoreInvariants: a clean fold passes, each broken shape is
// caught, and the audit compares witnesses.
import CoreCrypto
import CoreReplay
import CoreWire
import Foundation
import Testing

@testable import CoreInvariants

@Suite("CoreInvariants")
struct CoreInvariantsTests {
  @Test("the fold canary passes every hard stop")
  func canaryClean() {
    let v = Invariants.check(FoldCanary.state())
    #expect(!Invariants.halts(v), "\(v.filter { $0.severity == .hardStop })")
    #expect(v.contains { $0.id == "I14_forks_surfaced" && $0.severity == .notice })
  }

  @Test("broken shapes are hard stops")
  func broken() throws {
    var s = FoldCanary.state()
    let id = try #require(s.txns.first { $0.value.isLive && !$0.value.splits.isEmpty }?.key)
    s.txns[id]!.splits[0].amountMinor += 1
    #expect(Invariants.check(s).contains { $0.id == "I8_split_sum" })

    var u = FoldCanary.state()
    let unparsed = try #require(u.txns.first { $0.value.unparsed }?.key)
    u.txns[unparsed]!.annotations["project_id"] = Keyed("01JC0000000000000000000005", opID: "x")
    u.txns[unparsed]!.needsReview = false
    let v = Invariants.check(u)
    #expect(v.contains { $0.id == "I19_unparsed_links_empty" } && v.contains { $0.id == "I12_money_shape" })

    var c = FoldCanary.state()
    let live = try #require(c.txns.first { $0.value.isLive && !$0.value.unparsed }?.key)
    c.txns[live]!.categorySource = CategorySource(kind: .rule, ruleID: "r")
    c.txns[live]!.category = nil
    #expect(Invariants.check(c).contains { $0.id == "I18_category_source_shape" })

    var p = FoldCanary.state()
    p.pendingByCurrency["AED", default: []].append(live)
    #expect(Invariants.check(p).contains { $0.id == "I10_fx_pending_index" })

    var k = FoldCanary.state()
    k.anomalies.append(Anomaly(kind: "made_up", detail: "", atSeq: 1))
    #expect(Invariants.halts(Invariants.check(k)))
  }

  @Test("the audit compares witnesses, not bookkeeping")
  func audit() {
    let a = FoldCanary.state()
    var b = a
    b.appliedAtCursor.removeAll()
    #expect(Invariants.audit(kept: a, refolded: b) == nil)
    b.homeCurrency = "USD"
    #expect(Invariants.audit(kept: a, refolded: b)?.id == "I22_audit_refold")
  }

  static let ingestA = String(repeating: "a", count: 64)
  static let ingestB = String(repeating: "b", count: 64)
  static let rowA = "01JC0000000000000000000001"
  static let rowB = "01JC0000000000000000000002"
  static let rowC = "01JC0000000000000000000003"

  static func row(_ type: String, _ v: Int, _ id: String, ingest: String, amount: Int, source: String? = nil, category: String? = nil, opID: String)
    -> String
  {
    let cat = category.map { "\"\($0)\"" } ?? "null"
    let src = source.map { #","category_source":\#($0)"# } ?? ""
    return #"{"v":\#(v),"type":"\#(type)","op_id":"\#(opID)","authored_at":"2020-02-01T00:00:00.000Z","entity":{"kind":"txn","id":"\#(id)"},"parent_version":null,"ingest_id":"\#(ingest)","payload":{"amount_minor":"\#(amount)","currency":"AED","direction":"debit","posted_at":"2020-02-01T08:00:00.000Z","merchant_raw":"SYNTHETIC SHOP","last4":"0000","category":\#(cat)\#(src),"needs_review":true,"tier":"template"}}"#
  }

  static func edit(_ type: String, _ v: Int, _ id: String, parent: Int, payload: String, opID: String) -> String {
    #"{"v":\#(v),"type":"\#(type)","op_id":"\#(opID)","authored_at":"2020-02-01T00:00:00.000Z","entity":{"kind":"txn","id":"\#(id)"},"parent_version":\#(parent),"payload":\#(payload)}"#
  }

  static func parts(_ n: Int) -> String {
    #"{"parts":["# + (0..<n).map { _ in #"{"category":"food","amount_minor":"1"}"# }.joined(separator: ",") + "]}"
  }

  static func foldBlobs(_ ops: [(v: Int, json: String)]) throws -> State {
    var rows: [FoldRow] = []
    for (i, o) in ops.enumerated() {
      let body = Data(#"{"v":\#(o.v),"kind":"ops","ops":[\#(o.json)]}"#.utf8)
      rows.append(
        FoldRow(seq: Int64(i + 1), writerID: "ios-peer", counter: Int64(i + 1), outcome: .opened(plaintext: Data(), ops: try OpCodec.decodeBlobOps(body))))
    }
    return try LedgerFold.page(rows, onto: State())
  }

  @Test("an old split of more than 16 parts is an anomaly at every version, and 16 parts still apply", arguments: [1, 3])
  func legacySplitCap(v: Int) throws {
    let s = try Self.foldBlobs([
      (4, Self.row("txn_ingested", 4, Self.rowA, ingest: Self.ingestA, amount: 17, opID: "op-1")),
      (v, Self.edit("txn_split", v, Self.rowA, parent: 1, payload: Self.parts(17), opID: "op-2")),
    ])
    #expect(s.txns[Self.rowA]?.splits.isEmpty == true && s.txns[Self.rowA]?.version == 1)
    #expect(s.anomalies.contains { $0.kind == "invalid_payload" })
    let ok = try Self.foldBlobs([
      (v, Self.row("txn_ingested", v, Self.rowA, ingest: Self.ingestA, amount: 16, opID: "op-1")),
      (v, Self.edit("txn_split", v, Self.rowA, parent: 1, payload: Self.parts(16), opID: "op-2")),
    ])
    #expect(ok.txns[Self.rowA]?.splits.count == 16)
  }

  @Test("an old category edit keeps a current row's source truthful")
  func legacyCategoryEdit() throws {
    let set = try Self.foldBlobs([
      (4, Self.row("txn_ingested", 4, Self.rowA, ingest: Self.ingestA, amount: 500, opID: "op-1")),
      (3, Self.edit("txn_edited", 3, Self.rowA, parent: 1, payload: #"{"category":"dining"}"#, opID: "op-2")),
    ])
    #expect(set.txns[Self.rowA]?.category == "dining" && set.txns[Self.rowA]?.categorySource?.kind == .user)

    let dictionary = #"{"kind":"dictionary","bundle":"2026.10.11-1","entry":"contains:shop"}"#
    let cleared = try Self.foldBlobs([
      (4, Self.row("txn_ingested", 4, Self.rowA, ingest: Self.ingestA, amount: 500, source: dictionary, category: "dining", opID: "op-1")),
      (3, Self.edit("txn_edited", 3, Self.rowA, parent: 1, payload: #"{"category":null}"#, opID: "op-2")),
    ])
    #expect(cleared.txns[Self.rowA]?.category == nil && cleared.txns[Self.rowA]?.categorySource?.kind == CategorySource.Kind.none)

    let kept = try Self.foldBlobs([
      (4, Self.row("txn_ingested", 4, Self.rowA, ingest: Self.ingestA, amount: 500, source: dictionary, category: "dining", opID: "op-1")),
      (3, Self.edit("txn_edited", 3, Self.rowA, parent: 1, payload: #"{"category":"groceries"}"#, opID: "op-2")),
    ])
    #expect(kept.txns[Self.rowA]?.category == "groceries" && kept.txns[Self.rowA]?.categorySource?.kind == .dictionary)
  }

  @Test("an old supersede of a row in a chain extends the chain; one of a row outside a chain links nothing")
  func legacySupersede() throws {
    let chained = try Self.foldBlobs([
      (4, Self.row("txn_ingested", 4, Self.rowA, ingest: Self.ingestA, amount: 500, opID: "op-1")),
      (4, Self.row("txn_superseded", 4, Self.rowB, ingest: Self.ingestA, amount: 501, opID: "op-2")),
      (3, Self.row("txn_superseded", 3, Self.rowC, ingest: Self.ingestA, amount: 502, opID: "op-3")),
    ])
    #expect(chained.txns[Self.rowB]?.successorID == Self.rowC && chained.txns[Self.rowC]?.isLive == true)

    let single = try Self.foldBlobs([
      (4, Self.row("txn_ingested", 4, Self.rowA, ingest: Self.ingestA, amount: 500, opID: "op-1")),
      (3, Self.row("txn_superseded", 3, Self.rowB, ingest: Self.ingestA, amount: 501, opID: "op-2")),
    ])
    #expect(single.txns[Self.rowA]?.successorID == nil && single.txns[Self.rowA]?.supersededBy == "op-2")
  }

  @Test("the canary exercises ops below v4 on current rows, so a change to them moves the fold print")
  func canaryHoldsOldOpsOnCurrentRows() {
    let s = FoldCanary.state()
    let edited = s.txns["01JC0000000000000000000081"]
    #expect(edited?.category == "dining" && edited?.categorySource?.kind == .user && edited?.splits.isEmpty == true)
    #expect(s.anomalies.contains { $0.kind == "invalid_payload" && $0.atSeq == 54 })
    #expect(s.txns["01JC0000000000000000000083"]?.successorID == "01JC0000000000000000000084")
  }

  @Test("every old op on a current row folds to a state the invariants accept", arguments: [1, 2, 3])
  func legacyOpsOnCurrentRows(v: Int) throws {
    let dictionary = #"{"kind":"dictionary","bundle":"2026.10.11-1","entry":"contains:shop"}"#
    var later: [String] = [
      Self.edit("txn_categorized", v, Self.rowA, parent: 1, payload: #"{"category":null}"#, opID: "op-9"),
      Self.edit("txn_categorized", v, Self.rowB, parent: 1, payload: #"{"category":"dining"}"#, opID: "op-9"),
      Self.edit("txn_split", v, Self.rowA, parent: 1, payload: Self.parts(500), opID: "op-9"),
      Self.edit("txn_edited", v, Self.rowA, parent: 1, payload: #"{"category":null,"merchant_raw":"OTHER","needs_review":false}"#, opID: "op-9"),
      Self.edit("txn_edited", v, Self.rowB, parent: 1, payload: #"{"category":"dining","amount_minor":"7","currency":"usd","direction":"credit"}"#, opID: "op-9"),
      Self.edit("txn_edited", v, Self.rowB, parent: 1, payload: #"{"amount_home_minor":null,"possible_duplicate_of":"\#(Self.rowA)"}"#, opID: "op-9"),
      Self.row("txn_superseded", v, Self.rowC, ingest: Self.ingestA, amount: 502, opID: "op-9"),
      Self.row("txn_superseded", v, Self.rowC, ingest: Self.ingestB, amount: 503, category: "dining", opID: "op-9"),
    ]
    if v >= 2 {
      later.append(
        Self.edit("txn_duplicate_disposition", v, Self.rowA, parent: 1, payload: #"{"other_txn_id":"\#(Self.rowB)","disposition":"same"}"#, opID: "op-9"))
    }
    for json in later {
      let s = try Self.foldBlobs([
        (4, Self.row("txn_ingested", 4, Self.rowA, ingest: Self.ingestA, amount: 500, source: dictionary, category: "dining", opID: "op-1")),
        (4, Self.row("txn_ingested", 4, Self.rowB, ingest: Self.ingestB, amount: 600, opID: "op-2")),
        (v, json),
      ])
      #expect(!Invariants.halts(Invariants.check(s)))
    }
  }

  @Test("a decided page folds onto a copy; set-aside rows consume their seq; a newer op halts")
  func page() throws {
    let canary = FoldCanary.log()
    let rows = canary.prefix(5).map { FoldRow(seq: $0.seq, writerID: $0.writerID, counter: $0.seq, outcome: .opened(plaintext: Data(), ops: $0.ops)) }
    let s = try LedgerFold.page(rows + [FoldRow(seq: 6, writerID: "dev-a", counter: 9, outcome: .setAside(.aeadFailed, alarm: true))], onto: State())
    #expect(s.cursors.hot == 6 && s.unreadable.map(\.reason) == ["aeadFailed"])
    #expect(throws: FoldHalt.self) { try LedgerFold.page(rows, onto: s) }
  }
}
