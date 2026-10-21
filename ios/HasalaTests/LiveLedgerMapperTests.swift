import CoreAuth
import CoreDomain
import CoreInvariants
import CoreMailbox
import CoreOutbox
import CoreProjection
import CoreReplay
import CoreStore
import CoreSync
import CoreTime
import CoreWire
import Foundation
import HasalaMocks
import HasalaModels
import Testing

@testable import Hasala

/// AT-REV-3: the bundled sample seed, authored as "Use sample data" authors it, folded
/// (CoreInvariants' `LedgerFold`) and projected (CoreProjection), then mapped by
/// `LedgerStateMapper`, gives HasalaKit's engines Maya's figures: the Home hero, Plan,
/// Activity and Bills of the Paper boards that `MayaLedger` reproduces.
///
/// The seed is generated from `MayaLedger` (Tools/SampleSeedExport), so a drift in the
/// export, the fold, the projector or the mapper shows up here as a different figure.
@MainActor
@Suite("Live ledger mapper (AT-REV-3)")
struct LiveLedgerMapperTests {
  nonisolated struct FixedClock: CoreTime.Clock {
    let ms: Int64
    func nowMs() -> Int64 { ms }
  }

  /// Saturday 10 October 2026, 13:40 in Dubai: the seed's anchor and `MayaLedger.now`.
  static let anchor: Int64 = 1_791_625_200_000
  static let user = UserID("6f1c2d3e-4a5b-4c6d-8e7f-90a1b2c3d4e5")!
  static let writer = WriterID("ios-0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d")!

  /// One enrolled account's pieces in memory, at the anchor.
  struct Account {
    let context: SyncContext
    let projection: ProjectionStore
    let observer: LedgerPageObserver
    let outbox: Outbox
  }

