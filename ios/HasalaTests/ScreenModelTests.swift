import HasalaMocks
import HasalaModels
import Testing

@testable import Hasala

/// The screen view models over the Maya ledger (spec 04 §15.1: the code under test is the
/// shipped view model, over the mock store).
@MainActor
@Suite("Screen view models")
struct ScreenModelTests {
  @Test func anEditShowsUndoAndUndoRevertsIt() throws {
    let app = AppModel(store: InMemoryLedger())
    #expect(app.perform(.categorize("lulu", "groceries", learnRule: false, project: nil)))
    let toast = try #require(app.toast)
    #expect(toast.title == "Sorted into Groceries")
    #expect(toast.actionTitle == "Undo")
    #expect(ReviewEngine.queue(app.store.state).count == 5)
    app.toastAction()
    #expect(ReviewEngine.queue(app.store.state).count == 6)
    #expect(app.toast == nil)
  }

  @Test func aRefusalSaysWhy() {
    let app = AppModel(store: InMemoryLedger())
    #expect(!app.perform(.moveMoney(from: nil, to: "dining", YearMonth(2026, 10), .aed(9_999_00))))
    #expect(app.toast?.title == "There isn't enough to move")
    #expect(app.toast?.undo == nil)
  }

  @Test func homeFollowsTheLedger() {
    let app = AppModel(store: InMemoryLedger())
    let home = HomeViewModel(app: app)
    #expect(home.snapshot == Maya.home)
    // Sorting a card updates the Needs-you poster.
    app.perform(.categorize("lulu", "groceries", learnRule: false, project: nil))
    guard case .count(let n, _) = home.snapshot.needsYou.cards[0].figure else {
      Issue.record("first card is not the review poster")
      return
    }
    #expect(n == 5)
    // "Later" puts the review card off; "Details" on a late bill opens Bills.
    #expect(home.needsYou("review", primary: false) == nil)
    #expect(!home.snapshot.needsYou.cards.contains { $0.id == "review" })
    #expect(home.needsYou("bill.axa", primary: false) == .bills)
    #expect(home.openWidget("nextBill") == .bills)
    #expect(home.openWidget("today") == nil)
    #expect(app.tab == .activity)
  }

  /// Gmail skipped at setup: Home's Needs you leads with "Connect Gmail" (spec 04 §6.6 row 4);
  /// "Connect" opens the connect sheet and "Later" puts it off.
  @Test func homeOffersConnectGmailWhenTheLaneSaysSo() throws {
    let mailbox = MockMailbox()
    let app = AppModel(store: InMemoryLedger(), mailbox: mailbox)
    let home = HomeViewModel(app: app)
    #expect(home.snapshot == Maya.home)
    mailbox.gmailOffer = .connect
    let rail = home.snapshot.needsYou
    let card = try #require(rail.cards.first)
    #expect(card.id == "gmail.connect" && card.title == "Connect Gmail" && card.primaryAction == "Connect")
    #expect(rail.count == Maya.home.needsYou.count + 1)
    #expect(rail.subtitle == Maya.home.needsYou.subtitle)
    #expect(home.needsYou(card.id, primary: true) == nil)
    #expect(app.sheet == .connectGmail(.connect))
    app.sheet = nil
    #expect(home.needsYou(card.id, primary: false) == nil)
    #expect(app.sheet == nil)
    #expect(!home.snapshot.needsYou.cards.contains { $0.id == "gmail.connect" })
    #expect(home.snapshot == Maya.home)  // the count and subtitle too

    mailbox.gmailOffer = .reconnect
    #expect(home.snapshot.needsYou.cards.first?.title == "Reconnect Gmail")
    mailbox.gmailOffer = nil
    #expect(home.snapshot == Maya.home)
  }

  @Test func theGmailCardSaysWhatNeedsDoingWhenItIsAlone() {
    let rail = GmailOffer.reconnect.adding(to: NeedsYouRail(count: 0, subtitle: "All caught up", cards: []))
    #expect(rail.count == 1 && rail.cards.map(\.id) == ["gmail.reconnect"])
    #expect(rail.subtitle == "Gmail needs reconnecting")
    #expect(GmailOffer(cardID: "gmail.connect") == .connect)
    #expect(GmailOffer(cardID: "review") == nil && GmailOffer(cardID: "gmail.other") == nil)
  }

