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
    precision: String = "time", grant: String = Mbx.a, mid: String? = nil, verified: Bool = true, kind: String? = nil
  ) -> String {
    let dedupe = mid.map { #","dedupe":{"message_id":"\#($0)"}"# } ?? ""
    let marker = kind.map { #","kind":\#($0)"# } ?? ""
    let gates =
      verified
      ? #"{"ar":"pass","sender":"trusted","template":"\#(template)","card":"unknown","forwarded":false\#(marker)}"#
      : #"{"ar":"fail","sender":"untrusted","template":"\#(template)","card":"unknown","forwarded":false\#(marker)}"#
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
  @Test("the debit alert that follows a transfer notice is merged into it without a person, whatever its merchant and card")
  func alertAfterNotice() throws {
    var log = Log()
    try log.blob(Notice.row(1, id: Ids.t1, template: Notice.arabic))
    try log.blob(Notice.alert(2, id: Ids.t2, at: "2026-10-03T10:03:00.000Z"))
    let s = log.state
    let alert = try #require(s.txns[Ids.t2])
    #expect(alert.copyOf == Ids.t1 && alert.mergedInto == Ids.t1 && alert.mergeKind == "transfer" && alert.mergeOp == "op-1002")
    #expect(!alert.isHeldCopy && !alert.isLive)
    #expect(s.txns[Ids.t1]?.copyOf == nil && s.txns[Ids.t1]?.isLive == true)
    #expect(s.txns[Ids.t1]?.aliases.map(\.txnID) == [Ids.t2] && s.txns[Ids.t1]?.aliases.first?.kind == "transfer")
    #expect(s.txns.values.filter { $0.isLive && !$0.isHeldCopy && $0.amountMinor == 314_159 }.count == 1)
    #expect(DuplicateRules.transferCopyWindowMs == 1_800_000)
    #expect(log.kinds.isEmpty)
  }

  @Test("a notice that follows its alert stays the row and the alert merges into it; the English notice pairs too")
  func noticeAfterAlert() throws {
    var log = Log()
    try log.blob(Notice.alert(1, id: Ids.t1, at: "2026-10-03T10:00:00.000Z"))
    try log.blob(
      Notice.row(2, id: Ids.t2, template: Notice.english, merchant: "SAMPLE BANK PJSC", last4: "0202", at: "2026-10-03T10:20:00.000Z"))
    let s = log.state
    #expect(s.txns[Ids.t1]?.copyOf == Ids.t2 && s.txns[Ids.t1]?.mergedInto == Ids.t2 && s.txns[Ids.t1]?.mergeKind == "transfer")
    #expect(s.txns[Ids.t2]?.copyOf == nil && s.txns[Ids.t2]?.isLive == true && s.txns[Ids.t2]?.merchantRaw == "SAMPLE BANK PJSC")
  }

  @Test("more than thirty minutes apart, another amount, a credit, a card purchase or a day-precision row stays separate")
  func separate() throws {
    var log = Log()
    try log.blob(Notice.row(1, id: Ids.t1, template: Notice.arabic))
    try log.blob(Notice.alert(2, id: Ids.t2, at: "2026-10-03T10:30:01.000Z"))
    try log.blob(Notice.alert(3, id: Ids.t3, at: "2026-10-03T10:05:00.000Z", amount: "314158"))
    try log.blob(Notice.alert(4, id: Ids.ulid(7), at: "2026-10-03T10:05:00.000Z", direction: "credit"))
    try log.blob(
      Notice.row(5, id: Ids.ulid(8), template: Notice.card, merchant: "SHOP", last4: "0707", at: "2026-10-03T10:05:00.000Z"))
    try log.blob(Notice.alert(6, id: Ids.ulid(9), at: "2026-10-03T10:05:00.000Z", precision: "day"))
    for id in [Ids.t1, Ids.t2, Ids.t3, Ids.ulid(7), Ids.ulid(8), Ids.ulid(9)] {
      #expect(log.state.txns[id]?.copyOf == nil, "\(id)")
    }
  }

  @Test("an alert exactly thirty minutes after its notice is still its copy")
  func windowEdge() throws {
    var log = Log()
    try log.blob(Notice.row(1, id: Ids.t1, template: Notice.arabic))
    try log.blob(Notice.alert(2, id: Ids.t2, at: "2026-10-03T10:30:00.000Z"))
    #expect(log.state.txns[Ids.t2]?.copyOf == Ids.t1)
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
    #expect(s.txns[Ids.t1]?.copyOf == Ids.t3 && s.txns[Ids.t1]?.mergedInto == Ids.t3 && s.txns[Ids.t1]?.mergeKind == "transfer")
    #expect(s.txns.values.filter(\.isLive).map(\.id) == [Ids.t3])
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

  @Test("a pair whose notice or alert did not pass the sender gates is still held for the person")
  func unverifiedStaysHeld() throws {
    var log = Log()
    try log.blob(Notice.row(1, id: Ids.t1, template: Notice.arabic, verified: false))
    try log.blob(Notice.alert(2, id: Ids.t2, at: "2026-10-03T10:03:00.000Z"))
    let alert = try #require(log.state.txns[Ids.t2])
    #expect(alert.copyOf == Ids.t1 && alert.isHeldCopy && alert.mergedInto == nil)
  }

  @Test("keep both counts both rows; clearing the decision merges them again; merge is a no-op")
  func undo() throws {
    var log = Log()
    try log.blob(Notice.row(1, id: Ids.t1, template: Notice.arabic))
    try log.blob(Notice.alert(2, id: Ids.t2, at: "2026-10-03T10:02:00.000Z"))
    try log.blob(Copy.resolve(Ids.t2, other: Ids.t1, "keep_both", parent: 1, op: 50))
    var alert = try #require(log.state.txns[Ids.t2])
    #expect(alert.isLive && !alert.isHeldCopy && alert.copyDecision == "keep_both" && alert.mergedInto == nil)
    #expect(log.state.txns[Ids.t1]?.aliases.isEmpty == true)
    try log.blob(Copy.resolve(Ids.t2, other: Ids.t1, nil, parent: 2, op: 51))
    alert = try #require(log.state.txns[Ids.t2])
    #expect(alert.mergedInto == Ids.t1 && alert.mergeKind == "transfer" && alert.mergeOp == "op-51" && alert.copyDecision == nil)
    try log.blob(Copy.resolve(Ids.t2, other: Ids.t1, "merge", parent: 3, op: 52))
    #expect(log.state.txns[Ids.t2]?.mergeKind == "transfer" && log.state.txns[Ids.t1]?.aliases.count == 1)
    #expect(log.kinds.isEmpty)
  }

  @Test("rows read without a template pair through gates.kind")
  func kindMarker() throws {
    var log = Log()
    try log.blob(Notice.row(1, id: Ids.t1, template: "none", merchant: "SAMPLE PAYEE", kind: #""transfer_notice""#))
    try log.blob(
      Notice.row(
        2, id: Ids.t2, template: "none", merchant: "FUNDS TRANSFER DEBIT", last4: "0606", at: "2026-10-03T10:04:00.000Z",
        kind: #""account_debit_alert""#))
    let s = log.state
    #expect(s.txns[Ids.t1]?.gates?.kind == "transfer_notice" && s.txns[Ids.t2]?.gates?.kind == "account_debit_alert")
    #expect(s.txns[Ids.t2]?.mergedInto == Ids.t1 && s.txns[Ids.t2]?.mergeKind == "transfer")
    #expect(String(decoding: s.serialized(), as: UTF8.self).contains(#""kind":"account_debit_alert""#))

    var mixed = Log()
    try mixed.blob(Notice.alert(1, id: Ids.t1, at: "2026-10-03T10:00:00.000Z"))
    try mixed.blob(Notice.row(2, id: Ids.t2, template: "none", at: "2026-10-03T10:05:00.000Z", kind: #""transfer_notice""#))
    #expect(mixed.state.txns[Ids.t1]?.mergedInto == Ids.t2 && mixed.state.txns[Ids.t2]?.isLive == true)
  }

  @Test("an unknown or malformed gates.kind is ignored, and two notices by marker never pair")
  func unknownKind() throws {
    var log = Log()
    try log.blob(Notice.row(1, id: Ids.t1, template: "none", merchant: "PAYEE ONE", kind: #""transfer_notice""#))
    try log.blob(
      Notice.row(2, id: Ids.t2, template: "none", merchant: "PAYEE TWO", at: "2026-10-03T10:01:00.000Z", kind: #""card_purchase""#))
    try log.blob(Notice.row(3, id: Ids.t3, template: "none", merchant: "PAYEE THREE", at: "2026-10-03T10:02:00.000Z", kind: "7"))
    try log.blob(
      Notice.row(4, id: Ids.ulid(7), template: "none", merchant: "PAYEE FOUR", at: "2026-10-03T10:03:00.000Z", kind: #""transfer_notice""#))
    let s = log.state
    #expect(s.txns[Ids.t2]?.gates?.kind == nil && s.txns[Ids.t3]?.gates?.kind == nil)
    for id in [Ids.t1, Ids.t2, Ids.t3, Ids.ulid(7)] {
      #expect(s.txns[id]?.copyOf == nil && s.txns[id]?.mergedInto == nil, "\(id)")
    }
    #expect(log.kinds.isEmpty)
  }

  @Test("a generic probable copy still waits for the person")
  func genericStillAsks() throws {
    var log = Log()
    try log.blob(Copy.alert(1, id: Ids.t1, grant: Mbx.a, gates: Copy.pass))
    try log.blob(Copy.alert(2, id: Ids.t2, grant: Mbx.b, at: "2026-10-03T08:05:00.000Z", gates: Copy.pass))
    let copy = try #require(log.state.txns[Ids.t2])
    #expect(copy.isHeldCopy && copy.mergedInto == nil)
  }

  @Test("the fold is the same on every replay, and a re-read alert is refused")
  func replayIdempotent() throws {
    func fold() throws -> Log {
      var log = Log()
      try log.blob(Notice.row(1, id: Ids.t1, template: Notice.arabic))
      try log.blob(Notice.alert(2, id: Ids.t2, at: "2026-10-03T10:02:00.000Z"))
      try log.blob(Copy.resolve(Ids.t2, other: Ids.t1, "keep_both", parent: 1, op: 50))
      try log.blob(Copy.resolve(Ids.t2, other: Ids.t1, nil, parent: 2, op: 51))
      return log
    }
    let a = try fold()
    let b = try fold()
    #expect(a.state.serialized() == b.state.serialized())
    var again = try fold()
    try again.blob(Notice.alert(2, id: Ids.t3, at: "2026-10-03T10:02:00.000Z"))
    #expect(again.state.txns[Ids.t3] == nil && again.kinds == ["duplicate_ingest"])
    #expect(again.state.txns[Ids.t1]?.aliases.count == 1)
  }

  @Test("after keep both, a copy of the notice or the alert from a second mailbox merges into its own row")
  func keepBothThenCrossMailboxCopies() throws {
    let other = "fedcba9876543210fedcba9876543210"
    var log = Log()
    try log.blob(Notice.row(1, id: Ids.t1, template: Notice.arabic, grant: Mbx.a, mid: Copy.mid))
    try log.blob(
      Notice.row(
        2, id: Ids.t2, template: Notice.account, merchant: "MB FUND TRANSFER DEBIT", last4: "0606", at: "2026-10-03T10:02:00.000Z",
        grant: Mbx.a, mid: other))
    #expect(log.state.txns[Ids.t2]?.mergedInto == Ids.t1)
    try log.blob(Copy.resolve(Ids.t2, other: Ids.t1, "keep_both", parent: 1, op: 50))
    #expect(log.state.byDedupeKey["mid:" + other] == Ids.t2)
    try log.blob(Notice.row(3, id: Ids.t3, template: Notice.arabic, grant: Mbx.b, mid: Copy.mid))
    try log.blob(
      Notice.row(
        4, id: Ids.ulid(7), template: Notice.account, merchant: "MB FUND TRANSFER DEBIT", last4: "0606",
        at: "2026-10-03T10:02:00.000Z", grant: Mbx.b, mid: other))
    let s = log.state
    #expect(s.txns[Ids.t1]?.isLive == true && s.txns[Ids.t2]?.isLive == true)
    #expect(s.txns[Ids.t2]?.copyOf == Ids.t1 && s.txns[Ids.t2]?.copyDecision == "keep_both")
    #expect(s.txns[Ids.t1]?.copyOf == nil && s.txns[Ids.t1]?.mergedInto == nil)
    #expect(s.txns[Ids.t3]?.mergedInto == Ids.t1 && s.txns[Ids.t3]?.mergeKind == "certain")
    #expect(s.txns[Ids.ulid(7)]?.mergedInto == Ids.t2 && s.txns[Ids.ulid(7)]?.mergeKind == "certain")
    #expect(s.byDedupeKey["mid:" + other] == Ids.t2 && s.byDedupeKey["mid:" + Copy.mid] == Ids.t1)
    try log.blob(Copy.resolve(Ids.t2, other: Ids.t1, nil, parent: 2, op: 51))
    #expect(log.state.txns[Ids.t2]?.mergedInto == Ids.t1 && log.state.byDedupeKey["mid:" + other] == Ids.t1)
    #expect(log.kinds.isEmpty)
  }

  @Test("an account alert that does not describe a transfer is held for the person, not merged")
  func nonTransferAlertHeld() throws {
    var log = Log()
    try log.blob(Notice.row(1, id: Ids.t1, template: Notice.arabic))
    try log.blob(Notice.alert(2, id: Ids.t2, at: "2026-10-03T10:03:00.000Z", merchant: "CREDIT CARD PAYMENT"))
    let held = try #require(log.state.txns[Ids.t2])
    #expect(held.copyOf == Ids.t1 && held.isHeldCopy && held.mergedInto == nil)

    var arabic = Log()
    try arabic.blob(Notice.row(1, id: Ids.t1, template: Notice.arabic))
    try arabic.blob(Notice.alert(2, id: Ids.t2, at: "2026-10-03T10:03:00.000Z", merchant: "تحويل أموال"))
    #expect(arabic.state.txns[Ids.t2]?.mergedInto == Ids.t1)

    var short = Log()
    try short.blob(Notice.row(1, id: Ids.t1, template: Notice.arabic))
    try short.blob(Notice.alert(2, id: Ids.t2, at: "2026-10-03T10:03:00.000Z", merchant: "OUTWARD FUNDS TRANS"))
    #expect(short.state.txns[Ids.t2]?.mergedInto == Ids.t1)

    var transport = Log()
    try transport.blob(Notice.row(1, id: Ids.t1, template: Notice.arabic))
    try transport.blob(Notice.alert(2, id: Ids.t2, at: "2026-10-03T10:03:00.000Z", merchant: "TRANSPORT FARE"))
    #expect(transport.state.txns[Ids.t2]?.isHeldCopy == true)
  }

  @Test("an alert the person filed before its notice came carries its category to the notice")
  func alertFirstCarriesEdits() throws {
    var log = Log()
    try log.blob(Notice.alert(1, id: Ids.t1, at: "2026-10-03T10:00:00.000Z"))
    try log.blob(
      op(
        "txn_categorized", #"{"category":"dining","needs_review":false,"source":{"kind":"user"}}"#, id: 40, entity: ("txn", Ids.t1),
        parent: 1))
    try log.blob(Notice.row(2, id: Ids.t2, template: Notice.arabic, merchant: "SAMPLE PAYEE", at: "2026-10-03T10:04:00.000Z"))
    let s = log.state
    #expect(s.txns[Ids.t1]?.mergedInto == Ids.t2)
    #expect(s.txns[Ids.t2]?.category == "dining" && s.txns[Ids.t2]?.categorySource?.kind == .user)
    #expect(s.txns[Ids.t2]?.needsReview == false)
    #expect(log.kinds.isEmpty)
  }

  @Test("clearing keep both carries what the person set on the alert to the row that stays")
  func undoCarriesEdits() throws {
    var log = Log()
    try log.blob(Notice.row(1, id: Ids.t1, template: Notice.arabic))
    try log.blob(Notice.alert(2, id: Ids.t2, at: "2026-10-03T10:02:00.000Z"))
    try log.blob(Copy.resolve(Ids.t2, other: Ids.t1, "keep_both", parent: 1, op: 50))
    try log.blob(
      op(
        "txn_categorized", #"{"category":"dining","needs_review":false,"source":{"kind":"user"}}"#, id: 51, entity: ("txn", Ids.t2),
        parent: 2))
    try log.blob(Copy.resolve(Ids.t2, other: Ids.t1, nil, parent: 3, op: 52))
    let s = log.state
    #expect(s.txns[Ids.t2]?.mergedInto == Ids.t1)
    #expect(s.txns[Ids.t1]?.category == "dining" && s.txns[Ids.t1]?.categorySource?.kind == .user)
  }

  @Test("gates.kind does not make a transfer of a row that a known non-transfer template read")
  func kindIgnoredForKnownTemplate() throws {
    var log = Log()
    try log.blob(Notice.row(1, id: Ids.t1, template: Notice.arabic))
    try log.blob(
      Notice.row(
        2, id: Ids.t2, template: Notice.card, merchant: "MB FUND TRANSFER DEBIT", last4: "0606", at: "2026-10-03T10:02:00.000Z",
        kind: #""account_debit_alert""#))
    #expect(log.state.txns[Ids.t2]?.copyOf == nil && log.state.txns[Ids.t2]?.mergedInto == nil)
    #expect(DuplicateRules.transferRole(log.state.txns[Ids.t2]!) == nil)
  }
}
