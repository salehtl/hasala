import CoreWire
import Foundation
import Testing

@testable import CoreReplay

@Suite struct HeadOpTypeTests {
  static let id = "01JC0000000000000000000010"

  static func fold(_ ops: [String], seq: Int64, writer: String = "ios-0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d", into s: inout State) throws {
    let body = Array(#"{"v":4,"kind":"ops","ops":[\#(ops.joined(separator: ","))]}"#.utf8)
    try Replay.foldBlob(PositionedBlob(writerID: writer, writerCounter: seq, seq: seq, body: body), into: &s)
  }

  static let ingest =
    #"{"v":4,"type":"txn_ingested","op_id":"t1","authored_at":"2026-10-01T08:00:00.000Z","entity":{"kind":"txn","id":"\#(id)"},"parent_version":null,"ingest_id":"\#(String(repeating: "0", count: 63))1","payload":{"amount_minor":"2500","currency":"AED","direction":"debit","posted_at":"2026-10-03T08:00:00.000Z","merchant_raw":"TAILSCALE INC","last4":"4412","needs_review":true}}"#

  static func categorize(_ op: String, parent: Int, at: String) -> String {
    #"{"v":4,"type":"txn_categorized","op_id":"\#(op)","authored_at":"\#(at)","entity":{"kind":"txn","id":"\#(id)"},"parent_version":\#(parent),"payload":{"category":"subscriptions","needs_review":false,"source":{"kind":"user"}}}"#
  }

  static var head: (State) -> EntityHead? { { $0.heads[State.entityKey("txn", id)] } }

  @Test func theHeadNamesTheTypeOfItsOp() throws {
    var s = State()
    try Self.fold([Self.ingest], seq: 1, into: &s)
    #expect(Self.head(s)?.opType == "txn_ingested")
    try Self.fold([Self.categorize("c1", parent: 1, at: "2026-10-20T09:00:00.000Z")], seq: 2, into: &s)
    #expect(Self.head(s)?.opType == "txn_categorized")
    #expect(Self.head(s)?.authoredAtMs == 1_792_486_800_000)
    try Self.fold(
      [Self.categorize("c0", parent: 1, at: "2026-10-19T09:00:00.000Z")], seq: 3, writer: "ios-1a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d",
      into: &s)
    #expect(s.forks.last?.winnerOp == "c1")
    #expect(Self.head(s)?.opType == "txn_categorized" && Self.head(s)?.opID == "c1")
    #expect(s.anomalies.isEmpty)
  }

  @Test func theWitnessDoesNotCarryItAndASnapshotKeepsIt() throws {
    var s = State()
    try Self.fold([Self.ingest, Self.categorize("c1", parent: 1, at: "2026-10-20T09:00:00.000Z")], seq: 1, into: &s)
    let w = String(decoding: s.serialized(), as: UTF8.self)
    #expect(!w.contains("op_type") && !w.contains("opType"))
    let back = try SnapshotCodec.decode(try SnapshotCodec.encode(StateSnapshot(state: s))).state
    #expect(Self.head(back)?.opType == "txn_categorized")
    #expect(back == s)
  }

  @Test func aSnapshotFromBeforeTheHeadTypeIsRefused() throws {
    var s = State()
    try Self.fold([Self.ingest], seq: 1, into: &s)
    var old = StateSnapshot(state: s)
    old.formatVersion = 3
    #expect(throws: SnapshotError.version) { try SnapshotCodec.decode(try SnapshotCodec.encode(old)) }
  }
}