  /// The Profile card says what Gmail needs before its status; Sign-in & security's row
  /// shows that page's own status.
  @Test func theProfileCardsSayWhatIsTrue() {
    #expect(ProfileSheet.title(.working, nil) == "Bank alerts are working")
    #expect(ProfileSheet.title(.working, .connect) == "Gmail isn't connected")
    #expect(ProfileSheet.title(.reconnect, nil) == "Gmail needs reconnecting")
    #expect(ProfileSheet.hue(.working, .reconnect) == .rose)
    let passkey = MockAccountService.securityState(for: .passkey)
    #expect(ProfileSheet.securityStatus(passkey).text == "Protected")
    #expect(ProfileSheet.securityStatus(passkey).tone == .success)
    var passwordOnly = passkey
    passwordOnly.passkeys = []
    #expect(ProfileSheet.securityStatus(passwordOnly).text == "Password only")
    #expect(ProfileSheet.securityStatus(passwordOnly).tone == .warning)
    passwordOnly.frozen = FreezeInfo(by: .operator, when: nil)
    #expect(ProfileSheet.securityStatus(passwordOnly).text == "Frozen")
  }

  @Test func startOpensTheReviewCover() {
    let app = AppModel(store: InMemoryLedger())
    _ = HomeViewModel(app: app).needsYou("review", primary: true)
    #expect(app.cover == .review)
  }

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

  @Test func moveMoneyOffersTheShortfall() {
    let app = AppModel(store: InMemoryLedger())
    let sheet = BudgetSheetViewModel(app: app, category: "groceries")
    #expect(sheet.shortfall == .aed(318_00))
    // Paper's Move money board, then the needs behind "Show all" (03a §6.13, §7.4):
    // Dining is over pace and Groceries is the destination, so neither is offered.
    let sources = sheet.sources(to: "groceries")
    #expect(sources.prefix(4).map(\.name) == ["Ready to assign", "Travel", "Shopping", "Entertainment"])
    #expect(sources.map { $0.detail.rendered(hidden: false) }.prefix(4)
      == ["1,000.00 not in a budget yet", "2,500.00 left · nothing spent yet", "1,168.20 left", "505.00 left"])
    #expect(sources.dropFirst(4).prefix(2).map(\.name) == ["Transport", "Healthcare"])
    #expect(!sources.contains { $0.id == "dining" || $0.id == "groceries" || $0.id == "rent" })
    #expect(sheet.move(.aed(318_00), from: nil, to: "groceries"))
    #expect(sheet.plan.readyToAssign == .aed(682_00))
  }

  @Test func assignNeverTakesFromTheDestination() {
    let app = AppModel(store: InMemoryLedger())
    let assign = BudgetSheetViewModel(app: app, category: nil)
    #expect(assign.sources(to: nil).contains { $0.id == "shopping" })
    #expect(!assign.sources(to: "shopping").contains { $0.id == "shopping" })
    #expect(!assign.move(.aed(100_00), from: "shopping", to: "shopping"))
    #expect(app.toast == nil)
    #expect(app.store.state.plan.budget("shopping", YearMonth(2026, 10)) == .aed(1_600_00))
  }

  @Test func snapshotsAreReusedUntilTheLedgerChanges() {
    let app = AppModel(store: InMemoryLedger())
    let plan = PlanViewModel(app: app)
    let before = plan.snapshot
    #expect(plan.snapshot == before)
    #expect(app.perform(.moveMoney(from: nil, to: "groceries", YearMonth(2026, 10), .aed(318_00))))
    #expect(plan.snapshot.readyToAssign == .aed(682_00))
    #expect(app.avatarInitial == app.snapshot.header.avatarInitial)
  }

  @Test func profileSettingsAndRules() {
    let app = AppModel(store: InMemoryLedger())
    let profile = ProfileViewModel(app: app)
    profile.setFaceIDLock(false)
    #expect(!profile.snapshot.prefs.faceIDLock)
    profile.setNotifications(.everything)
    #expect(profile.snapshot.prefs.notifications == .everything)
    #expect(profile.rules.first?.pattern == "\"carrefour\"")
    profile.setRule("r-zuma", enabled: false)
    #expect(profile.rules.first { $0.id == "r-zuma" }?.enabled == false)
    #expect(profile.exportRows.count == app.store.state.txns.count)
  }
}
