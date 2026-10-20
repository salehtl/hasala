import CoreCategorize
import CoreReplay
import CoreTime
import CoreWire
import Testing

@testable import CoreProjection

@Suite struct ModelSourceProjectionTests {
  static func id(_ n: Int) -> String { "01JC00000000000000000000\(n)0" }

  static func categorize(_ n: Int, tag: String, review: Bool) -> String {
    #"{"v":4,"type":"txn_categorized","op_id":"c\#(n)","authored_at":"2026-10-01T09:00:00.000Z","entity":{"kind":"txn","id":"\#(id(n))"},"parent_version":1,"payload":{"category":"dining","needs_review":\#(review),"source":{"kind":"model","model":"\#(tag)"}}}"#
  }

  @Test func onlyAFiledCloudAnswerIsConfirmedAndLeavesReview() throws {
    var s = State()
    try HomeSourceProjectionTests.blob(
      1,
      #"{"v":4,"type":"home_currency_set","op_id":"h","authored_at":"2026-10-01T08:00:00.000Z","parent_version":null,"payload":{"currency":"AED"}}"#,
      into: &s)
    try HomeSourceProjectionTests.blob(2, (1...4).map { HomeSourceProjectionTests.txn($0, "AED") }.joined(separator: ","), into: &s)
    try HomeSourceProjectionTests.blob(
      3,
      [
        Self.categorize(1, tag: "apple-fm/26.1", review: false), Self.categorize(2, tag: "cf-clef/1", review: false),
        Self.categorize(3, tag: "cf-clef/1", review: true), Self.categorize(4, tag: "apple-fm/26.1", review: true),
      ].joined(separator: ","), into: &s)
    #expect(s.anomalies.isEmpty)
    let db = try Projector.open(path: nil)
    try Projector.project(s, dictionary: try MerchantDictionary.bundled().get(), projectedAtMs: 0, into: db)
    let r = LedgerReader(db)
    #expect(try r.txn(Self.id(1))?.reviewLane == "uncategorized")
    #expect(try r.txn(Self.id(2))?.reviewLane == nil)
    #expect(try r.txn(Self.id(3))?.reviewLane == "needs_review")
    #expect(try r.txn(Self.id(4))?.reviewLane == "needs_review")
    #expect(try r.txn(Self.id(2))?.categorySourceRef == "cf-clef/1")
    let lines = try r.moneyLines(from: CivilDate(year: 2026, month: 10, day: 1)!, to: CivilDate(year: 2026, month: 10, day: 31)!)
    var confirmed: [String: Bool] = [:]
    for l in lines { confirmed[l.txnID] = l.confirmed }
    #expect(confirmed == [Self.id(1): false, Self.id(2): true, Self.id(3): false, Self.id(4): false])
    let rows = try r.sweepRows()
    #expect(rows.allSatisfy { $0.version == 2 })
  }

  @Test func sweepRowsCarryTheGatesTemplate() throws {
    var s = State()
    let gated = #"{"v":4,"type":"txn_ingested","op_id":"g5","authored_at":"2026-10-01T08:00:00.000Z","entity":{"kind":"txn","id":"\#(Self.id(5))"},"parent_version":null,"ingest_id":"\#(String(repeating: "0", count: 63))5","payload":{"amount_minor":"2500","currency":"AED","direction":"debit","posted_at":"2026-10-03T08:00:00.000Z","merchant_raw":"EXAMPLE PERSON NAME","last4":"4412","needs_review":true,"tier":"template","entry_method":"mailbox","bank":"enbd","gates":{"ar":"pass","sender":"trusted","template":"enbd.transfer.v1@2","card":"known","forwarded":false}}}"#
    try HomeSourceProjectionTests.blob(1, [HomeSourceProjectionTests.txn(1, "AED"), gated].joined(separator: ","), into: &s)
    #expect(s.anomalies.isEmpty)
    let db = try Projector.open(path: nil)
    try Projector.project(s, dictionary: try MerchantDictionary.bundled().get(), projectedAtMs: 0, into: db)
    var templates: [String: String?] = [:]
    for r in try LedgerReader(db).sweepRows() { templates[r.id] = r.template }
    #expect(templates == [Self.id(1): nil, Self.id(5): "enbd.transfer.v1@2"])
    #expect(TxnRow.template(gatesJSON: nil) == nil && TxnRow.template(gatesJSON: "not json") == nil)
  }
}
