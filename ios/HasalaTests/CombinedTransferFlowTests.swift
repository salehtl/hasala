import CoreDomain
import CoreJSON
import CoreProjection
import CoreReplay
import CoreWire
import Foundation
import HasalaMocks
import HasalaModels
import Testing

@testable import Hasala

@MainActor
@Suite("A transfer combined from two bank emails")
struct CombinedTransferFlowTests {
  typealias Mapper = LiveLedgerMapperTests

  static func dib(message: String, at: String, template: String, merchant: String, last4: String) -> JSONObject {
    JSONObject([
      ("amount_minor", .string("314159")), ("currency", .string("AED")), ("direction", .string("debit")),
      ("posted_at", .string("2026-10-03T\(at).000Z")), ("posted_precision", .string("time")),
      ("merchant_raw", .string(merchant)), ("last4", .string(last4)), ("needs_review", .bool(true)),
      ("category", .null), ("tier", .string("template")), ("entry_method", .string("mailbox")), ("bank", .string("dib")),
      ("provenance", .object(JSONObject([
        ("provider", .string("gmail")), ("grant_id", .string("u/mbx-a")), ("message_id", .string(message)),
      ]))),
      ("gates", .object(JSONObject([
        ("ar", .string("pass")), ("sender", .string("trusted")), ("template", .string(template)), ("card", .string("unknown")),
        ("forwarded", .bool(false)),
      ]))),
    ])
  }

  static func store(_ a: Mapper.Account, alert: inout String, notice: inout String) async throws -> LiveLedgerStore {
    var blobs: [AuthoredBlob] = []
    var ids: [String] = []
    if let b = try a.observer.stamps.build(try await a.observer.authorContext(), { o throws(AuthorError) in
      ids.append(try o.ingest(
        payload: Self.dib(message: "m1", at: "10:00:00", template: "dib.account.v1@3", merchant: "MB FUND TRANSFER DEBIT", last4: "0606"),
        ingestID: String(repeating: "a", count: 64)))
      ids.append(try o.ingest(
        payload: Self.dib(message: "m2", at: "10:04:00", template: "dib.transfer.v1@1", merchant: "SAMPLE PAYEE", last4: "0909"),
        ingestID: String(repeating: "b", count: 64)))
    }) { blobs.append(b) }
    alert = ids[0]
    notice = ids[1]
    return try await LiveUndoTests.store(a, suite: "combined.transfer.tests", extra: blobs)
  }

  @Test func keepingACombinedTransferApartCountsBothAndUndoCombinesThemAgain() async throws {
    let a = try Mapper.account()
    var alert = ""
    var notice = ""
    let store = try await Self.store(a, alert: &alert, notice: &notice)
    #expect(store.state.txn(alert) == nil)
    let row = try #require(store.state.txn(notice))
    #expect(row.combinedCopy == alert && row.merchant != "MB FUND TRANSFER DEBIT")

    let app = AppModel(store: store)
    app.sheet = .transaction(notice)
    let txn = TransactionViewModel(app: app, id: notice)
    #expect(txn.detail?.combined == true)
    txn.keepApart()
    #expect(app.toast?.title == "Kept both" && app.toast?.actionTitle == "Undo")
    #expect(txn.detail?.combined == false)
    try await Mapper.eventually { try a.projection.reader.txn(alert) != nil }
    #expect(try a.projection.reader.txn(alert)?.copyDecision == "keep_both")
    #expect(try a.projection.reader.transferCopy(of: notice) == nil)

    app.toastAction()
    try await Mapper.eventually { try a.projection.reader.txn(alert) == nil }
    #expect(try a.projection.reader.txn(alert) == nil)
    #expect(try a.projection.reader.transferCopy(of: notice)?.copyID == alert)
  }

  @Test func undoAfterTheRevivedRowWasSortedStillCombinesAndKeepsTheSort() async throws {
    let a = try Mapper.account()
    var alert = ""
    var notice = ""
    let store = try await Self.store(a, alert: &alert, notice: &notice)
    let app = AppModel(store: store)
    TransactionViewModel(app: app, id: notice).keepApart()
    try await Mapper.eventually { try a.projection.reader.txn(alert) != nil }
    let revived = try #require(try a.projection.reader.txn(alert))
    if let b = try a.observer.stamps.build(try await a.observer.authorContext(), { o throws(AuthorError) in
      o.categorize(txnID: alert, parentVersion: revived.version, category: "groceries", needsReview: false)
    }) {
      try await a.outbox.enqueue(b.ops)
    }
    try await a.observer.reproject()
    #expect(try a.projection.reader.txn(alert)?.version == revived.version + 1)

    app.toastAction()
    try await Mapper.eventually { try a.projection.reader.txn(alert) == nil }
    #expect(try a.projection.reader.transferCopy(of: notice)?.copyID == alert)
    #expect(try a.projection.reader.txn(notice)?.category == "groceries")
    #expect(try a.projection.reader.forkNotices(kind: "txn").filter { $0.entityID == alert }.isEmpty)
  }

  @Test func theSheetOffersNothingForARowThatWasNotCombined() {
    let app = AppModel(store: InMemoryLedger())
    let txn = TransactionViewModel(app: app, id: "carrefour")
    #expect(txn.detail?.combined == false)
    txn.keepApart()
    #expect(app.store.state.txn("carrefour")?.combinedCopy == nil)
  }
}
