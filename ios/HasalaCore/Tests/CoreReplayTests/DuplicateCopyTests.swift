import CoreJSON
import CoreWire
import Foundation
import Testing

@testable import CoreReplay

enum Copy {
  static let mid = "0123456789abcdef0123456789abcdef"
  static let pass = #","gates":{"ar":"pass","sender":"trusted","template":"enbd-card@1","card":"known","forwarded":false}"#
  static let fail = #","gates":{"ar":"fail","sender":"untrusted","template":"enbd-card@1","card":"known","forwarded":false}"#

  static func alert(
    _ n: Int, id: String, grant: String, merchant: String = "STARBUCKS DIFC", amount: String = "2700",
    at: String = "2026-10-03T08:00:00.000Z", mid: String? = nil, gates: String = Copy.fail
  ) -> String {
    let dedupe = mid.map { #","dedupe":{"message_id":"\#($0)"}"# } ?? ""
    return op(
      "txn_ingested",
      #"{"amount_minor":"\#(amount)","currency":"AED","direction":"debit","posted_at":"\#(at)","posted_precision":"time","merchant_raw":"\#(merchant)","last4":"4412","needs_review":false,"category":null,"tier":"template","entry_method":"mailbox","bank":"enbd","provenance":{"provider":"gmail","grant_id":"\#(grant)","message_id":"m\#(n)"}\#(gates)\#(dedupe)}"#,
      id: 1000 + n, entity: ("txn", id), ingest: Ids.ingest(n))
  }

  static func resolve(_ id: String, other: String, _ decision: String?, parent: Int, op opID: Int) -> String {
    op(
      "txn_copy_resolved", #"{"other_txn_id":"\#(other)","decision":\#(decision.map { "\"\($0)\"" } ?? "null")}"#, id: opID,
      entity: ("txn", id), parent: parent)
  }
}

@Suite("CoreReplay duplicate copies")
struct DuplicateCopyTests {
  @Test("a shared Message-ID merges at once; the earlier import is canonical when neither sender verified")
  func certainEarliest() throws {
    var log = Log()
    try log.blob(Copy.alert(1, id: Ids.t1, grant: Mbx.a, mid: Copy.mid))
    try log.blob(Copy.alert(2, id: Ids.t2, grant: Mbx.b, at: "2026-10-03T09:30:00.000Z", mid: Copy.mid))
    let s = log.state
    #expect(s.txns[Ids.t2]?.mergedInto == Ids.t1 && s.txns[Ids.t2]?.mergeKind == "certain")
    #expect(s.txns[Ids.t1]?.aliases.map(\.mailboxMessageID) == ["m2"])
    #expect(s.txns[Ids.t1]?.aliases.first?.sourceMailbox == Mbx.b)
    #expect(s.txns[Ids.t2]?.isLive == false && s.txns[Ids.t1]?.isLive == true)
    #expect(s.byDedupeKey["mid:" + Copy.mid] == Ids.t1)
    #expect(s.liveByIngestID[Ids.ingest(2)] == nil && s.pendingByCurrency.isEmpty == false)
    #expect(log.kinds.isEmpty)
  }

  @Test("the copy whose sender verified wins")
  func certainVerifiedWins() throws {
    var log = Log()
    try log.blob(Copy.alert(1, id: Ids.t1, grant: Mbx.a, mid: Copy.mid, gates: Copy.fail))
    try log.blob(Copy.alert(2, id: Ids.t2, grant: Mbx.b, mid: Copy.mid, gates: Copy.pass))
    let s = log.state
    #expect(s.txns[Ids.t1]?.mergedInto == Ids.t2)
    #expect(s.txns[Ids.t2]?.aliases.map(\.txnID) == [Ids.t1])
    #expect(s.txns[Ids.t2]?.possibleDuplicateOf == nil)
    #expect(s.byDedupeKey["mid:" + Copy.mid] == Ids.t2)
  }

  @Test("the same alert imported again is refused, not added")
  func rescan() throws {
    var log = Log()
    try log.blob(Copy.alert(1, id: Ids.t1, grant: Mbx.a, mid: Copy.mid))
    try log.blob(Copy.alert(2, id: Ids.t2, grant: Mbx.b, mid: Copy.mid))
    try log.blob(Copy.alert(2, id: Ids.t3, grant: Mbx.b, mid: Copy.mid))
    #expect(log.kinds == ["duplicate_ingest"])
    #expect(log.state.txns[Ids.t3] == nil)
    #expect(log.state.txns[Ids.t1]?.aliases.count == 1)
  }

