import CoreCategorize
import CoreReplay
import CoreWire
import Testing

@testable import CoreProjection

@Suite struct RefundLinkProjectionTests {
  static func blob(_ seq: Int64, _ ops: String, into s: inout State) throws {
    let body = Array(#"{"v":4,"kind":"ops","ops":[\#(ops)]}"#.utf8)
    try Replay.foldBlob(
      PositionedBlob(writerID: "ios-0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d", writerCounter: seq, seq: seq, body: body), into: &s)
  }

  static func id(_ n: Int) -> String { "01JC00000000000000000000\(n)0" }

  static func txn(_ n: Int, _ direction: String) -> String {
    let ingest = String(repeating: "0", count: 63) + "\(n)"
    return #"{"v":4,"type":"txn_ingested","op_id":"t\#(n)","authored_at":"2026-10-01T08:00:00.000Z","entity":{"kind":"txn","id":"\#(id(n))"},"parent_version":null,"ingest_id":"\#(ingest)","payload":{"amount_minor":"2500","currency":"AED","direction":"\#(direction)","posted_at":"2026-10-03T08:00:00.000Z","merchant_raw":"SHOP \#(n)","last4":"4412","needs_review":true}}"#
  }

  static func refund(_ n: Int, of target: String) -> String {
    #"{"v":4,"type":"txn_annotated","op_id":"a\#(n)","authored_at":"2026-10-01T08:00:00.000Z","parent_version":null,"payload":{"txn_id":"\#(id(n))","set":{"refund_of":"\#(target)"}}}"#
  }

  @Test func aRowCarriesItsRefundLinkAsWrittenWhetherOrNotItResolves() throws {
    var s = State()
    try Self.blob(1, [Self.txn(1, "debit"), Self.txn(2, "credit"), Self.txn(3, "credit")].joined(separator: ","), into: &s)
    try Self.blob(2, [Self.refund(2, of: Self.id(1)), Self.refund(3, of: Self.id(9))].joined(separator: ","), into: &s)
    #expect(s.anomalies.isEmpty)
    let db = try Projector.open(path: nil)
    try Projector.project(s, dictionary: try MerchantDictionary.bundled().get(), projectedAtMs: 0, into: db)
    let r = LedgerReader(db)
    let matched = try #require(try r.txn(Self.id(2)))
    #expect(matched.refundOf == Self.id(1) && matched.refundTarget == Self.id(1) && matched.refundState == "ok")
    let unresolved = try #require(try r.txn(Self.id(3)))
    #expect(unresolved.refundOf == Self.id(9) && unresolved.refundTarget == nil && unresolved.refundState == "broken")
    #expect(try r.txn(Self.id(1))?.refundOf == nil)
  }
}
