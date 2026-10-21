import CoreDomain
import CoreJSON
import CorePrimitives
import CoreProjection
import CoreReplay
import CoreWire
import Foundation
import HasalaMocks
import HasalaModels
import Testing

@testable import Hasala

@MainActor
@Suite("Same purchase in the app")
struct SamePurchaseFlowTests {
  static func payload(_ minor: String, _ currency: String, _ at: String, _ merchant: String) -> JSONObject {
    JSONObject([
      ("amount_minor", .string(minor)), ("currency", .string(currency)), ("direction", .string("debit")),
      ("posted_at", .string(at)), ("posted_precision", .string("time")), ("merchant_raw", .string(merchant)),
      ("last4", .string("4412")), ("needs_review", .bool(false)), ("category", .string("shopping")),
      ("category_source", .object(JSONObject([("kind", .string("user"))]))), ("tier", .string("template")),
      ("entry_method", .string("mailbox")), ("bank", .string("enbd")),
    ])
  }

  static func reader() throws -> (LedgerReader, foreign: String, home: String) {
    var a = OpAuthor(AuthorContext(writerID: "ios-w", nowMs: 1_791_625_200_000, ownLastMs: nil, maxAuthored: [:], random: SystemRandom()))
    a.setHomeCurrency("AED")
    try a.setRate(currency: "USD", rateMicro: 3_672_500)
    let f = try a.ingest(payload: payload("2500", "USD", "2026-10-07T16:15:00.000Z", "AMAZON"), ingestID: String(repeating: "a", count: 64))
    let h = try a.ingest(
      payload: payload("9300", "AED", "2026-10-09T04:00:00.000Z", "AMAZON MKTPLACE"), ingestID: String(repeating: "b", count: 64))
    var s = State()
    try Replay.foldOps(try a.build().ops, seq: 1, writerID: "ios-w", into: &s)
    let db = try Projector.open(path: nil)
    try Projector.project(s, dictionary: AccountRuntime.dictionary, projectedAtMs: 0, into: db)
    return (LedgerReader(db), f, h)
  }

  @Test func theMapperAsksOnTheAEDPostingOnly() throws {
    let (r, f, h) = try Self.reader()
    let rows = try r.activity(limit: 100)
    var txns = try rows.map { try LedgerStateMapper.txn($0, r: r, ruleByID: [:], billID: nil) }
    LedgerStateMapper.markSamePurchases(&txns, rows: rows, home: "AED")
    #expect(txns.first { $0.id == h }?.samePurchase == SamePurchaseMatch(of: f))
    #expect(txns.first { $0.id == f }?.samePurchase == nil)
    #expect(txns.first { $0.id == h }?.activeReviewReason == .samePurchase)
    #expect(txns.first { $0.id == f }?.homeMinor == 9_181)
  }

  @Test func theOptimisticPatchCountsOnceOrKeepsBoth() throws {
    var s = Scenario.mayaSamePurchase.state
    let (title, inverses) = try LiveLedgerStore.patch(.resolveSamePurchase("amazon-aed", same: true), &s, now: MayaLedger.now)
    #expect(title == "Counted once")
    #expect(inverses == [.samePurchase(foreign: "amazon-usd", previousHome: 91_81, previousRateMicro: nil, home: "amazon-aed", previousNote: "")])
    #expect(s.txn("amazon-usd")?.homeMinor == 93_00 && s.txn("amazon-usd")?.amount == Money(minor: 25_00, currency: "USD"))
    #expect(s.txn("amazon-aed")?.archived == true && s.txn("amazon-aed")?.note == "Settled the USD 25.00 purchase")
    #expect(s.txn("amazon-aed")?.samePurchase == nil)

    var k = Scenario.mayaSamePurchase.state
    let (kept, back) = try LiveLedgerStore.patch(.resolveSamePurchase("amazon-aed", same: false), &k, now: MayaLedger.now)
    #expect(kept == "Kept both" && back == [.samePurchaseDeclined(home: "amazon-aed")])
    #expect(k.txn("amazon-aed")?.archived == false && k.txn("amazon-aed")?.samePurchase == nil)
    #expect(k.txn("amazon-usd")?.homeMinor == 91_81)

    var n = Scenario.mayaSamePurchase.state
    #expect(throws: ActionError.notFound) {
      try LiveLedgerStore.patch(.resolveSamePurchase("amazon-usd", same: true), &n, now: MayaLedger.now)
    }
  }

  @Test func theNoteMatchesTheCore() {
    #expect(SamePurchaseText.note(Money(minor: 25_00, currency: "USD")) == SamePurchase.note(foreignMinor: 25_00, currency: "USD"))
  }

  @Test func theDeckAsksThenCountsOnceAndUndoBringsItBack() throws {
    let store = InMemoryLedger(state: Scenario.mayaSamePurchase.state)
    let app = AppModel(store: store)
    let deck = ReviewViewModel(app: app)
    let card = try #require(deck.cards.first { $0.id == "amazon-aed" })
    #expect(card.reviewReason == .samePurchase && card.samePurchase)
    #expect(card.copyLine == "Same purchase as USD 25.00 (about AED 91.81) at Amazon on Wed 7 Oct?")
    let token = try #require(try store.apply(.resolveSamePurchase("amazon-aed", same: true)))
    #expect(store.state.txn("amazon-aed")?.archived == true && store.state.txn("amazon-usd")?.homeMinor == 93_00)
    #expect(!deck.cards.contains { $0.id == "amazon-aed" })
    store.undo(token)
    #expect(store.state.txn("amazon-aed")?.archived == false && store.state.txn("amazon-usd")?.homeMinor == 91_81)
    #expect(store.state.txn("amazon-aed")?.samePurchase != nil)
  }

  @Test func sortingTheCardKeepsBoth() throws {
    let app = AppModel(store: InMemoryLedger(state: Scenario.mayaSamePurchase.state))
    let deck = ReviewViewModel(app: app)
    #expect(deck.sort("amazon-aed", into: "shopping", alwaysUse: false, project: nil))
    #expect(app.store.state.txn("amazon-aed")?.samePurchase == nil && app.store.state.txn("amazon-aed")?.archived == false)
    #expect(app.store.state.txn("amazon-usd")?.homeMinor == 91_81)
  }
}
