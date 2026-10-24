import CoreCategorize
import CoreDomain
import CoreReplay
import CoreTestSupport
import CoreWire
import GRDB
import Testing

@testable import CoreProjection

@Suite struct SortingProjectionTests {
  typealias M = MerchantGroupProjectionTests
  static let writer = "ios-0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"
  static let other = "ios-1b2c3d4e-5f60-4b7c-8d9e-0f1a2b3c4d5e"

  static func rejection(_ key: String, _ category: String, _ rejected: Bool, op: String, at: String = "2026-10-10T08:00:00.000Z") -> String {
    #"{"v":4,"type":"merchant_category_rejected","op_id":"\#(op)","authored_at":"\#(at)","parent_version":null,"payload":{"merchant_key":"\#(key)","category":"\#(category)","rejected":\#(rejected)}}"#
  }

  static func rename(_ key: String, _ name: String, op: String, at: String = "2026-10-10T08:00:00.000Z") -> String {
    #"{"v":4,"type":"merchant_named","op_id":"\#(op)","authored_at":"\#(at)","parent_version":null,"payload":{"merchant_key":"\#(key)","display_name":"\#(name)"}}"#
  }

  static func context(_ s: State, random: SeededRandom) -> AuthorContext {
    AuthorContext(writerID: writer, nowMs: 1_791_000_000_000, ownLastMs: nil, maxAuthored: [:], random: random)
  }

  static func fold(_ blobs: [AuthoredBlob], seq: inout Int64, into s: inout State) throws {
    for b in blobs {
      seq += 1
      try Replay.foldOps(b.ops, seq: seq, writerID: writer, into: &s)
    }
  }

  @Test func rejectionsAreKeptPerMerchantKeyAndReadPerGroup() throws {
    var s = State()
    try M.blob(
      1,
      [
        M.txn(1, "TAILSCALE.COM", posted: "2026-10-01T08:00:00.000Z"),
        M.txn(2, "TAILSCALE INC", posted: "2026-10-02T08:00:00.000Z"),
        M.txn(3, "AL NOOR PHARMACY", posted: "2026-10-03T08:00:00.000Z"),
      ], into: &s)
    try M.blob(2, [Self.rejection("tailscale.com", "shopping", true, op: "r1")], into: &s)
    try M.blob(3, [Self.rejection("tailscale inc", "shopping", true, op: "r2")], writer: Self.other, into: &s)
    try M.blob(4, [Self.rejection("tailscale inc", "dining", true, op: "r3")], into: &s)
    try M.blob(5, [Self.rejection("tailscale inc", "dining", false, op: "r4", at: "2026-10-01T00:00:00.000Z")], into: &s)
    #expect(s.anomalies.isEmpty)
    #expect(s.merchantRejections.count == 3)
    #expect(s.merchantRejections[State.rejectionKey("tailscale inc", "dining")]?.rejected == false)
    let (db, r) = try M.project(s)
    #expect(try r.rejections() == ["n:tailscale": ["shopping"]])
    let sweep = try r.sweepRows()
    #expect(sweep.first { $0.id == M.id(1) }?.rejected == ["shopping"])
    #expect(sweep.first { $0.id == M.id(3) }?.rejected == [])
    let stored = try db.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM merchant_rejection WHERE merchant_group = 'n:tailscale'") }
    #expect(stored == 3)

    try M.blob(6, [M.txn(4, "PAYPAL *TAILSCALE", posted: "2026-10-04T08:00:00.000Z")], into: &s)
    let (_, later) = try M.project(s)
    #expect(try later.sweepRows().first { $0.id == M.id(4) }?.rejected == ["shopping"])
  }

  static func filed(_ n: Int, op: String, at: String, category: String, source: String, review: Bool = false) -> String {
    #"{"v":4,"type":"txn_categorized","op_id":"\#(op)","authored_at":"\#(at)","entity":{"kind":"txn","id":"\#(M.id(n))"},"parent_version":1,"payload":{"category":"\#(category)","needs_review":\#(review),"source":\#(source)}}"#
  }