  @Test("a probable copy is held: same bank, amount, card and merchant within ten minutes")
  func probableHold() throws {
    var log = Log()
    try log.blob(Copy.alert(1, id: Ids.t1, grant: Mbx.a, merchant: "STARBUCKS  DIFC"))
    try log.blob(Copy.alert(2, id: Ids.t2, grant: Mbx.b, merchant: "starbucks difc", at: "2026-10-03T08:10:00.000Z"))
    try log.blob(Copy.alert(3, id: Ids.t3, grant: Mbx.b, at: "2026-10-03T08:20:01.000Z"))
    try log.blob(Copy.alert(4, id: Ids.ulid(7), grant: Mbx.b, amount: "2701", at: "2026-10-03T08:01:00.000Z"))
    let s = log.state
    #expect(s.txns[Ids.t2]?.copyOf == Ids.t1 && s.txns[Ids.t2]?.isHeldCopy == true)
    #expect(s.txns[Ids.t3]?.copyOf == nil && s.txns[Ids.ulid(7)]?.copyOf == nil)
    #expect(DuplicateRules.probableCopyWindowMs == 600_000)
  }

  @Test("keep both counts the copy; merge hides it; undo holds it again")
  func resolutions() throws {
    var log = Log()
    try log.blob(Copy.alert(1, id: Ids.t1, grant: Mbx.a))
    try log.blob(Copy.alert(2, id: Ids.t2, grant: Mbx.b, at: "2026-10-03T08:04:00.000Z"))
    try log.blob(Copy.resolve(Ids.t2, other: Ids.t1, "merge", parent: 1, op: 50))
    #expect(log.state.txns[Ids.t2]?.mergedInto == Ids.t1 && log.state.txns[Ids.t2]?.mergeKind == "user")
    #expect(log.state.txns[Ids.t1]?.aliases.map(\.kind) == ["user"])
    try log.blob(Copy.resolve(Ids.t2, other: Ids.t1, nil, parent: 2, op: 51))
    #expect(log.state.txns[Ids.t2]?.isHeldCopy == true && log.state.txns[Ids.t1]?.aliases.isEmpty == true)
    #expect(log.state.liveByIngestID[Ids.ingest(2)] == Ids.t2)
    try log.blob(Copy.resolve(Ids.t2, other: Ids.t1, "keep_both", parent: 3, op: 52))
    #expect(log.state.txns[Ids.t2]?.copyDecision == "keep_both" && log.state.txns[Ids.t2]?.isHeldCopy == false)
    #expect(log.kinds.isEmpty)
    try log.blob(Copy.resolve(Ids.t2, other: Ids.t3, "merge", parent: 4, op: 53))
    #expect(log.kinds == ["duplicate_disposition_mismatch"])
  }

  @Test("removing the canonical's mailbox brings its copy back as the row")
  func retirePromotes() throws {
    var log = Log()
    try log.blob(Copy.alert(1, id: Ids.t1, grant: Mbx.a, mid: Copy.mid))
    try log.blob(Copy.alert(2, id: Ids.t2, grant: Mbx.b, mid: Copy.mid))
    try log.blob(Copy.alert(3, id: Ids.t3, grant: Mbx.b, merchant: "ENOC", at: "2026-10-03T12:00:00.000Z"))
    try log.blob(Copy.alert(4, id: Ids.ulid(7), grant: Mbx.b, merchant: "ENOC", at: "2026-10-03T12:05:00.000Z"))
    try log.blob(Mbx.retire(Mbx.a, id: 60))
    let s = log.state
    #expect(s.txns[Ids.t1]?.retiredBy == "op-60")
    #expect(s.txns[Ids.t2]?.isLive == true && s.txns[Ids.t2]?.mergedInto == nil)
    #expect(s.liveByIngestID[Ids.ingest(2)] == Ids.t2 && s.byDedupeKey["mid:" + Copy.mid] == Ids.t2)
    #expect(s.txns[Ids.ulid(7)]?.copyOf == Ids.t3)
    try log.blob(Mbx.retire(Mbx.b, id: 61))
    #expect(log.state.byDedupeKey.isEmpty)
    #expect(log.state.txns.values.allSatisfy { !$0.isLive })
  }
}

enum Notice {
  static let arabic = "dib.transfer.v1@1"
  static let english = "dib.money-transfer.v1@1"
  static let account = "dib.account.v1@3"
  static let card = "dib.card.v1@2"

