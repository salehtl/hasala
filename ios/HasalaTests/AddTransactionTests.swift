import CoreJSON
import CoreTime
import CoreWire
import Foundation
import HasalaDesign
import HasalaMocks
import HasalaModels
import Testing

@testable import Hasala

@MainActor
@Suite("Add transaction")
struct AddTransactionTests {
  private func type(_ keys: [AmountKey], into model: AddTransactionModel) {
    for k in keys { model.entry.type(k) }
  }

  @Test func theKeypadEntersFils() {
    let model = AddTransactionModel(app: AppModel(store: InMemoryLedger()))
    #expect(model.saveTitle == "Enter an amount")
    type([.digit(4), .digit(8), .decimal, .digit(5)], into: model)
    #expect(model.entry.minor == 48_50)
    #expect(model.saveTitle == "Add AED 48.50")
    type([.digit(0), .digit(9)], into: model)
    #expect(model.entry.minor == 48_50)
    type([.delete, .delete, .delete], into: model)
    #expect(model.entry.minor == 48_00)
  }

  @Test func saveWaitsForAnAmountAMerchantAndACategory() {
    let model = AddTransactionModel(app: AppModel(store: InMemoryLedger()))
    #expect(!model.canSave)
    type([.digit(2), .digit(5)], into: model)
    #expect(model.missing == "Add who it was with")
    model.merchant = "   "
    #expect(!model.canSave)
    model.merchant = "Corner Bakery"
    #expect(model.missing == "Choose a category")
    #expect(!model.canSave)
    model.categoryID = "dining"
    #expect(model.missing == nil)
    #expect(model.canSave)
    model.entry = AmountEntry(typing: "0.00")
    #expect(!model.canSave)
  }

  @Test func aNameOverEightyCharactersSaysWhy() {
    let model = AddTransactionModel(app: AppModel(store: InMemoryLedger()))
    type([.digit(2), .digit(5)], into: model)
    model.categoryID = "dining"
    model.merchant = String(repeating: "a", count: 81)
    #expect(!model.canSave)
    #expect(model.missing == "Keep the name to 80 characters")
    model.merchant = String(repeating: "a", count: 80)
    #expect(model.missing == nil)
    #expect(model.canSave)
  }

  @Test func savingAddsTheRowAndClosesTheSheet() throws {
    let store = InMemoryLedger()
    let app = AppModel(store: store)
    app.router.open(.addTransaction)
    let model = AddTransactionModel(app: app)
    #expect(model.accountID == "enbd")
    let before = store.state.txns.count
    type([.digit(3), .digit(2), .decimal, .digit(7), .digit(5)], into: model)
    model.merchant = "  Corner Bakery "
    model.categoryID = "dining"
    model.accountID = "cash"
    model.postedAt = AddTransactionDates.date(LocalDateTime(2026, 10, 9, 8, 15))
    #expect(model.save())
    #expect(store.state.txns.count == before + 1)
    let t = try #require(store.state.txns.last)
    #expect(t.merchant == "Corner Bakery")
    #expect(t.amount == .aed(32_75))
    #expect(t.direction == .out)
    #expect(t.categoryID == "dining")
    #expect(t.accountID == "cash")
    #expect(t.postedAt == LocalDateTime(2026, 10, 9, 8, 15))
    #expect(!t.needsReview)
    #expect(app.sheet == nil)
    #expect(app.toast?.title == "Added Corner Bakery")
  }

  @Test func aDateAfterNowIsHeldToNow() throws {
    let store = InMemoryLedger()
    let model = AddTransactionModel(app: AppModel(store: store))
    model.entry = AmountEntry(typing: "10")
    model.merchant = "Cafe"
    model.categoryID = "dining"
    model.postedAt = AddTransactionDates.date(LocalDateTime(2026, 12, 1, 9, 0))
    #expect(model.draft?.postedAt == MayaLedger.now)
  }

  @Test func theDatesRoundTripAtPlusFour() {
    let t = LocalDateTime(2026, 10, 10, 0, 5)
    #expect(AddTransactionDates.local(AddTransactionDates.date(t)) == t)
    #expect(AddTransactionDates.date(t).timeIntervalSince1970 == 1_791_576_300)
  }

