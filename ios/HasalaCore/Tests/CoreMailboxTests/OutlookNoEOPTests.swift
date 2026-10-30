import CoreDomain
import CoreJSON
import CoreMail
import CorePrimitives
import CoreReplay
import CoreStore
import CoreTestSupport
import CoreWire
import Foundation
import Testing

@testable import CoreMailbox

@Suite struct OutlookNoEOPTests {
  static let t0 = OutlookRig.t0
  static let day: Int64 = 86_400_000
  static let writer = RuntimeGlueTests.writer.string

  static func authoring(_ store: LedgerStore) -> MailboxAuthoring {
    MailboxAuthoring(store: store, writerID: writer, random: SeededRandom(), stamps: AuthorStamps())
  }

  static func fold(_ store: LedgerStore) throws -> State {
    let pending = try store.pendingOps()
    var body = Data(#"{"v":4,"kind":"ops","ops":["#.utf8)
    for (i, p) in pending.enumerated() {
      if i > 0 { body += Data(",".utf8) }
      body += p.opJSON
    }
    body += Data("]}".utf8)
    var s = State()
    try Replay.foldOps(try OpCodec.decodeBlobOps(body), seq: 1, writerID: writer, into: &s)
    return s
  }

  static func row(_ s: State, message id: String) -> Txn? {
    s.txns.values.first { $0.mailboxMessageID == id }
  }

  static func gatedPayload(ar: String) -> JSONObject {
    var p = RuntimeGlueTests.draft(1).payload
    p["gates"] = .object(
      JSONObject([
        ("ar", .string(ar)), ("sender", .string("untrusted")), ("template", .string("none")), ("card", .string("none")),
        ("forwarded", .bool(false)),
      ]))
    return p
  }

  static func authresReasons() throws -> [String] {
    var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while root.path != "/", !FileManager.default.fileExists(atPath: root.appendingPathComponent("conformance/authres").path) {
      root.deleteLastPathComponent()
    }
    let data = try Data(contentsOf: root.appendingPathComponent("conformance/authres/vectors.json"))
    let doc = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    return try #require(doc?["reasons"] as? [String])
  }

  @Test func everyAuthResultsReasonFolds() throws {
    let reasons = try Self.authresReasons()
    #expect(
      Set(reasons)
        == Set(
          [
            AuthResults.Reason.pass, .noAR, .multipleAR, .notTopmost, .fail, .parseError, .noEOP, .notInbox, .unknownSender,
            .noDMARCReject,
          ].map(\.rawValue)))
    #expect(Set(State.gateARValues) == Set(reasons))
    for r in reasons {
      var a = OpAuthor(
        AuthorContext(writerID: Self.writer, nowMs: Self.t0, ownLastMs: nil, maxAuthored: [:], random: SeededRandom()))
      _ = try a.ingest(payload: Self.gatedPayload(ar: r), ingestID: RuntimeGlueTests.draft(1).ingestID)
      var s = State()
      try Replay.foldOps(try a.build().ops, seq: 1, writerID: Self.writer, into: &s)
      #expect(s.anomalies.isEmpty, "\(r)")
      #expect(s.txns.values.first?.gates?.ar == r)
    }
    var a = OpAuthor(
      AuthorContext(writerID: Self.writer, nowMs: Self.t0, ownLastMs: nil, maxAuthored: [:], random: SeededRandom()))
    _ = try a.ingest(payload: Self.gatedPayload(ar: "no_such_reason"), ingestID: RuntimeGlueTests.draft(1).ingestID)
    #expect(throws: AuthorError.self) { try a.build() }
  }

  @Test func anyVerdictButPassIsAnUnverifiedSender() {
    #expect(TxnGates().senderUnverified == false)
    #expect(TxnGates(ar: "pass", sender: "trusted").senderUnverified == false)
    #expect(TxnGates(ar: "no_eop", sender: "untrusted").senderUnverified == true)
    #expect(TxnGates(ar: "pass", sender: "untrusted").senderUnverified == false)
    #expect(TxnGates(sender: "untrusted").senderUnverified == false)
    #expect(TxnGates(ar: "no_ar", sender: "untrusted").senderUnverified == true)
    #expect(TxnGates(ar: "multiple_ar", sender: "untrusted").senderUnverified == true)
    #expect(TxnGates(ar: "fail", sender: "trusted").senderUnverified == true)
  }

