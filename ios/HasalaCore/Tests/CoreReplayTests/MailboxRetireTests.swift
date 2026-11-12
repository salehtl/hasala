import CoreJSON
import CoreWire
import Foundation
import Testing

@testable import CoreReplay

enum Mbx {
  static let a = "u1/mbx-0000000000000000000000000000000a"
  static let b = "u1/mbx-0000000000000000000000000000000b"
  static let legacy = "u1"

  static func prov(_ grant: String, provider: String = "gmail", message: String) -> String {
    #","entry_method":"mailbox","provenance":{"provider":"\#(provider)","grant_id":"\#(grant)","message_id":"\#(message)"}"#
  }

  static func retire(_ grant: String, provider: String = "gmail", legacy: Bool = false, id: Int) -> String {
    op("mailbox_retired", #"{"grant_id":"\#(grant)","provider":"\#(provider)","legacy":\#(legacy)}"#, id: id)
  }
}

@Suite("CoreReplay mailbox retire")
struct MailboxRetireTests {
  @Test("a v4 import projects its mailbox and provider; a v3 import does not")
  func projects() throws {
    var log = Log()
    try log.blob(ingest(1, id: Ids.t1, extra: Mbx.prov(Mbx.a, message: "m1")))
    let t = try #require(log.state.txns[Ids.t1])
    #expect(t.sourceMailbox == Mbx.a && t.sourceProvider == "gmail")
    let w = String(decoding: log.state.serialized(), as: UTF8.self)
    #expect(w.contains(#""source_mailbox":"u1/mbx-0000000000000000000000000000000a""#))
    #expect(w.contains(#""source_provider":"gmail""#))

    var v3 = Log()
    let body = #"{"v":1,"type":"txn_ingested","op_id":"v3-1","authored_at":"2026-10-01T08:00:00.000Z","entity":{"kind":"txn","id":"T1"},"parent_version":null,"ingest_id":"\#(Ids.ingest(1))","payload":{"amount_minor":"5000","currency":"AED","direction":"debit","posted_at":"2026-10-03T08:00:00.000Z","merchant_raw":"X","last4":"1","provenance":{"provider":"gmail","grant_id":"g","message_id":"m"}}}"#
    try Replay.foldBlob(
      PositionedBlob(writerID: Log.w1, writerCounter: 1, seq: 1, body: Array(#"{"v":1,"kind":"ops","ops":[\#(body)]}"#.utf8)),
      into: &v3.state)
    #expect(v3.state.txns["T1"]?.mailboxMessageID == "m")
    #expect(v3.state.txns["T1"]?.sourceMailbox == nil)
    #expect(!String(decoding: v3.state.serialized(), as: UTF8.self).contains("source_mailbox"))
  }

  @Test("remove retires that mailbox's earlier rows, edited ones too, and nothing else")
  func remove() throws {
    var log = Log()
    try log.blob(ingest(1, id: Ids.t1, extra: Mbx.prov(Mbx.a, message: "m1")))
    try log.blob(ingest(2, id: Ids.t2, merchant: "ENOC", extra: Mbx.prov(Mbx.a, message: "m2")))
    try log.blob(ingest(3, id: Ids.t3, merchant: "IKEA", extra: Mbx.prov(Mbx.b, message: "m3")))
    try log.blob(ingest(4, id: Ids.ulid(9), merchant: "CASH", extra: #","entry_method":"manual""#))
    try log.blob(
      op(
        "txn_categorized", #"{"category":"transport","needs_review":false,"source":{"kind":"user"}}"#, id: 50,
        entity: ("txn", Ids.t2), parent: 1))
    try log.blob(Mbx.retire(Mbx.a, id: 60))
    let s = log.state
    #expect(s.txns[Ids.t1]?.retiredBy == "op-60" && s.txns[Ids.t2]?.retiredBy == "op-60")
    #expect(s.txns[Ids.t3]?.retiredBy == nil && s.txns[Ids.ulid(9)]?.retiredBy == nil)
    #expect(s.txns[Ids.t2]?.category == "transport")
    #expect(s.liveByIngestID[Ids.ingest(1)] == nil && s.liveByIngestID[Ids.ingest(3)] == Ids.t3)
    #expect(!s.byFingerprint.values.contains { $0.contains(Ids.t1) || $0.contains(Ids.t2) })
    #expect(s.mailboxRetirements == [
      MailboxRetirement(opID: "op-60", grantID: Mbx.a, provider: "gmail", legacy: false, atSeq: 6, txnIDs: [Ids.t1, Ids.t2])
    ])
    #expect(log.kinds.isEmpty)
  }

  @Test("keep authors nothing, so every row stays live")
  func keep() throws {
    var log = Log()
    try log.blob(ingest(1, id: Ids.t1, extra: Mbx.prov(Mbx.a, message: "m1")))
    #expect(log.state.txns[Ids.t1]?.isLive == true)
    #expect(log.state.mailboxRetirements.isEmpty)
    #expect(!String(decoding: log.state.serialized(), as: UTF8.self).contains("retired_by"))
  }

  @Test("an import after the retire is new; the same message again is a fresh row, not a duplicate")
  func reconnect() throws {
    var log = Log()
    try log.blob(ingest(1, id: Ids.t1, extra: Mbx.prov(Mbx.a, message: "m1")))
    try log.blob(Mbx.retire(Mbx.a, id: 60))
    try log.blob(ingest(1, id: Ids.t2, extra: Mbx.prov(Mbx.a, message: "m1")))
    try log.blob(ingest(5, id: Ids.t3, merchant: "NEW", extra: Mbx.prov(Mbx.a, message: "m5")))
    let s = log.state
    #expect(log.kinds.isEmpty)
    #expect(s.txns[Ids.t1]?.retiredBy == "op-60")
    #expect(s.txns[Ids.t2]?.isLive == true && s.txns[Ids.t3]?.isLive == true)
    #expect(s.liveByIngestID[Ids.ingest(1)] == Ids.t2)
    #expect(s.mailboxRetirements.first?.txnIDs == [Ids.t1])
  }

  @Test("an edit of a row its mailbox's removal retired still applies, with a notice")
  func editAfterRetire() throws {
    var log = Log()
    try log.blob(ingest(1, id: Ids.t1, extra: Mbx.prov(Mbx.a, message: "m1")))
    try log.blob(ingest(2, id: Ids.t2, merchant: "ENOC", extra: Mbx.prov(Mbx.b, message: "m2")))
    try log.blob(Mbx.retire(Mbx.a, id: 60))
    try log.blob(
      op(
        "txn_categorized", #"{"category":"transport","needs_review":false,"source":{"kind":"user"}}"#, id: 61,
        entity: ("txn", Ids.t1), parent: 1),
      op(
        "txn_categorized", #"{"category":"transport","needs_review":false,"source":{"kind":"user"}}"#, id: 62,
        entity: ("txn", Ids.t2), parent: 1),
      as: Log.w2)
    try log.blob(op("txn_edited", #"{"merchant_raw":"CARREFOUR"}"#, id: 63, entity: ("txn", Ids.t1), parent: 2))
    let s = log.state
    #expect(s.txns[Ids.t1]?.category == "transport" && s.txns[Ids.t1]?.version == 3)
    #expect(s.txns[Ids.t1]?.merchantRaw == "CARREFOUR" && s.txns[Ids.t1]?.retiredBy == "op-60")
    #expect(s.txns[Ids.t2]?.category == "transport" && s.txns[Ids.t2]?.version == 2)
    #expect(s.anomalies.map(\.kind) == ["edit_of_retired", "edit_of_retired"])
    #expect(s.anomalies.map(\.atSeq) == [4, 5])
    #expect(!s.byFingerprint.values.contains { $0.contains(Ids.t1) })
  }

  @Test("when nothing of the row a notice names survives the remove, an open notice or a same answer clears and a different answer stays")
  func noticeOnRetiredRowClears() throws {
    var log = Log()
    try log.blob(ingest(1, id: Ids.t1, extra: Mbx.prov(Mbx.a, message: "m1")))
    try log.blob(ingest(2, id: Ids.t2, extra: #","entry_method":"manual""#))
    try log.blob(ingest(3, id: Ids.t3, extra: Mbx.prov(Mbx.b, message: "m3")))
    try log.blob(ingest(4, id: Ids.ulid(9), merchant: "ENOC", extra: Mbx.prov(Mbx.a, message: "m4")))
    try log.blob(ingest(5, id: Ids.ulid(10), merchant: "ENOC", extra: #","entry_method":"manual""#))
    try log.blob(ingest(6, id: Ids.ulid(11), merchant: "IKEA", extra: Mbx.prov(Mbx.a, message: "m6")))
    try log.blob(ingest(7, id: Ids.ulid(12), merchant: "IKEA", extra: #","entry_method":"manual""#))
    try log.blob(
      op(
        "txn_duplicate_disposition", #"{"other_txn_id":"\#(Ids.t1)","disposition":"same"}"#, id: 50, entity: ("txn", Ids.t2),
        parent: 1))
    try log.blob(
      op(
        "txn_duplicate_disposition", #"{"other_txn_id":"\#(Ids.ulid(11))","disposition":"different"}"#, id: 51,
        entity: ("txn", Ids.ulid(12)), parent: 1))
    #expect(log.state.txns[Ids.t2]?.possibleDuplicateOf == Ids.t1 && log.state.txns[Ids.t2]?.duplicateDisposition == "same")
    #expect(log.state.txns[Ids.t3]?.possibleDuplicateOf == Ids.t1)
    #expect(log.state.txns[Ids.ulid(10)]?.possibleDuplicateOf == Ids.ulid(9))
    try log.blob(Mbx.retire(Mbx.b, id: 59))
    #expect(log.state.txns[Ids.t2]?.possibleDuplicateOf == Ids.t1 && log.state.txns[Ids.t3]?.possibleDuplicateOf == Ids.t1)
    try log.blob(Mbx.retire(Mbx.a, id: 60))
    let s = log.state
    #expect(s.txns[Ids.t2]?.possibleDuplicateOf == nil && s.txns[Ids.t2]?.duplicateDisposition == nil)
    #expect(s.txns[Ids.t3]?.possibleDuplicateOf == nil && s.txns[Ids.t3]?.retiredBy == "op-59")
    #expect(s.txns[Ids.ulid(10)]?.possibleDuplicateOf == nil)
    #expect(s.txns[Ids.ulid(11)]?.retiredBy == "op-60")
    #expect(s.txns[Ids.ulid(12)]?.possibleDuplicateOf == Ids.ulid(11) && s.txns[Ids.ulid(12)]?.duplicateDisposition == "different")
    #expect(s.txns[Ids.t2]?.version == 2 && s.txns[Ids.t2]?.isLive == true)
    #expect(log.kinds == ["possible_duplicate", "possible_duplicate", "possible_duplicate", "possible_duplicate"])
  }

  @Test("when the remove promotes a merged copy of the row a notice names, the notice moves to that copy with its answer")
  func noticeMovesToPromotedCopy() throws {
    var log = Log()
    try log.blob(Copy.alert(1, id: Ids.t1, grant: Mbx.a, mid: Copy.mid))
    try log.blob(Copy.alert(2, id: Ids.t2, grant: Mbx.b, mid: Copy.mid))
    try log.blob(ingest(3, id: Ids.t3, amount: "2700", merchant: "STARBUCKS DIFC", extra: #","entry_method":"manual""#))
    try log.blob(Copy.alert(4, id: Ids.ulid(7), grant: Mbx.a, merchant: "ENOC", mid: "fedcba9876543210fedcba9876543210"))
    try log.blob(Copy.alert(5, id: Ids.ulid(8), grant: Mbx.b, merchant: "ENOC", mid: "fedcba9876543210fedcba9876543210"))
    try log.blob(ingest(6, id: Ids.ulid(9), amount: "2700", merchant: "ENOC", extra: #","entry_method":"manual""#))
    try log.blob(
      op(
        "txn_duplicate_disposition", #"{"other_txn_id":"\#(Ids.ulid(7))","disposition":"different"}"#, id: 50,
        entity: ("txn", Ids.ulid(9)), parent: 1))
    #expect(log.state.txns[Ids.t2]?.mergedInto == Ids.t1 && log.state.txns[Ids.t3]?.possibleDuplicateOf == Ids.t1)
    #expect(log.state.txns[Ids.ulid(8)]?.mergedInto == Ids.ulid(7) && log.state.txns[Ids.ulid(9)]?.possibleDuplicateOf == Ids.ulid(7))
    try log.blob(Mbx.retire(Mbx.a, id: 60))
    let s = log.state
    #expect(s.txns[Ids.t2]?.isLive == true && s.txns[Ids.ulid(8)]?.isLive == true)
    #expect(s.txns[Ids.t3]?.possibleDuplicateOf == Ids.t2 && s.txns[Ids.t3]?.duplicateDisposition == nil)
    #expect(s.txns[Ids.ulid(9)]?.possibleDuplicateOf == Ids.ulid(8) && s.txns[Ids.ulid(9)]?.duplicateDisposition == "different")
    #expect(s.txns.values.allSatisfy { $0.possibleDuplicateMovedFrom.isEmpty })
    #expect(log.kinds == ["possible_duplicate", "possible_duplicate"])
  }

  @Test("a notice that a merge moved goes back to the copy the remove promotes")
  func noticeReturnsToPromotedCopy() throws {
    var log = Log()
    try log.blob(Copy.alert(1, id: Ids.t1, grant: Mbx.a, mid: Copy.mid, gates: Copy.fail))
    try log.blob(ingest(3, id: Ids.t3, amount: "2700", merchant: "STARBUCKS DIFC", extra: #","entry_method":"manual""#))
    try log.blob(Copy.alert(2, id: Ids.t2, grant: Mbx.b, at: "2026-10-04T08:00:00.000Z", mid: Copy.mid, gates: Copy.pass))
    #expect(log.state.txns[Ids.t1]?.mergedInto == Ids.t2 && log.state.txns[Ids.t3]?.possibleDuplicateOf == Ids.t2)
    try log.blob(Mbx.retire(Mbx.b, id: 60))
    let s = log.state
    #expect(s.txns[Ids.t1]?.isLive == true && s.txns[Ids.t2]?.retiredBy == "op-60")
    #expect(s.txns[Ids.t3]?.possibleDuplicateOf == Ids.t1 && s.txns[Ids.t3]?.possibleDuplicateMovedFrom.isEmpty == true)
  }

  @Test("legacy rows join only when the op says so, and only for the same provider")
  func legacy() throws {
    func fold(legacy: Bool) throws -> State {
      var log = Log()
      try log.blob(ingest(1, id: Ids.t1, extra: Mbx.prov(Mbx.legacy, message: "m1")))
      try log.blob(ingest(2, id: Ids.t2, merchant: "ENOC", extra: Mbx.prov(Mbx.legacy, provider: "outlook", message: "m2")))
      try log.blob(ingest(3, id: Ids.t3, merchant: "IKEA", extra: Mbx.prov("u2", message: "m3")))
      try log.blob(Mbx.retire(Mbx.a, legacy: legacy, id: 60))
      return log.state
    }
    let on = try fold(legacy: true)
    #expect(on.txns[Ids.t1]?.retiredBy == "op-60")
    #expect(on.txns[Ids.t2]?.retiredBy == nil && on.txns[Ids.t3]?.retiredBy == nil)
    let off = try fold(legacy: false)
    #expect(off.txns.values.allSatisfy { $0.retiredBy == nil })
  }

  @Test("a malformed retire is an invalid payload and retires nothing")
  func malformed() throws {
    var log = Log()
    try log.blob(ingest(1, id: Ids.t1, extra: Mbx.prov(Mbx.a, message: "m1")))
    try log.blob(op("mailbox_retired", #"{"grant_id":"\#(Mbx.a)","provider":"gmail"}"#, id: 60))
    try log.blob(op("mailbox_retired", #"{"grant_id":"","provider":"gmail","legacy":false}"#, id: 61))
    try log.blob(op("mailbox_retired", #"{"grant_id":"\#(Mbx.a)","provider":"G","legacy":false}"#, id: 62))
    #expect(log.kinds == ["invalid_payload", "invalid_payload", "invalid_payload"])
    #expect(log.state.txns[Ids.t1]?.isLive == true && log.state.mailboxRetirements.isEmpty)
  }

  @Test("the op is parent-free and authorable")
  func registry() {
    #expect(OpType.mailboxRetired.isParentFree && OpType.mailboxRetired.minVersion == 4)
    #expect(MailboxGrant.account(of: Mbx.a) == "u1" && MailboxGrant.account(of: "u1") == "u1")
  }
}

@Suite("CoreReplay mailbox retire through a supersede")
struct MailboxRetireSupersedeTests {
  @Test("a v4 successor without provenance keeps its predecessor's mailbox")
  func successorInherits() throws {
    var log = Log()
    try log.blob(ingest(1, id: Ids.t1, extra: Mbx.prov(Mbx.a, message: "m1")))
    try log.blob(
      op(
        "txn_superseded",
        #"{"amount_minor":"5100","currency":"AED","direction":"debit","posted_at":"2026-10-03T08:00:00.000Z","merchant_raw":"CARREFOUR MOE","last4":"4412","needs_review":true}"#,
        id: 70, entity: ("txn", Ids.t2), ingest: Ids.ingest(1)))
    #expect(log.state.txns[Ids.t2]?.sourceMailbox == Mbx.a)
    try log.blob(Mbx.retire(Mbx.a, id: 71))
    #expect(log.state.txns[Ids.t2]?.retiredBy == "op-71")
    #expect(log.state.txns[Ids.t1]?.retiredBy == nil)
  }
}
