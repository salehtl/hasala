import CoreCategorize
import CoreReplay
import CoreWire
import GRDB
import Testing

@testable import CoreProjection

@Suite struct BillChangesProjectionTests {
  static func bill(_ id: String, _ extra: String, at: String) -> String {
    #"{"v":4,"type":"bill_set","op_id":"op-\#(id)","authored_at":"\#(at)","entity":{"kind":"bill","id":"\#(id)"},"parent_version":null,"payload":{"name":"Netflix","keys":["netflix"],"direction":"debit","currency":"AED","amount_mode":"fixed","amount_minor":"5600","tolerance_bp":200,"cadence":{"unit":"month","every":1},"anchor":"2026-01-06","start":"2026-01-06","end":null,"category":null,"account":null,"source":"manual","status":"active"\#(extra)}}"#
  }

  @Test func billsCarryChangesPausesAndCreatedAt() throws {
    #expect(ProjectionSchema.version == 12)
    var s = State()
    let ops = [
      Self.bill("bm_plain", "", at: "2026-10-01T08:00:00.000Z"),
      Self.bill(
        "bm_full",
        #","changes":[{"from":"2026-06-06","amount_mode":"fixed","amount_minor":"6300","tolerance_bp":100},{"from":"2026-09-06","amount_mode":"variable","amount_minor":"7000","tolerance_bp":null}],"pauses":[{"from":"2026-02-01","until":"2026-03-01"},{"from":"2026-08-01","until":null}]"#,
        at: "2026-10-02T08:00:00.000Z"),
    ].joined(separator: ",")
    try Replay.foldBlob(
      PositionedBlob(
        writerID: "ios-0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d", writerCounter: 1, seq: 1,
        body: Array(#"{"v":4,"kind":"ops","ops":[\#(ops)]}"#.utf8)),
      into: &s)
    #expect(s.anomalies.isEmpty)
    let db = try Projector.open(path: nil)
    try Projector.project(s, dictionary: try MerchantDictionary.bundled().get(), projectedAtMs: 0, into: db)
    let bills = try LedgerReader(db).bills()
    #expect(bills.map(\.id) == ["bm_plain", "bm_full"])
    #expect(bills[0].bill == s.bills["bm_plain"])
    #expect(bills[1].bill == s.bills["bm_full"])
    #expect(bills[0].bill.changes.isEmpty && bills[0].bill.pauses.isEmpty && bills[0].bill.createdAt == "2026-10-01T08:00:00.000Z")
    #expect(bills[1].bill.changes.count == 2 && bills[1].bill.pauses.last?.until == nil)
    let raw = try db.read { db in
      try Row.fetchAll(db, sql: "SELECT changes_json, pauses_json FROM bill ORDER BY first_seq, rowid").map {
        [$0["changes_json"] as String?, $0["pauses_json"] as String?]
      }
    }
    #expect(raw[0] == [nil, nil])
    #expect(raw[1][1] == #"[{"from":"2026-02-01","until":"2026-03-01"},{"from":"2026-08-01","until":null}]"#)
  }
}