  static func row(
    _ n: Int, id: String, template: String, merchant: String = "DIB TRANSFER", last4: String = "0909",
    amount: String = "314159", at: String = "2026-10-03T10:00:00.000Z", direction: String = "debit",
    precision: String = "time", grant: String = Mbx.a, mid: String? = nil, verified: Bool = true
  ) -> String {
    let dedupe = mid.map { #","dedupe":{"message_id":"\#($0)"}"# } ?? ""
    let gates =
      verified
      ? #"{"ar":"pass","sender":"trusted","template":"\#(template)","card":"unknown","forwarded":false}"#
      : #"{"ar":"fail","sender":"untrusted","template":"\#(template)","card":"unknown","forwarded":false}"#
    return op(
      "txn_ingested",
      #"{"amount_minor":"\#(amount)","currency":"AED","direction":"\#(direction)","posted_at":"\#(at)","posted_precision":"\#(precision)","merchant_raw":"\#(merchant)","last4":"\#(last4)","needs_review":true,"category":null,"tier":"template","entry_method":"mailbox","bank":"dib","provenance":{"provider":"gmail","grant_id":"\#(grant)","message_id":"m\#(n)"},"gates":\#(gates)\#(dedupe)}"#,
      id: 1000 + n, entity: ("txn", id), ingest: Ids.ingest(n))
  }

  static func alert(
    _ n: Int, id: String, at: String, merchant: String = "MB FUND TRANSFER DEBIT", amount: String = "314159",
    direction: String = "debit", precision: String = "time", grant: String = Mbx.a
  ) -> String {
    row(
      n, id: id, template: account, merchant: merchant, last4: "0606", amount: amount, at: at, direction: direction,
      precision: precision, grant: grant)
  }
}

@Suite("CoreReplay transfer notice copies")
struct TransferCopyTests {
  @Test("the debit alert that follows a transfer notice is held as its copy, whatever its merchant and card")
  func alertAfterNotice() throws {
    var log = Log()
    try log.blob(Notice.row(1, id: Ids.t1, template: Notice.arabic))
    try log.blob(Notice.alert(2, id: Ids.t2, at: "2026-10-03T10:03:00.000Z"))
    let s = log.state
    #expect(s.txns[Ids.t2]?.copyOf == Ids.t1 && s.txns[Ids.t2]?.isHeldCopy == true)
    #expect(s.txns[Ids.t1]?.copyOf == nil)
    #expect(DuplicateRules.transferCopyWindowMs == 3_600_000)
    #expect(log.kinds.isEmpty)
  }

  @Test("a notice that follows its alert is the held one; the English notice pairs too")
  func noticeAfterAlert() throws {
    var log = Log()
    try log.blob(Notice.alert(1, id: Ids.t1, at: "2026-10-03T10:00:00.000Z"))
    try log.blob(
      Notice.row(2, id: Ids.t2, template: Notice.english, merchant: "SAMPLE BANK PJSC", last4: "0202", at: "2026-10-03T10:20:00.000Z"))
    #expect(log.state.txns[Ids.t2]?.copyOf == Ids.t1)
  }

  @Test("more than an hour apart, another amount, a credit, a card purchase or a day-precision row stays separate")
  func separate() throws {
    var log = Log()
    try log.blob(Notice.row(1, id: Ids.t1, template: Notice.arabic))
    try log.blob(Notice.alert(2, id: Ids.t2, at: "2026-10-03T11:00:01.000Z"))
    try log.blob(Notice.alert(3, id: Ids.t3, at: "2026-10-03T10:05:00.000Z", amount: "314158"))
    try log.blob(Notice.alert(4, id: Ids.ulid(7), at: "2026-10-03T10:05:00.000Z", direction: "credit"))
    try log.blob(
      Notice.row(5, id: Ids.ulid(8), template: Notice.card, merchant: "SHOP", last4: "0707", at: "2026-10-03T10:05:00.000Z"))
    try log.blob(Notice.alert(6, id: Ids.ulid(9), at: "2026-10-03T10:05:00.000Z", precision: "day"))
    for id in [Ids.t1, Ids.t2, Ids.t3, Ids.ulid(7), Ids.ulid(8), Ids.ulid(9)] {
      #expect(log.state.txns[id]?.copyOf == nil, "\(id)")
    }
  }

