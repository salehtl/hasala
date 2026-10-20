import CoreDomain
import CoreJSON
import CoreProjection
import CoreReplay
import CoreTime
import Foundation
import HasalaMocks
import HasalaModels
import Testing

@testable import Hasala

@MainActor
@Suite("Live undo")
struct LiveUndoTests {
  typealias Mapper = LiveLedgerMapperTests

  static let october = CivilMonth(year: 2026, month: 10)!
  static let november = CivilMonth(year: 2026, month: 11)!

  static func store(_ a: Mapper.Account, suite: String, extra: [AuthoredBlob] = []) async throws -> LiveLedgerStore {
    for b in try await Mapper.seed(a) + extra { try await a.outbox.enqueue(b.ops) }
    try await a.observer.reproject()
    let store = LiveLedgerStore(
      reader: a.projection.reader, author: LedgerEditAuthor(observer: a.observer, outbox: a.outbox),
      profile: Mapper.context().profile, prefs: DevicePrefsStore(defaults: UserDefaults(suiteName: suite)!),
      clock: { MayaLedger.now })
    await store.reload()
    return store
  }

  static func assigned(_ a: Mapper.Account, _ c: String, _ m: CivilMonth) throws -> Int64 {
    try a.projection.reader.planEngine(month: october, today: CivilDate(year: 2026, month: 10, day: 10)!).assigned(m, c)
  }

  static func alert(grant: String, message: String, at: String, merchant: String = "TEST CAFE JLT", minor: String = "2700",
                    currency: String = "AED") -> JSONObject
  {
    JSONObject([
      ("amount_minor", .string(minor)), ("currency", .string(currency)), ("direction", .string("debit")),
      ("posted_at", .string("2026-10-03T\(at).000Z")), ("posted_precision", .string("time")),
      ("merchant_raw", .string(merchant)), ("last4", .string("4412")), ("needs_review", .bool(false)),
      ("category", .string("dining")), ("category_source", .object(JSONObject([("kind", .string("user"))]))),
      ("tier", .string("template")), ("entry_method", .string("mailbox")), ("bank", .string("enbd")),
      ("provenance", .object(JSONObject([
        ("provider", .string("gmail")), ("grant_id", .string(grant)), ("message_id", .string(message)),
      ]))),
    ])
  }

  @Test func undoingAMoveTakesTheMoneyBack() async throws {
    let a = try Mapper.account()
    let store = try await Self.store(a, suite: "undo.move.tests")
    var failed = false
    store.onWriteFailed = { failed = true }
    let before = try Self.assigned(a, "dining", Self.october)
    let token = try #require(try store.apply(.moveMoney(from: nil, to: "dining", MayaLedger.october, .aed(100_00))))
    #expect(store.canUndo(token))
    try await Mapper.eventually { try Self.assigned(a, "dining", Self.october) == before + 100_00 }
    #expect(try Self.assigned(a, "dining", Self.october) == before + 100_00)
    store.undo(token)
    try await Mapper.eventually { try Self.assigned(a, "dining", Self.october) == before }
    #expect(try Self.assigned(a, "dining", Self.october) == before)
    #expect(try a.projection.reader.planState().moves.values.contains { $0.undoes != nil })
    #expect(!failed)
  }

  @Test func undoingABudgetEditAfterAMoveLeavesLaterMonthsAlone() async throws {
    let a = try Mapper.account()
    let store = try await Self.store(a, suite: "undo.budget.tests")
    let october = try Self.assigned(a, "dining", Self.october)
    let november = try Self.assigned(a, "dining", Self.november)
    try store.apply(.moveMoney(from: nil, to: "dining", MayaLedger.october, .aed(300_00)))
    try await Mapper.eventually { try Self.assigned(a, "dining", Self.october) == october + 300_00 }
    let token = try #require(try store.apply(.setBudget("dining", MayaLedger.october, .aed(2_000_00))))
    #expect(store.canUndo(token))
    try await Mapper.eventually { try Self.assigned(a, "dining", Self.november) == 2_000_00 }
    #expect(try Self.assigned(a, "dining", Self.november) == 2_000_00)
    store.undo(token)
    try await Mapper.eventually { try Self.assigned(a, "dining", Self.november) == november }
    #expect(try Self.assigned(a, "dining", Self.november) == november)
    #expect(try Self.assigned(a, "dining", Self.october) == october + 300_00)
  }

