import CoreGraphics
import HasalaMocks
import HasalaModels
import Observation
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

  /// A swipe or a pill asks which category; the bucket's list keeps its own order with the
  /// suggestion in its place, and so do the projects; the sheet's sort files it and VoiceOver
  /// hears where the deck stands.
  @Test func aPickKeepsTheSuggestionInPlaceAndAnnouncesTheFiling() {
    let app = AppModel(store: InMemoryLedger())
    ReviewEntry.request(app, at: "lulu")
    let deck = ReviewViewModel(app: app)
    deck.pick("lulu", .need)
    #expect(deck.picking?.choice == .need && deck.picking?.card.id == "lulu")
    #expect(deck.picking?.card.suggestion?.id == "groceries")
    let options = deck.options(for: .need, card: "lulu").map(\.id)
    #expect(options == ReviewEngine.options(for: .need, app.store.state).map(\.id))
    #expect(options.firstIndex(of: "groceries") == 2)
    #expect(deck.projects(for: "lulu").map(\.name) == ["Japan trip"])
    #expect(deck.projects(for: "lulu").map(\.suggested) == [false])
    app.perform(.saveProject("eid", ProjectDraft(name: "Eid", starts: LocalDate(2026, 10, 1), ends: LocalDate(2026, 10, 9))))
    #expect(deck.projects(for: "lulu").map(\.name) == ["Japan trip", "Eid"])
    #expect(deck.projects(for: "lulu").map(\.suggested) == [false, true])
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

  @Test func theBadgeIgnoresTheChosenPeriodAndTheDeckFollowsIt() {
    var state = MayaLedger.state
    state.txns.append(Txn(id: "sep-shop", merchant: "Corner Shop", amount: .aed(12_50),
                          postedAt: LocalDateTime(2026, 9, 20, 18, 0), accountID: "dib"))
    let app = AppModel(store: InMemoryLedger(state: state))
    #expect(app.reviewCount == 7)
    #expect(ReviewViewModel(app: app).total == 6)
    app.choose(.allTime)
    #expect(ReviewViewModel(app: app).cards.last?.id == "sep-shop")
    app.period = .month(YearMonth(2026, 9))
    #expect(app.reviewCount == 7)
    let deck = ReviewViewModel(app: app)
    #expect(deck.total == 1 && deck.cards.map(\.id) == ["sep-shop"])
    deck.sort("sep-shop", into: "groceries", alwaysUse: false, project: nil)
    #expect(deck.cards.isEmpty && app.reviewCount == 6)
    #expect(deck.sorted.map(\.merchant) == ["Corner Shop"])
    app.period = Period(YearMonth(2026, 8), YearMonth(2026, 10))
    #expect(app.reviewCount == 6)
    #expect(ReviewTabView.emptyLine == "New transactions Hasala can't sort on its own show up here.")
    #expect(ReviewTabView.orderLine(months: 1) == "Oldest first")
    #expect(ReviewTabView.orderLine(months: 2) == "Newest month first")
  }

  @Test func theReviewTabFollowsThePeriodAndNamesTheRest() {
    var state = MayaLedger.state
    state.txns.append(Txn(id: "sep-shop", merchant: "Corner Shop", amount: .aed(12_50),
                          postedAt: LocalDateTime(2026, 9, 20, 18, 0), accountID: "dib"))
    let app = AppModel(store: InMemoryLedger(state: state))
    #expect(app.reviewCards.count == 6)
    #expect(app.reviewElsewhere?.line == "1 more in an earlier month")
    app.period = .month(YearMonth(2026, 9))
    #expect(app.reviewCards.map(\.id) == ["sep-shop"])
    #expect(app.reviewElsewhere?.line == "6 more in later months")
    #expect(app.reviewCount == 7)
    app.period = .month(YearMonth(2026, 8))
    #expect(app.reviewCards.isEmpty)
    #expect(ReviewTabView.countLine(0, elsewhere: app.reviewElsewhere, period: app.period.title)
      == "Nothing to sort in August 2026")
    #expect(ReviewTabView.countLine(0) == "All caught up")
    app.period = app.reviewElsewhere!.widened
    #expect(app.period == Period(YearMonth(2026, 8), MayaLedger.october))
    #expect(app.reviewCards.count == 7 && app.reviewElsewhere == nil)
  }

  @Test func aDeckFromTheReviewTabKeepsItsPeriod() {
    var state = MayaLedger.state
    state.txns.append(Txn(id: "sep-shop", merchant: "Corner Shop", amount: .aed(12_50),
                          postedAt: LocalDateTime(2026, 9, 20, 18, 0), accountID: "dib"))
    let app = AppModel(store: InMemoryLedger(state: state))
    app.period = .month(YearMonth(2026, 9))
    ReviewEntry.open(app, at: nil)
    let deck = ReviewViewModel(app: app)
    #expect(deck.periodTitle == "September 2026" && !deck.isThisMonth)
    #expect(deck.total == 1 && deck.cards.map(\.id) == ["sep-shop"])
    #expect(deck.elsewhere?.line == "6 more in later months")
    deck.sort("sep-shop", into: "groceries", alwaysUse: false, project: nil)
    #expect(deck.cards.isEmpty && app.reviewCount == 6)
    deck.showElsewhere()
    #expect(app.period == Period(YearMonth(2026, 9), MayaLedger.october))
    #expect(deck.total == 6 && deck.position == 1 && deck.elsewhere == nil)
    #expect(deck.sorted.map(\.merchant) == ["Corner Shop"])
  }

  @Test func aDeckFromOutsideReviewFollowsTheAppsPeriod() {
    var state = MayaLedger.state
    state.txns.append(Txn(id: "sep-shop", merchant: "Corner Shop", amount: .aed(12_50),
                          postedAt: LocalDateTime(2026, 9, 20, 18, 0), accountID: "dib"))
    let app = AppModel(store: InMemoryLedger(state: state))
    app.period = .month(YearMonth(2026, 9))
    ActivityViewModel(app: app).startReview()
    #expect(app.cover == .review)
    let deck = ReviewViewModel(app: app)
    #expect(deck.periodTitle == "September 2026" && !deck.isThisMonth)
    #expect(deck.total == 1 && deck.cards.map(\.id) == ["sep-shop"])
    #expect(deck.elsewhere?.line == "6 more in later months")
    app.choose(.allTime)
    deck.periodChanged()
    #expect(deck.periodTitle == "All time" && deck.total == 7 && deck.total == app.reviewCount)
    #expect(deck.elsewhere == nil)
    app.cover = nil
    app.open(.review)
    #expect(app.cover == .review && ReviewViewModel(app: app).total == 7)
  }

  @Test func aNewPeriodKeepsTheCardInFrontAndOneOrderForTheSession() {
    var state = MayaLedger.state
    for (i, day) in [12, 20].enumerated() {
      state.txns.append(Txn(id: "sep-\(i)", merchant: "Corner Shop", amount: .aed(12_50 + Int64(i)),
                            postedAt: LocalDateTime(2026, 9, day, 18, 0), accountID: "dib"))
    }
    let app = AppModel(store: InMemoryLedger(state: state))
    ReviewEntry.open(app, at: "lulu")
    let deck = ReviewViewModel(app: app)
    #expect(deck.cards.first?.id == "lulu" && deck.total == 6)
    app.period = Period(YearMonth(2026, 9), MayaLedger.october)
    deck.periodChanged()
    let order = deck.cards.map(\.id)
    #expect(order.first == "lulu" && deck.total == 8 && order.count == 8)
    deck.skip(order[0])
    #expect(deck.cards.map(\.id) == Array(order.dropFirst()))
    deck.sort(order[1], into: "groceries", alwaysUse: false, project: nil)
    #expect(deck.cards.map(\.id) == Array(order.dropFirst(2)))
  }

  @Test func theBellOpensTheDeckAtAllTimeFromAPastMonth() throws {
    var state = MayaHistory.state
    for i in 0..<5 {
      state.txns.append(Txn(id: "jun-\(i)", merchant: "Corner Shop", amount: .aed(10_00 + Int64(i)),
                            postedAt: LocalDateTime(2026, 6, 3 + i, 18, 0), accountID: "dib"))
    }
    let app = AppModel(store: InMemoryLedger(state: state))
    app.period = .month(YearMonth(2026, 8))
    let bell = try #require(app.needsALook.first { $0.id == "review" })
    #expect(bell.title == "11 transactions to sort")
    #expect(app.reviewCount == 11)
    #expect(ReviewTabView.countLine(ReviewEngine.cards(app.store.state).count) == "11 to sort · about 2 minutes")
    let home = HomeViewModel(app: app)
    #expect(bell.destination == .review(.allTime))
    let after = home.openNotification(bell.destination)
    #expect(app.tab == .review)
    #expect(app.period.isAllTime && app.period.title == "All time")
    #expect(app.period == .allTime(since: app.earliestMonth, today: MayaLedger.october))
    after?()
    #expect(app.cover == .review)
    let deck = ReviewViewModel(app: app)
    #expect(deck.periodTitle == "All time" && !deck.isThisMonth && deck.elsewhere == nil)
    #expect(app.reviewCards.count == 11 && app.reviewElsewhere == nil)
    #expect(deck.total == 11 && deck.position == 1)
    #expect(deck.cards.prefix(6).map(\.id) == ["atm", "transfer-in", "apple", "lulu", "dubai-taxi", "steam"])
    #expect(deck.cards.suffix(5).map(\.id) == (0..<5).map { "jun-\($0)" })
    let months = ReviewEngine.months(deck.cards, now: app.store.now)
    #expect(months.map(\.title) == ["This month", "June"])
  }

  @Test func aPeriodChosenInActivityScopesHomeButNotTheBellOrItsDeck() throws {
    let app = AppModel(store: InMemoryLedger(state: Scenario.mayaRange.state))
    let activity = ActivityViewModel(app: app)
    #expect(activity.snapshot.isThisMonth && app.snapshot.isThisMonth)
    #expect(app.reviewCount == 9)
    activity.choosePeriod()
    #expect(app.sheet == .period)
    let range = Period(YearMonth(2026, 8), YearMonth(2026, 10))
    app.period = range
    app.sheet = nil
    #expect(activity.snapshot.period == range && !activity.snapshot.isThisMonth)
    #expect(activity.snapshot.days.contains { $0.date.yearMonth == YearMonth(2026, 8) })
    #expect(app.snapshot.period == range)
    #expect(app.reviewCount == 9)
    let review = try #require(app.snapshot.aboutNow.first { $0.id == "review" })
    #expect(review.detail.rendered(hidden: false) == "9 waiting")
    let deck = ReviewViewModel(app: app)
    #expect(Set(deck.cards.map(\.id)).isSuperset(of: ["aug-corner-shop", "sep-steam", "aug-talabat-copy"]))
    #expect(deck.cards.first { $0.id == "sep-steam" }?.senderUnverified == true)
    #expect(deck.cards.first { $0.id == "aug-talabat-copy" }?.reviewReason == .probableCopy)
    #expect(app.thisMonthSnapshot.isThisMonth)
    activity.backToThisMonth()
    #expect(app.period == .month(MayaLedger.october))
    #expect(activity.snapshot.isThisMonth && app.snapshot.isThisMonth && app.reviewCount == 9)
  }

  @Test func theReviewTabSaysHowLongItTakes() {
    #expect(ReviewTabView.countLine(6) == "6 to sort · about a minute")
    #expect(ReviewTabView.countLine(13) == "13 to sort · about 3 minutes")
    #expect(ReviewTabView.countLine(0) == "All caught up")
    #expect(ActivityContent.minutes(6) == "about 1 minute")
    #expect(ActivityContent.minutes(7) == "about 2 minutes")
  }

  @Test func theReviewTabCountsUnreadableMail() {
    #expect(ReviewTabView.unreadableLine(1) == "1 bank email we couldn't read")
    #expect(ReviewTabView.unreadableLine(3) == "3 bank emails we couldn't read")
    #expect(ReviewTabView.unreadableDetail == "Add it yourself from your bank app")
  }

  @Test func allCaughtUpCountsARuleTheStoreAddsLater() {
    let app = AppModel(store: LateRuleLedger())
    let deck = ReviewViewModel(app: app)
    let rules = app.store.state.rules.count
    #expect(deck.sort("lulu", into: "groceries", alwaysUse: true, project: nil))
    #expect(app.store.state.rules.count == rules)
    #expect(deck.sorted.first?.learnedRule == true)
    #expect(deck.sort("steam", into: "entertainment", alwaysUse: false, project: nil))
    #expect(deck.sorted.filter(\.learnedRule).count == 1)
  }

  @Test func theSheetMergesAProbableCopy() {
    let app = AppModel(store: InMemoryLedger(state: Scenario.mayaCopy.state))
    app.sheet = .transaction("starbucks-copy")
    app.router.transaction = [.reviewReason(.probableCopy)]
    let txn = TransactionViewModel(app: app, id: "starbucks-copy")
    #expect(txn.detail?.reviewReason == .probableCopy)
    txn.resolve(.probableCopy, merge: true)
    #expect(app.store.state.txn("starbucks-copy") == nil)
    #expect(app.sheet == nil)
    #expect(app.toast?.title == "Merged")
  }

  @Test func theSheetKeepsBothCopies() {
    let app = AppModel(store: InMemoryLedger(state: Scenario.mayaCopy.state))
    app.sheet = .transaction("starbucks-copy")
    app.router.transaction = [.reviewReason(.probableCopy)]
    let txn = TransactionViewModel(app: app, id: "starbucks-copy")
    txn.resolve(.probableCopy, merge: false)
    #expect(app.store.state.txn("starbucks-copy")?.isHeldCopy == false)
    #expect(app.router.transaction.isEmpty)
    #expect(app.sheet == .transaction("starbucks-copy"))
  }

  @Test func theSheetCountsASamePurchaseOnce() {
    let app = AppModel(store: InMemoryLedger(state: Scenario.mayaSamePurchase.state))
    app.sheet = .transaction("amazon-aed")
    let txn = TransactionViewModel(app: app, id: "amazon-aed")
    #expect(txn.detail?.reviewReason == .samePurchase)
    txn.resolve(.samePurchase, merge: true)
    #expect(app.store.state.txn("amazon-aed")?.archived == true)
    #expect(app.store.state.txn("amazon-usd")?.homeMinor == 93_00)
    #expect(app.sheet == nil)
  }

  @Test func activityFiltersAndSearches() {
    let app = AppModel(store: InMemoryLedger())
    let activity = ActivityViewModel(app: app)
    activity.select(.toReview)
    #expect(activity.snapshot.rowCount == 6)
    activity.select(.income)
    #expect(activity.snapshot.rowCount == 0)
    activity.select(.all)
    #expect(activity.snapshot.rowCount == 26)
    #expect(activity.snapshot.days.flatMap(\.rows).filter(\.toReview).count == 6)
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
    txn.choose("groceries", alwaysUse: true)
    #expect(txn.detail?.needsReview == false && txn.detail?.category?.id == "groceries")
    #expect(app.store.state.rules.count == rules + 1)
    #expect(app.reviewCount == 5)
  }

  /// Search: the transactions it finds (merchant matches first), the categories by
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
    let all = FlowLayout.rows(sizes, width: nil, spacing: 8)
    #expect(all.map(\.indices) == [[0, 1, 2]])
    let exact = 77.4 + 8 + 120.3
    #expect(FlowLayout.rows(sizes, width: exact - 0.3, spacing: 8).map(\.indices) == [[0, 1], [2]])
    #expect(FlowLayout.rows(sizes, width: 150, spacing: 8).map(\.indices) == [[0], [1], [2]])
    // A chip wider than the row takes a row of its own.
    #expect(FlowLayout.rows([CGSize(width: 400, height: 40)], width: 300, spacing: 8).count == 1)
  }
}

@MainActor
@Observable
private final class LateRuleLedger: LedgerStore {
  let inner = InMemoryLedger()
  var state: LedgerState { inner.state }
  var now: LocalDateTime { inner.now }
  var revision: Int { inner.revision }

  func apply(_ edit: LedgerEdit) throws(ActionError) -> UndoToken? {
    if case .categorize(let id, let category, true, let project) = edit {
      return try inner.apply(.categorize(id, category, learnRule: false, project: project))
    }
    return try inner.apply(edit)
  }

  func undo(_ token: UndoToken) { inner.undo(token) }
}