  @Test func aGmailDKIMAndDMARCFailIsSenderUnverified() {
    let headers = [
      "Authentication-Results: mx.google.com;", "       dkim=fail header.d=bank.example;",
      "       dmarc=fail header.from=bank.example", "From: x", "",
    ].joined(separator: "\r\n")
    let a = AuthResults.analyze(headers, provider: .gmail)
    #expect(a.verdict.reason == .fail)
    #expect(TxnGates(ar: a.verdict.reason.rawValue, sender: "untrusted").senderUnverified == true)
    let pass = AuthResults.analyze(
      ["Authentication-Results: mx.google.com; dkim=pass header.d=bank.example", "From: a@bank.example", ""].joined(separator: "\r\n"),
      provider: .gmail)
    #expect(pass.verdict.reason == .pass)
    #expect(TxnGates(ar: pass.verdict.reason.rawValue, sender: "untrusted").senderUnverified == false)
  }

  @Test func aJunkAlertFoldsIntoReview() async throws {
    let store = try RuntimeGlueTests.ledger()
    let rig = OutlookRig(ledgerStore: store, author: Self.authoring(store).opAuthor)
    rig.graph.add(
      SyntheticOutlookMail.dibCard(id: "AAkALgAA-junk", amount: "1.00", dateMs: Self.t0 - Self.day, folder: FakeGraph.junkID))
    await rig.connectAndActivate()
    #expect(await rig.state().phase == .active)
    #expect(rig.accounted("AAkALgAA-junk") == .op)
    let s = try Self.fold(store)
    #expect(s.anomalies.isEmpty)
    let t = try #require(Self.row(s, message: "AAkALgAA-junk"))
    #expect(t.needsReview && !t.unparsed && t.amountMinor == 100)
    #expect(t.gates?.ar == "fail" && t.gates?.sender == "untrusted")
    #expect(t.gates?.senderUnverified == true)
    #expect(t.category == nil)
  }

  @Test func aKnownSenderInTheInboxFoldsWithNoSenderReason() async throws {
    let store = try RuntimeGlueTests.ledger()
    let rig = OutlookRig(ledgerStore: store, author: Self.authoring(store).opAuthor)
    rig.graph.add(SyntheticOutlookMail.dibCard(id: "AAkALgAA-inbox", amount: "1.00", dateMs: Self.t0 - Self.day, eop: false))
    await rig.connectAndActivate()
    let s = try Self.fold(store)
    let t = try #require(Self.row(s, message: "AAkALgAA-inbox"))
    #expect(!t.needsReview)
    #expect(t.gates?.ar == "pass" && t.gates?.sender == "trusted")
    #expect(t.gates?.senderUnverified == false)
  }

  @Test func aBatchOf200WithOneJunkAlertImportsAll() async throws {
    let store = try RuntimeGlueTests.ledger()
    let rig = OutlookRig(ledgerStore: store, author: Self.authoring(store).opAuthor)
    for n in 0..<199 {
      rig.graph.add(
        SyntheticOutlookMail.dibCard(id: "AAkALgAA-ok\(n)", amount: "\(n + 2).00", dateMs: Self.t0 - Self.day - Int64(n) * 1_000))
    }
    rig.graph.add(
      SyntheticOutlookMail.dibCard(
        id: "AAkALgAA-junk", amount: "1.00", dateMs: Self.t0 - 2 * Self.day, folder: FakeGraph.junkID))
    await rig.connectAndActivate()
    #expect(await rig.state().phase == .active)
    #expect(try store.pendingOps().count == 200)
    let s = try Self.fold(store)
    #expect(s.anomalies.isEmpty)
    let rows = Array(s.txns.values)
    #expect(rows.count == 200)
    #expect(rows.filter { !$0.needsReview }.count == 199)
    let review = rows.filter(\.needsReview)
    #expect(review.count == 1 && review.first?.mailboxMessageID == "AAkALgAA-junk")
    #expect(review.first?.gates?.senderUnverified == true)
  }