  @Test func theBudgetInverseKeepsTheOnwardBaseAndTheMonthsMoves() {
    var plan = CoreReplay.PlanState()
    plan.cells["dining", default: [:]]["2026-09"] = PlanCell(latestSet: 1_600_00, onwardSet: 1_600_00)
    plan.cells["dining", default: [:]]["2026-10"] = PlanCell(movesAll: 300_00)
    #expect(
      LedgerEditAuthor.budgetInverse(plan, category: "dining", month: Self.october, shown: MayaLedger.october)
        == .budget(category: "dining", month: MayaLedger.october, onward: 1_600_00, assigned: 1_900_00))
    plan.cells["dining", default: [:]]["2026-10"] = PlanCell(
      latestSet: 1_200_00, onwardSet: nil, movesAll: 300_00, movesSinceSet: 100_00)
    #expect(
      LedgerEditAuthor.budgetInverse(plan, category: "dining", month: Self.october, shown: MayaLedger.october)
        == .budget(category: "dining", month: MayaLedger.october, onward: 1_600_00, assigned: 1_300_00))
  }

  @Test func undoingStopTrackingABillTracksItAgain() async throws {
    let a = try Mapper.account()
    let store = try await Self.store(a, suite: "undo.bill.tests")
    func status(_ id: String) throws -> String? { try a.projection.reader.bills().first { $0.id == id }?.bill.status }
    let bill = try #require(store.state.bills.first { !$0.isIncome && $0.state == .tracked })
    let token = try #require(try store.apply(.stopTrackingBill(bill.id)))
    #expect(store.canUndo(token))
    try await Mapper.eventually { try status(bill.id) == "cancelled" }
    #expect(try status(bill.id) == "cancelled")
    store.undo(token)
    try await Mapper.eventually { try status(bill.id) == "active" }
    #expect(try status(bill.id) == "active")
  }

  @Test func undoingAMergeHoldsTheCopyAgain() async throws {
    let a = try Mapper.account()
    var copy = ""
    var blobs: [AuthoredBlob] = []
    if let b = try a.observer.stamps.build(try await a.observer.authorContext(), { o throws(AuthorError) in
      try o.ingest(payload: Self.alert(grant: "u/mbx-a", message: "m1", at: "08:00:00"), ingestID: String(repeating: "c", count: 64))
      copy = try o.ingest(
        payload: Self.alert(grant: "u/mbx-b", message: "m2", at: "08:05:00"), ingestID: String(repeating: "d", count: 64))
    }) { blobs.append(b) }
    let store = try await Self.store(a, suite: "undo.merge.tests", extra: blobs)
    #expect(store.state.txn(copy)?.isHeldCopy == true)
    let app = AppModel(store: store)
    #expect(app.perform(.resolveCopy(copy, merge: true)))
    #expect(app.toast?.title == "Merged" && app.toast?.actionTitle == "Undo")
    try await Mapper.eventually { try a.projection.reader.txn(copy) == nil }
    #expect(try a.projection.reader.txn(copy) == nil)
    app.toastAction()
    try await Mapper.eventually { try a.projection.reader.txn(copy)?.heldCopy == true }
    #expect(try a.projection.reader.txn(copy)?.heldCopy == true)
  }

  @Test func undoingSamePurchaseKeepsTheRateEstimate() async throws {
    let a = try Mapper.account()
    var foreign = ""
    var home = ""
    var blobs: [AuthoredBlob] = []
    if let b = try a.observer.stamps.build(try await a.observer.authorContext(), { o throws(AuthorError) in
      foreign = try o.ingest(
        payload: Self.alert(grant: "u/mbx-a", message: "m3", at: "08:00:00", merchant: "AMAZON", minor: "2500", currency: "USD"),
        ingestID: String(repeating: "e", count: 64))
      home = try o.ingest(
        payload: Self.alert(grant: "u/mbx-a", message: "m4", at: "09:00:00", merchant: "AMAZON MKTPLACE", minor: "9300"),
        ingestID: String(repeating: "f", count: 64))
    }) { blobs.append(b) }
    let store = try await Self.store(a, suite: "undo.same.tests", extra: blobs)
    #expect(store.state.txn(home)?.samePurchase?.of == foreign)
    #expect(store.state.txn(foreign)?.isEstimate == true)
    let token = try #require(try store.apply(.resolveSamePurchase(home, same: true)))
    try await Mapper.eventually { try a.projection.reader.txn(foreign)?.homeSource == .stated }
    #expect(try a.projection.reader.txn(foreign)?.homeSource == .stated)
    store.undo(token)
    try await Mapper.eventually { try a.projection.reader.txn(foreign)?.homeSource == .rate }
    let row = try #require(try a.projection.reader.txn(foreign))
    #expect(row.homeSource == .rate && row.homeRateMicro == 3_672_500 && row.amountHomeMinor == 91_81)
    #expect(try a.projection.reader.txn(home)?.archived == nil)
  }

  @Test func aToastOffersUndoOnlyWhenTheEditCanBeTakenBack() async throws {
    let a = try Mapper.account()
    for b in try await Mapper.seed(a) { try await a.outbox.enqueue(b.ops) }
    try await a.observer.reproject()
    let store = LiveLedgerStore(
      reader: a.projection.reader, author: nil, profile: Mapper.context().profile,
      prefs: DevicePrefsStore(defaults: UserDefaults(suiteName: "undo.toast.tests")!), clock: { MayaLedger.now })
    await store.reload()
    let app = AppModel(store: store)
    let bill = try #require(store.state.bills.first { !$0.isIncome && $0.state == .tracked })
    #expect(app.perform(.stopTrackingBill(bill.id)))
    #expect(app.toast?.title == "Stopped tracking \(bill.name)")
    #expect(app.toast?.actionTitle == nil && app.toast?.undo == nil)
  }

  @Test func learningARuleDoesNotTakeOverAMerchantFiledElsewhere() async throws {
    let a = try Mapper.account()
    var taxi = ""
    var blobs: [AuthoredBlob] = []
    if let b = try a.observer.stamps.build(try await a.observer.authorContext(), { o throws(AuthorError) in
      var mall = Self.alert(grant: "u/mbx-a", message: "m5", at: "10:00:00", merchant: "QWERTY MALL")
      mall["category"] = .string("groceries")
      mall["category_source"] = .object(JSONObject([("kind", .string("dictionary")), ("bundle", .string("2026.10.11-1")),
                                                    ("entry", .string("contains:qwerty mall"))]))
      try o.ingest(payload: mall, ingestID: String(repeating: "1", count: 64))
      var cab = Self.alert(grant: "u/mbx-a", message: "m6", at: "11:00:00", merchant: "QWERTY TAXI")
      cab["category"] = .null
      cab["category_source"] = nil
      cab["needs_review"] = .bool(true)
      taxi = try o.ingest(payload: cab, ingestID: String(repeating: "2", count: 64))
    }) { blobs.append(b) }
    let store = try await Self.store(a, suite: "undo.rule.tests", extra: blobs)
    try store.apply(.categorize(taxi, "transport", learnRule: true, project: nil))
    try await Mapper.eventually { try a.projection.reader.rules().contains { $0.category == "transport" && $0.origin == "learned" } }
    let rule = try #require(try a.projection.reader.rules().first { $0.category == "transport" && $0.origin == "learned" })
    #expect(rule.match == "exact" && rule.patterns == ["qwerty taxi"])
  }
}
