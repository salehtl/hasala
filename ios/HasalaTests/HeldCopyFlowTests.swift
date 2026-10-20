import CoreCategorize
import CoreProjection
import CoreReplay
import CoreWire
import Foundation
import HasalaMocks
import HasalaModels
import Testing

@testable import Hasala

@MainActor
@Suite("Held copies in the app")
struct HeldCopyFlowTests {
  static func ulid(_ n: Int) -> String { "01JC" + String(repeating: "0", count: 22 - String(n).count) + String(n) }

  static func alert(_ n: Int, grant: String, at: String) -> String {
    let ingest = String(repeating: "0", count: 62) + "0\(n)"
    return #"{"v":4,"type":"txn_ingested","op_id":"op-\#(n)","authored_at":"2026-10-01T08:00:00.000Z","entity":{"kind":"txn","id":"\#(ulid(n))"},"parent_version":null,"ingest_id":"\#(ingest)","payload":{"amount_minor":"2700","currency":"AED","direction":"debit","posted_at":"2026-10-03T\#(at).000Z","posted_precision":"time","merchant_raw":"STARBUCKS DIFC","last4":"4412","needs_review":false,"category":"dining","category_source":{"kind":"user"},"tier":"template","entry_method":"mailbox","bank":"enbd","provenance":{"provider":"gmail","grant_id":"\#(grant)","message_id":"m\#(n)"}}}"#
  }

  static func reader(sameInbox: Bool) throws -> LedgerReader {
    var s = State()
    let blobs = [alert(1, grant: "u/mbx-a", at: "08:00:00"), alert(2, grant: sameInbox ? "u/mbx-a" : "u/mbx-b", at: "08:05:00")]
    for (i, op) in blobs.enumerated() {
      let body = Array(#"{"v":4,"kind":"ops","ops":[\#(op)]}"#.utf8)
      try Replay.foldBlob(PositionedBlob(writerID: "ios-w", writerCounter: Int64(i + 1), seq: Int64(i + 1), body: body), into: &s)
    }
    let db = try Projector.open(path: nil)
    try Projector.project(s, dictionary: AccountRuntime.dictionary, projectedAtMs: 0, into: db)
    return LedgerReader(db)
  }

  @Test func theMapperCarriesTheHoldAndWhichInboxItCameFrom() throws {
    let other = try Self.reader(sameInbox: false)
    let row = try #require(try other.txn(Self.ulid(2)))
    let t = try LedgerStateMapper.txn(row, r: other, ruleByID: [:], billID: nil)
    #expect(t.heldCopy == HeldCopy(of: Self.ulid(1), fromOtherInbox: true))
    #expect(!t.countsInPlan)
    let first = try LedgerStateMapper.txn(try #require(try other.txn(Self.ulid(1))), r: other, ruleByID: [:], billID: nil)
    #expect(first.heldCopy == nil && first.countsInPlan)
    let same = try Self.reader(sameInbox: true)
    let s = try LedgerStateMapper.txn(try #require(try same.txn(Self.ulid(2))), r: same, ruleByID: [:], billID: nil)
    #expect(s.heldCopy?.fromOtherInbox == false)
  }

  @Test func theOptimisticPatchHidesAMergeAndCountsAKeep() throws {
    var s = Scenario.mayaCopy.state
    let (merged, _) = try LiveLedgerStore.patch(.resolveCopy("starbucks-copy", merge: true), &s, now: MayaLedger.now)
    #expect(merged == "Merged" && s.txn("starbucks-copy") == nil)
    var k = Scenario.mayaCopy.state
    let (kept, _) = try LiveLedgerStore.patch(.resolveCopy("starbucks-copy", merge: false), &k, now: MayaLedger.now)
    #expect(kept == "Kept both" && k.txn("starbucks-copy")?.countsInPlan == true)
    var n = Scenario.mayaCopy.state
    #expect(throws: ActionError.notFound) { try LiveLedgerStore.patch(.resolveCopy("starbucks", merge: true), &n, now: MayaLedger.now) }
  }

  @Test func sortingAHeldCopyKeepsItAndFilesIt() throws {
    let app = AppModel(store: InMemoryLedger(state: Scenario.mayaCopy.state))
    let deck = ReviewViewModel(app: app)
    #expect(deck.cards.contains { $0.id == "starbucks-copy" && $0.reviewReason == .probableCopy })
    #expect(deck.sort("starbucks-copy", into: "dining", alwaysUse: false, project: nil))
    #expect(app.store.state.txn("starbucks-copy")?.isHeldCopy == false)
    #expect(app.store.state.txn("starbucks-copy")?.countsInPlan == true)
  }

  @Test func keepingBothCanBeUndone() throws {
    var k = Scenario.mayaCopy.state
    let (_, inverses) = try LiveLedgerStore.patch(.resolveCopy("starbucks-copy", merge: false), &k, now: MayaLedger.now)
    #expect(inverses == [.copyReopened(txn: "starbucks-copy")])
  }

  @Test func undoingASortOfAHeldCopyHoldsItAgain() throws {
    let app = AppModel(store: InMemoryLedger(state: Scenario.mayaCopy.state))
    let deck = ReviewViewModel(app: app)
    #expect(deck.sort("starbucks-copy", into: "dining", alwaysUse: false, project: nil))
    #expect(app.store.state.txn("starbucks-copy")?.isHeldCopy == false)
    app.toastAction()
    #expect(app.store.state.txn("starbucks-copy")?.isHeldCopy == true)
    #expect(deck.cards.contains { $0.id == "starbucks-copy" && $0.reviewReason == .probableCopy })
  }

  @Test func aCopyResolutionWithNoDecisionHoldsTheCopyAgain() throws {
    var s = State()
    let resolved = { (n: Int, decision: String) in
      #"{"v":4,"type":"txn_copy_resolved","op_id":"op-\#(n)","authored_at":"2026-10-04T08:00:00.000Z","entity":{"kind":"txn","id":"\#(Self.ulid(2))"},"parent_version":\#(n - 2),"payload":{"other_txn_id":"\#(Self.ulid(1))","decision":\#(decision)}}"#
    }
    let blobs = [Self.alert(1, grant: "u/mbx-a", at: "08:00:00"), Self.alert(2, grant: "u/mbx-b", at: "08:05:00"),
                 resolved(3, #""keep_both""#), resolved(4, "null")]
    var held: [Bool] = []
    for (i, op) in blobs.enumerated() {
      let body = Array(#"{"v":4,"kind":"ops","ops":[\#(op)]}"#.utf8)
      try Replay.foldBlob(PositionedBlob(writerID: "ios-w", writerCounter: Int64(i + 1), seq: Int64(i + 1), body: body), into: &s)
      guard i >= 1 else { continue }
      let db = try Projector.open(path: nil)
      try Projector.project(s, dictionary: AccountRuntime.dictionary, projectedAtMs: 0, into: db)
      held.append(try #require(try LedgerReader(db).txn(Self.ulid(2))).heldCopy)
    }
    #expect(held == [true, false, true])
  }
}
