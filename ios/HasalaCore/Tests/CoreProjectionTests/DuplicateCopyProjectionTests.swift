import CoreCategorize
import CoreDomain
import CoreReplay
import CoreTime
import CoreWire
import GRDB
import Testing

@testable import CoreProjection

@Suite("projection of duplicate copies")
struct DuplicateCopyProjectionTests {
  typealias M = MailboxRetireProjectionTests
  static let mid = "0123456789abcdef0123456789abcdef"

  static func alert(_ n: Int, grant: String, at: String, mid: String? = nil) -> String {
    let dedupe = mid.map { #","dedupe":{"message_id":"\#($0)"}"# } ?? ""
    return #"{"v":4,"type":"txn_ingested","op_id":"op-\#(n)","authored_at":"2026-10-01T08:00:00.000Z","entity":{"kind":"txn","id":"\#(M.ulid(n))"},"parent_version":null,"ingest_id":"\#(M.ingestID(n))","payload":{"amount_minor":"2700","currency":"AED","direction":"debit","posted_at":"2026-10-03T\#(at).000Z","posted_precision":"time","merchant_raw":"STARBUCKS DIFC","last4":"4412","needs_review":false,"category":"dining","category_source":{"kind":"user"},"tier":"template","entry_method":"mailbox","bank":"enbd","provenance":{"provider":"gmail","grant_id":"\#(grant)","message_id":"m\#(n)"}\#(dedupe)}}"#
  }

  static let home = #"{"v":4,"type":"home_currency_set","op_id":"op-home","authored_at":"2026-10-01T08:00:00.000Z","parent_version":null,"payload":{"currency":"AED"}}"#

  static func resolve(_ decision: String, parent: Int) -> String {
    #"{"v":4,"type":"txn_copy_resolved","op_id":"op-r\#(parent)","authored_at":"2026-10-01T08:00:00.000Z","entity":{"kind":"txn","id":"\#(M.ulid(2))"},"parent_version":\#(parent),"payload":{"other_txn_id":"\#(M.ulid(1))","decision":"\#(decision)"}}"#
  }

  static func spent(_ r: LedgerReader) throws -> Int64 {
    let d = CivilDate(wire: "2026-10-03")!
    return try r.moneyLines(from: d, to: d).filter { $0.flow == .spend }.reduce(0) { $0 + ($1.signedHome ?? 0) }
  }

  @Test("a held probable copy is in review and out of every total; keep both counts it")
  func heldThenKept() throws {
    let s = try M.fold([Self.home, Self.alert(1, grant: M.a, at: "08:00:00"), Self.alert(2, grant: M.b, at: "08:06:00")])
    let r = try M.reader(s)
    let held = try #require(try r.txn(M.ulid(2)))
    #expect(held.heldCopy && held.copyOf == M.ulid(1) && held.reviewLane == "copy")
    #expect(try r.review().map(\.id) == [M.ulid(2)])
    #expect(try Self.spent(r) == 2700)
    var kept = s
    let body = Array(#"{"v":4,"kind":"ops","ops":[\#(Self.resolve("keep_both", parent: 1))]}"#.utf8)
    try Replay.foldBlob(PositionedBlob(writerID: "ios-w", writerCounter: 9, seq: 9, body: body), into: &kept)
    let r2 = try M.reader(kept)
    #expect(try r2.txn(M.ulid(2))?.heldCopy == false && r2.txn(M.ulid(2))?.reviewLane == nil)
    #expect(try Self.spent(r2) == 5400)
  }

  @Test("a merged copy leaves the rows and stays known by its message and ingest id")
  func mergedIsAnAlias() throws {
    let s = try M.fold([Self.home, Self.alert(1, grant: M.a, at: "08:00:00", mid: Self.mid), Self.alert(2, grant: M.b, at: "08:00:00", mid: Self.mid)])
    let r = try M.reader(s)
    #expect(try r.txn(M.ulid(2)) == nil && r.txn(M.ulid(1)) != nil)
    #expect(try r.hasIngest(M.ingestID(2)))
    #expect(try r.knownMailboxMessageIDs(["m1", "m2", "m9"]) == ["m1", "m2"])
    #expect(try Self.spent(r) == 2700)
    #expect(try r.activity().count == 1)
  }
}
