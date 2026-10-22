import CoreCategorize
import CoreReplay
import CoreTime
import CoreWire
import GRDB
import Testing

@testable import CoreProjection

@Suite struct MerchantGroupProjectionTests {
  static func id(_ n: Int) -> String { "01JC" + String(repeating: "0", count: 21 - "\(n)".count) + "\(n)0" }

  static func txn(
    _ n: Int, _ merchant: String, posted: String, direction: String = "debit", at: String = "2026-10-01T08:00:00.000Z", extra: String = #","needs_review":true"#
  ) -> String {
    let ingest = String(repeating: "0", count: 64 - "\(n)".count) + "\(n)"
    return #"{"v":4,"type":"txn_ingested","op_id":"t\#(n)","authored_at":"\#(at)","entity":{"kind":"txn","id":"\#(id(n))"},"parent_version":null,"ingest_id":"\#(ingest)","payload":{"amount_minor":"\#(1000 + n)","currency":"AED","direction":"\#(direction)","posted_at":"\#(posted)","merchant_raw":"\#(merchant)","last4":"4412"\#(extra)}}"#
  }

  static func categorize(_ n: Int, op: String, parent: Int, at: String, category: String = "subscriptions") -> String {
    #"{"v":4,"type":"txn_categorized","op_id":"\#(op)","authored_at":"\#(at)","entity":{"kind":"txn","id":"\#(id(n))"},"parent_version":\#(parent),"payload":{"category":"\#(category)","needs_review":false,"source":{"kind":"user"}}}"#
  }

  static func split(_ n: Int, op: String, parent: Int, at: String) -> String {
    #"{"v":4,"type":"txn_split","op_id":"\#(op)","authored_at":"\#(at)","entity":{"kind":"txn","id":"\#(id(n))"},"parent_version":\#(parent),"payload":{"parts":[{"category":"dining","amount_minor":"500"},{"category":"groceries","amount_minor":"\#(1000 + n - 500)"}]}}"#
  }

