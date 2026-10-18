import CoreCategorize
import CoreReplay
import CoreWire
import GRDB
import Testing

@testable import CoreProjection

@Suite("projection of a mailbox retire")
struct MailboxRetireProjectionTests {
  static let a = "u1/mbx-0000000000000000000000000000000a"
  static let b = "u1/mbx-0000000000000000000000000000000b"
  static let dictionary = try! MerchantDictionary.bundled().get()

  static func ulid(_ n: Int) -> String { "01JC" + String(repeating: "0", count: 22 - String(n).count) + String(n) }
  static func ingestID(_ n: Int) -> String { String(repeating: "0", count: 62) + (n < 10 ? "0\(n)" : "\(n)") }

  static func ingest(_ n: Int, grant: String?, provider: String = "gmail", type: String = "txn_ingested") -> String {
    let prov =
      grant.map { #","entry_method":"mailbox","provenance":{"provider":"\#(provider)","grant_id":"\#($0)","message_id":"m\#(n)"}"# }
      ?? #","entry_method":"manual""#
    return #"{"v":4,"type":"\#(type)","op_id":"op-\#(n)-\#(type)","authored_at":"2026-10-01T08:00:00.000Z","entity":{"kind":"txn","id":"\#(ulid(type == "txn_ingested" ? n : n + 50))"},"parent_version":null,"ingest_id":"\#(ingestID(n))","payload":{"amount_minor":"\#(1000 + n)","currency":"AED","direction":"debit","posted_at":"2026-10-03T08:00:00.000Z","merchant_raw":"SHOP \#(n)","last4":"4412","needs_review":false,"category":null\#(prov)}}"#
  }

  static func fold(_ blobs: [String]) throws -> State {
    var s = State()
    for (i, ops) in blobs.enumerated() {
      let body = Array(#"{"v":4,"kind":"ops","ops":[\#(ops)]}"#.utf8)
      try Replay.foldBlob(PositionedBlob(writerID: "ios-w", writerCounter: Int64(i + 1), seq: Int64(i + 1), body: body), into: &s)
    }
    return s
  }

  static func reader(_ s: State, pending: [[Op]] = []) throws -> LedgerReader {
    let db = try Projector.open(path: nil)
    try Projector.project(s, pending: pending, writerID: "ios-w", dictionary: dictionary, projectedAtMs: 0, into: db)
    return LedgerReader(db)
  }

  static let edit = #"{"v":4,"type":"txn_categorized","op_id":"op-edit","authored_at":"2026-10-01T08:00:00.000Z","entity":{"kind":"txn","id":"\#(ulid(2))"},"parent_version":1,"payload":{"category":"groceries","needs_review":false,"source":{"kind":"user"}}}"#

  @Test("rows carry their mailbox; the counts show the total and the edited ones")
  func counts() throws {
    let s = try Self.fold([
      [Self.ingest(1, grant: Self.a), Self.ingest(2, grant: Self.a), Self.ingest(3, grant: Self.b), Self.ingest(4, grant: nil)].joined(separator: ","),
      Self.ingest(5, grant: "u1"), Self.edit,
    ])
    let r = try Self.reader(s)
    #expect(try r.txn(Self.ulid(1))?.sourceMailbox == Self.a)
    #expect(try r.txn(Self.ulid(4))?.sourceMailbox == nil)
    #expect(try r.txn(Self.ulid(2))?.userTouched == true && r.txn(Self.ulid(1))?.userTouched == false)
    #expect(try r.mailboxImports(grantID: Self.a, provider: "gmail", legacy: false) == MailboxImportCounts(total: 2, edited: 1))
    #expect(try r.mailboxImports(grantID: Self.a, provider: "gmail", legacy: true) == MailboxImportCounts(total: 3, edited: 1))
    #expect(try r.mailboxImports(grantID: Self.a, provider: "outlook", legacy: true).total == 0)
    #expect(try r.otherMailboxCount(grantID: Self.a, provider: "gmail") == 1)
    #expect(try r.otherMailboxCount(grantID: Self.a, provider: "outlook") == 0)
  }

  @Test("retired rows and their superseded predecessors leave the projection, so a reconnect imports them again")
  func retiredRowsLeave() throws {
    let retire = #"{"v":4,"type":"mailbox_retired","op_id":"op-retire","authored_at":"2026-10-01T08:00:00.000Z","parent_version":null,"payload":{"grant_id":"\#(Self.a)","provider":"gmail","legacy":false}}"#
    let s = try Self.fold([
      [Self.ingest(1, grant: Self.a), Self.ingest(2, grant: Self.a), Self.ingest(3, grant: Self.b)].joined(separator: ","),
      Self.ingest(1, grant: Self.a, type: "txn_superseded"), retire,
    ])
    let r = try Self.reader(s)
    #expect(try r.txn(Self.ulid(1)) == nil && r.txn(Self.ulid(51)) == nil && r.txn(Self.ulid(2)) == nil)
    #expect(try r.txn(Self.ulid(3)) != nil)
    #expect(try !r.hasIngest(Self.ingestID(1)) && r.hasIngest(Self.ingestID(3)))
    #expect(try r.knownMailboxMessageIDs(["m1", "m2", "m3"]) == ["m3"])
    #expect(try r.activity().map(\.id) == [Self.ulid(3)])
    #expect(try r.mailboxImports(grantID: Self.a, provider: "gmail", legacy: false).total == 0)
  }

  @Test("a retire still in the outbox already hides the rows")
  func pendingRetire() throws {
    let s = try Self.fold([[Self.ingest(1, grant: Self.a), Self.ingest(3, grant: Self.b)].joined(separator: ",")])
    let body = Array(#"{"v":4,"kind":"ops","ops":[{"v":4,"type":"mailbox_retired","op_id":"op-retire","authored_at":"2026-10-01T08:00:00.000Z","parent_version":null,"payload":{"grant_id":"\#(Self.a)","provider":"gmail","legacy":false}}]}"#.utf8)
    let ops = try OpCodec.decodeBlobOps(body)
    let r = try Self.reader(s, pending: [ops])
    #expect(try r.txn(Self.ulid(1)) == nil && r.txn(Self.ulid(3)) != nil)
  }
}