  @Test func theReaderFillsThePersonsLastPickPerGroupAndDirection() throws {
    var s = State()
    try M.blob(
      1,
      [
        M.txn(1, "TAILSCALE.COM", posted: "2026-08-01T08:00:00.000Z"),
        M.txn(2, "TAILSCALE INC", posted: "2026-07-15T08:00:00.000Z"),
        M.txn(3, "TAILSCALE.COM", posted: "2026-09-01T08:00:00.000Z"),
        M.txn(4, "TAILSCALE.COM", posted: "2026-09-02T08:00:00.000Z"),
        M.txn(5, "TAILSCALE.COM", posted: "2026-10-01T08:00:00.000Z"),
        M.txn(6, "TAILSCALE INC", posted: "2026-10-02T08:00:00.000Z", direction: "credit"),
        M.txn(7, "AL NOOR PHARMACY", posted: "2026-10-03T08:00:00.000Z"),
      ], into: &s)
    try M.blob(
      2,
      [
        Self.filed(1, op: "p1", at: "2026-10-05T09:00:00.000Z", category: "subscriptions", source: #"{"kind":"user"}"#),
        Self.filed(2, op: "p2", at: "2026-10-07T09:00:00.000Z", category: "shopping", source: #"{"kind":"user"}"#),
        Self.filed(3, op: "p3", at: "2026-10-09T09:00:00.000Z", category: "dining", source: #"{"kind":"held"}"#, review: true),
        Self.filed(
          4, op: "p4", at: "2026-10-09T10:00:00.000Z", category: "entertainment", source: #"{"kind":"model","model":"cf-clef/1"}"#,
          review: true),
        Self.rejection("tailscale.com", "shopping", true, op: "r1"),
      ], into: &s)
    #expect(s.anomalies.isEmpty, "\(s.anomalies)")
    let (_, r) = try M.project(s)
    #expect(try r.txn(M.id(2))?.categorizedMs == M.ms("2026-10-07T09:00:00.000Z"))
    #expect(try r.lastPicks() == [LastPick.Key(group: "n:tailscale", direction: "debit"): "shopping"])
    let sweep = try r.sweepRows()
    let waiting = try #require(sweep.first { $0.id == M.id(5) })
    #expect(waiting.picked == "shopping" && waiting.rejected == ["shopping"])
    #expect(!ModelSuggestionSweep.eligible(waiting))
    #expect(sweep.first { $0.id == M.id(6) }?.picked == nil)
    let other = try #require(sweep.first { $0.id == M.id(7) })
    #expect(other.picked == nil && ModelSuggestionSweep.eligible(other))
    #expect(try r.sweepRows(group: "n:tailscale").first { $0.id == M.id(5) }?.picked == "shopping")
  }

  @Test func aPickInACategoryNoLongerActiveStillKeepsTheMerchantFromTheModels() throws {
    var s = State()
    try M.blob(
      1, [M.txn(1, "TAILSCALE.COM", posted: "2026-08-01T08:00:00.000Z"), M.txn(2, "TAILSCALE.COM", posted: "2026-10-01T08:00:00.000Z")],
      into: &s)
    try M.blob(2, [Self.filed(1, op: "p1", at: "2026-10-05T09:00:00.000Z", category: "shopping", source: #"{"kind":"user"}"#)], into: &s)
    let (db, r) = try M.project(s)
    try db.write { db in try db.execute(sql: "UPDATE category SET active = 0 WHERE id = 'shopping'") }
    #expect(try r.lastPicks() == [LastPick.Key(group: "n:tailscale", direction: "debit"): "shopping"])
    let waiting = try #require(try r.sweepRows().first { $0.id == M.id(2) })
    #expect(waiting.picked == "shopping" && !ModelSuggestionSweep.eligible(waiting))
  }

  @Test func aRenameAndARejectionFromTwoDevicesBothSurvive() throws {
    for order in [false, true] {
      var s = State()
      try M.blob(1, [M.txn(1, "TAILSCALE.COM", posted: "2026-10-01T08:00:00.000Z")], into: &s)
      let rename = Self.rename("tailscale.com", "Tailscale", op: "n1", at: "2026-10-10T09:00:00.000Z")
      let reject = Self.rejection("tailscale.com", "shopping", true, op: "j1", at: "2026-10-10T08:00:00.000Z")
      try M.blob(2, [order ? rename : reject], writer: order ? Self.writer : Self.other, into: &s)
      try M.blob(3, [order ? reject : rename], writer: order ? Self.other : Self.writer, into: &s)
      #expect(s.anomalies.isEmpty)
      #expect(s.merchantNames["tailscale.com"]?.value == "Tailscale")
      #expect(s.merchantRejections[State.rejectionKey("tailscale.com", "shopping")]?.rejected == true)
      let (_, r) = try M.project(s)
      #expect(try r.txn(M.id(1))?.displayName == "Tailscale")
      #expect(try r.rejections()["n:tailscale"] == ["shopping"])
    }
  }

  @Test func theWitnessHasNoRejectionsUntilTheFirstOne() throws {
    var s = State()
    try M.blob(1, [M.txn(1, "TAILSCALE.COM", posted: "2026-10-01T08:00:00.000Z")], into: &s)
    #expect(!String(decoding: s.serialized(), as: UTF8.self).contains("merchantRejections"))
    try M.blob(2, [Self.rejection("tailscale.com", "shopping", false, op: "j0")], into: &s)
    #expect(String(decoding: s.serialized(), as: UTF8.self).contains(#""merchantRejections":[["tailscale.com\u0000shopping""#))
    try M.blob(3, [#"{"v":4,"type":"merchant_category_rejected","op_id":"bad","authored_at":"2026-10-10T08:00:00.000Z","parent_version":null,"payload":{"merchant_key":"tailscale.com","category":"x","rejected":true}}"#], into: &s)
    try M.blob(4, [#"{"v":4,"type":"merchant_category_rejected","op_id":"bad2","authored_at":"2026-10-10T08:00:00.000Z","parent_version":null,"payload":{"merchant_key":"tailscale.com","category":"shopping"}}"#], into: &s)
    #expect(s.anomalies.map(\.kind) == ["invalid_payload", "invalid_payload"])
    #expect(s.merchantRejections.count == 1)
  }

  @Test func anOldBuildSetsAsideOnlyTheBlobThatCarriesTheRejection() throws {
    let blobs = [
      #"{"v":4,"kind":"ops","ops":[\#(M.txn(1, "TAILSCALE.COM", posted: "2026-10-01T08:00:00.000Z"))]}"#,
      #"{"v":4,"kind":"ops","ops":[\#(Self.rejection("tailscale.com", "shopping", true, op: "j1"))]}"#,
      #"{"v":4,"kind":"ops","ops":[\#(M.categorize(1, op: "c1", parent: 1, at: "2026-10-10T09:00:00.000Z"))]}"#,
    ]
    var current = State()
    var old = State()
    for (i, body) in blobs.enumerated() {
      let seq = Int64(i + 1)
      try Replay.foldBlob(PositionedBlob(writerID: Self.writer, writerCounter: seq, seq: seq, body: Array(body.utf8)), into: &current)
      let older = body.replacingOccurrences(of: "merchant_category_rejected", with: "profile_set")
      try Replay.foldBlob(PositionedBlob(writerID: Self.writer, writerCounter: seq, seq: seq, body: Array(older.utf8)), into: &old)
    }
    #expect(current.unreadable.isEmpty && current.merchantRejections.count == 1)
    #expect(old.unreadable.map(\.seq) == [2])
    #expect(old.merchantRejections.isEmpty)
    #expect(old.txns[M.id(1)]?.category == "subscriptions" && current.txns[M.id(1)]?.category == "subscriptions")
  }

  @Test func reachBackFilesTheGroupsRowsButNotTheUnreadableAndPausingHoldsThem() throws {
    let random = SeededRandom(seed: "reach-projection")
    var s = State()
    let unverified = #","needs_review":true,"gates":{"ar":"fail","sender":"untrusted","template":"dib.card.v1@1","card":"known","forwarded":false}"#
    let dictionary = #","category":"shopping","category_source":{"kind":"dictionary","bundle":"2026.10.11-1","entry":"contains:tailscale"},"needs_review":false"#
    try M.blob(
      1,
      [
        M.txn(1, "TAILSCALE.COM", posted: "2026-08-01T08:00:00.000Z"),
        M.txn(2, "TAILSCALE INC", posted: "2026-09-01T08:00:00.000Z"),
        M.txn(3, "PAYPAL *TAILSCALE", posted: "2026-10-01T08:00:00.000Z"),
        M.txn(4, "TAILSCALE.COM", posted: "2026-10-02T08:00:00.000Z", extra: unverified),
        M.txn(5, "TAILSCALE.COM", posted: "2026-10-03T08:00:00.000Z", extra: dictionary),
        M.txn(6, "AL NOOR PHARMACY", posted: "2026-10-04T08:00:00.000Z"),
        M.txn(7, "TAILSCALE INC", posted: "2026-10-05T08:00:00.000Z", direction: "credit"),
        #"{"v":4,"type":"txn_ingested","op_id":"t8","authored_at":"2026-10-01T08:00:00.000Z","entity":{"kind":"txn","id":"\#(M.id(8))"},"parent_version":null,"ingest_id":"\#(String(repeating: "0", count: 63))8","payload":{"posted_at":"2026-10-06T08:00:00.000Z","merchant_raw":"TAILSCALE.COM","unparsed":true,"tier":"none","needs_review":true}}"#,
      ], into: &s)
    #expect(s.anomalies.isEmpty, "\(s.anomalies)")
    let (_, r) = try M.project(s)
    let rows = try r.reachRows()
    #expect(rows.first { $0.id == M.id(8) }?.unparsed == true)
    #expect(rows.filter(\.unparsed).map(\.id) == [M.id(8)])
    let members = RuleReach.members(rows: rows, group: "n:tailscale", direction: "debit", home: "AED")
    #expect(Set(members.map(\.id)) == Set([1, 2, 3].map(M.id)))
    let eligible = RuleReach.eligible(rows: rows, group: "n:tailscale", direction: "debit", home: "AED")
    #expect(Set(eligible.map(\.id)) == Set([1, 2, 3, 5].map(M.id)))
    let patterns = RuleReach.patterns(filed: "TAILSCALE.COM", members: eligible)
    var a = OpAuthor(Self.context(s, random: random))
    let ruleID = try a.rule(OpAuthor.RuleDraft(patterns: patterns, match: .exact, category: "subscriptions", priority: 100, origin: "learned"))
    let input = RuleInput(id: ruleID, patterns: patterns, match: "exact", category: "subscriptions", priority: 100)
    let targets = RuleReach.plan(rows: rows, rule: input, group: "n:tailscale", direction: "debit", home: "AED")
    #expect(Set(targets.map(\.txnID)) == Set([1, 2, 3, 5].map(M.id)))
    for t in targets {
      a.categorize(txnID: t.txnID, parentVersion: t.version, category: "subscriptions", source: CategorySource(kind: .rule, ruleID: ruleID))
    }
    var seq: Int64 = 1
    try Self.fold([try a.build()], seq: &seq, into: &s)
    #expect(s.anomalies.isEmpty)
    let (_, filed) = try M.project(s)
    for n in [1, 2, 3, 5] {
      let t = try #require(try filed.txn(M.id(n)))
      #expect(t.category == "subscriptions" && t.categorySource == "rule" && t.categorySourceRef == ruleID && !t.needsReview)
      #expect(t.reviewLane == nil && t.categorizedMs != nil)
    }
    #expect(try filed.txn(M.id(4))?.needsReview == true && filed.txn(M.id(4))?.category == nil)
    #expect(try filed.txn(M.id(6))?.category == nil && filed.txn(M.id(7))?.category == nil)
    #expect(try filed.txn(M.id(8))?.category == nil && filed.txn(M.id(8))?.unparsed == true)

    let rule = try #require(try filed.rules().first { $0.id == ruleID })
    let held = try filed.activity(limit: 1_000).filter {
      $0.categorySource == "rule" && $0.categorySourceRef == ruleID && !$0.needsReview && $0.category != nil
    }.map { (id: $0.id, version: $0.version, category: $0.category ?? "") }
    #expect(held.count == 4)
    let snapshot = OpAuthor.RuleSnapshot(
      id: ruleID, version: rule.version,
      draft: OpAuthor.RuleDraft(patterns: rule.patterns, match: .exact, category: rule.category, priority: rule.priority, origin: rule.origin))
    var ctx = Self.context(s, random: random)
    ctx.ownLastMs = 1_791_000_100_000
    try Self.fold(try OpAuthor.setRule(snapshot, enabled: false, heldRows: held, context: ctx), seq: &seq, into: &s)
    let (_, paused) = try M.project(s)
    for n in [1, 2, 3, 5] {
      let t = try #require(try paused.txn(M.id(n)))
      #expect(t.categorySource == "held" && t.needsReview && t.reviewLane == "needs_review")
    }
  }

  @Test func reachBackAcrossAThousandRowsFoldsInBlobsOfFiveHundred() throws {
    let random = SeededRandom(seed: "reach-1000")
    var s = State()
    for chunk in 0..<5 {
      try M.blob(Int64(chunk + 1), (1...200).map { M.txn(chunk * 200 + $0, ["TAILSCALE.COM", "TAILSCALE INC"][$0 % 2], posted: "2026-08-03T08:00:00.000Z") }, into: &s)
    }
    let (_, r) = try M.project(s)
    let rows = try r.reachRows()
    var a = OpAuthor(Self.context(s, random: random))
    let ruleID = try a.rule(OpAuthor.RuleDraft(patterns: ["tailscale.com", "tailscale inc"], match: .exact, category: "subscriptions", priority: 100, origin: "learned"))
    let input = RuleInput(id: ruleID, patterns: ["tailscale.com", "tailscale inc"], match: "exact", category: "subscriptions", priority: 100)
    let targets = RuleReach.plan(rows: rows, rule: input, group: "n:tailscale", direction: "debit", home: "AED")
    #expect(targets.count == 1_000)
    var seq: Int64 = 5
    try Self.fold([try a.build()], seq: &seq, into: &s)
    var ctx = Self.context(s, random: random)
    ctx.ownLastMs = 1_791_000_100_000
    let blobs = try OpAuthor.categorizations(RuleReach.items(targets, ruleID: ruleID, category: "subscriptions"), context: ctx)
    #expect(blobs.map(\.ops.count) == [500, 500])
    try Self.fold(blobs, seq: &seq, into: &s)
    #expect(s.anomalies.isEmpty)
    #expect(s.txns.values.filter { $0.categorySource?.kind == .rule && $0.category == "subscriptions" }.count == 1_000)
  }
}