  nonisolated final class GatedClock: CoreTime.Clock, @unchecked Sendable {
    let ms: Int64
    private let lock = NSLock()
    private var gate: DispatchSemaphore?
    private let reached = DispatchSemaphore(value: 0)

    init(ms: Int64) { self.ms = ms }

    func close() { lock.withLock { gate = DispatchSemaphore(value: 0) } }

    func open() { lock.withLock { () -> DispatchSemaphore? in defer { gate = nil }; return gate }?.signal() }

    func nowMs() -> Int64 {
      if let g = lock.withLock({ gate }) {
        reached.signal()
        g.wait()
      }
      return ms
    }

    func waitUntilHeld() async {
      await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
        DispatchQueue.global().async {
          self.reached.wait()
          c.resume()
        }
      }
    }
  }

  static func account(clock: any CoreTime.Clock = FixedClock(ms: anchor)) throws -> Account {
    let store = try LedgerStore.inMemory()
    try store.create(StoreMeta(userID: user, writerID: writer, apiBase: "https://api.hasala.app", keyEpoch: 1, createdAt: anchor))
    let context = SyncContext(
      userID: user, writerID: writer, store: store,
      secrets: Secrets(store: MemorySecretStore(), apiHost: "api.hasala.app"),
      client: AuthClient(transport: MiniHasalad(invite: "")), clock: clock, random: SystemRandom())
    let projection = try ProjectionStore.inMemory()
    let observer = LedgerPageObserver(context: context, projection: projection, dictionary: AccountRuntime.dictionary)
    let outbox = Outbox(store: store, clock: FixedClock(ms: anchor), debounce: .seconds(3600), onAuthored: {})
    return Account(context: context, projection: projection, observer: observer, outbox: outbox)
  }

  /// The seed's blobs, through the observer's gate (a review account, an empty ledger).
  static func seed(_ a: Account) async throws -> [AuthoredBlob] {
    let batches = try await a.observer.sampleBatches(account: AccountInfo(user_id: user.string, review_account: true))
    let opening = try a.observer.stamps.build(try await a.observer.authorContext()) { o throws(AuthorError) in
      o.setHomeCurrency("AED")
      try o.setRate(currency: "USD", rateMicro: 3_672_500)
    }
    return batches + [opening].compactMap { $0 }
  }

  static func context() -> LedgerStateMapper.Context {
    LedgerStateMapper.Context(
      today: MayaLedger.now.date,
      profile: ProfileInfo(displayName: "Maya Rahman", email: "maya@example.com", signIn: .password))
  }

  /// Seed → fold → project → map: the blobs as the rows of one pulled page.
  static func foldedState(extra: (inout OpAuthor) throws(AuthorError) -> Void = { _ throws(AuthorError) in }) async throws -> LedgerState {
    let a = try account()
    var blobs = try await seed(a)
    if let more = try a.observer.stamps.build(try await a.observer.authorContext(), extra) { blobs.append(more) }
    var rows: [FoldRow] = []
    for (i, b) in blobs.enumerated() {
      let plaintext = Data(try OpCodec.encodeBlobOps(b.ops))
      rows.append(FoldRow(seq: Int64(i + 1), writerID: writer.string, counter: Int64(i + 1), outcome: .opened(plaintext: plaintext, ops: b.ops)))
    }
    let state = try LedgerFold.page(rows, onto: State())
    try a.projection.project(
      state, pending: [], writerID: writer.string, dictionary: AccountRuntime.dictionary, projectedAtMs: anchor)
    return try LedgerStateMapper.map(a.projection.reader, context: context())
  }

  // MARK: Home source

  @Test func foreignRowsCarryTheirHomeSource() async throws {
    let wall = Int64(1_791_633_600_000)
    var ids: [String] = []
    let live = try await Self.foldedState { o throws(AuthorError) in
      ids.append(try o.manualEntry(amountMinor: 25_00, currency: "USD", direction: "debit", localWallMs: wall, merchant: "Amazon US", category: "shopping"))
      ids.append(try o.manualEntry(amountMinor: 40_00, currency: "EUR", direction: "debit", localWallMs: wall, merchant: "Zara Paris", category: "shopping"))
    }
    #expect(ids.count == 2)
    let usd = try #require(live.txns.first { $0.id == ids.first })
    #expect(usd.homeMinor == 91_81 && usd.homeSource == .rate && usd.homeRateMicro == 3_672_500)
    #expect(usd.homeAmount.estimateLine == "Estimate at 3.6725 AED per USD. Your bank's charge can be a little higher.")
    let eur = try #require(live.txns.first { $0.id == ids.last })
    #expect(eur.homeMinor == nil && eur.homeSource == nil && eur.isNotCounted)
    #expect(live.txns.filter { $0.amount.currency == "AED" }.allSatisfy { $0.homeSource == .identity })
  }

  // MARK: Home

  @Test func homeHeroAndWidgetsAreMayas() async throws {
    let live = try await Self.foldedState()
    let now = MayaLedger.now
    let got = HomeEngine.snapshot(live, now: now)
    let want = HomeEngine.snapshot(MayaLedger.state, now: now)
    // The hero: 11,115.62 spent of 19,000, the tick at 11,217.17 (the bills paid so far are
    // linked to their payments in the seed too), on track, and the tiles.
    #expect(got.hero == want.hero)
    #expect(got.hero == Maya.home.hero)
    #expect(got.hero.tick == .aed(11_217_17))
    #expect(got.hero.tiles.map(\.value) == [.aed(9_040_80), .aed(1_247_54), .aed(5_000_00)])
    #expect(HomeEngine.billsThisMonth(live, month: MayaLedger.october).paid == 8_005_89)
    // The bell: the transactions to sort, AXA three days late and du's new price. The detector's
    // proposals are not ops, so live finds no bill yet (the mock's Apple.com/bill). A bill's row
    // id is its bill id, which the seed mints afresh, so rows compare by what they say.
    let wantRows = want.notifications.needsALook.filter { !$0.id.hasPrefix("found.") }
    #expect(got.notifications.needsALook.map(\.title) == wantRows.map(\.title))
    #expect(got.notifications.needsALook.map(\.line) == wantRows.map(\.line))
    #expect(got.notifications.needsALook.map(\.when) == wantRows.map(\.when))
    #expect(got.notifications.count == 3)
    // Widgets: the bucket pace rows, the next bill, net worth, the trip, the goal, today.
    func widget(_ s: HomeSnapshot, _ id: String) -> HomeWidget? { s.widgets.first { $0.id == id } }
    #expect(widget(got, "budgetPace") == widget(want, "budgetPace"))
    #expect(widget(got, "nextBill") == widget(want, "nextBill"))
    guard case .today(let gotToday)? = widget(got, "today"), case .today(let wantToday)? = widget(want, "today") else {
      Issue.record("no today widget")
      return
    }
    #expect(gotToday.summary == wantToday.summary)
    #expect(gotToday.rows.map(\.merchant) == wantToday.rows.map(\.merchant))
    #expect(gotToday.rows.map(\.detail) == wantToday.rows.map(\.detail))
    #expect(gotToday.rows.map(\.amount) == wantToday.rows.map(\.amount))
    #expect(widget(got, "project.Japan trip") == widget(want, "project.Japan trip"))
    #expect(widget(got, "goal.Emergency fund") == widget(want, "goal.Emergency fund"))
    guard case .netWorth(let nw)? = widget(got, "netWorth") else {
      Issue.record("no net worth widget")
      return
    }
    #expect(nw.total == .aed(227_568_00))
  }

  // MARK: Plan

  @Test func planIsPlanOctober() async throws {
    let live = try await Self.foldedState()
    let got = PlanEngine.snapshot(live, now: MayaLedger.now)
    let want = PlanEngine.snapshot(MayaLedger.state, now: MayaLedger.now)
    #expect(got.readyToAssign == .aed(1_000_00))
    #expect(got.incomeLine == want.incomeLine)
    #expect(got.split == want.split)
    #expect(got.startedFrom == want.startedFrom)
    #expect(got.sections.map(\.bucket) == want.sections.map(\.bucket))
    #expect(got.sections.map(\.budget) == want.sections.map(\.budget))
    #expect(got.sections.map(\.left) == want.sections.map(\.left))
    #expect(got.sections.map(\.done) == want.sections.map(\.done))
    #expect(got.sections.map { $0.rows.map(\.name) } == want.sections.map { $0.rows.map(\.name) })
    for (g, w) in zip(got.sections.flatMap(\.rows), want.sections.flatMap(\.rows)) {
      #expect(g.trailing == w.trailing, "\(w.name)")
      #expect(g.budget == w.budget && g.spent == w.spent, "\(w.name)")
      #expect(g.verdict == w.verdict && g.progress == w.progress, "\(w.name)")
    }
    #expect(got.projects.map(\.left) == [.aed(7_140_00)])
    #expect(got.projects.map(\.dates) == want.projects.map(\.dates))
  }

  @Test func incomeReceivedAboveTheSourceIsReadyToAssign() async throws {
    let wall = Int64(1_791_633_600_000)
    let base = PlanEngine.snapshot(try await Self.foldedState(), now: MayaLedger.now)
    let live = try await Self.foldedState { o throws(AuthorError) in
      _ = try o.manualEntry(amountMinor: 30_000_00, currency: "AED", direction: "credit", localWallMs: wall,
                            merchant: "Acme bonus", category: "salary")
    }
    let got = PlanEngine.snapshot(live, now: MayaLedger.now)
    let month = MayaLedger.now.date.yearMonth
    #expect(live.plan.income(in: month).minor > live.plan.income.minor)
    #expect(got.readyToAssign.minor - base.readyToAssign.minor >= 5_000_00)
    #expect(got.readyToAssign.minor == live.plan.income(in: month).minor - got.sections.map(\.budget.minor).reduce(0, +))
  }

  // MARK: Activity and Review

  @Test func activityAndReviewAreMayas() async throws {
    let live = try await Self.foldedState()
    let now = MayaLedger.now
    let got = ActivityEngine.snapshot(live, now: now, filter: .all)
    let want = ActivityEngine.snapshot(MayaLedger.state, now: now, filter: .all)
    #expect(got.countLine == "26 transactions this month")
    #expect(got.review?.count == 6)
    #expect(got.review?.unplanned == .aed(827_28))
    #expect(got.chips == want.chips)
    #expect(got.comingUp.map(\.name) == ["DEWA", "AXA Insurance"])
    #expect(got.days.map(\.title) == want.days.map(\.title))
    #expect(got.days.map(\.total) == want.days.map(\.total))
    #expect(got.days.map { $0.rows.map(\.merchant) } == want.days.map { $0.rows.map(\.merchant) })
    #expect(ReviewEngine.cards(live).count == 6)
    let dining = ActivityEngine.snapshot(live, now: now, filter: TxnFilter(category: "dining"))
    #expect(dining.summary?.total == .aed(642_75))
  }

  // MARK: Sample rows

  /// The seed's `sample-<n>` message ids reach the screens, so every sample row's sheet
  /// says it is sample data instead of naming a bank email (spec 06 §13.5).
  @Test func sampleRowsAreMarkedSample() async throws {
    let live = try await Self.foldedState()
    let fromMail = live.txns.filter { $0.provenance != nil }
    #expect(!fromMail.isEmpty)
    let notSample = fromMail.filter { !$0.isSample }.map(\.merchant)
    #expect(notSample == [])
    let sampleCount = live.txns.filter { $0.isSample }.count
    #expect(sampleCount == Scenario.mayaSample.state.txns.filter { $0.isSample }.count)
    let row = try #require(fromMail.first)
    #expect(TransactionEngine.detail(row.id, live, now: MayaLedger.now)?.isSample == true)
  }

  // MARK: Bills

  @Test func billsAreMayas() async throws {
    let live = try await Self.foldedState()
    let got = BillsEngine.snapshot(live, now: MayaLedger.now)
    let want = BillsEngine.snapshot(MayaLedger.state, now: MayaLedger.now)
    #expect(got.next14 == .aed(1_039_15))
    #expect(got.incomeLine == want.incomeLine)
    #expect(got.needsALook.map(\.name) == ["AXA Insurance", "du"])
    #expect(got.needsALook.map(\.kind) == want.needsALook.map(\.kind))
    #expect(got.upcoming.map(\.name) == want.upcoming.map(\.name))
    #expect(got.recentlyPaid.map(\.name) == want.recentlyPaid.map(\.name))
    #expect(got.paidThisMonth == .aed(8_005_89))
    #expect(got.tracked == want.tracked)
  }

  // MARK: The app's own path

  /// "Use sample data" as the app runs it, before any upload: the blobs go through the
  /// outbox and the projection shows them as the pending overlay. Same figures.
  @Test func theOutboxOverlayShowsTheSameMonth() async throws {
    let a = try Self.account()
    for b in try await Self.seed(a) { try await a.outbox.enqueue(b.ops) }
    try await a.observer.reproject()
    let live = try LedgerStateMapper.map(a.projection.reader, context: Self.context())
    let folded = try await Self.foldedState()
    let now = MayaLedger.now
    #expect(HomeEngine.snapshot(live, now: now).hero == HomeEngine.snapshot(folded, now: now).hero)
    // Every load mints fresh ids (the user category's among them), so compare figures.
    let (lp, fp) = (PlanEngine.snapshot(live, now: now), PlanEngine.snapshot(folded, now: now))
    #expect(lp.readyToAssign == fp.readyToAssign)
    #expect(lp.sections.map(\.left) == fp.sections.map(\.left))
    #expect(lp.sections.flatMap(\.rows).map(\.trailing) == fp.sections.flatMap(\.rows).map(\.trailing))
    #expect(BillsEngine.snapshot(live, now: now).next14 == .aed(1_039_15))
    #expect(live.txns.filter { $0.postedAt.date.yearMonth == MayaLedger.october }.count == 26)
    // The gate is one-shot: a second load is refused, and nothing more is authored.
    await #expect(throws: SampleLoadError.self) { _ = try await Self.seed(a) }
  }

  /// A review swipe through the live store: the card leaves at once, the edit is
  /// authored as `txn_categorized` into the outbox, and the projection agrees.
  @Test func aLaterRateCountsTheRowsWaitingForIt() async throws {
    let wall = Int64(1_791_633_600_000)
    var id = ""
    let live = try await Self.foldedState { o throws(AuthorError) in
      id = try o.manualEntry(amountMinor: 40_00, currency: "EUR", direction: "debit", localWallMs: wall, merchant: "Zara Paris", category: "shopping")
      try o.setRate(currency: "EUR", rateMicro: 4_050_000)
    }
    let eur = try #require(live.txns.first { $0.id == id })
    #expect(eur.homeMinor == 162_00 && eur.homeSource == .rate && eur.homeRateMicro == 4_050_000)
    #expect(live.rates.map(\.currency) == ["EUR", "USD"])
    #expect(live.rates.map(\.rateMicro) == [4_050_000, 3_672_500])
    #expect(ExchangeRates.page(live).missing.isEmpty)
  }

  @Test func aRateSetOnTheRatesPageIsAuthoredAndReadBack() async throws {
    let a = try Self.account()
    for b in try await Self.seed(a) { try await a.outbox.enqueue(b.ops) }
    let wall = Int64(1_791_633_600_000)
    var id = ""
    if let b = try a.observer.stamps.build(try await a.observer.authorContext(), { o throws(AuthorError) in
      id = try o.manualEntry(amountMinor: 40_00, currency: "EUR", direction: "debit", localWallMs: wall, merchant: "Zara Paris", category: "shopping")
    }) { try await a.outbox.enqueue(b.ops) }
    try await a.observer.reproject()
    let store = LiveLedgerStore(
      reader: a.projection.reader, author: LedgerEditAuthor(observer: a.observer, outbox: a.outbox),
      profile: Self.context().profile, prefs: DevicePrefsStore(defaults: UserDefaults(suiteName: "rates.tests")!),
      clock: { MayaLedger.now })
    await store.reload()
    #expect(store.state.txn(id)?.isNotCounted == true)
    #expect(ExchangeRates.page(store.state).missing.map(\.currency) == ["EUR"])
    #expect(try store.apply(.setRate(currency: "EUR", rateMicro: 4_050_000)) == nil)
    #expect(store.state.txn(id)?.homeMinor == 162_00)
    try await Self.eventually { try a.projection.reader.txn(id)?.amountHomeMinor == 162_00 }
    try await Self.eventually { try a.projection.reader.rates().contains { $0.currency == "EUR" && $0.rateMicro == 4_050_000 } }
    #expect(throws: ActionError.invalidAmount) { try store.apply(.setRate(currency: "AED", rateMicro: 1_000_000)) }
    try store.apply(.unsetRate(currency: "EUR"))
    try await Self.eventually { try a.projection.reader.rates().contains { $0.currency == "EUR" && $0.rateMicro == nil } }
    #expect(try a.projection.reader.txn(id)?.amountHomeMinor == 162_00)
  }

  @Test func aReviewEditIsAuthoredAndReadBack() async throws {
    let a = try Self.account()
    for b in try await Self.seed(a) { try await a.outbox.enqueue(b.ops) }
    try await a.observer.reproject()
    let store = LiveLedgerStore(
      reader: a.projection.reader, author: LedgerEditAuthor(observer: a.observer, outbox: a.outbox),
      profile: Self.context().profile, prefs: DevicePrefsStore(defaults: UserDefaults(suiteName: "laneb.tests")!),
      clock: { MayaLedger.now })
    await store.reload()
    let steam = try #require(store.state.txns.first { $0.merchant == "Steam" && $0.needsReview })
    let pending = try a.context.store.pendingCount()
    let token = try store.apply(.categorize(steam.id, "entertainment", learnRule: false, project: nil))
    #expect(token?.title == "Sorted into Entertainment")
    #expect(ReviewEngine.cards(store.state).count == 5)
    // Wait for the background write and the reload.
    for _ in 0..<100 where try a.context.store.pendingCount() == pending {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(try a.context.store.pendingCount() == pending + 1)
    // The op is queued before it is re-projected: wait for the projection too.
    try await Self.eventually { try a.projection.reader.txn(steam.id)?.category == "entertainment" }
    let row = try #require(try a.projection.reader.txn(steam.id))
    #expect(row.category == "entertainment" && !row.needsReview)
    // Undo writes the old category back.
    store.undo(try #require(token))
    for _ in 0..<100 where try a.context.store.pendingCount() == pending + 1 {
      try await Task.sleep(for: .milliseconds(20))
    }
    try await Self.eventually { try a.projection.reader.txn(steam.id)?.needsReview == true }
    #expect(try a.projection.reader.txn(steam.id)?.needsReview == true)
  }

  @Test func aReloadWhileASortIsBeingWrittenDoesNotBringTheCardBack() async throws {
    let clock = GatedClock(ms: Self.anchor)
    let a = try Self.account(clock: clock)
    for b in try await Self.seed(a) { try await a.outbox.enqueue(b.ops) }
    try await a.observer.reproject()
    let store = LiveLedgerStore(
      reader: a.projection.reader, author: LedgerEditAuthor(observer: a.observer, outbox: a.outbox),
      profile: Self.context().profile, prefs: DevicePrefsStore(defaults: UserDefaults(suiteName: "sort.reload.tests")!),
      clock: { MayaLedger.now })
    await store.reload()
    let app = AppModel(store: store)
    let deck = ReviewViewModel(app: app)
    let steam = try #require(deck.cards.first { $0.merchant == "Steam" })
    let before = deck.cards.count

    clock.close()
    #expect(deck.sort(steam.id, into: "entertainment", alwaysUse: false, project: nil))
    await clock.waitUntilHeld()
    await store.reload()
    #expect(!deck.cards.contains { $0.id == steam.id })
    #expect(deck.cards.count == before - 1)
    #expect(app.reviewCount == before - 1)

    clock.open()
    try await Self.eventually { try a.projection.reader.txn(steam.id)?.category == "entertainment" }
    #expect(try a.projection.reader.txn(steam.id)?.needsReview == false)
    try await Task.sleep(for: .milliseconds(100))
    await store.reload()
    #expect(!deck.cards.contains { $0.id == steam.id })
    #expect(store.state.txn(steam.id)?.categoryID == "entertainment")
  }

  @Test func aProjectIsMadeFilledCompletedAndRemovedThroughTheOutbox() async throws {
    let a = try Self.account()
    for b in try await Self.seed(a) { try await a.outbox.enqueue(b.ops) }
    try await a.observer.reproject()
    let store = LiveLedgerStore(
      reader: a.projection.reader, author: LedgerEditAuthor(observer: a.observer, outbox: a.outbox),
      profile: Self.context().profile, prefs: DevicePrefsStore(defaults: UserDefaults(suiteName: "projects.tests")!),
      clock: { MayaLedger.now })
    await store.reload()
    let id = store.newProjectID()
    #expect(id.count == 26)
    try store.apply(.saveProject(id, ProjectDraft(
      name: "Kitchen refresh", glyph: .rent, budget: .aed(8_000_00), starts: LocalDate(2026, 10, 1))))
    try await Self.eventually { try a.projection.reader.projects().contains { $0.id == id } }
    let row = try #require(try a.projection.reader.projects().first { $0.id == id }?.project)
    #expect(row.name == "Kitchen refresh" && row.budgetMinor == 8_000_00 && row.startsOn == "2026-10-01")
    #expect(row.endsOn == nil && row.icon == "house" && row.status == "active" && !row.countInPlan)

    let carrefour = try #require(store.state.txns.first { $0.merchant.hasPrefix("Carrefour") && !$0.needsReview })
    try store.apply(.assignProject([carrefour.id], id))
    try await Self.eventually { try a.projection.reader.txn(carrefour.id)?.projectID == id }
    await store.reload()
    #expect(PlanEngine.project(id, store.state, now: MayaLedger.now)?.transactions.map(\.id) == [carrefour.id])

    try store.apply(.completeProject(id, true))
    try await Self.eventually { try a.projection.reader.projects().first { $0.id == id }?.project.status == "completed" }
    #expect(try a.projection.reader.projects().first { $0.id == id }?.project.completedOn == "2026-10-10")
    await store.reload()
    #expect(store.state.project(id)?.complete == true)

    try store.apply(.removeProject(id))
    try await Self.eventually { try !a.projection.reader.projects().contains { $0.id == id } }
    await store.reload()
    #expect(store.state.project(id) == nil)
  }

  @Test func anUncategorizedRowFromAnEarlierMonthIsInThatMonthsQueue() async throws {
    let a = try Self.account()
    for b in try await Self.seed(a) { try await a.outbox.enqueue(b.ops) }
    try await a.observer.reproject()
    let author = LedgerEditAuthor(observer: a.observer, outbox: a.outbox)
    let store = LiveLedgerStore(
      reader: a.projection.reader, author: author, profile: Self.context().profile,
      prefs: DevicePrefsStore(defaults: UserDefaults(suiteName: "review.window.tests")!), clock: { MayaLedger.now })
    await store.reload()
    let old = try #require(store.state.txns.first { $0.merchant == "Carrefour" && $0.postedAt.date == LocalDate(2026, 9, 13) })
    try await author.undo([.category(txn: old.id, category: nil, needsReview: false)])
    try await Self.eventually { try a.projection.reader.txn(old.id)?.category == nil }
    await store.reload()
    let row = try #require(try a.projection.reader.txn(old.id))
    #expect(!row.needsReview && row.reviewLane == "uncategorized")
    let september = ReviewWindow.month(YearMonth(2026, 9))
    #expect(ReviewEngine.queue(store.state, in: september).map(\.id) == [old.id])
    #expect(!ReviewEngine.queue(store.state, in: .month(YearMonth(2026, 10))).contains { $0.id == old.id })
    let app = AppModel(store: store)
    #expect(app.reviewCount == 7)
    app.period = .month(YearMonth(2026, 9))
    #expect(app.reviewCount == 7)
    #expect(ReviewEngine.queue(store.state).last?.id == old.id)
    #expect(try store.apply(.categorize(old.id, "groceries", learnRule: false, project: nil)) != nil)
    #expect(app.reviewCount == 6)
  }

  @Test func aStoppedImportKeepsItsCount() throws {
    let a = try Self.account()
    let store = LiveLedgerStore(
      reader: a.projection.reader, author: nil, profile: Self.context().profile,
      prefs: DevicePrefsStore(defaults: UserDefaults(suiteName: "laneb.tests")!), clock: { MayaLedger.now })
    store.noteImport(MailboxProgress(stage: .downloading, done: 25, total: 500))
    store.noteImport(MailboxProgress(stage: .failed(.offline), done: 0, total: 0))
    #expect(store.importProgress == MailboxProgress(stage: .failed(.offline), done: 25, total: 500))
    store.noteImport(MailboxProgress(stage: .downloading, done: 50, total: 500))
    #expect(store.importProgress == MailboxProgress(stage: .downloading, done: 50, total: 500))
  }

  @MainActor final class Count {
    var n = 0
  }

  @Test func theImportFollowerReloadsOnACommitAndEndsThePillOnDone() async throws {
    let a = try Self.account()
    let store = LiveLedgerStore(
      reader: a.projection.reader, author: nil, profile: Self.context().profile,
      prefs: DevicePrefsStore(defaults: UserDefaults(suiteName: "laneb.tests")!), clock: { MayaLedger.now })
    await store.reload()
    #expect(store.state.txns.isEmpty)
    let events = LaneEvents()
    let refreshed = Count()
    let follower = ImportFollower(store: store) { refreshed.n += 1 }
    follower.follow([events])

    for b in try await Self.seed(a) { try await a.outbox.enqueue(b.ops) }
    try await a.observer.reproject()
    events.send(.committed)
    try await Self.eventually { !store.state.txns.isEmpty }
    #expect(refreshed.n == 0)

    events.send(.progress(MailboxProgress(stage: .downloading, done: 25, total: 500)))
    try await Self.eventually { store.importProgress?.done == 25 }
    #expect(LiveMailboxConnecting.importing(phase: .scanning, seen: true, progress: store.importProgress)?.count
      == "25 of 500")

    events.send(.progress(MailboxProgress(stage: .done, done: 500, total: 500)))
    try await Self.eventually { refreshed.n == 1 }
    #expect(store.importProgress?.stage == .done)
    #expect(LiveMailboxConnecting.importing(phase: .scanning, seen: true, progress: store.importProgress) == nil)

    events.send(.progress(MailboxProgress(stage: .failed(.gmail), done: 0, total: 0)))
    try await Self.eventually { refreshed.n == 2 }
    #expect(store.importProgress == MailboxProgress(stage: .failed(.gmail), done: 500, total: 500))

    follower.stop()
    events.send(.progress(MailboxProgress(stage: .downloading, done: 1, total: 2)))
    try await Task.sleep(for: .milliseconds(100))
    #expect(store.importProgress?.stage == .failed(.gmail))
  }

  /// Polls `condition` for up to 3 s (a write is queued, then re-projected).
  static func eventually(_ condition: () throws -> Bool) async throws {
    for _ in 0..<150 where try !condition() { try await Task.sleep(for: .milliseconds(20)) }
  }

  /// Undoing a rename puts back the name shown before it: an earlier rename stays, and a
  /// merchant that had none goes back to its dictionary or prettified name.
  @Test func undoingARenameRestoresTheNameBefore() async throws {
    let a = try Self.account()
    for b in try await Self.seed(a) { try await a.outbox.enqueue(b.ops) }
    try await a.observer.reproject()
    let store = LiveLedgerStore(
      reader: a.projection.reader, author: LedgerEditAuthor(observer: a.observer, outbox: a.outbox),
      profile: Self.context().profile, prefs: DevicePrefsStore(defaults: UserDefaults(suiteName: "laneb.tests")!),
      clock: { MayaLedger.now })
    await store.reload()
    let steam = try #require(store.state.txns.first { $0.merchant == "Steam" })
    let original = steam.merchant
    func shows(_ id: String, _ name: String) async throws {
      try await Self.eventually { try a.projection.reader.txn(id)?.displayName == name }
      await store.reload()
      #expect(try a.projection.reader.txn(id)?.displayName == name)
    }
    let first = try store.apply(.renameMerchant(steam.id, "Games"))
    try await shows(steam.id, "Games")
    let second = try store.apply(.renameMerchant(steam.id, "Valve"))
    try await shows(steam.id, "Valve")
    store.undo(try #require(second))
    try await shows(steam.id, "Games")
    // Back past the first rename: the seed's own rename ("Steam") is put back.
    store.undo(try #require(first))
    try await shows(steam.id, original)
    #expect(LedgerEditAuthor.unrenamed(try #require(try a.projection.reader.txn(steam.id)).merchantRaw) != original)
    // A merchant with no rename goes back to its derived name.
    let plain = try #require(
      try a.projection.reader.activity(limit: 1_000).first {
        $0.displayName == LedgerEditAuthor.unrenamed($0.merchantRaw) && $0.displayName != original
      })
    let renamed = try store.apply(.renameMerchant(plain.id, "Something else"))
    try await shows(plain.id, "Something else")
    store.undo(try #require(renamed))
    try await shows(plain.id, plain.displayName)
  }

  @Test func theOptimisticPatchTakesARemovedProjectsTransactionsOut() throws {
    var s = MayaLedger.state
    #expect(s.txns.contains { $0.projectID == "japan" })
    _ = try LiveLedgerStore.patch(.removeProject("japan"), &s, now: MayaLedger.now)
    #expect(s.project("japan") == nil)
    #expect(s.txns.allSatisfy { $0.projectID != "japan" })
    #expect(throws: ActionError.invalidProject) {
      try LiveLedgerStore.patch(.saveProject("x", ProjectDraft(name: " ")), &s, now: MayaLedger.now)
    }
  }

  @Test func aWriteThatFailsIsReportedAndItsUndoDropped() async throws {
    let a = try Self.account()
    for b in try await Self.seed(a) { try await a.outbox.enqueue(b.ops) }
    try await a.observer.reproject()
    let empty = try Self.account()
    let store = LiveLedgerStore(
      reader: a.projection.reader, author: LedgerEditAuthor(observer: empty.observer, outbox: empty.outbox),
      profile: Self.context().profile, prefs: DevicePrefsStore(defaults: UserDefaults(suiteName: "write.failure.tests")!),
      clock: { MayaLedger.now })
    await store.reload()
    let app = AppModel(store: store)
    store.onWriteFailed = { [weak app] in app?.writeFailed() }
    let steam = try #require(store.state.txns.first { $0.merchant == "Steam" && $0.needsReview })
    #expect(app.perform(.categorize(steam.id, "entertainment", learnRule: false, project: nil)))
    let token = try #require(app.toast?.undo)
    #expect(store.canUndo(token))
    try await Self.eventually { app.toast?.title == "That change didn't save" }
    #expect(app.toast?.title == "That change didn't save")
    #expect(!store.canUndo(token))
    try await Self.eventually { store.state.txn(steam.id)?.needsReview == true }
    #expect(store.state.txn(steam.id)?.needsReview == true)
  }
}