  @Test func theDraftRefusesWhatCannotBeAuthored() {
    let at = MayaLedger.now
    #expect(ManualEntryDraft(amount: .aed(0), merchant: "Cafe", categoryID: nil, postedAt: at).refusal == .invalidAmount)
    #expect(ManualEntryDraft(amount: .aed(-5), merchant: "Cafe", categoryID: nil, postedAt: at).refusal == .invalidAmount)
    #expect(ManualEntryDraft(amount: .aed(1), merchant: " ", categoryID: nil, postedAt: at).refusal == .invalidMerchant)
    #expect(
      ManualEntryDraft(amount: .aed(1), merchant: String(repeating: "a", count: 81), categoryID: nil, postedAt: at).refusal
        == .invalidMerchant)
    #expect(ManualEntryDraft(amount: .aed(1), merchant: "Cafe", categoryID: nil, postedAt: at).refusal == nil)
    let store = InMemoryLedger()
    #expect(throws: ActionError.notFound) {
      try store.apply(.addTransaction(ManualEntryDraft(amount: .aed(1), merchant: "Cafe", categoryID: "nope", postedAt: at)))
    }
    #expect(throws: ActionError.notFound) {
      try store.apply(
        .addTransaction(ManualEntryDraft(amount: .aed(1), merchant: "Cafe", categoryID: "dining", postedAt: at, accountID: "nope")))
    }
  }

  @Test func theLocalWallTimeIsTheChosenTimeAsIfUTC() throws {
    #expect(try LedgerEditAuthor.localWallMs(LocalDateTime(1970, 1, 2, 4, 30)) == 86_400_000 + 270 * 60_000)
    #expect(throws: LedgerEditAuthor.Failure.self) { try LedgerEditAuthor.localWallMs(LocalDateTime(2026, 2, 30, 9, 0)) }
  }

  @Test func theLiveStoreAuthorsAManualTxnIngested() async throws {
    let a = try LiveLedgerMapperTests.account()
    for b in try await LiveLedgerMapperTests.seed(a) { try await a.outbox.enqueue(b.ops) }
    try await a.observer.reproject()
    let store = LiveLedgerStore(
      reader: a.projection.reader, author: LedgerEditAuthor(observer: a.observer, outbox: a.outbox),
      profile: LiveLedgerMapperTests.context().profile,
      prefs: DevicePrefsStore(defaults: UserDefaults(suiteName: "addtxn.tests")!), clock: { MayaLedger.now })
    await store.reload()
    let account = try #require(store.state.accounts.first)
    let pending = try a.context.store.pendingCount()
    let before = store.state.txns.count
    let draft = ManualEntryDraft(
      amount: .aed(32_75), merchant: " Corner Bakery ", categoryID: "dining", postedAt: LocalDateTime(2026, 10, 9, 8, 15),
      accountID: account.id)
    #expect(try store.apply(.addTransaction(draft)) == nil)
    #expect(store.state.txns.count == before + 1)
    #expect(store.state.txns.contains { $0.merchant == "Corner Bakery" && $0.amount == .aed(32_75) })

    try await LiveLedgerMapperTests.eventually { try a.context.store.pendingCount() == pending + 2 }
    let ops = try a.context.store.pendingOps().suffix(2)
    #expect(ops.map(\.opType) == ["txn_ingested", "txn_annotated"])
    let ingested = try #require(ops.first)
    let json = try #require(try JSONParser.parse(ingested.opJSON).objectValue)
    let payload = try #require(json["payload"]?.objectValue)
    #expect(payload["entry_method"] == .string("manual"))
    #expect(payload["amount_minor"] == .string("3275"))
    #expect(payload["currency"] == .string("AED"))
    #expect(payload["direction"] == .string("debit"))
    #expect(payload["merchant_raw"] == .string("Corner Bakery"))
    #expect(payload["category"] == .string("dining"))
    #expect(payload["needs_review"] == .bool(false))
    #expect(payload["posted_at"] == .string("2026-10-09T04:15:00.000Z"))
    #expect(json["ingest_id"]?.stringValue?.count == 64)

    let id = try #require(ingested.entityID)
    try await LiveLedgerMapperTests.eventually { try a.projection.reader.txn(id)?.effectiveAccountID == account.id }
    let row = try #require(try a.projection.reader.txn(id))
    #expect(row.entryMethod == "manual")
    #expect(row.amountMinor == 32_75)
    #expect(row.category == "dining")
    #expect(!row.needsReview)
    #expect(row.effectiveAccountID == account.id)
    try await LiveLedgerMapperTests.eventually { store.state.txn(id) != nil }
    #expect(store.state.txn(id)?.merchant == "Corner Bakery")
    #expect(!store.state.txns.contains { $0.id.hasPrefix("pending-manual-") })
  }
}
