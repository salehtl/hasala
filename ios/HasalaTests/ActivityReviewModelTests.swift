import CoreGraphics
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

  /// A To sort row opens the deck at its own card, then reads on down the list; Start opens
  /// it at the oldest.
  @Test func aRowStartsTheSessionAtItsCard() {
    let app = AppModel(store: InMemoryLedger())
    ReviewEntry.open(app, at: "lulu")
    #expect(app.cover == .review)
    let deck = ReviewViewModel(app: app)
    #expect(deck.cards.map(\.id) == ["lulu", "dubai-taxi", "steam", "atm", "transfer-in", "apple"])
    #expect(deck.position == 1 && deck.total == 6)
    // The request is used once: the next session starts at the oldest again.
    #expect(ReviewViewModel(app: app).cards.first?.id == "atm")
    // A request for another account's model is not taken by this one.
    let other = AppModel(store: InMemoryLedger())
    ReviewEntry.request(other, at: "steam")
    #expect(ReviewViewModel(app: app).cards.first?.id == "atm")
  }

  /// A swipe or a pill asks which category; the bucket's list leads with the suggestion; the
  /// sheet's sort files it and VoiceOver hears where the deck stands.
  @Test func aPickLeadsWithTheSuggestionAndAnnouncesTheFiling() {
    let app = AppModel(store: InMemoryLedger())
    ReviewEntry.request(app, at: "lulu")
    let deck = ReviewViewModel(app: app)
    deck.pick("lulu", .need)
    #expect(deck.picking?.choice == .need && deck.picking?.card.id == "lulu")
    #expect(deck.options(for: .need, card: "lulu").first?.id == "groceries")
    #expect(deck.projects.map(\.name) == ["Japan trip"])
    deck.picking = nil
    #expect(deck.sort("lulu", into: "groceries", alwaysUse: true, project: nil))
    #expect(deck.filedAnnouncement("Need") == "Filed as Need. 2 of 6.")
    #expect(deck.sorted.first?.learnedRule == true)
    #expect(app.toast?.title == "Sorted into Groceries" && app.toast?.actionTitle == "Undo")
    // A card without a guess has nothing to use.
    #expect(!deck.useSuggestion("transfer-in"))
  }

  /// The last card filed: the announcement says so, and All caught up counts the session.
  @Test func theLastFilingIsAllCaughtUp() {
    let app = AppModel(store: InMemoryLedger())
    let deck = ReviewViewModel(app: app)
    for card in deck.cards.map(\.id) {
      if !deck.useSuggestion(card) { deck.sort(card, into: "salary", alwaysUse: false, project: nil) }
    }
    #expect(deck.cards.isEmpty)
    #expect(deck.filedAnnouncement("Income") == "Filed as Income. All caught up.")
    #expect(ReviewDoneView.tally(sorted: deck.sorted.count, rules: 0) == "6 sorted")
    #expect(ReviewDoneView.tally(sorted: 6, rules: 3) == "6 sorted · 3 new rules")
    #expect(ReviewDoneView.tally(sorted: 1, rules: 1) == "1 sorted · 1 new rule")
    #expect(app.reviewCount == 0)
  }

  /// The Review tab's line under the title, about ten seconds a card.
  @Test func theReviewTabSaysHowLongItTakes() {
    #expect(ReviewTabView.countLine(6) == "6 to sort · about a minute")
    #expect(ReviewTabView.countLine(13) == "13 to sort · about 3 minutes")
    #expect(ReviewTabView.countLine(0) == "All caught up")
    #expect(ActivityContent.minutes(6) == "about 1 minute")
    #expect(ActivityContent.minutes(7) == "about 2 minutes")
  }

  @Test func activityFiltersAndSearches() {
    let app = AppModel(store: InMemoryLedger())
    let activity = ActivityViewModel(app: app)
    activity.select(.toReview)
    #expect(activity.snapshot.rowCount == 6)
    activity.select(.income)
    #expect(activity.snapshot.rowCount == 0)
    activity.select(.all)
    activity.search("talabat")
    #expect(activity.snapshot.rowCount == 2)
    #expect(activity.exportRows.count == 2)
    activity.open("talabat")
    #expect(app.sheet == .transaction("talabat"))
  }

  /// A category filter: the summary and its rows in one card, exported as shown; clearing it
  /// goes back to the overview.
  @Test func aCategoryFilterListsItsRowsAndClears() {
    let app = AppModel(store: InMemoryLedger())
    let activity = ActivityViewModel(app: app)
    activity.show(category: "dining")
    #expect(activity.snapshot.summary?.title == "Dining")
    #expect(activity.snapshot.rows.count == 5)
    #expect(activity.exportRows.count == 5)
    activity.show(category: nil)
    #expect(activity.snapshot.summary == nil && activity.snapshot.review != nil)
  }

  /// Coming up pushes the bill inside the tab; "Start review" opens the deck.
  @Test func activityOpensBillsAndTheDeck() {
    let app = AppModel(store: InMemoryLedger())
    let activity = ActivityViewModel(app: app)
    activity.openBill("dewa")
    #expect(app.router.activity == [.bill("dewa")])
    activity.startReview()
    #expect(app.cover == .review)
  }

  /// Search's "Open in Activity" switches to Activity at its root and leaves the filter for
  /// that account's Activity screen, once.
  @Test func aRequestFromSearchOpensActivityFiltered() {
    let app = AppModel(store: InMemoryLedger())
    app.router.activity = [.bill("dewa")]
    ActivityRequests.shared.show(TxnFilter(category: "dining"), in: app)
    #expect(app.tab == .activity && app.router.activity.isEmpty)
    #expect(ActivityRequests.shared.take(for: AppModel(store: InMemoryLedger())) == nil)
    #expect(ActivityRequests.shared.take(for: app) == TxnFilter(category: "dining"))
    #expect(ActivityRequests.shared.take(for: app) == nil)
  }

  @Test func theTransactionSheetEdits() throws {
    let app = AppModel(store: InMemoryLedger())
    let txn = TransactionViewModel(app: app, id: "carrefour")
    #expect(txn.detail?.sortedByRule == true)
    txn.setNote("Weekly shop")
    #expect(txn.detail?.note == "Weekly shop")
    #expect(!txn.saveSplit([SplitLine(id: 1, categoryID: "groceries", amount: .aed(1_00))]))
    #expect(txn.saveSplit([SplitLine(id: 1, categoryID: "groceries", amount: .aed(297_00)),
                           SplitLine(id: 2, categoryID: "shopping", amount: .aed(45_15))]))
    #expect(txn.detail?.splits.count == 2)
    txn.removeSplit()
    #expect(txn.detail?.splits.isEmpty == true)
    txn.toggleRefund()
    #expect(txn.detail?.isRefund == true)
    txn.setArchived(true)
    #expect(txn.detail?.archived == true)
  }

  /// Choose a category on a row still in review: it carries the suggestion, and Save with
  /// the rule on sorts it and teaches the rule.
  @Test func choosingACategoryTeachesARule() {
    let app = AppModel(store: InMemoryLedger())
    let txn = TransactionViewModel(app: app, id: "lulu")
    #expect(txn.detail?.needsReview == true && txn.detail?.suggestion?.id == "groceries")
    #expect(txn.merchantName == "Lulu Hypermarket")
    #expect(txn.categoryGroups.map(\.bucket) == [.needs, .wants, .savings, .other])
    let rules = app.store.state.rules.count
    txn.choose("groceries", alwaysUse: true, project: nil)
    #expect(txn.detail?.needsReview == false && txn.detail?.category?.id == "groceries")
    #expect(app.store.state.rules.count == rules + 1)
    #expect(app.reviewCount == 5)
  }

  /// The Debug Search: the transactions it finds (merchant matches first), the categories by
  /// name, and the rules whose words hold the query.
  @Test func searchFindsTransactionsCategoriesAndRules() {
    let s = MayaLedger.state
    let now = InMemoryLedger().now
    let carre = SearchResults("carre", s, now: now)
    #expect(carre.rows.count == 3)
    #expect(carre.top?.merchant == "Carrefour" && carre.top?.detail == "Groceries · Fri 9 Oct")
    #expect(carre.rules.map(\.pattern) == ["carrefour"] && carre.rules.first?.matches == 3)
    #expect(carre.categories.isEmpty)
    #expect(SearchResults("din", s, now: now).categories.map(\.id) == ["dining"])
    #expect(SearchResults("zzzz", s, now: now).isEmpty)
  }

  /// Chips wrap at the width offered, with half a point for the pixel grid, so a row that
  /// fits exactly never wraps when it is placed.
  @Test func chipsWrapOnlyWhenTheyDoNotFit() {
    let sizes = [CGSize(width: 77.4, height: 40), CGSize(width: 120.3, height: 40), CGSize(width: 90, height: 40)]
    let all = ChipFlow.rows(sizes, width: nil, spacing: 8)
    #expect(all.map(\.indices) == [[0, 1, 2]])
    let exact = 77.4 + 8 + 120.3
    #expect(ChipFlow.rows(sizes, width: exact - 0.3, spacing: 8).map(\.indices) == [[0, 1], [2]])
    #expect(ChipFlow.rows(sizes, width: 150, spacing: 8).map(\.indices) == [[0], [1], [2]])
    // A chip wider than the row takes a row of its own.
    #expect(ChipFlow.rows([CGSize(width: 400, height: 40)], width: 300, spacing: 8).count == 1)
  }
}
