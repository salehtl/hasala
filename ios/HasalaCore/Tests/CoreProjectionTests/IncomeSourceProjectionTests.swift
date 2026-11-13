import CoreCategorize
import CoreDomain
import CoreReplay
import CoreTime
import CoreWire
import GRDB
import Testing

@testable import CoreProjection

@Suite struct IncomeSourceProjectionTests {
  static func blob(_ seq: Int64, _ ops: String, into s: inout State) throws {
    let body = Array(#"{"v":4,"kind":"ops","ops":[\#(ops)]}"#.utf8)
    try Replay.foldBlob(
      PositionedBlob(writerID: "ios-0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d", writerCounter: seq, seq: seq, body: body), into: &s)
  }

  static func paycheck(_ n: Int, _ postedAt: String) -> String {
    let id = "01JC00000000000000000000\(n)0"
    let ingest = String(repeating: "0", count: 63) + "\(n)"
    return #"{"v":4,"type":"txn_ingested","op_id":"t\#(n)","authored_at":"\#(postedAt)","entity":{"kind":"txn","id":"\#(id)"},"parent_version":null,"ingest_id":"\#(ingest)","payload":{"amount_minor":"2500000","currency":"AED","direction":"credit","posted_at":"\#(postedAt)","merchant_raw":"PAYROLL","last4":"4412","needs_review":false,"category":"salary","category_source":{"kind":"user"}}}"#
  }

  static func source(active: Bool, at: String) -> String {
    #"{"v":4,"type":"income_source_set","op_id":"s-\#(at)","authored_at":"\#(at)","parent_version":null,"payload":{"id":"salary-1","name":"Salary","category_id":"salary","amount_minor":"2500000","payday":1,"active":\#(active)}}"#
  }

  @Test func anInactiveSourceKeepsItsPaydayForPaychecksUpToTheWriteThatTurnedItOff() throws {
    #expect(ProjectionSchema.version == 13)
    var s = State()
    try Self.blob(
      1, #"{"v":4,"type":"home_currency_set","op_id":"h","authored_at":"2026-09-01T08:00:00.000Z","parent_version":null,"payload":{"currency":"AED"}}"#,
      into: &s)
    try Self.blob(2, Self.source(active: true, at: "2026-09-01T08:00:00.000Z"), into: &s)
    try Self.blob(3, [Self.paycheck(1, "2026-10-30T08:00:00.000Z"), Self.paycheck(2, "2026-10-31T08:00:00.000Z")].joined(separator: ","), into: &s)
    try Self.blob(4, Self.source(active: false, at: "2026-10-31T08:00:00.000Z"), into: &s)
    try Self.blob(5, Self.paycheck(3, "2026-11-29T08:00:00.000Z"), into: &s)
    #expect(s.anomalies.isEmpty)
    let db = try Projector.open(path: nil)
    try Projector.project(s, dictionary: try MerchantDictionary.bundled().get(), projectedAtMs: 0, into: db)
    let r = LedgerReader(db)
    #expect(try r.planState().incomeSources["salary-1"]?.write.atMs == 1_793_433_600_000)
    let november = CivilMonth(year: 2026, month: 11)!
    let e = try r.planEngine(month: november, today: CivilDate(year: 2026, month: 11, day: 30)!)
    #expect(e.received(CivilMonth(year: 2026, month: 10)!, "salary") == 0)
    #expect(e.received(november, "salary") == 7_500_000)
    #expect(e.received(CivilMonth(year: 2026, month: 12)!, "salary") == 0)
  }
}
