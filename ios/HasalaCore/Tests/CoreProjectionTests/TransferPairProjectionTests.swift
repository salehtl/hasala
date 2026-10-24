import CoreCategorize
import CoreDomain
import CoreReplay
import CoreTime
import CoreWire
import GRDB
import Testing

@testable import CoreProjection

@Suite("projection of combined transfer pairs")
struct TransferPairProjectionTests {
  typealias M = MailboxRetireProjectionTests
  typealias D = DuplicateCopyProjectionTests

  static let payee = "SAMPLE PAYEE"
  static let code = "MB FUND TRANSFER DEBIT"

  static func dib(_ n: Int, template: String, merchant: String, last4: String, at: String, grant: String = M.a, mid: String? = nil) -> String {
    let dedupe = mid.map { #","dedupe":{"message_id":"\#($0)"}"# } ?? ""
    return #"{"v":4,"type":"txn_ingested","op_id":"op-\#(n)","authored_at":"2026-10-01T08:00:00.000Z","entity":{"kind":"txn","id":"\#(M.ulid(n))"},"parent_version":null,"ingest_id":"\#(M.ingestID(n))","payload":{"amount_minor":"314159","currency":"AED","direction":"debit","posted_at":"2026-10-03T\#(at).000Z","posted_precision":"time","merchant_raw":"\#(merchant)","last4":"\#(last4)","needs_review":true,"category":null,"tier":"template","entry_method":"mailbox","bank":"dib","provenance":{"provider":"gmail","grant_id":"\#(grant)","message_id":"m\#(n)"},"gates":{"ar":"pass","sender":"trusted","template":"\#(template)","card":"unknown","forwarded":false}\#(dedupe)}}"#
  }

  static func notice(_ n: Int, at: String, grant: String = M.a, mid: String? = nil) -> String {
    dib(n, template: "dib.transfer.v1@1", merchant: payee, last4: "0909", at: at, grant: grant, mid: mid)
  }

  static func alert(_ n: Int, at: String, grant: String = M.a) -> String {
    dib(n, template: "dib.account.v1@3", merchant: code, last4: "0606", at: at, grant: grant)
  }

  static func resolve(_ copy: Int, other: Int, _ decision: String?, parent: Int, op: String) -> String {
    #"{"v":4,"type":"txn_copy_resolved","op_id":"\#(op)","authored_at":"2026-10-04T08:00:00.000Z","entity":{"kind":"txn","id":"\#(M.ulid(copy))"},"parent_version":\#(parent),"payload":{"other_txn_id":"\#(M.ulid(other))","decision":\#(decision.map { "\"\($0)\"" } ?? "null")}}"#
  }

  static func out(_ r: LedgerReader) throws -> Int64 {
    let d = CivilDate(wire: "2026-10-03")!
    return try r.moneyLines(from: d, to: d).filter { $0.flow == .spend || $0.flow == .uncategorizedOut }.reduce(0) { $0 + ($1.signedHome ?? 0) }
  }

  static func live(_ r: LedgerReader) throws -> [String] { try r.activity().map(\.id).sorted() }

  @Test("alert first: the notice is the row, with the payee, and names its merged copy for undo")
  func alertFirst() throws {
    let s = try M.fold([D.home, Self.alert(1, at: "10:00:00"), Self.notice(2, at: "10:04:00")])
    let r = try M.reader(s)
    #expect(try Self.live(r) == [M.ulid(2)])
    let row = try #require(try r.txn(M.ulid(2)))
    #expect(row.merchantRaw == Self.payee && row.displayName != Self.code)
    #expect(try r.transferCopy(of: M.ulid(2)) == .init(txnID: M.ulid(2), copyID: M.ulid(1), copyOf: M.ulid(2), version: 1))
    #expect(try r.transferCopies().keys.sorted() == [M.ulid(2)])
    #expect(try Self.out(r) == 314_159)
  }

  @Test("notice first: the notice is the row and the alert is its merged copy")
  func noticeFirst() throws {
    let s = try M.fold([D.home, Self.notice(1, at: "10:00:00"), Self.alert(2, at: "10:03:00")])
    let r = try M.reader(s)
    #expect(try Self.live(r) == [M.ulid(1)])
    #expect(try r.txn(M.ulid(1))?.merchantRaw == Self.payee)
    #expect(try r.transferCopy(of: M.ulid(1)) == .init(txnID: M.ulid(1), copyID: M.ulid(2), copyOf: M.ulid(1), version: 1))
    #expect(try Self.out(r) == 314_159)
  }

  @Test("keep both after the merge counts both rows; clearing it combines them again; totals follow")
  func undoAfterMerge() throws {
    let base = [D.home, Self.alert(1, at: "10:00:00"), Self.notice(2, at: "10:04:00")]
    let kept = try M.fold(base + [Self.resolve(1, other: 2, "keep_both", parent: 1, op: "op-keep")])
    let rk = try M.reader(kept)
    #expect(try Self.live(rk) == [M.ulid(1), M.ulid(2)])
    #expect(try rk.txn(M.ulid(1))?.merchantRaw == Self.code && rk.txn(M.ulid(2))?.merchantRaw == Self.payee)
    #expect(try rk.txn(M.ulid(1))?.heldCopy == false && rk.txn(M.ulid(1))?.copyDecision == "keep_both")
    #expect(try rk.transferCopy(of: M.ulid(2)) == nil && rk.transferCopies().isEmpty)
    #expect(try Self.out(rk) == 628_318)

    let again = try M.fold(
      base + [Self.resolve(1, other: 2, "keep_both", parent: 1, op: "op-keep"), Self.resolve(1, other: 2, nil, parent: 2, op: "op-undo")])
    let ra = try M.reader(again)
    #expect(try Self.live(ra) == [M.ulid(2)])
    #expect(try ra.transferCopy(of: M.ulid(2)) == .init(txnID: M.ulid(2), copyID: M.ulid(1), copyOf: M.ulid(2), version: 3))
    #expect(try Self.out(ra) == 314_159)
  }

  @Test("keep both replays the same, and a second keep both changes nothing")
  func undoIdempotent() throws {
    let ops = [
      D.home, Self.notice(1, at: "10:00:00"), Self.alert(2, at: "10:03:00"),
      Self.resolve(2, other: 1, "keep_both", parent: 1, op: "op-keep"),
    ]
    let a = try M.fold(ops)
    let b = try M.fold(ops)
    #expect(a.serialized() == b.serialized())
    let twice = try M.fold(ops + [Self.resolve(2, other: 1, "keep_both", parent: 2, op: "op-keep-2")])
    let r = try M.reader(twice)
    #expect(try Self.live(r) == [M.ulid(1), M.ulid(2)])
    #expect(try Self.out(r) == 628_318)
    #expect(try r.txn(M.ulid(2))?.copyDecision == "keep_both")
  }

  @Test("an alert kept as the row because it had its own copy decision shows the notice's payee")
  func alertKeptShowsPayee() throws {
    let ops = [
      D.home, Self.alert(1, at: "10:00:00"), Self.alert(2, at: "10:05:00"),
      Self.resolve(2, other: 1, "keep_both", parent: 1, op: "op-keep"), Self.notice(3, at: "10:06:00"),
    ]
    let s = try M.fold(ops)
    #expect(s.txns[M.ulid(3)]?.mergedInto == M.ulid(2) && s.txns[M.ulid(3)]?.mergeKind == "transfer")
    #expect(s.transferDisplaySource(M.ulid(2)) == M.ulid(3) && s.transferDisplaySource(M.ulid(1)) == nil)
    let r = try M.reader(s)
    #expect(try Self.live(r) == [M.ulid(1), M.ulid(2)])
    let row = try #require(try r.txn(M.ulid(2)))
    #expect(row.merchantRaw == Self.payee && row.merchantKey == Canon.merchantKey(Self.payee))
    #expect(try r.txn(M.ulid(1))?.merchantRaw == Self.code)
    #expect(try r.transferCopy(of: M.ulid(2)) == .init(txnID: M.ulid(2), copyID: M.ulid(3), copyOf: M.ulid(2), version: 1))
    #expect(try Self.out(r) == 628_318)

    let apart = try M.reader(try M.fold(ops + [Self.resolve(3, other: 2, "keep_both", parent: 1, op: "op-apart")]))
    #expect(try Self.live(apart) == [M.ulid(1), M.ulid(2), M.ulid(3)])
    #expect(try apart.txn(M.ulid(2))?.merchantRaw == Self.code && apart.txn(M.ulid(3))?.merchantRaw == Self.payee)
    #expect(try Self.out(apart) == 942_477)
  }

  @Test("after the combined row leaves with its mailbox, the promoted row offers no keep apart for a copy of the retired row")
  func promotedRowOffersNoStaleCopy() throws {
    let retire = #"{"v":4,"type":"mailbox_retired","op_id":"op-retire","authored_at":"2026-10-05T08:00:00.000Z","parent_version":null,"payload":{"grant_id":"\#(M.a)","provider":"gmail","legacy":false}}"#
    let s = try M.fold([
      D.home, Self.notice(1, at: "10:00:00", mid: D.mid), Self.notice(2, at: "10:00:00", grant: M.b, mid: D.mid),
      Self.alert(3, at: "10:03:00", grant: M.b), retire,
    ])
    #expect(s.txns[M.ulid(3)]?.mergedInto == M.ulid(2) && s.txns[M.ulid(3)]?.copyOf == M.ulid(1))
    let r = try M.reader(s)
    #expect(try Self.live(r) == [M.ulid(2)])
    #expect(try r.transferCopy(of: M.ulid(2)) == nil && r.transferCopies().isEmpty)
  }
}
