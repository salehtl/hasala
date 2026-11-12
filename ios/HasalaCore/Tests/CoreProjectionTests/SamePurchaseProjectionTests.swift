import CoreDomain
import CoreReplay
import Testing

@testable import CoreProjection

@Suite("same purchase rows read from the projection")
struct SamePurchaseProjectionTests {
  typealias M = MailboxRetireProjectionTests
  typealias D = DuplicateCopyProjectionTests

  static let rate = #"{"v":4,"type":"rate_set","op_id":"op-rate","authored_at":"2026-10-01T08:00:00.000Z","parent_version":null,"payload":{"currency":"USD","rate_micro":"3672500"}}"#

  static func txn(_ n: Int, minor: Int, currency: String, day: String) -> String {
    #"{"v":4,"type":"txn_ingested","op_id":"op-\#(n)","authored_at":"2026-10-01T08:00:00.000Z","entity":{"kind":"txn","id":"\#(M.ulid(n))"},"parent_version":null,"ingest_id":"\#(M.ingestID(n))","payload":{"amount_minor":"\#(minor)","currency":"\#(currency)","direction":"debit","posted_at":"2026-10-\#(day)T10:00:00.000Z","posted_precision":"time","merchant_raw":"AMAZON","last4":"4412","needs_review":false,"category":"shopping","tier":"template","entry_method":"mailbox","bank":"enbd"}}"#
  }

  static func stated(_ n: Int, minor: Int) -> String {
    #"{"v":4,"type":"txn_edited","op_id":"op-e\#(n)","authored_at":"2026-10-02T08:00:00.000Z","entity":{"kind":"txn","id":"\#(M.ulid(n))"},"parent_version":1,"payload":{"amount_home_minor":"\#(minor)"}}"#
  }

  static func merged(_ n: Int, note: String) -> String {
    #"{"v":4,"type":"txn_annotated","op_id":"op-a\#(n)","authored_at":"2026-10-02T08:00:00.000Z","parent_version":null,"payload":{"txn_id":"\#(M.ulid(n))","set":{"archived":"user","note":"\#(note)"}}}"#
  }

  static func rows(_ ops: [String]) throws -> [SamePurchase.Row] {
    let r = try M.reader(try M.fold(ops))
    return try (r.activity() + r.archived()).map(\.samePurchaseRow)
  }

  @Test("a home amount stated on the row is held to the stated tolerance; an estimate at a rate keeps the wider one")
  func statedTolerance() throws {
    let base = [D.home, Self.rate, Self.txn(1, minor: 2_500, currency: "USD", day: "03"), Self.txn(2, minor: 9_400, currency: "AED", day: "05")]
    let estimate = try Self.rows(base)
    #expect(estimate.first { $0.id == M.ulid(1) }?.homeStated == false)
    #expect(SamePurchase.pairs(estimate, home: "AED").map(\.home) == [M.ulid(2)])

    let held = try Self.rows(base + [Self.stated(1, minor: 9_181)])
    #expect(held.first { $0.id == M.ulid(1) }?.homeStated == true)
    #expect(SamePurchase.pairs(held, home: "AED").isEmpty)
  }

  static func alert(_ n: Int, grant: String, verified: Bool) -> String {
    let trust = verified ? #""ar":"pass","sender":"trusted""# : #""ar":"fail","sender":"untrusted""#
    return #"{"v":4,"type":"txn_ingested","op_id":"op-\#(n)","authored_at":"2026-10-01T08:00:00.000Z","entity":{"kind":"txn","id":"\#(M.ulid(n))"},"parent_version":null,"ingest_id":"\#(M.ingestID(n))","payload":{"amount_minor":"2500","currency":"USD","direction":"debit","posted_at":"2026-10-03T10:00:00.000Z","posted_precision":"time","merchant_raw":"AMAZON","last4":"4412","needs_review":false,"category":"shopping","tier":"template","entry_method":"mailbox","bank":"enbd","provenance":{"provider":"gmail","grant_id":"\#(grant)","message_id":"m\#(n)"},"gates":{\#(trust),"template":"enbd-card@1","card":"known","forwarded":false},"dedupe":{"message_id":"0123456789abcdef0123456789abcdef"}}}"#
  }

  static let decline = [
    #"{"v":4,"type":"txn_edited","op_id":"op-decline","authored_at":"2026-10-06T08:00:00.000Z","entity":{"kind":"txn","id":"\#(M.ulid(2))"},"parent_version":1,"payload":{"possible_duplicate_of":"\#(M.ulid(1))"}}"#,
    #"{"v":4,"type":"txn_duplicate_disposition","op_id":"op-different","authored_at":"2026-10-06T08:00:00.000Z","entity":{"kind":"txn","id":"\#(M.ulid(2))"},"parent_version":2,"payload":{"other_txn_id":"\#(M.ulid(1))","disposition":"different"}}"#,
  ].joined(separator: ",")

  static func declinedStays(_ ops: [String], survivor: String) throws {
    let r = try M.reader(try M.fold(ops))
    let rows = try (r.activity() + r.archived())
    #expect(SamePurchase.pairs(rows.map(\.samePurchaseRow), home: "AED").isEmpty)
    let posting = try #require(rows.first { $0.id == M.ulid(2) })
    #expect(posting.possibleDuplicateOf == survivor && posting.duplicateDisposition == "different")
    #expect(!RuleReach.ruled(posting.reachRow, samePurchase: []))
  }

  @Test("a declined pair stays declined when the purchase it names merges into its verified copy or leaves with a removed mailbox")
  func declinedAcrossMergeAndRemove() throws {
    let posting = Self.txn(2, minor: 9_300, currency: "AED", day: "05")
    try Self.declinedStays(
      [D.home, Self.rate, Self.alert(1, grant: M.a, verified: false), posting, Self.decline, Self.alert(3, grant: M.b, verified: true)],
      survivor: M.ulid(3))
    let retire = #"{"v":4,"type":"mailbox_retired","op_id":"op-retire","authored_at":"2026-10-07T08:00:00.000Z","parent_version":null,"payload":{"grant_id":"\#(M.a)","provider":"gmail","legacy":false}}"#
    try Self.declinedStays(
      [D.home, Self.rate, Self.alert(1, grant: M.a, verified: false), Self.alert(3, grant: M.b, verified: false), posting, Self.decline, retire],
      survivor: M.ulid(3))
  }

  @Test("the settled note reaches the pairing, so a purchase already settled is not offered to a later posting")
  func settledNote() throws {
    let rows = try Self.rows([
      D.home, Self.rate, Self.txn(1, minor: 2_500, currency: "USD", day: "03"), Self.txn(2, minor: 9_300, currency: "AED", day: "05"),
      Self.txn(3, minor: 9_300, currency: "AED", day: "06"), Self.stated(1, minor: 9_300),
      Self.merged(2, note: SamePurchase.note(foreignMinor: 2_500, currency: "USD")),
    ])
    #expect(rows.first { $0.id == M.ulid(2) }?.archived == true)
    #expect(SamePurchase.pairs(rows, home: "AED").isEmpty)
  }
}
