import CoreCategorize
import CoreReplay
import CoreWire
import Testing

@testable import CoreProjection

@Suite struct BillForkCreatedAtTests {
  static let writerA = "ios-0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"
  static let writerB = "ios-1a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"

  static func bill(_ id: String, op: String, at: String, parent: Int? = nil, amount: String = "5600", extra: String = "")
    -> String
  {
    #"{"v":4,"type":"bill_set","op_id":"\#(op)","authored_at":"\#(at)","entity":{"kind":"bill","id":"\#(id)"},"parent_version":\#(parent.map(String.init) ?? "null"),"payload":{"name":"Netflix","keys":["netflix"],"direction":"debit","currency":"AED","amount_mode":"fixed","amount_minor":"\#(amount)","tolerance_bp":200,"cadence":{"unit":"month","every":1},"anchor":"2026-01-06","start":"2026-01-06","end":null,"category":null,"account":null,"source":"detected","status":"active"\#(extra)}}"#
  }

  static func fold(_ blobs: [(writer: String, counter: Int64, ops: [String])]) throws -> State {
    var s = State()
    for (i, b) in blobs.enumerated() {
      try Replay.foldBlob(
        PositionedBlob(
          writerID: b.writer, writerCounter: b.counter, seq: Int64(i + 1),
          body: Array(#"{"v":4,"kind":"ops","ops":[\#(b.ops.joined(separator: ","))]}"#.utf8)),
        into: &s)
    }
    return s
  }

  @Test func aCreateCarriesAnEarlierCreatedAt() throws {
    let s = try Self.fold([
      (
        Self.writerA, 1,
        [
          Self.bill("bd_a", op: "op-a", at: "2026-10-10T09:40:00.000Z", extra: #","created_at":"2026-09-01T04:00:00.000Z""#),
          Self.bill("bd_b", op: "op-b", at: "2026-10-10T09:40:00.001Z", extra: #","created_at":"2026-11-01T04:00:00.000Z""#),
          Self.bill("bd_c", op: "op-c", at: "2026-10-10T09:40:00.002Z", extra: #","created_at":"yesterday""#),
        ]
      ),
      (Self.writerA, 2, [Self.bill("bd_a", op: "op-d", at: "2026-10-11T09:40:00.000Z", parent: 1, extra: #","created_at":"2026-01-01T00:00:00.000Z""#)]),
    ])
    #expect(s.anomalies.isEmpty)
    #expect(s.bills["bd_a"]?.createdAt == "2026-09-01T04:00:00.000Z")
    #expect(s.bills["bd_a"]?.version == 2)
    #expect(s.bills["bd_b"]?.createdAt == "2026-10-10T09:40:00.001Z")
    #expect(s.bills["bd_c"]?.createdAt == "2026-10-10T09:40:00.002Z")
  }

  @Test func forkNoticesAndTheLoserRecordAreReadable() throws {
    let create = Self.bill("bd_a", op: "op-create", at: "2026-10-01T08:00:00.000Z")
    let mine = Self.bill("bd_a", op: "op-mine", at: "2026-10-02T08:00:00.000Z", parent: 1, amount: "6300")
    let theirs = Self.bill("bd_a", op: "op-theirs", at: "2026-10-03T08:00:00.000Z", parent: 1, amount: "5900")
    let s = try Self.fold([(Self.writerA, 1, [create]), (Self.writerA, 2, [mine]), (Self.writerB, 1, [theirs])])
    #expect(s.bills["bd_a"]?.amountMinor == 5_900)
    let db = try Projector.open(path: nil)
    try Projector.project(s, dictionary: try MerchantDictionary.bundled().get(), projectedAtMs: 0, into: db)
    let reader = LedgerReader(db)
    let forks = try reader.forkNotices(kind: "bill")
    #expect(forks.count == 1)
    #expect(forks.first?.entityID == "bd_a" && forks.first?.winnerOp == "op-theirs" && forks.first?.loserOp == "op-mine")
    #expect(try reader.forkNotices(kind: "txn").isEmpty)
    let op = try #require(try OpCodec.decodeBlobOps(Array(#"{"v":4,"kind":"ops","ops":[\#(mine)]}"#.utf8)).first)
    let loser = try #require(Replay.billRecord(op))
    #expect(loser.amountMinor == 6_300 && loser.keys == ["netflix"] && loser.status == "active")
  }
}
