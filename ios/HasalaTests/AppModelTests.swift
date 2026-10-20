import HasalaDesign
import HasalaMocks
import HasalaModels
import Testing

@testable import Hasala

@MainActor
@Suite("App shell")
struct AppModelTests {
  @Test func hidingAmountsShowsTheToastAndShowingClearsIt() {
    let app = AppModel(store: InMemoryLedger())
    #expect(!app.amountsHidden)
    app.toggleAmountsHidden()
    #expect(app.amountsHidden)
    #expect(app.toast?.title == "Amounts hidden")
    app.toastAction()
    #expect(!app.amountsHidden)
    #expect(app.toast == nil)
  }

  @Test func theReviewBadgeFollowsHomesPeriod() {
    var state = MayaLedger.state
    state.txns.append(Txn(id: "sep-shop", merchant: "Corner Shop", amount: .aed(12_50),
                          postedAt: LocalDateTime(2026, 9, 20, 18, 0), accountID: "dib"))
    let app = AppModel(store: InMemoryLedger(state: state))
    #expect(app.period == .month(MayaLedger.october))
    #expect(app.reviewCount == 6)
    app.period = .month(YearMonth(2026, 9))
    #expect(app.reviewWindow == ReviewWindow(from: LocalDate(2026, 9, 1), to: LocalDate(2026, 9, 30)))
    #expect(app.reviewCount == 1)
    app.period = Period(YearMonth(2026, 8), YearMonth(2026, 10))
    #expect(app.reviewWindow == ReviewWindow(from: LocalDate(2026, 8, 1), to: LocalDate(2026, 10, 31)))
    #expect(app.reviewCount == 7)
    app.period = .month(YearMonth(2026, 12))
    #expect(app.period == .month(MayaLedger.october))
    #expect(app.reviewCount == 6)
    #expect(AppModel(store: InMemoryLedger(state: state)).period == .month(MayaLedger.october))
  }

  @Test func homesToReviewRowCountsTheReviewTabsQueue() {
    var state = MayaLedger.state
    for i in 0..<3 {
      state.txns.append(Txn(id: "oct-\(i)", merchant: "Corner Shop", amount: .aed(12_50),
                            postedAt: LocalDateTime(2026, 10, 3 + i, 18, 0), accountID: "dib"))
    }
    let app = AppModel(store: InMemoryLedger(state: state))
    func homeWaiting() -> Int {
      guard let row = app.snapshot.aboutNow.first(where: { $0.destination == .review }) else { return 0 }
      return Int(row.detail.rendered(hidden: false).prefix { $0.isNumber }) ?? -1
    }
    app.period = .month(YearMonth(2026, 9))
    #expect(app.reviewCount == 0)
    #expect(homeWaiting() == app.reviewCount)
    app.period = Period(YearMonth(2026, 9), MayaLedger.october)
    #expect(app.reviewCount == 9)
    #expect(homeWaiting() == app.reviewCount)
  }

  @Test func theEarliestMonthIsReadOncePerLedgerChange() throws {
    let store = InMemoryLedger(state: MayaHistory.state)
    let app = AppModel(store: store)
    #expect(app.earliestMonth == YearMonth(2026, 4))
    try store.apply(.archive("h-rent-4", true))
    #expect(app.earliestMonth == YearMonth(2026, 4))
    let empty = AppModel(store: InMemoryLedger(state: MayaHistory.firstDays, now: MayaHistory.firstDaysNow))
    #expect(empty.earliestMonth == MayaLedger.october)
  }

  @Test func theHiddenScenarioStartsHidden() {
    #expect(Scenario.mayaHidden.startsWithAmountsHidden)
    #expect(!Scenario.maya.startsWithAmountsHidden)
  }

  /// The wash stays at the top of the screen while the content is at rest, pulled down, or
  /// held down by a refresh, and scrolls away with the content (Paper: absolute, 420 tall).
  @Test func theWashMovesOnlyUpWithTheContent() {
    let inset = 116.0
    #expect(WashPin.offset(contentOffset: -inset, insetTop: inset) == 0)  // at rest
    #expect(WashPin.offset(contentOffset: -inset - 140, insetTop: inset) == 0)  // pulled
    // The spinner's hold: the inset grows by the spinner and the content is held below it.
    #expect(WashPin.offset(contentOffset: -inset - 60, insetTop: inset + 60) == 0)
    #expect(WashPin.offset(contentOffset: -inset + 120, insetTop: inset) == -120)  // scrolled
    #expect(WashPin.offset(contentOffset: -inset + 0.5, insetTop: inset) == -0.5)
  }

  @Test func interIsRegisteredInTheApp() {
    #expect(HasalaFonts.register())
    #expect(HasalaFonts.allFacesAvailable)
  }

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