  static func blob(_ seq: Int64, _ ops: [String], writer: String = "ios-0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d", into s: inout State) throws {
    let body = Array(#"{"v":4,"kind":"ops","ops":[\#(ops.joined(separator: ","))]}"#.utf8)
    try Replay.foldBlob(PositionedBlob(writerID: writer, writerCounter: seq, seq: seq, body: body), into: &s)
  }

  static func project(_ s: State, pending: [[Op]] = []) throws -> (DatabaseQueue, LedgerReader) {
    let db = try Projector.open(path: nil)
    try Projector.project(
      s, pending: pending, writerID: "ios-0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d", dictionary: try MerchantDictionary.bundled().get(),
      projectedAtMs: 0, into: db)
    return (db, LedgerReader(db))
  }

  static func ms(_ instant: String) -> Int64 { (try? parseInstantMs(instant)) ?? -1 }

  @Test func spellingsOfOneMerchantShareAGroupAndTheReaderFindsThem() throws {
    var s = State()
    try Self.blob(
      1,
      [
        Self.txn(1, "TAILSCALE INC", posted: "2026-08-03T08:00:00.000Z"),
        Self.txn(2, "TAILSCALE.COM 4155550100 US", posted: "2026-09-03T08:00:00.000Z"),
        Self.txn(3, "PADDLE.NET* TAILSCALE", posted: "2026-10-03T08:00:00.000Z"),
        Self.txn(4, "AL NOOR TRADING LLC", posted: "2026-10-04T08:00:00.000Z"),
        Self.txn(5, "AL NOOR PHARMACY", posted: "2026-10-05T08:00:00.000Z"),
        Self.txn(6, "PAYPAL *NETFLIX", posted: "2026-10-06T08:00:00.000Z"),
        Self.txn(7, "TAILSCALE INC", posted: "2026-10-07T08:00:00.000Z", direction: "credit"),
      ], into: &s)
    #expect(s.anomalies.isEmpty)
    let (_, r) = try Self.project(s)
    var groups: [String: String] = [:]
    for n in 1...7 { groups[Self.id(n)] = try #require(try r.txn(Self.id(n))).merchantGroup }
    #expect(groups[Self.id(1)] == "n:tailscale" && groups[Self.id(2)] == "n:tailscale" && groups[Self.id(3)] == "n:tailscale")
    #expect(groups[Self.id(4)] == "n:al noor trading" && groups[Self.id(5)] == "n:al noor pharmacy")
    #expect(groups[Self.id(6)] == "d:netflix")
    #expect(groups[Self.id(7)] == "n:tailscale")
    #expect(try r.txn(Self.id(1))?.merchantKey != r.txn(Self.id(2))?.merchantKey)

    let tailscale = try r.group("n:tailscale")
    #expect(tailscale.map(\.id) == [7, 3, 2, 1].map(Self.id))
    #expect(try r.group("n:tailscale", limit: 2).map(\.id) == [7, 3].map(Self.id))
    #expect(try r.group("n:tailscale", limit: 0).isEmpty)
    #expect(try r.group("n:al noor").isEmpty)
    let sweep = try r.sweepRows(group: "n:tailscale")
    #expect(sweep.map(\.id) == tailscale.map(\.id))
    #expect(sweep.allSatisfy { $0.merchantGroup == "n:tailscale" })
    #expect(try r.sweepRows().first { $0.id == Self.id(4) }?.merchantGroup == "n:al noor trading")
  }

  @Test func theGroupColumnIsIndexedAndTheSchemaIsBumped() throws {
    #expect(ProjectionSchema.version == 8)
    let (db, r) = try Self.project(State())
    let indexes = try db.read { db in
      try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'txn' AND sql LIKE '%merchant_group%'")
    }
    #expect(indexes == ["txn_merchant_group"])
    let statements: [(String, StatementArguments)] = [
      (LedgerReader.groupSQL, ["n:x"]), (LedgerReader.groupSQL + " LIMIT ?", ["n:x", 2]), (LedgerReader.sweepGroupSQL, ["n:x"]),
    ]
    for (sql, arguments) in statements {
      let plan = try db.read { db in
        try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + sql, arguments: arguments).map { $0["detail"] as String }
      }
      #expect(plan.contains { $0.contains("txn_merchant_group") }, "\(sql): \(plan)")
      #expect(!plan.contains { $0.contains("TEMP B-TREE") }, "\(sql): \(plan)")
    }
    #expect(try r.isUsable())
  }

  @Test func aGroupIsNotCutWithoutALimit() throws {
    var s = State()
    for chunk in 0..<6 {
      try Self.blob(Int64(chunk + 1), (1...200).map { Self.txn(chunk * 200 + $0, "TAILSCALE INC", posted: "2026-08-03T08:00:00.000Z") }, into: &s)
    }
    #expect(s.anomalies.isEmpty)
    let (_, r) = try Self.project(s)
    #expect(try r.group("n:tailscale").count == 1_200)
    #expect(try r.group("n:tailscale", limit: 1_000).count == 1_000)
    #expect(try r.sweepRows(group: "n:tailscale").count == 1_200)
  }

  @Test func rowsWithNoMerchantShareNoGroup() throws {
    var s = State()
    try Self.blob(
      1,
      [
        Self.txn(1, "", posted: "2026-10-03T08:00:00.000Z"),
        Self.txn(2, "", posted: "2026-10-04T08:00:00.000Z"),
        Self.txn(3, "   ", posted: "2026-10-05T08:00:00.000Z"),
      ], into: &s)
    #expect(s.anomalies.isEmpty)
    let (db, r) = try Self.project(s)
    for n in 1...3 { #expect(try #require(try r.txn(Self.id(n))).merchantGroup == nil) }
    #expect(try r.group("").isEmpty)
    #expect(try r.sweepRows(group: "").isEmpty)
    #expect(try r.sweepRows().filter { $0.merchantGroup == nil }.count == 3)
    let nulls = try db.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM txn WHERE merchant_group IS NULL") }
    #expect(nulls == 3)
  }

  @Test func filedAtIsTheAuthoredTimeOfTheCategorizeAtTheHead() throws {
    var s = State()
    try Self.blob(
      1,
      [
        Self.txn(1, "TAILSCALE INC", posted: "2026-08-03T08:00:00.000Z"),
        Self.txn(2, "TAILSCALE INC", posted: "2026-08-04T08:00:00.000Z"),
        Self.txn(3, "TAILSCALE INC", posted: "2026-08-05T08:00:00.000Z"),
      ], into: &s)
    try Self.blob(
      2,
      [
        Self.categorize(1, op: "c1", parent: 1, at: "2026-10-20T09:00:00.000Z"),
        Self.categorize(2, op: "c2", parent: 1, at: "2026-10-20T09:00:00.000Z"),
        Self.categorize(2, op: "c2b", parent: 2, at: "2026-10-21T10:30:00.000Z"),
        Self.categorize(3, op: "c3", parent: 1, at: "2026-10-20T09:00:00.000Z"),
        Self.split(3, op: "s3", parent: 2, at: "2026-10-22T09:00:00.000Z"),
      ], into: &s)
    #expect(s.anomalies.isEmpty)
    let (_, r) = try Self.project(s)
    #expect(try r.txn(Self.id(1))?.categorizedMs == Self.ms("2026-10-20T09:00:00.000Z"))
    #expect(try r.txn(Self.id(2))?.categorizedMs == Self.ms("2026-10-21T10:30:00.000Z"))
    #expect(try r.txn(Self.id(3))?.categorizedMs == nil)
    let sweep = try r.sweepRows()
    #expect(sweep.first { $0.id == Self.id(2) }?.categorizedMs == Self.ms("2026-10-21T10:30:00.000Z"))
  }

  @Test func aRuleFilingOnIngestIsFiledAtTheIngest() throws {
    var s = State()
    let rule = #","category":"subscriptions","category_source":{"kind":"rule","rule_id":"01JC0000000000000000000R10"},"needs_review":false"#
    let dictionary = #","category":"subscriptions","category_source":{"kind":"dictionary","bundle":"2026.10.21-1","entry":"contains:netflix"},"needs_review":false"#
    try Self.blob(
      1,
      [
        Self.txn(1, "TAILSCALE INC", posted: "2026-10-03T08:00:00.000Z", at: "2026-10-03T09:15:00.000Z", extra: rule),
        Self.txn(2, "NETFLIX.COM", posted: "2026-10-03T08:00:00.000Z", at: "2026-10-03T09:15:00.000Z", extra: dictionary),
        Self.txn(3, "TAILSCALE INC", posted: "2026-10-04T08:00:00.000Z", at: "2026-10-04T09:15:00.000Z", extra: rule),
      ], into: &s)
    try Self.blob(2, [Self.split(3, op: "s3", parent: 1, at: "2026-10-05T09:00:00.000Z")], into: &s)
    #expect(s.anomalies.isEmpty)
    let (_, r) = try Self.project(s)
    #expect(try r.txn(Self.id(1))?.categorySource == "rule")
    #expect(try r.txn(Self.id(1))?.categorizedMs == Self.ms("2026-10-03T09:15:00.000Z"))
    #expect(try r.txn(Self.id(2))?.categorySource == "dictionary")
    #expect(try r.txn(Self.id(2))?.categorizedMs == nil)
    #expect(try r.txn(Self.id(3))?.categorizedMs == nil)
  }

  @Test func anUnreadableAuthoredTimeIsNoFiledAt() throws {
    var s = State()
    try Self.blob(1, [Self.txn(1, "TAILSCALE INC", posted: "2026-08-03T08:00:00.000Z")], into: &s)
    try Self.blob(2, [Self.categorize(1, op: "c1", parent: 1, at: "2026-10-20T09:00:00.000Z")], into: &s)
    let key = State.entityKey("txn", Self.id(1))
    #expect(s.heads[key]?.authoredAtMs == Self.ms("2026-10-20T09:00:00.000Z"))
    s.heads[key]?.authoredAtMs = 0
    let (_, r) = try Self.project(s)
    #expect(try r.txn(Self.id(1))?.categorizedMs == nil)
  }

  @Test func aRowNeverCategorizedHasNoFiledAt() throws {
    var s = State()
    try Self.blob(1, [Self.txn(1, "NETFLIX.COM", posted: "2026-08-03T08:00:00.000Z")], into: &s)
    let (_, r) = try Self.project(s)
    let row = try #require(try r.txn(Self.id(1)))
    #expect(row.categorizedMs == nil)
    #expect(row.merchantGroup == "d:netflix")
  }

  @Test func aForkKeepsTheWinnersFiledAt() throws {
    var s = State()
    try Self.blob(1, [Self.txn(1, "TAILSCALE INC", posted: "2026-08-03T08:00:00.000Z")], into: &s)
    try Self.blob(2, [Self.categorize(1, op: "late", parent: 1, at: "2026-10-21T09:00:00.000Z")], into: &s)
    try Self.blob(
      3, [Self.categorize(1, op: "early", parent: 1, at: "2026-10-20T09:00:00.000Z", category: "shopping")],
      writer: "ios-1a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d", into: &s)
    try Self.blob(
      4, [Self.categorize(1, op: "later", parent: 1, at: "2026-10-22T09:00:00.000Z", category: "groceries")],
      writer: "ios-2a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d", into: &s)
    #expect(s.forks.count == 2)
    let (_, r) = try Self.project(s)
    let row = try #require(try r.txn(Self.id(1)))
    #expect(row.category == "groceries")
    #expect(row.categorizedMs == Self.ms("2026-10-22T09:00:00.000Z"))
  }

  @Test func aPendingCategorizeSetsFiledAt() throws {
    var s = State()
    try Self.blob(1, [Self.txn(1, "TAILSCALE INC", posted: "2026-08-03T08:00:00.000Z")], into: &s)
    let ops = try OpCodec.decodeBlobOps(
      Array(#"{"v":4,"kind":"ops","ops":[\#(Self.categorize(1, op: "p1", parent: 1, at: "2026-10-22T07:00:00.000Z"))]}"#.utf8))
    let (_, r) = try Self.project(s, pending: [ops])
    let row = try #require(try r.txn(Self.id(1)))
    #expect(row.pending)
    #expect(row.categorizedMs == Self.ms("2026-10-22T07:00:00.000Z"))
  }
}
