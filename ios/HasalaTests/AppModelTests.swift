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

  @Test func theReviewBadgeIgnoresHomesPeriod() {
    var state = MayaLedger.state
    state.txns.append(Txn(id: "sep-shop", merchant: "Corner Shop", amount: .aed(12_50),
                          postedAt: LocalDateTime(2026, 9, 20, 18, 0), accountID: "dib"))
    let app = AppModel(store: InMemoryLedger(state: state))
    #expect(app.period == .month(MayaLedger.october))
    #expect(app.reviewCount == 7)
    for period in [Period.month(YearMonth(2026, 9)), .month(YearMonth(2026, 6)), Period(YearMonth(2026, 8), YearMonth(2026, 10))] {
      app.period = period
      #expect(app.reviewCount == 7)
      #expect(app.needsALook.first { $0.id == "review" }?.title == "7 transactions to sort")
    }
    app.period = .month(YearMonth(2026, 12))
    #expect(app.period == .month(MayaLedger.october))
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
      guard let row = app.snapshot.aboutNow.first(where: { $0.destination == .review(nil) }) else { return 0 }
      return Int(row.detail.rendered(hidden: false).prefix { $0.isNumber }) ?? -1
    }
    app.period = .month(YearMonth(2026, 9))
    #expect(app.reviewCount == 9)
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

  @Test func allTimeIsRememberedAsAllTimeAndGrowsWithOlderTransactions() throws {
    let store = InMemoryLedger(state: MayaHistory.state)
    let app = AppModel(store: store)
    #expect(!app.period.isAllTime && app.period.showsBudgets)
    app.choose(.allTime)
    #expect(app.period.isAllTime && !app.period.showsBudgets)
    #expect(app.period == .allTime(since: YearMonth(2026, 4), today: MayaLedger.october))
    #expect(app.period.title == "All time" && app.period.preset(today: MayaLedger.october) == .allTime)
    #expect(app.snapshot.period?.isAllTime == true && !app.snapshot.isThisMonth)
    #expect(app.snapshot.hero.plan == .aed(0) && app.snapshot.hero.bars.isEmpty)
    #expect(app.reviewWindow == .all && app.reviewElsewhere == nil)
    let before = app.snapshot.hero.spent.minor
    try store.apply(.addTransaction(ManualEntryDraft(
      amount: .aed(25_00), merchant: "Corner Shop", categoryID: nil, postedAt: LocalDateTime(2025, 11, 4, 9, 0))))
    #expect(app.earliestMonth == YearMonth(2025, 11))
    #expect(app.period.isAllTime && app.period.first == YearMonth(2025, 11) && app.period.last == MayaLedger.october)
    #expect(app.snapshot.hero.spent.minor == before + 25_00)

    app.period = Period(YearMonth(2025, 11), MayaLedger.october)
    #expect(!app.period.isAllTime && app.period.showsBudgets && app.period.title == "Nov 2025 – Oct 2026")
    app.choose(.allTime)
    app.period = .month(MayaLedger.october)
    #expect(!app.period.isAllTime && app.snapshot.isThisMonth)
    #expect(AppModel(store: store).period == .month(MayaLedger.october))
  }

  @Test func allTimeWithNothingOlderIsThisMonthStillCalledAllTime() {
    let app = AppModel(store: InMemoryLedger(state: MayaHistory.firstDays, now: MayaHistory.firstDaysNow))
    app.choose(.allTime)
    #expect(app.period.isAllTime && app.period.range == MayaLedger.october...MayaLedger.october)
    #expect(app.period.title == "All time" && !app.snapshot.isThisMonth)
    #expect(app.snapshot.hero.caption.rendered(hidden: false) == "spent, all time")
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

  @Test func theUndoLineStaysLongerThanAToast() {
    #expect(AppModel.dwell(lasting: false, voiceOver: false) == HMotion.toastDwell)
    #expect(AppModel.dwell(lasting: true, voiceOver: false) == HMotion.undoLineDwell)
    #expect(AppModel.dwell(lasting: true, voiceOver: true) == HMotion.toastDwellVoiceOver)
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
    #expect(ReviewTabView.countLine(app.reviewCards.count) == "5 to sort · about a minute")
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

@MainActor
@Suite("Pull to refresh")
struct SyncActivityTests {
  final class Gate {
    var calls = 0
    private var opened = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func pass() async {
      calls += 1
      if opened { return }
      await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
      opened = true
      for k in waiting { k.resume() }
      waiting = []
    }
  }

  final class Said {
    var all: [String] = []
  }

  static func activity(_ gate: Gate) -> (SyncActivity, Said) {
    let sync = SyncActivity()
    let said = Said()
    sync.announce = { said.all.append($0) }
    sync.work = { await gate.pass() }
    return (sync, said)
  }

  @Test func aStartShowsTheIndicatorUntilTheSyncEnds() async {
    let gate = Gate()
    let (sync, said) = Self.activity(gate)
    #expect(!sync.isSyncing)
    let task = sync.start()
    #expect(sync.isSyncing)
    #expect(said.all == ["Updating"])
    gate.open()
    await task.value
    #expect(!sync.isSyncing)
    #expect(said.all == ["Updating", "Updated"])
    #expect(gate.calls == 1)
  }

  @Test func thePullEndsBeforeTheSync() async {
    let gate = Gate()
    let (sync, _) = Self.activity(gate)
    await sync.pull(holding: .milliseconds(30))
    #expect(sync.isSyncing)
    gate.open()
    await sync.start().value
    #expect(!sync.isSyncing)
  }

  @Test func aQuickSyncEndsThePullAtOnce() async {
    let (sync, said) = Self.activity(Gate())
    sync.work = {}
    let started = ContinuousClock.now
    await sync.pull(holding: .seconds(10))
    #expect(ContinuousClock.now - started < .seconds(5))
    #expect(!sync.isSyncing)
    #expect(said.all == ["Updating", "Updated"])
  }

  @Test func aPullWhileSyncingJoinsTheRunningSync() async {
    let gate = Gate()
    let (sync, said) = Self.activity(gate)
    let first = sync.start()
    await sync.pull(holding: .milliseconds(10))
    await sync.pull(holding: .milliseconds(10))
    #expect(sync.start() == first)
    #expect(sync.runs == 1)
    #expect(said.all == ["Updating"])
    gate.open()
    await first.value
    #expect(gate.calls == 1)
    #expect(!sync.isSyncing)
  }

  final class Outcomes {
    var all: [WorkCoordinator.Outcome] = []
  }

  @Test func aFailedSyncClearsTheIndicatorAndTheNextPullStartsAgain() async {
    let sync = SyncActivity()
    sync.announce = { _ in }
    let outcomes = Outcomes()
    sync.work = { outcomes.all.append(WorkCoordinator.Outcome(newData: false, stop: .offline)) }
    await sync.start().value
    #expect(!sync.isSyncing)
    #expect(outcomes.all.last?.failed == true)
    await sync.pull(holding: .seconds(5))
    #expect(sync.runs == 2)
    #expect(outcomes.all.count == 2)
    #expect(!sync.isSyncing)
  }

  @Test func theMockEndsThePullAtOnce() async {
    let app = AppModel(store: InMemoryLedger())
    app.sync.announce = { _ in }
    await app.pull()
    #expect(!app.sync.isSyncing)
    #expect(app.sync.runs == 1)
  }

  @Test func aListLeftBelowTheTopAfterTheSpinnerIsStuck() {
    #expect(RefreshSettle.isStuck(contentOffset: -230, insetTop: 170))
    #expect(!RefreshSettle.isStuck(contentOffset: -170, insetTop: 170))
    #expect(!RefreshSettle.isStuck(contentOffset: -230, insetTop: 230))
    #expect(!RefreshSettle.isStuck(contentOffset: 400, insetTop: 170))
  }
}