  /// The toast's disc and what VoiceOver hears (Paper page 14 §03): a done edit gets the
  /// accent check and "… Undo available."; a note gets its glyph on the ink disc.
  @Test func aToastSaysWhatHappenedAndWhatItOffers() throws {
    let app = AppModel(store: InMemoryLedger())
    #expect(app.perform(.categorize("lulu", "groceries", learnRule: false, project: nil)))
    let done = try #require(app.toast)
    #expect(done.disc == .done)
    #expect(AppModel.announcement(for: done) == "Sorted into Groceries. Undo available.")
    app.toggleAmountsHidden()
    let hidden = try #require(app.toast)
    #expect(hidden.disc == .note(.eyeSlash))
    #expect(AppModel.announcement(for: hidden) == "Amounts hidden. Until you tap the eye again. Show available.")
    app.say("Outlook connected. Checking for alerts.")
    #expect(app.toast.map(AppModel.announcement(for:)) == "Outlook connected. Checking for alerts.")
  }

  /// A touch holds the toast; letting go starts its time again, and it can be sent away.
  @Test func aHeldToastStaysUntilLetGo() {
    let app = AppModel(store: InMemoryLedger())
    app.say("Bill marked as paid")
    app.holdToast(true)
    #expect(app.toast != nil)
    app.holdToast(false)
    #expect(app.toast != nil)
    app.dismissToast()
    #expect(app.toast == nil)
  }

  @Test func aRefusalSaysWhy() {
    let app = AppModel(store: InMemoryLedger())
    #expect(!app.perform(.moveMoney(from: nil, to: "dining", YearMonth(2026, 10), .aed(9_999_00))))
    #expect(app.toast?.title == "There isn't enough to move")
    #expect(app.toast?.undo == nil)
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

  // MARK: Routing (plan B7.2)

  /// Never two sheets at once: a second waits for the first to go, then opens with its
  /// profile path; a sheet that went takes its pushed pages with it.
  @Test func sheetsQueueAndTakeTheirPagesWithThem() {
    let app = AppModel(store: InMemoryLedger())
    let router = app.router
    router.open(.notifications)
    #expect(app.sheet == .notifications)
    router.open(.profile, profile: [.bankAlerts])
    #expect(app.sheet == nil)
    router.sheetDismissed()
    #expect(app.sheet == .profile && router.profile == [.bankAlerts])
    router.profile.append(.mailbox("gmail"))
    app.sheet = nil
    router.sheetDismissed()
    #expect(router.profile.isEmpty && router.nextSheet == nil)
    app.open("carrefour")
    #expect(app.sheet == .transaction("carrefour") && router.transaction.isEmpty)
  }

  @Test func theSelectedTabTappedAgainGoesToItsRoot() {
    let router = AppModel(store: InMemoryLedger()).router
    router.home = [.bills, .bill("axa")]
    router.plan = [.category("dining")]
    router.popToRoot(.home)
    #expect(router.home.isEmpty && router.plan == [.category("dining")])
    router.sheet = .profile
    router.cover = .review
    router.clearPresentation()
    #expect(router.sheet == nil && router.cover == nil)
  }

  /// The Review tab's badge is the queue (6 on Maya), and follows the ledger.
  @Test func theReviewBadgeCountsTheQueue() {
    let app = AppModel(store: InMemoryLedger())
    #expect(app.reviewCount == 6)
    app.perform(.categorize("lulu", "groceries", learnRule: false, project: nil))
    #expect(app.reviewCount == 5)
    #expect(ReviewTabView.countLine(6) == "6 to sort · about a minute")
    #expect(ReviewTabView.countLine(13) == "13 to sort · about 3 minutes")
    #expect(ReviewTabView.countLine(0) == "All caught up")
  }

  @Test func editsMadeAsOneGestureAreAllTakenBack() {
    let store = InMemoryLedger(state: Scenario.mayaCopy.state)
    let app = AppModel(store: store)
    #expect(app.perform([.resolveCopy("starbucks-copy", merge: false),
                         .categorize("starbucks-copy", "groceries", learnRule: false, project: nil)]))
    #expect(app.toast?.title == "Sorted into Groceries")
    #expect(app.toast?.earlier.count == 1)
    app.toastAction()
    #expect(store.state.txn("starbucks-copy")?.isHeldCopy == true)
    #expect(store.state.txn("starbucks-copy")?.categoryID == Scenario.mayaCopy.state.txn("starbucks-copy")?.categoryID)
  }

  @Test func aFailedWriteSaysSo() {
    let app = AppModel(store: InMemoryLedger())
    app.writeFailed()
    #expect(app.toast?.title == "That change didn't save")
    #expect(app.toast?.undo == nil)
  }

  @Test func theSnapshotCoverIsUpWheneverTheSceneIsNotActive() {
    #expect(SnapshotCover.covers(.background))
    #expect(SnapshotCover.covers(.inactive))
    #expect(!SnapshotCover.covers(.active))
  }

  @Test func aRefusedEditTakesBackTheEditsBeforeIt() {
    let store = InMemoryLedger(state: Scenario.mayaCopy.state)
    let app = AppModel(store: store)
    #expect(!app.perform([.resolveCopy("starbucks-copy", merge: false),
                          .categorize("no-such-txn", "groceries", learnRule: false, project: nil)]))
    #expect(store.state.txn("starbucks-copy")?.isHeldCopy == true)
    #expect(app.toast?.undo == nil)
  }
}