  @Test func oneRefusedDraftGoesToReviewAndTheBatchCommits() async throws {
    let store = try RuntimeGlueTests.ledger()
    let persistence = LedgerMailboxPersistence(
      tables: MailboxTableStore(writer: store.db), author: Self.authoring(store).opAuthor, nowMs: { RuntimeGlueTests.now })
    var bad = RuntimeGlueTests.draft(150, amount: "-5")
    var p = bad.payload
    p["gates"] = Self.gatedPayload(ar: "no_eop")["gates"]
    bad = MailboxIngestDraft(messageID: bad.messageID, ingestID: bad.ingestID, internalDateMs: bad.internalDateMs, payload: p, needsReview: true)
    var c = MailboxCommit()
    c.drafts = (0..<200).map { $0 == 150 ? bad : RuntimeGlueTests.draft($0, amount: "\($0 + 1)00") }
    c.accounted = c.drafts.map {
      AccountedRecord(messageID: $0.messageID, outcome: .op, internalDateMs: RuntimeGlueTests.now, atMs: RuntimeGlueTests.now)
    }
    try await persistence.commit(c)
    #expect(try store.pendingCount() == 200)
    #expect(try await persistence.accounted(among: c.drafts.map(\.messageID)).count == 200)
    let s = try Self.fold(store)
    #expect(s.anomalies.isEmpty && s.txns.count == 200)
    let refused = try #require(Self.row(s, message: "m150"))
    #expect(refused.unparsed && refused.needsReview && refused.parseError == "payload_refused")
    #expect(refused.gates?.ar == "no_eop" && refused.gates?.senderUnverified == true)
    #expect(s.txns.values.filter { !$0.unparsed }.count == 199)
  }

  static func withPayload(_ d: MailboxIngestDraft, _ edit: (inout JSONObject) -> Void) -> MailboxIngestDraft {
    var p = d.payload
    edit(&p)
    return MailboxIngestDraft(messageID: d.messageID, ingestID: d.ingestID, internalDateMs: d.internalDateMs, payload: p, needsReview: true)
  }

  @Test func anOversizedMerchantOrProvenanceStillLetsTheBatchCommit() async throws {
    let store = try RuntimeGlueTests.ledger()
    let persistence = LedgerMailboxPersistence(
      tables: MailboxTableStore(writer: store.db), author: Self.authoring(store).opAuthor, nowMs: { RuntimeGlueTests.now })
    let long = String(repeating: "A", count: 9_000)
    let merchant = Self.withPayload(RuntimeGlueTests.draft(3)) { $0["merchant_raw"] = .string(long) }
    let provenance = Self.withPayload(RuntimeGlueTests.draft(7)) {
      $0["provenance"] = .object(JSONObject([
        ("provider", .string("gmail")), ("grant_id", .string("g1")), ("message_id", .string(long)),
      ]))
    }
    var c = MailboxCommit()
    c.drafts = (0..<10).map { n in n == 3 ? merchant : (n == 7 ? provenance : RuntimeGlueTests.draft(n, amount: "\(n + 1)00")) }
    c.accounted = c.drafts.map {
      AccountedRecord(messageID: $0.messageID, outcome: .op, internalDateMs: RuntimeGlueTests.now, atMs: RuntimeGlueTests.now)
    }
    try await persistence.commit(c)
    #expect(try store.pendingCount() == 10)
    let s = try Self.fold(store)
    #expect(s.anomalies.isEmpty && s.txns.count == 10)
    let m3 = try #require(Self.row(s, message: "m3"))
    #expect(m3.unparsed && m3.needsReview && m3.parseError == "payload_refused" && m3.merchantRaw.isEmpty)
    let refused = s.txns.values.filter { $0.parseError == "payload_refused" }
    #expect(refused.count == 2)
    #expect(refused.contains { $0.mailboxMessageID == nil })
    #expect(s.txns.values.filter { !$0.unparsed }.count == 8)
  }

  @Test func theLastShapesTrimThenDropTheProvenance() {
    let ok = RuntimeGlueTests.draft(1)
    let trimmed = MessageDisposer.refusedShape(ok, keepGates: false, provenance: .trimmed)
    #expect(trimmed.payload["provenance"] == ok.payload["provenance"])
    let huge = Self.withPayload(ok) {
      $0["provenance"] = .object(JSONObject([
        ("provider", .string("gmail")), ("grant_id", .string("g1")), ("message_id", .string(String(repeating: "x", count: 300))),
        ("extra", .string("y")),
      ]))
    }
    #expect(MessageDisposer.refusedShape(huge, keepGates: false, provenance: .trimmed).payload["provenance"] == nil)
    #expect(MessageDisposer.refusedShape(ok, keepGates: false, provenance: .none).payload["provenance"] == nil)
    let extra = Self.withPayload(ok) {
      $0["provenance"] = .object(JSONObject([
        ("provider", .string("gmail")), ("grant_id", .string("g1")), ("message_id", .string("m1")), ("extra", .string("y")),
      ]))
    }
    #expect(MessageDisposer.refusedShape(extra, keepGates: false, provenance: .trimmed).payload["provenance"]
      == .object(JSONObject([("provider", .string("gmail")), ("grant_id", .string("g1")), ("message_id", .string("m1"))])))
  }
}