  @Test("two notices never pair with each other, and each alert pairs with one notice")
  func oneToOne() throws {
    var log = Log()
    try log.blob(Notice.row(1, id: Ids.t1, template: Notice.arabic, at: "2026-10-03T10:00:00.000Z"))
    try log.blob(Notice.row(2, id: Ids.t2, template: Notice.arabic, at: "2026-10-03T10:20:00.000Z"))
    try log.blob(Notice.alert(3, id: Ids.t3, at: "2026-10-03T10:01:00.000Z"))
    try log.blob(Notice.alert(4, id: Ids.ulid(7), at: "2026-10-03T10:21:00.000Z"))
    try log.blob(Notice.alert(5, id: Ids.ulid(8), at: "2026-10-03T10:22:00.000Z"))
    let s = log.state
    #expect(s.txns[Ids.t2]?.copyOf == nil)
    #expect(s.txns[Ids.t3]?.copyOf == Ids.t1)
    #expect(s.txns[Ids.ulid(7)]?.copyOf == Ids.t2)
    #expect(s.txns[Ids.ulid(8)]?.copyOf == nil)
  }

  @Test("merge keeps the notice paired; keep both frees it for another alert")
  func resolutions() throws {
    var log = Log()
    try log.blob(Notice.row(1, id: Ids.t1, template: Notice.arabic))
    try log.blob(Notice.alert(2, id: Ids.t2, at: "2026-10-03T10:02:00.000Z"))
    try log.blob(Copy.resolve(Ids.t2, other: Ids.t1, "merge", parent: 1, op: 50))
    try log.blob(Notice.alert(3, id: Ids.t3, at: "2026-10-03T10:04:00.000Z"))
    #expect(log.state.txns[Ids.t2]?.mergedInto == Ids.t1 && log.state.txns[Ids.t3]?.copyOf == nil)

    var kept = Log()
    try kept.blob(Notice.row(1, id: Ids.t1, template: Notice.arabic))
    try kept.blob(Notice.alert(2, id: Ids.t2, at: "2026-10-03T10:02:00.000Z"))
    try kept.blob(Copy.resolve(Ids.t2, other: Ids.t1, "keep_both", parent: 1, op: 50))
    try kept.blob(Notice.alert(3, id: Ids.t3, at: "2026-10-03T10:04:00.000Z", merchant: "SAMPLE PURPOSE"))
    #expect(kept.state.txns[Ids.t2]?.isHeldCopy == false && kept.state.txns[Ids.t3]?.copyOf == Ids.t1)
    #expect(kept.kinds.isEmpty)
  }

  @Test("the same notice read twice keeps the pair on the copy that stays")
  func certainCopyKeepsThePair() throws {
    var log = Log()
    try log.blob(Notice.alert(1, id: Ids.t1, at: "2026-10-03T10:00:00.000Z"))
    try log.blob(
      Notice.row(2, id: Ids.t2, template: Notice.arabic, at: "2026-10-03T10:01:00.000Z", grant: Mbx.a, mid: Copy.mid, verified: false))
    try log.blob(Notice.row(3, id: Ids.t3, template: Notice.arabic, at: "2026-10-03T10:01:30.000Z", grant: Mbx.b, mid: Copy.mid))
    let s = log.state
    #expect(s.txns[Ids.t2]?.mergedInto == Ids.t3)
    #expect(s.txns[Ids.t3]?.copyOf == Ids.t1 && s.txns[Ids.t3]?.isHeldCopy == true)
  }

  @Test("removing the notice's mailbox releases the held alert")
  func retireReleases() throws {
    var log = Log()
    try log.blob(Notice.row(1, id: Ids.t1, template: Notice.arabic, grant: Mbx.a))
    try log.blob(Notice.alert(2, id: Ids.t2, at: "2026-10-03T10:02:00.000Z", grant: Mbx.b))
    #expect(log.state.txns[Ids.t2]?.copyOf == Ids.t1)
    try log.blob(Mbx.retire(Mbx.a, id: 60))
    #expect(log.state.txns[Ids.t2]?.copyOf == nil && log.state.txns[Ids.t2]?.isLive == true)
  }
}
