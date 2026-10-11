// Unit tests for CoreReplay's v4 families (spec 03c §13 vectors, 03a §12, 03b
// §10), the snapshot and the canary. The v3 fold is pinned by
// conformance/replay (HasalaCoreConformanceTests).
import CoreJSON
import CoreWire
import Foundation
import Testing

@testable import CoreReplay

/// A tiny log builder: ops written as JSON text, folded through blob decode.
struct Log {
  var state = State()
  var seq: Int64 = 0

  static let w1 = "ios-0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"
  static let w2 = "ios-1b2c3d4e-5f60-4b7c-8d9e-0f1a2b3c4d5e"

  @discardableResult
  mutating func blob(_ ops: String..., as writer: String = Log.w1) throws -> Int64 {
    seq += 1
    let body = Array(#"{"v":4,"kind":"ops","ops":[\#(ops.joined(separator: ","))]}"#.utf8)
    try Replay.foldBlob(PositionedBlob(writerID: writer, writerCounter: seq, seq: seq, body: body), into: &state)
    return seq
  }

  var kinds: [String] { state.anomalies.map(\.kind) }
}

enum Ids {
  static func ulid(_ n: Int) -> String { "01JC" + String(repeating: "0", count: 22 - String(n).count) + String(n) }
  static let t1 = ulid(1), t2 = ulid(2), t3 = ulid(3), r1 = ulid(4), p1 = ulid(5), g1 = ulid(6)
  static func ingest(_ n: Int) -> String { String(repeating: "0", count: 62) + (n < 10 ? "0\(n)" : "\(n)") }
}

func op(
  _ type: String, _ payload: String, id: Int, entity: (String, String)? = nil, parent: Int? = nil, ingest: String? = nil,
  at: String = "2026-10-01T08:00:00.000Z"
) -> String {
  var s = #"{"v":4,"type":"\#(type)","op_id":"op-\#(id)","authored_at":"\#(at)""#
  if let e = entity { s += #","entity":{"kind":"\#(e.0)","id":"\#(e.1)"}"# }
  s += #","parent_version":\#(parent.map(String.init) ?? "null")"#
  if let i = ingest { s += #","ingest_id":"\#(i)""# }
  return s + #","payload":\#(payload)}"#
}

func ingest(_ n: Int, id: String, amount: String = "5000", merchant: String = "CARREFOUR MOE", extra: String = "") -> String {
  op(
    "txn_ingested",
    #"{"amount_minor":"\#(amount)","currency":"AED","direction":"debit","posted_at":"2026-10-03T08:00:00.000Z","merchant_raw":"\#(merchant)","last4":"4412","needs_review":true\#(extra)}"#,
    id: 1000 + n, entity: ("txn", id), ingest: Ids.ingest(n))
}

@Suite("CoreReplay v4")
struct CoreReplayV4Tests {
  @Test("txn v4 defaults: category_source from the category, fields stored, witness omits defaults")
  func txnDefaults() throws {
    var log = Log()
    try log.blob(ingest(1, id: Ids.t1, extra: #","category":"groceries","entry_method":"manual","location":"DIFC""#))
    let t = try #require(log.state.txns[Ids.t1])
    #expect(t.categorySource == .user)
    #expect(t.entryMethod == "manual" && t.location == "DIFC")
    #expect(log.kinds.isEmpty)
    let w = String(decoding: log.state.serialized(), as: UTF8.self)
    #expect(w.contains(#""category_source":{"kind":"user"}"#))
    #expect(!w.contains("annotations") && !w.contains("successor_id") && !w.contains("merchantNames"))
  }

  @Test("txn-02: verified_origin_domain is refused at v4")
  func verifiedOriginRefused() throws {
    var log = Log()
    try log.blob(ingest(1, id: Ids.t1, extra: #","verified_origin_domain":"x.ae""#))
    #expect(log.kinds == ["invalid_payload"])
    #expect(log.state.txns.isEmpty)
  }

  @Test("txn-01: a v4 category must be a CategoryId; source must agree with it")
  func categoryGrammar() throws {
    var log = Log()
    try log.blob(ingest(1, id: Ids.t1, extra: #","category":"Groceries""#))
    try log.blob(ingest(2, id: Ids.t2, extra: #","category":null,"category_source":{"kind":"rule","rule_id":"\#(Ids.r1)"}"#))
    #expect(log.kinds == ["invalid_payload", "invalid_payload"])
  }

  @Test("txn-03: txn_categorized at v4 requires needs_review and source")
  func categorizeRequiresFields() throws {
    var log = Log()
    try log.blob(ingest(1, id: Ids.t1))
    try log.blob(op("txn_categorized", #"{"category":"dining","source":{"kind":"user"}}"#, id: 2, entity: ("txn", Ids.t1), parent: 1))
    try log.blob(op("txn_categorized", #"{"category":"dining","needs_review":false}"#, id: 3, entity: ("txn", Ids.t1), parent: 1))
    try log.blob(
      op("txn_categorized", #"{"category":"dining","needs_review":false,"source":{"kind":"user"}}"#, id: 4, entity: ("txn", Ids.t1), parent: 1))
    #expect(log.kinds == ["invalid_payload", "invalid_payload"])
    let t = try #require(log.state.txns[Ids.t1])
    #expect(t.category == "dining" && t.categorySource == .user && !t.needsReview && t.version == 2)
  }

  @Test("txn-05/06/07: un-split with [], one part and 17 parts refused, notes kept")
  func splitShapes() throws {
    var log = Log()
    try log.blob(ingest(1, id: Ids.t1, amount: "34215"))
    try log.blob(
      op(
        "txn_split",
        #"{"parts":[{"category":"groceries","amount_minor":"29700"},{"category":"shopping","amount_minor":"4515","note":"Kitchen towels"}]}"#,
        id: 2, entity: ("txn", Ids.t1), parent: 1))
    #expect(log.state.txns[Ids.t1]?.splits.count == 2)
    #expect(log.state.txns[Ids.t1]?.splits[1].note == "Kitchen towels")
    try log.blob(op("txn_split", #"{"parts":[{"category":"groceries","amount_minor":"34215"}]}"#, id: 3, entity: ("txn", Ids.t1), parent: 2))
    let many = (0..<17).map { _ in #"{"category":"groceries","amount_minor":"1"}"# }.joined(separator: ",")
    try log.blob(op("txn_split", #"{"parts":[\#(many)]}"#, id: 4, entity: ("txn", Ids.t1), parent: 2))
    try log.blob(op("txn_split", #"{"parts":[]}"#, id: 5, entity: ("txn", Ids.t1), parent: 2))
    #expect(log.kinds == ["invalid_payload", "invalid_payload"])
    #expect(log.state.txns[Ids.t1]?.splits.isEmpty == true)
    #expect(log.state.txns[Ids.t1]?.version == 3)
  }

  @Test("txn-09: a category key in a v4 txn_edited is refused; the rest applies")
  func editedCategoryRefused() throws {
    var log = Log()
    try log.blob(ingest(1, id: Ids.t1))
    try log.blob(op("txn_edited", #"{"category":"dining","last4":"9999"}"#, id: 2, entity: ("txn", Ids.t1), parent: 1))
    #expect(log.kinds == ["unsupported_edit_field"])
    #expect(log.state.txns[Ids.t1]?.last4 == "9999")
    #expect(log.state.txns[Ids.t1]?.category == nil)
  }

  @Test("annot-01/04/08: set and clear, a later position wins whatever its stamp, no version bump")
  func annotations() throws {
    var log = Log()
    try log.blob(ingest(1, id: Ids.t1))
    try log.blob(op("txn_annotated", #"{"txn_id":"\#(Ids.t1)","set":{"note":"Kitchen run"}}"#, id: 2, at: "2026-10-05T00:00:00.000Z"))
    try log.blob(op("txn_annotated", #"{"txn_id":"\#(Ids.t1)","set":{"note":"Older stamp"}}"#, id: 3, at: "2026-10-01T00:00:00.000Z"), as: Log.w2)
    #expect(log.state.txns[Ids.t1]?.annotation("note") == "Older stamp")
    #expect(log.state.txns[Ids.t1]?.annotations["note"]?.opID == "op-3")
    try log.blob(op("txn_annotated", #"{"txn_id":"\#(Ids.t1)","set":{"note":""}}"#, id: 4))
    #expect(log.state.txns[Ids.t1]?.annotation("note") == nil)
    #expect(log.state.txns[Ids.t1]?.annotations["note"] != nil)
    #expect(log.state.txns[Ids.t1]?.version == 1)
    #expect(log.state.forks.isEmpty && log.kinds.isEmpty)
  }

  @Test("annot-03/06/07: links refused on unparsed, unknown txn, unknown set key")
  func annotationRefusals() throws {
    var log = Log()
    try log.blob(
      op(
        "txn_ingested", #"{"posted_at":"2026-10-03T08:00:00.000Z","unparsed":true,"tier":"none","needs_review":true}"#, id: 1,
        entity: ("txn", Ids.t1), ingest: Ids.ingest(1)))
    try log.blob(op("txn_annotated", #"{"txn_id":"\#(Ids.t1)","set":{"project_id":"\#(Ids.p1)","note":"x"}}"#, id: 2))
    try log.blob(op("txn_annotated", #"{"txn_id":"\#(Ids.t2)","set":{"note":"x"}}"#, id: 3))
    try log.blob(op("txn_annotated", #"{"txn_id":"\#(Ids.t1)","set":{"colour":"x"}}"#, id: 4))
    #expect(log.kinds == ["unsupported_edit_field", "unknown_entity", "invalid_payload"])
    #expect(log.state.txns[Ids.t1]?.annotation("note") == "x")
    #expect(log.state.txns[Ids.t1]?.annotation("project_id") == nil)
  }

  @Test("txn-10/11: a supersede carries annotations; onto an unparsed successor only note and archived")
  func supersedeCarries() throws {
    var log = Log()
    try log.blob(ingest(1, id: Ids.t1))
    try log.blob(
      op(
        "txn_annotated",
        #"{"txn_id":"\#(Ids.t1)","set":{"note":"n","archived":"user","account_id":"ac_cash","project_id":"\#(Ids.p1)","refund_of":"\#(Ids.r1)"}}"#,
        id: 2))
    let s = try log.blob(
      op(
        "txn_superseded", #"{"posted_at":"2026-10-03T08:00:00.000Z","unparsed":true,"tier":"none","needs_review":true}"#, id: 3,
        entity: ("txn", Ids.t2), ingest: Ids.ingest(1)))
    #expect(log.kinds == ["unsupported_edit_field", "unsupported_edit_field", "unsupported_edit_field"])
    #expect(log.state.anomalies.allSatisfy { $0.atSeq == s })
    #expect(log.state.anomalies.map(\.detail).map { $0.split(separator: " ")[1] } == ["account_id", "project_id", "refund_of"])
    let succ = try #require(log.state.txns[Ids.t2])
    #expect(Array(succ.annotations.keys).sorted() == ["archived", "note"])
    #expect(log.state.txns[Ids.t1]?.annotations.count == 5)
    #expect(log.state.txns[Ids.t1]?.successorID == Ids.t2)
    #expect(succ.ingestID == log.state.txns[Ids.t1]?.ingestID)
    // A later parsed supersede copies note and archived only.
    try log.blob(ingest(1, id: Ids.t3).replacingOccurrences(of: "txn_ingested", with: "txn_superseded"))
    #expect(Array(log.state.txns[Ids.t3]!.annotations.keys).sorted() == ["archived", "note"])
    // annot-05: an annotation addressed to the first row forwards to the live one.
    try log.blob(op("txn_annotated", #"{"txn_id":"\#(Ids.t1)","set":{"note":"forwarded"}}"#, id: 9))
    #expect(log.state.txns[Ids.t3]?.annotation("note") == "forwarded")
    #expect(log.state.txns[Ids.t1]?.annotation("note") == "n")
  }

  @Test("merch-01/02, trust-01/02: keyed by position; denormalized domains refused")
  func merchantAndTrust() throws {
    var log = Log()
    try log.blob(op("merchant_named", #"{"merchant_key":"carrefour moe","display_name":"Carrefour"}"#, id: 1))
    try log.blob(op("merchant_named", #"{"merchant_key":"carrefour moe","display_name":null}"#, id: 2))
    #expect(log.state.merchantNames["carrefour moe"]?.value == nil)
    try log.blob(op("sender_trust_set", #"{"domain":"emiratesnbd.com","trusted":true}"#, id: 3))
    try log.blob(op("sender_trust_set", #"{"domain":"EmiratesNBD.com","trusted":true}"#, id: 4))
    try log.blob(op("sender_trust_set", #"{"domain":"emiratesnbd.com.","trusted":true}"#, id: 5))
    try log.blob(op("sender_trust_set", #"{"domain":"emiratesnbd.com","trusted":false}"#, id: 6))
    #expect(log.kinds == ["invalid_payload", "invalid_payload"])
    #expect(log.state.senderTrust["emiratesnbd.com"]?.value == false)
  }

  @Test("cat-05: v3 and v4 category writes share one positional rule; v4 shape carries icon")
  func categoryShapes() throws {
    var log = Log()
    try log.blob(op("category_defined", #"{"id":"pets","name":"Pets","kind":"spending","bucket":"want","icon":"paw","active":true}"#, id: 1))
    #expect(log.state.categories["pets"]?.shape == 4 && log.state.categories["pets"]?.icon == "paw")
    try log.blob(op("category_defined", #"{"id":"pets","name":" Pets","kind":"spending","bucket":"want","active":true}"#, id: 2))
    try log.blob(op("category_defined", #"{"id":"pets","name":"Pets","kind":"income","bucket":"want","active":true}"#, id: 3))
    #expect(log.kinds == ["invalid_payload", "invalid_payload"])
  }

  @Test("rule-01/02/03/04: v4 rule shape, regex refused, pattern bounds and duplicates")
  func ruleShapes() throws {
    var log = Log()
    let good = #"{"patterns":["careem","uber"],"match":"starts_with","category":"transport","priority":10,"enabled":true,"origin":"manual"}"#
    try log.blob(op("rule_added", good, id: 1, entity: ("rule", Ids.r1), at: "2026-10-10T08:00:00.000Z"))
    let r = try #require(log.state.rules[Ids.r1])
    #expect(r.shape == 4 && r.patterns == ["careem", "uber"] && !r.removed && r.createdAt == "2026-10-10T08:00:00.000Z")
    try log.blob(op("rule_added", good.replacingOccurrences(of: "starts_with", with: "regex"), id: 2, entity: ("rule", Ids.r1), parent: 1))
    try log.blob(op("rule_added", good.replacingOccurrences(of: #""uber""#, with: #""careem""#), id: 3, entity: ("rule", Ids.r1), parent: 1))
    try log.blob(op("rule_added", good.replacingOccurrences(of: "10", with: "10.0"), id: 4, entity: ("rule", Ids.r1), parent: 1))
    #expect(log.kinds == ["invalid_payload", "invalid_payload", "invalid_payload"])
    try log.blob(
      op("rule_added", good.replacingOccurrences(of: #""enabled":true"#, with: #""enabled":false"#), id: 5, entity: ("rule", Ids.r1), parent: 1))
    #expect(log.state.rules[Ids.r1]?.enabled == false && log.state.rules[Ids.r1]?.version == 2)
    #expect(log.state.rules[Ids.r1]?.createdAt == "2026-10-10T08:00:00.000Z")
  }

  @Test("projects and goals fold as entities with forks")
  func projectsGoals() throws {
    var log = Log()
    let p = #"{"name":"Japan trip","starts_on":"2026-12-14","ends_on":"2026-12-28","budget_minor":"1200000","count_in_plan":false,"status":"active","icon":"plane"}"#
    try log.blob(op("project_defined", p, id: 1, entity: ("project", Ids.p1), at: "2026-09-01T10:00:00.000Z"))
    try log.blob(op("project_defined", p.replacingOccurrences(of: "Japan trip", with: "Japan"), id: 2, entity: ("project", Ids.p1), parent: 1))
    try log.blob(op("project_defined", p.replacingOccurrences(of: "Japan trip", with: "Tokyo"), id: 3, entity: ("project", Ids.p1), parent: 1, at: "2026-09-01T09:00:00.000Z"), as: Log.w2)
    #expect(log.state.projects[Ids.p1]?.name == "Japan")
    #expect(log.state.projects[Ids.p1]?.version == 3)
    #expect(log.state.forks.count == 1)
    try log.blob(op("project_defined", p.replacingOccurrences(of: "2026-12-28", with: "2026-12-01"), id: 4, entity: ("project", Ids.p1), parent: 3))
    #expect(log.kinds == ["invalid_payload"])
    let g = #"{"name":"Cash","target_minor":"100000","source":{"kind":"account","account_id":"ac cash"},"status":"active"}"#
    try log.blob(op("goal_defined", g, id: 5, entity: ("goal", Ids.g1)))
    try log.blob(op("goal_defined", g.replacingOccurrences(of: "ac cash", with: "ac_cash"), id: 6, entity: ("goal", Ids.g1)))
    #expect(log.kinds == ["invalid_payload", "invalid_payload"])
    #expect(log.state.goals[Ids.g1]?.startingMinor == 0)
  }

  @Test("plan: sets absorb earlier moves, undo validates, P-11 for an older stamp from another writer")
  func plan() throws {
    var log = Log()
    try log.blob(op("budget_set", #"{"category_id":"dining","month":"2026-10","amount_minor":"160000","scope":"onward"}"#, id: 1, at: "2026-10-10T09:00:00.000Z"))
    try log.blob(op("budget_moved", #"{"month":"2026-10","from_category_id":null,"to_category_id":"dining","amount_minor":"20000","reason":"move"}"#, id: 2))
    #expect(log.state.plan.cells["dining"]?["2026-10"]?.movesSinceSet == 20000)
    try log.blob(op("budget_moved", #"{"month":"2026-10","from_category_id":"dining","to_category_id":null,"amount_minor":"20000","reason":"undo","undoes":"op-2"}"#, id: 3))
    try log.blob(op("budget_moved", #"{"month":"2026-10","from_category_id":"dining","to_category_id":null,"amount_minor":"20000","reason":"undo","undoes":"op-2"}"#, id: 4))
    #expect(log.kinds == ["plan_undo_mismatch"])
    #expect(log.state.plan.moves["op-2"]?.undone == true)
    #expect(log.state.plan.cells["dining"]?["2026-10"]?.movesAll == 0)
    try log.blob(op("budget_set", #"{"category_id":"dining","month":"2026-10","amount_minor":"180000","scope":"only"}"#, id: 5, at: "2026-10-09T00:00:00.000Z"), as: Log.w2)
    #expect(log.state.plan.overwrites.count == 1)
    #expect(log.state.plan.overwrites.first?.replacedValue == "160000")
    #expect(log.state.plan.cells["dining"]?["2026-10"]?.latestSet == 180000)
    #expect(log.state.plan.cells["dining"]?["2026-10"]?.onwardSet == 160000)
    try log.blob(op("income_source_set", #"{"id":"salary-1","name":"Salary","category_id":"salary","amount_minor":"2500000","payday":28.0,"active":true}"#, id: 6))
    try log.blob(op("budget_set", #"{"category_id":"dining","month":"2026-10","amount_minor":"0160000","scope":"onward"}"#, id: 7))
    #expect(log.kinds == ["plan_undo_mismatch", "invalid_payload", "invalid_payload"])
  }

  @Test("bills and accounts: card needs an account, occurrence needs a bill")
  func billsAccounts() throws {
    var log = Log()
    try log.blob(op("card_linked", #"{"bank":"enbd","last4":"4412","state":"mine","account":"ac_cash"}"#, id: 1))
    try log.blob(op("account_set", #"{"id":"ac_cash","name":"Cash","institution":null,"kind":"cash","in_plan":true,"currency":"AED","statement_due_day":null,"active":true,"closed_on":null,"color":null}"#, id: 2))
    try log.blob(op("card_linked", #"{"bank":"enbd","last4":"4412","state":"mine","account":"ac_cash"}"#, id: 3))
    try log.blob(op("bill_occurrence_set", #"{"bill":"bd_axa","due":"2026-10-07","resolution":"paid"}"#, id: 4))
    #expect(log.kinds == ["unknown_entity", "unknown_entity"])
    #expect(log.state.cards.count == 1 && log.state.accounts["ac_cash"]?.firstSeq == 2)
  }

  @Test("reserved-01: a profile_set op sets its whole blob aside")
  func reservedType() throws {
    var log = Log()
    try log.blob(ingest(1, id: Ids.t1))
    try log.blob(
      op("txn_annotated", #"{"txn_id":"\#(Ids.t1)","set":{"note":"x"}}"#, id: 2), op("profile_set", #"{"name":"Maya"}"#, id: 3))
    #expect(log.state.unreadable.count == 1)
    #expect(log.state.txns[Ids.t1]?.annotations.isEmpty == true)
    #expect(log.kinds.isEmpty)
    var newer = log
    #expect(throws: ReplayStop.self) {
      try Replay.foldBlob(
        PositionedBlob(writerID: Log.w1, writerCounter: 9, seq: 99, body: Array(#"{"v":5,"kind":"ops","ops":[]}"#.utf8)),
        into: &newer.state)
    }
  }

  @Test("maxAuthored is per writer, over every op visited, and not witnessed")
  func maxAuthored() throws {
    var log = Log()
    try log.blob(op("merchant_named", #"{"merchant_key":"x","display_name":"X"}"#, id: 1, at: "2026-10-05T00:00:00.000Z"))
    try log.blob(op("merchant_named", #"{"merchant_key":"","display_name":"X"}"#, id: 2, at: "2026-10-06T00:00:00.000Z"))
    #expect(log.state.maxAuthored[Log.w1] == 1_791_244_800_000)
    #expect(!String(decoding: log.state.serialized(), as: UTF8.self).contains("maxAuthored"))
  }
}

@Suite("CoreReplay snapshot and canary")
struct SnapshotTests {
  @Test("the canary folds with only its intended notices")
  func canary() {
    let s = FoldCanary.state()
    #expect(s.cursors.hot == 40)
    #expect(s.anomalies.map(\.kind) == ["duplicate_ingest"])
    #expect(s.unreadable.isEmpty)
    #expect(s.merchantNames["carrefour moe"]?.value == "Carrefour MoE")
    #expect(s.plan.overwrites.count == 1)
    #expect(FoldCanary.foldPrint.utf8.count == 32)
  }

  @Test("snapshot round trip keeps every map's order and the witness")
  func roundTrip() throws {
    var log = Log()
    try log.blob(op("category_defined", #"{"id":"zz","name":"Zed","kind":"spending","bucket":"want","active":true}"#, id: 1))
    try log.blob(op("category_defined", #"{"id":"aa","name":"Aye","kind":"spending","bucket":"need","active":true}"#, id: 2))
    try log.blob(op("category_defined", #"{"id":"zz","name":"Zed 2","kind":"spending","bucket":"want","active":true}"#, id: 3))
    let data = try SnapshotCodec.encode(StateSnapshot(state: log.state))
    let back = try SnapshotCodec.decode(data).state
    #expect(Array(back.categories.keys) == ["zz", "aa"])
    #expect(back == log.state)
    #expect(back.serialized() == log.state.serialized())
    var bad = StateSnapshot(state: log.state)
    bad.foldPrint = "0"
    #expect(throws: SnapshotError.foldSemantics) { try SnapshotCodec.decode(try SnapshotCodec.encode(bad)) }
  }
}
