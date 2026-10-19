import CoreCategorize
import CoreReplay
import CoreWire
import Testing

@testable import CoreProjection

@Suite struct HomeSourceProjectionTests {
  static func blob(_ seq: Int64, _ ops: String, into s: inout State) throws {
    let body = Array(#"{"v":4,"kind":"ops","ops":[\#(ops)]}"#.utf8)
    try Replay.foldBlob(
      PositionedBlob(writerID: "ios-0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d", writerCounter: seq, seq: seq, body: body), into: &s)
  }

  static func txn(_ n: Int, _ ccy: String) -> String {
    let id = "01JC00000000000000000000\(n)0"
    let ingest = String(repeating: "0", count: 63) + "\(n)"
    return #"{"v":4,"type":"txn_ingested","op_id":"t\#(n)","authored_at":"2026-10-01T08:00:00.000Z","entity":{"kind":"txn","id":"\#(id)"},"parent_version":null,"ingest_id":"\#(ingest)","payload":{"amount_minor":"2500","currency":"\#(ccy)","direction":"debit","posted_at":"2026-10-03T08:00:00.000Z","merchant_raw":"SHOP \#(n)","last4":"4412","needs_review":true}}"#
  }

  @Test func theProjectionCarriesTheSource() throws {
    var s = State()
    try Self.blob(
      1,
      #"{"v":4,"type":"home_currency_set","op_id":"h","authored_at":"2026-10-01T08:00:00.000Z","parent_version":null,"payload":{"currency":"AED"}},{"v":4,"type":"rate_set","op_id":"r","authored_at":"2026-10-01T08:00:00.000Z","parent_version":null,"payload":{"currency":"USD","rate_micro":"3672500"}}"#,
      into: &s)
    try Self.blob(2, [Self.txn(1, "AED"), Self.txn(2, "USD"), Self.txn(3, "EUR"), Self.txn(4, "GBP")].joined(separator: ","), into: &s)
    try Self.blob(
      3,
      #"{"v":4,"type":"txn_edited","op_id":"e","authored_at":"2026-10-01T08:00:00.000Z","entity":{"kind":"txn","id":"01JC0000000000000000000040"},"parent_version":1,"payload":{"amount_home_minor":"10400"}}"#,
      into: &s)
    let db = try Projector.open(path: nil)
    try Projector.project(s, dictionary: try MerchantDictionary.bundled().get(), projectedAtMs: 0, into: db)
    let r = LedgerReader(db)
    #expect(try r.txn("01JC0000000000000000000010")?.homeSource == .identity)
    #expect(try r.txn("01JC0000000000000000000020")?.homeSource == .rate)
    #expect(try r.txn("01JC0000000000000000000020")?.amountHomeMinor == 9181)
    #expect(try r.txn("01JC0000000000000000000020")?.homeRateMicro == 3_672_500)
    #expect(try r.txn("01JC0000000000000000000040")?.homeRateMicro == nil)
    #expect(try r.txn("01JC0000000000000000000030")?.homeSource == nil)
    #expect(try r.txn("01JC0000000000000000000030")?.amountHomeMinor == nil)
    #expect(try r.txn("01JC0000000000000000000040")?.homeSource == .stated)
  }
}
