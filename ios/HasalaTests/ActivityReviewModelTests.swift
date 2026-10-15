import HasalaMocks
import HasalaModels
import Testing

@testable import Hasala

/// Activity, the transaction sheet and the review session over the Maya ledger.
@MainActor
@Suite("Activity and review models")
struct ActivityReviewModelTests {
  @Test func aReviewSessionCountsAndTallies() {
    let app = AppModel(store: InMemoryLedger())
    let deck = ReviewViewModel(app: app)
    #expect(deck.total == 6)
    #expect(deck.position == 1)
    let first = deck.cards[0].id
    #expect(first == "atm")
    deck.sort(first, into: "transfer", alwaysUse: false, project: nil)
    #expect(deck.position == 2)
    deck.skip(deck.cards[0].id)
    deck.useSuggestion(deck.cards[0].id)
    deck.sort(deck.cards[0].id, into: "groceries", alwaysUse: true, project: nil)
    #expect(deck.sorted.map(\.merchant) == ["ADCB ATM withdrawal", "Apple.com", "Lulu Hypermarket"])
    #expect(deck.sorted.filter(\.learnedRule).count == 1)
    #expect(deck.sorted.reduce(0) { $0 + $1.counted } == 14_99 + 214_30)
    // Undo from the toast takes the last sort out of the tally.
    app.toastAction()
    #expect(deck.sorted.count == 2)
    deck.close(goToActivity: true)
    #expect(app.cover == nil && app.tab == .activity)
  }

  @Test func activityFiltersAndSearches() {
    let app = AppModel(store: InMemoryLedger())
    let activity = ActivityViewModel(app: app)
    activity.select(.toReview)
    #expect(activity.snapshot.rowCount == 6)
    activity.select(.all)
    activity.search("talabat")
    #expect(activity.snapshot.rowCount == 2)
    #expect(activity.exportRows.count == 2)
    activity.open("talabat")
    #expect(app.sheet == .transaction("talabat"))
  }

  @Test func theTransactionSheetEdits() throws {
    let app = AppModel(store: InMemoryLedger())
    let txn = TransactionViewModel(app: app, id: "carrefour")
    txn.setNote("Weekly shop")
    #expect(txn.detail?.note == "Weekly shop")
    #expect(!txn.saveSplit([SplitLine(id: 1, categoryID: "groceries", amount: .aed(1_00))]))
    #expect(txn.saveSplit([SplitLine(id: 1, categoryID: "groceries", amount: .aed(297_00)),
                           SplitLine(id: 2, categoryID: "shopping", amount: .aed(45_15))]))
    #expect(txn.detail?.splits.count == 2)
    txn.setArchived(true)
    #expect(txn.detail?.archived == true)
  }
}
