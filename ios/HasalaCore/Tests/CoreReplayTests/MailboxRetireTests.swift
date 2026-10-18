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
