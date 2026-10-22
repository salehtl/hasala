import CoreWire
import Foundation
import Testing

@testable import CoreReplay

@Suite struct HeadFiledAtTests {
  static let id = "01JC0000000000000000000010"
  static let other = "ios-1a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"

  static func fold(_ ops: [String], seq: Int64, writer: String = "ios-0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d", into s: inout State) throws {
    let body = Array(#"{"v":4,"kind":"ops","ops":[\#(ops.joined(separator: ","))]}"#.utf8)
    try Replay.foldBlob(PositionedBlob(writerID: writer, writerCounter: seq, seq: seq, body: body), into: &s)
  }

  static func ingest(_ extra: String = #","needs_review":true"#) -> String {
    #"{"v":4,"type":"txn_ingested","op_id":"t1","authored_at":"2026-10-01T08:00:00.000Z","entity":{"kind":"txn","id":"\#(id)"},"parent_version":null,"ingest_id":"\#(String(repeating: "0", count: 63))1","payload":{"amount_minor":"2500","currency":"USD","direction":"debit","posted_at":"2026-10-03T08:00:00.000Z","merchant_raw":"TAILSCALE INC","last4":"4412"\#(extra)}}"#
  }

  static func categorize(_ op: String, parent: Int, at: String) -> String {
    #"{"v":4,"type":"txn_categorized","op_id":"\#(op)","authored_at":"\#(at)","entity":{"kind":"txn","id":"\#(id)"},"parent_version":\#(parent),"payload":{"category":"subscriptions","needs_review":false,"source":{"kind":"user"}}}"#
  }

  static func edit(_ op: String, parent: Int, at: String) -> String {
    #"{"v":4,"type":"txn_edited","op_id":"\#(op)","authored_at":"\#(at)","entity":{"kind":"txn","id":"\#(id)"},"parent_version":\#(parent),"payload":{"amount_home_minor":"9200"}}"#
  }

  static var head: (State) -> EntityHead? { { $0.heads[State.entityKey("txn", id)] } }

  @Test func onlyACategorizeMovesTheFiledAt() throws {
    var s = State()
    try Self.fold([Self.ingest()], seq: 1, into: &s)
    #expect(Self.head(s)?.categorizedAtMs == nil)
    try Self.fold([Self.categorize("c1", parent: 1, at: "2026-10-20T09:00:00.000Z")], seq: 2, into: &s)
    #expect(Self.head(s)?.categorizedAtMs == 1_792_486_800_000)
    try Self.fold([Self.edit("e1", parent: 2, at: "2026-10-21T09:00:00.000Z")], seq: 3, into: &s)
    #expect(Self.head(s)?.opID == "e1")
    #expect(Self.head(s)?.categorizedAtMs == 1_792_486_800_000)
    try Self.fold([Self.categorize("c0", parent: 1, at: "2026-10-19T09:00:00.000Z")], seq: 4, writer: Self.other, into: &s)
    #expect(s.forks.last?.winnerOp == "e1")
    #expect(Self.head(s)?.categorizedAtMs == 1_792_486_800_000)
    try Self.fold([Self.categorize("c2", parent: 2, at: "2026-10-22T09:00:00.000Z")], seq: 5, writer: Self.other, into: &s)
    #expect(s.forks.last?.winnerOp == "c2")
    #expect(Self.head(s)?.categorizedAtMs == 1_792_659_600_000)
    #expect(s.anomalies.isEmpty)
  }

  @Test func aCreateIsFiledOnlyWhenARuleFiledIt() throws {
    var rule = State()
    try Self.fold(
      [Self.ingest(#","category":"subscriptions","category_source":{"kind":"rule","rule_id":"01JC0000000000000000000R10"},"needs_review":false"#)],
      seq: 1, into: &rule)
    #expect(Self.head(rule)?.categorizedAtMs == 1_790_841_600_000)
    var dictionary = State()
    try Self.fold(
      [Self.ingest(#","category":"subscriptions","category_source":{"kind":"dictionary","bundle":"2026.10.21-1","entry":"contains:tailscale"},"needs_review":false"#)],
      seq: 1, into: &dictionary)
    #expect(Self.head(dictionary)?.categorizedAtMs == nil)
    #expect(rule.anomalies.isEmpty && dictionary.anomalies.isEmpty)
  }

  @Test func anUnreadableAuthoredTimeIsNoFiledAt() {
    #expect(State.filedAt(0) == nil)
    #expect(State.filedAt(1_792_486_800_000) == 1_792_486_800_000)
  }

  @Test func theWitnessDoesNotCarryItAndASnapshotKeepsIt() throws {
    var s = State()
    try Self.fold([Self.ingest(), Self.categorize("c1", parent: 1, at: "2026-10-20T09:00:00.000Z")], seq: 1, into: &s)
    let w = String(decoding: s.serialized(), as: UTF8.self)
    #expect(!w.contains("categorized_at") && !w.contains("categorizedAt"))
    let back = try SnapshotCodec.decode(try SnapshotCodec.encode(StateSnapshot(state: s))).state
    #expect(Self.head(back)?.categorizedAtMs == 1_792_486_800_000)
    #expect(back == s)
  }

  @Test func aSnapshotFromBeforeTheFiledAtIsRefused() throws {
    var s = State()
    try Self.fold([Self.ingest()], seq: 1, into: &s)
    var old = StateSnapshot(state: s)
    old.formatVersion = 3
    #expect(throws: SnapshotError.version) { try SnapshotCodec.decode(try SnapshotCodec.encode(old)) }
  }
}
