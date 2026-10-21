import CoreCategorize
import CoreDomain
import CoreInvariants
import CoreProjection
import CoreReplay
import CoreTime
import CoreWire
import Foundation
import HasalaMocks
import HasalaModels
import Testing

@testable import Hasala

@MainActor
@Suite("Live recurring edits")
struct LiveRecurringTests {
  typealias Mapper = LiveLedgerMapperTests

  @MainActor
  final class Clock {
    var now = MayaLedger.now
  }

  static func store(_ a: Mapper.Account, suite: String, clock: Clock = Clock()) async throws -> LiveLedgerStore {
    for b in try await Mapper.seed(a) { try await a.outbox.enqueue(b.ops) }
    try await a.observer.reproject()
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    let store = LiveLedgerStore(
      reader: a.projection.reader, author: LedgerEditAuthor(observer: a.observer, outbox: a.outbox),
      profile: Mapper.context().profile, prefs: DevicePrefsStore(defaults: defaults), clock: { clock.now })
    await store.reload()
    return store
  }

  static func record(_ a: Mapper.Account, _ id: String) throws -> CoreReplay.Bill? {
    try a.projection.reader.bills().first { $0.id == id }?.bill
  }

  static func bill(_ s: LiveLedgerStore, _ name: String) throws -> HasalaModels.Bill {
    try #require(s.state.bills.first { $0.name == name })
  }

  static func day(_ y: Int, _ m: Int, _ d: Int) -> CivilDate { CivilDate(year: y, month: m, day: d)! }

  @Test func aPriceChangeIsAppendedAndUndone() async throws {
    let a = try Mapper.account()
    let store = try await Self.store(a, suite: "recurring.amount.tests")
    let netflix = try Self.bill(store, "Netflix")
    let token = try #require(
      try store.apply(.editBillAmount(netflix.id, .aed(63_00), approximate: false, from: LocalDate(2026, 12, 6))))
    #expect(store.canUndo(token))
    try await Mapper.eventually { try Self.record(a, netflix.id)?.changes.isEmpty == false }
    let changed = try #require(try Self.record(a, netflix.id))
    #expect(changed.changes == [BillChange(from: "2026-12-06", amountMode: "fixed", amountMinor: 63_00, toleranceBp: 200)])
    #expect(changed.amountMinor == 56_00)
    try await Mapper.eventually { try Self.bill(store, "Netflix").nextAmount != nil }
    let shown = try Self.bill(store, "Netflix")
    #expect(shown.amount == .aed(56_00) && shown.nextAmount == .aed(63_00) && shown.nextAmountFrom == LocalDate(2026, 12, 6))
    store.undo(token)
    try await Mapper.eventually { try Self.record(a, netflix.id)?.changes.isEmpty == true }
    #expect(try Self.record(a, netflix.id)?.changes == [])
  }

  @Test func aPriceChangeFromTheStartReplacesTheTerms() async throws {
    let a = try Mapper.account()
    let store = try await Self.store(a, suite: "recurring.start.tests")
    let netflix = try Self.bill(store, "Netflix")
    try store.apply(.editBillAmount(netflix.id, .aed(60_00), approximate: true, from: LocalDate(2026, 10, 6)))
    try await Mapper.eventually { try Self.record(a, netflix.id)?.amountMinor == 60_00 }
    let r = try #require(try Self.record(a, netflix.id))
    #expect(r.amountMinor == 60_00 && r.amountMode == "variable" && r.changes.isEmpty)
    #expect(throws: ActionError.self) {
      try store.apply(.editBillAmount(netflix.id, .aed(60_00), approximate: false, from: LocalDate(2026, 12, 7)))
    }
  }

  @Test func undoingADeleteKeepsChangesAndPauses() async throws {
    let a = try Mapper.account()
    let store = try await Self.store(a, suite: "recurring.roundtrip.tests")
    let netflix = try Self.bill(store, "Netflix")
    try store.apply(.editBillAmount(netflix.id, .aed(63_00), approximate: false, from: LocalDate(2026, 12, 6)))
    try store.apply(.pauseBill(netflix.id, until: LocalDate(2027, 1, 1)))
    #expect(try Self.bill(store, "Netflix").state == .paused)
    try await Mapper.eventually { try Self.record(a, netflix.id)?.pauses.isEmpty == false }
    #expect(try Self.record(a, netflix.id)?.pauses == [BillPause(from: "2026-10-10", until: "2027-01-01")])
    try await Mapper.eventually { try Self.bill(store, "Netflix").nextDue == LocalDate(2027, 1, 6) }
    let paused = try Self.bill(store, "Netflix")
    #expect(paused.state == .paused)
    #expect(paused.pausedSince == LocalDate(2026, 10, 10) && paused.pausedUntil == LocalDate(2027, 1, 1))
    #expect(paused.nextDue == LocalDate(2027, 1, 6))
    let token = try #require(try store.apply(.deleteBill(netflix.id)))
    try await Mapper.eventually { try Self.record(a, netflix.id)?.status == "dismissed" }
    #expect(try Self.bill(store, "Netflix").state == .dismissed)
    store.undo(token)
    try await Mapper.eventually { try Self.record(a, netflix.id)?.status == "active" }
    let back = try #require(try Self.record(a, netflix.id))
    #expect(back.changes.map(\.from) == ["2026-12-06"])
    #expect(back.pauses == [BillPause(from: "2026-10-10", until: "2027-01-01")])
    try await Mapper.eventually { try Self.bill(store, "Netflix").state == .paused }
    try store.apply(.resumeBill(netflix.id))
    try await Mapper.eventually { try Self.record(a, netflix.id)?.pauses.isEmpty == true }
    try await Mapper.eventually { try Self.bill(store, "Netflix").state == .tracked }
    #expect(try Self.bill(store, "Netflix").state == .tracked)
    #expect(try Self.record(a, netflix.id)?.changes.count == 1)
  }

  @Test func endingThenTrackingAgainPausesTheGap() async throws {
    let a = try Mapper.account()
    let clock = Clock()
    let store = try await Self.store(a, suite: "recurring.end.tests", clock: clock)
    let netflix = try Self.bill(store, "Netflix")
    try store.apply(.editBillAmount(netflix.id, .aed(63_00), approximate: false, from: LocalDate(2026, 12, 6)))
    let ended = try #require(try store.apply(.endBill(netflix.id, lastPayment: LocalDate(2026, 11, 6))))
    #expect(store.canUndo(ended))
    try await Mapper.eventually { try Self.record(a, netflix.id)?.status == "cancelled" }
    let r = try #require(try Self.record(a, netflix.id))
    #expect(r.end == "2026-11-06" && r.changes.isEmpty)
    try await Mapper.eventually { try Self.bill(store, "Netflix").state == .ended }
    #expect(try Self.bill(store, "Netflix").endedOn == LocalDate(2026, 11, 6))
    clock.now = LocalDateTime(2026, 12, 20, 9, 0)
    for _ in 0..<150 where store.now != clock.now {
      await store.reload()
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(store.now == clock.now)
    try store.apply(.reactivateBill(netflix.id))
    try await Mapper.eventually { try Self.record(a, netflix.id)?.status == "active" }
    let again = try #require(try Self.record(a, netflix.id))
    #expect(again.end == nil)
    #expect(again.pauses == [BillPause(from: "2026-11-06", until: "2026-12-20")])
    try await Mapper.eventually { try Self.bill(store, "Netflix").state == .tracked }
    #expect(try Self.bill(store, "Netflix").nextDue == LocalDate(2027, 1, 6))
  }

  @Test func undoingAnEndBringsBackThePriceChange() async throws {
    let a = try Mapper.account()
    let store = try await Self.store(a, suite: "recurring.endundo.tests")
    let netflix = try Self.bill(store, "Netflix")
    try store.apply(.editBillAmount(netflix.id, .aed(63_00), approximate: false, from: LocalDate(2026, 12, 6)))
    let token = try #require(try store.apply(.stopTrackingBill(netflix.id)))
    try await Mapper.eventually { try Self.record(a, netflix.id)?.status == "cancelled" }
    #expect(try Self.record(a, netflix.id)?.changes == [])
    store.undo(token)
    try await Mapper.eventually { try Self.record(a, netflix.id)?.status == "active" }
    #expect(try Self.record(a, netflix.id)?.changes.map(\.amountMinor) == [63_00])
  }

  @Test func addingABillWithAPastPaymentMovesItsStartBack() async throws {
    let a = try Mapper.account()
    let store = try await Self.store(a, suite: "recurring.add.tests")
    let paid = try #require(
      store.state.txns.first {
        $0.direction == .out && !$0.archived && !$0.isTransfer && !$0.isRefund && !$0.isHeldCopy && $0.billID == nil
          && $0.postedAt.date < MayaLedger.now.date && $0.postedAt.date.day <= 28
      })
    let d = paid.postedAt.date
    let later = d.yearMonth.adding(months: 2)
    let draft = BillDraft(
      name: "  Gym Club ", amount: paid.amount, firstDue: LocalDate(later.year, later.month, d.day),
      categoryID: "subscriptions", linkTxns: [paid.id])
    let token = try #require(try store.apply(.addBill(draft)))
    #expect(store.canUndo(token))
    func added() throws -> (id: String, bill: CoreReplay.Bill)? {
      try a.projection.reader.bills().first { $0.bill.name == "Gym Club" }
    }
    try await Mapper.eventually { try added() != nil }
    let (id, b) = try #require(try added())
    #expect(id.hasPrefix("bm_"))
    #expect(b.start == Self.day(d.year, d.month, d.day).wire)
    #expect(b.anchor == Self.day(later.year, later.month, d.day).wire)
    #expect(b.keys == [Canon.merchantKey("Gym Club")] && b.source == "manual" && b.status == "active")
    let links = try a.projection.reader.billResolutions(bill: id)
    #expect(links.map(\.txn) == [paid.id] && links.map(\.due) == [b.start])
    try await Mapper.eventually { try Self.bill(store, "Gym Club").payments.count == 1 }
    let shown = try Self.bill(store, "Gym Club")
    try await Mapper.eventually { store.state.txn(paid.id)?.billID == id }
    #expect(shown.payments.first?.link == .linked && shown.source == .manual)
    #expect(store.state.txn(paid.id)?.billID == id)
    store.undo(token)
    try await Mapper.eventually { try added()?.bill.status == "dismissed" }
    #expect(try a.projection.reader.billResolutions(bill: id).isEmpty)
    try await Mapper.eventually { store.state.txn(paid.id)?.billID == nil }
    #expect(store.state.txn(paid.id)?.billID == nil)
  }

  @Test func aPaymentLinkedToAnotherBillIsRefused() async throws {
    let a = try Mapper.account()
    let store = try await Self.store(a, suite: "recurring.link.tests")
    let du = try Self.bill(store, "du")
    let netflix = try Self.bill(store, "Netflix")
    let taken = try #require(du.payments.first { $0.txnID != nil }?.txnID)
    #expect(throws: ActionError.self) { try store.apply(.linkBillPayments(netflix.id, [taken])) }
  }

  @Test func editingIncomeIsAuthoredAndUndone() async throws {
    let a = try Mapper.account()
    let store = try await Self.store(a, suite: "recurring.income.tests")
    let salary = try #require(store.state.bills.first { $0.isIncome })
    let token = try #require(try store.apply(.editIncome(id: salary.id, amount: .aed(26_000_00), payday: 25, active: true)))
    #expect(store.canUndo(token))
    func source() throws -> IncomeSource? { try a.projection.reader.incomeSources().first { $0.id == "salary" } }
    try await Mapper.eventually { try source()?.amountMinor == 26_000_00 }
    #expect(try source()?.payday == 25 && source()?.name == "Salary · Acme Gulf")
    store.undo(token)
    try await Mapper.eventually { try source()?.amountMinor == 25_000_00 }
    #expect(try source()?.payday == 28 && source()?.active == true)
    try store.apply(.editIncome(id: salary.id, amount: .aed(25_000_00), payday: 28, active: false))
    try await Mapper.eventually { try source()?.active == false }
    try await Mapper.eventually { store.state.bills.first { $0.isIncome }?.state == .ended }
    #expect(store.state.bills.first { $0.isIncome }?.id == salary.id)
  }

  @Test func oldShapedBillsMapAsBefore() async throws {
    let live = try await Mapper.foldedState()
    let rent = try #require(live.bills.first { $0.name == "Rent · Al Habtoor" })
    #expect(rent.amount == .aed(7_500_00) && !rent.approximate && rent.state == .tracked)
    #expect(rent.nextDue == LocalDate(2026, 11, 1) && rent.usualDay == 1 && rent.history == [LocalDate(2026, 10, 1)])
    #expect(rent.cadence == .monthly && rent.every == 1 && rent.source == .detected && rent.keys == ["al habtoor"])
    #expect(rent.nextAmount == nil && rent.pausedSince == nil && rent.endedOn == nil)
    #expect(rent.payments.map(\.link) == [.linked])
    let du = try #require(live.bills.first { $0.name == "du" })
    #expect(du.priceChangeFrom == .aed(389_00))
    let dewa = try #require(live.bills.first { $0.name == "DEWA" })
    #expect(dewa.approximate && dewa.nextDue == LocalDate(2026, 10, 14))
    #expect(live.txns.allSatisfy { $0.merchantKey != nil })
  }

  @Test func aDismissedNoticeStaysDismissedOnThisDevice() {
    let suite = "recurring.notice.tests"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    let prefs = DevicePrefsStore(defaults: defaults)
    prefs.dismissNotice("priceChange.t1")
    let notices = [
      BillNotice(id: "priceChange.t1", kind: .chargedWhilePaused(charged: .aed(5_00), on: LocalDate(2026, 10, 1))),
      BillNotice(id: "priceChange.t2", kind: .chargedWhilePaused(charged: .aed(5_00), on: LocalDate(2026, 10, 2))),
    ]
    let kept = LedgerStateMapper.notices(notices, dismissed: prefs.dismissedNoticeDigests, salt: prefs.salt)
    #expect(kept.map(\.id) == ["priceChange.t2"])
    #expect(!(defaults.stringArray(forKey: "prefs.bills.notices.dismissed.v1") ?? []).contains("priceChange.t1"))
  }

  static func wall(_ y: Int, _ m: Int, _ d: Int) throws -> Int64 {
    try LedgerEditAuthor.localWallMs(LocalDateTime(y, m, d, 10, 0))
  }

  static func gym(
    start: CivilDate = day(2026, 7, 15), amount: Int64 = 200_00, status: OpAuthor.BillStatus = .active,
    end: CivilDate? = nil, pauses: [OpAuthor.BillPauseDraft] = []
  ) -> OpAuthor.BillDraft {
    OpAuthor.BillDraft(
      name: "Gym Club", keys: ["gym club"], mode: .fixed(toleranceBp: 200), amountMinor: amount, anchor: start, start: start,
      end: end, category: "subscriptions", source: .manual, status: status, pauses: pauses)
  }

  @Test func matchedPaymentsPayTheirDues() async throws {
    var ids: [String] = []
    let live = try await Mapper.foldedState { o throws(AuthorError) in
      try o.setBill(id: "bm_gym", Self.gym())
      for (m, amount) in [(7, Int64(200_00)), (8, 200_00), (9, 230_00)] {
        ids.append(try o.manualEntry(amountMinor: amount, currency: "AED", direction: "debit", localWallMs: try! Self.wall(2026, m, 16), merchant: "Gym Club", category: "subscriptions"))
      }
      ids.append(try o.manualEntry(amountMinor: 550_00, currency: "AED", direction: "debit", localWallMs: try! Self.wall(2026, 10, 8), merchant: "AXA Insurance", category: "insurance"))
    }
    let gym = try #require(live.bills.first { $0.id == "bm_gym" })
    #expect(gym.payments.map(\.due) == [LocalDate(2026, 9, 15), LocalDate(2026, 8, 15), LocalDate(2026, 7, 15)])
    #expect(gym.payments.allSatisfy { $0.link == .matched })
    #expect(gym.payments.map(\.txnID) == [ids[2], ids[1], ids[0]])
    #expect(gym.nextDue == LocalDate(2026, 10, 15))
    #expect(live.txn(ids[0])?.billID == "bm_gym")
    #expect(gym.priceChangeFrom == .aed(200_00) && gym.amount == .aed(230_00))
    #expect(gym.notices.map(\.id) == ["priceChange.\(ids[2])"])
    #expect(gym.notices.first?.kind == .priceChange(usual: .aed(200_00), charged: .aed(230_00), from: LocalDate(2026, 9, 15)))
    let axa = try #require(live.bills.first { $0.name == "AXA Insurance" })
    #expect(axa.nextDue == LocalDate(2026, 11, 7))
    #expect(axa.payments.first?.link == .matched && axa.payments.first?.txnID == ids[3])
    #expect(BillsEngine.snapshot(live, now: MayaLedger.now).next14 == .aed(719_15))
  }

  static func folded(_ extra: (inout OpAuthor) throws(AuthorError) -> Void) async throws -> Mapper.Account {
    let a = try Mapper.account()
    var blobs = try await Mapper.seed(a)
    if let more = try a.observer.stamps.build(try await a.observer.authorContext(), extra) { blobs.append(more) }
    var rows: [FoldRow] = []
    for (i, b) in blobs.enumerated() {
      let plaintext = Data(try OpCodec.encodeBlobOps(b.ops))
      rows.append(
        FoldRow(seq: Int64(i + 1), writerID: Mapper.writer.string, counter: Int64(i + 1), outcome: .opened(plaintext: plaintext, ops: b.ops)))
    }
    let state = try LedgerFold.page(rows, onto: State())
    try a.projection.project(
      state, pending: [], writerID: Mapper.writer.string, dictionary: AccountRuntime.dictionary, projectedAtMs: Mapper.anchor)
    return a
  }

  @Test func aDismissedPriceNoticeKeepsTheUsualAmount() async throws {
    var txn = ""
    let a = try await Self.folded { o throws(AuthorError) in
      try o.setBill(id: "bm_gym", Self.gym())
      txn = try o.manualEntry(amountMinor: 230_00, currency: "AED", direction: "debit", localWallMs: try! Self.wall(2026, 9, 15), merchant: "Gym Club", category: "subscriptions")
    }
    var c = Mapper.context()
    c.digestSalt = "salt"
    let before = try #require(try LedgerStateMapper.map(a.projection.reader, context: c).bills.first { $0.id == "bm_gym" })
    #expect(before.notices.map(\.id) == ["priceChange.\(txn)"] && before.priceChangeFrom == .aed(200_00))
    c.dismissedNotices = [LocalAccountData.digest("priceChange.\(txn)", salt: "salt")]
    let gym = try #require(try LedgerStateMapper.map(a.projection.reader, context: c).bills.first { $0.id == "bm_gym" })
    #expect(gym.payments.map(\.txnID) == [txn])
    #expect(gym.notices.isEmpty && gym.priceChangeFrom == nil && gym.amount == .aed(200_00))
  }

  @Test func chargesWhilePausedAndAfterTheEndRaiseNotices() async throws {
    var ids: [String] = []
    let live = try await Mapper.foldedState { o throws(AuthorError) in
      try o.setBill(id: "bm_paused", Self.gym(pauses: [OpAuthor.BillPauseDraft(from: Self.day(2026, 9, 1))]))
      ids.append(try o.manualEntry(amountMinor: 200_00, currency: "AED", direction: "debit", localWallMs: try! Self.wall(2026, 9, 15), merchant: "Gym Club", category: "subscriptions"))
      var ended = Self.gym(status: .cancelled, end: Self.day(2026, 9, 6))
      ended.name = "Yoga"
      ended.keys = ["yoga house"]
      ended.anchor = Self.day(2026, 7, 6)
      ended.start = Self.day(2026, 7, 6)
      try o.setBill(id: "bm_ended", ended)
      ids.append(try o.manualEntry(amountMinor: 200_00, currency: "AED", direction: "debit", localWallMs: try! Self.wall(2026, 10, 7), merchant: "Yoga House", category: "subscriptions"))
    }
    let paused = try #require(live.bills.first { $0.id == "bm_paused" })
    #expect(paused.state == .paused)
    #expect(paused.payments.map(\.due) == [LocalDate(2026, 9, 15)])
    #expect(paused.notices.map(\.id) == ["chargedWhilePaused.\(ids[0])"])
    #expect(paused.notices.first?.kind == .chargedWhilePaused(charged: .aed(200_00), on: LocalDate(2026, 9, 15)))
    let ended = try #require(live.bills.first { $0.id == "bm_ended" })
    #expect(ended.state == .ended)
    #expect(ended.notices.map(\.id) == ["chargedAfterEnd.\(ids[1])"])
    #expect(ended.notices.first?.kind == .chargedAfterEnd(charged: .aed(200_00), on: LocalDate(2026, 10, 7)))
  }

  @Test func thePlanReadsTheBillsOfTheMonth() async throws {
    let a = try Mapper.account()
    for b in try await Mapper.seed(a) { try await a.outbox.enqueue(b.ops) }
    try await a.observer.reproject()
    let r = a.projection.reader
    let today = Self.day(2026, 10, 10)
    var rows = try r.activity(limit: 1_000_000)
    rows += try r.archived(limit: 1_000_000)
    let records = try r.bills()
    let derived = LedgerStateMapper.derive(records, resolutions: try r.billResolutions(), rows: rows, today: today)
    let roles = CoreDomain.PlanEngine(plan: try r.planState(), taxonomy: try r.taxonomy(), lines: [], today: today)
    let got = LedgerStateMapper.expectations(
      records, derived: derived, month: today.yearMonth, today: today, home: "AED", role: { roles.role($0) })
    let shown = got.map { "\($0.payee) \($0.expectedDay.wire) \($0.amount) \($0.status.rawValue) \($0.isEstimate)" }.sorted()
    #expect(
      shown == [
        "AXA Insurance 2026-10-07 55000 late false", "DEWA 2026-10-14 48915 upcoming true", "Netflix 2026-10-06 5600 paid false",
        "Rent · Al Habtoor 2026-10-01 750000 paid false", "Spotify 2026-10-08 2199 paid false", "du 2026-10-05 38900 paid false",
      ])
    #expect(got.first { $0.payee == "Netflix" }?.paidDay == Self.day(2026, 10, 6))
    let engine = try r.planEngine(month: today.yearMonth, today: today, bills: got)
    #expect(engine.hero(today.yearMonth).billsToCome == 1_039_15)
  }

  static func storeWith(
    _ a: Mapper.Account, suite: String, extra: @escaping (inout OpAuthor) throws(AuthorError) -> Void
  ) async throws -> LiveLedgerStore {
    for b in try await Mapper.seed(a) { try await a.outbox.enqueue(b.ops) }
    if let blob = try a.observer.stamps.build(try await a.observer.authorContext(), extra) {
      try await a.outbox.enqueue(blob.ops)
    }
    try await a.observer.reproject()
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    let store = LiveLedgerStore(
      reader: a.projection.reader, author: LedgerEditAuthor(observer: a.observer, outbox: a.outbox),
      profile: Mapper.context().profile, prefs: DevicePrefsStore(defaults: defaults), clock: { MayaLedger.now })
    await store.reload()
    return store
  }

  static func gymSeries(_ o: inout OpAuthor) throws(AuthorError) {
    for (m, amount) in [(6, Int64(56_00)), (7, 56_00), (8, 56_00), (9, 63_00), (10, 63_00)] {
      _ = try o.manualEntry(amountMinor: amount, currency: "AED", direction: "debit", localWallMs: try! wall(2026, m, 3), merchant: "Gym Club", category: "subscriptions")
    }
  }

  @Test func aCandidateIsTrackedAndTheUndoProposesItAgain() async throws {
    let a = try Mapper.account()
    let store = try await Self.storeWith(a, suite: "recurring.track.tests") { o throws(AuthorError) in try Self.gymSeries(&o) }
    let id = OpAuthor.detectedBillID(key: "gym club", direction: "debit", currency: "AED")
    let c = try #require(store.state.billCandidates.first { $0.id == id })
    #expect(c.amount == .aed(63_00) && c.seenCount == 5 && c.everyDays == 30 && c.last == LocalDate(2026, 10, 3))
    #expect(c.categoryID == "subscriptions")
    let token = try #require(try store.apply(.trackCandidate(id)))
    #expect(token.title == "Tracking Gym Club" && store.canUndo(token))
    #expect(!store.state.billCandidates.contains { $0.id == id })
    #expect(store.state.bills.contains { $0.id == id && $0.state == .tracked })
    try await Mapper.eventually { try Self.record(a, id) != nil }
    let r = try #require(try Self.record(a, id))
    #expect(r.source == "detected" && r.status == "active" && r.keys == ["gym club"] && r.amountMinor == 63_00)
    #expect(r.start == "2026-06-03" && r.anchor == "2026-10-03" && r.cadence.unit == "month" && r.amountMode == "fixed")
    try await Mapper.eventually { try Self.bill(store, "Gym Club").payments.count == 5 }
    let tracked = try Self.bill(store, "Gym Club")
    #expect(tracked.payments.allSatisfy { $0.link == .matched } && tracked.nextDue == LocalDate(2026, 11, 3))
    #expect(!store.state.billCandidates.contains { $0.id == id })
    store.undo(token)
    try await Mapper.eventually { try Self.record(a, id)?.status == "dismissed" }
    #expect(try Self.record(a, id)?.keys == [id])
    try await Mapper.eventually { store.state.billCandidates.contains { $0.id == id } }
    #expect(store.state.billCandidates.contains { $0.id == id })
    try store.apply(.trackCandidate(id))
    try await Mapper.eventually { try Self.record(a, id)?.status == "active" }
    #expect(try Self.record(a, id)?.version == 3 && Self.record(a, id)?.keys == ["gym club"])
  }

  @Test func notABillIsWrittenAndUndone() async throws {
    let a = try Mapper.account()
    let store = try await Self.storeWith(a, suite: "recurring.notabill.tests") { o throws(AuthorError) in try Self.gymSeries(&o) }
    let id = OpAuthor.detectedBillID(key: "gym club", direction: "debit", currency: "AED")
    #expect(store.state.billCandidates.contains { $0.id == id })
    let token = try #require(try store.apply(.dismissCandidate(id)))
    #expect(store.canUndo(token))
    #expect(!store.state.billCandidates.contains { $0.id == id })
    try await Mapper.eventually { try Self.record(a, id)?.status == "dismissed" }
    #expect(try Self.record(a, id)?.keys == ["gym club"] && Self.record(a, id)?.source == "detected")
    try await Mapper.eventually { store.state.bills.first { $0.id == id }?.state == .dismissed }
    #expect(!store.state.billCandidates.contains { $0.id == id })
    #expect(store.state.bills.first { $0.id == id }?.state == .dismissed)
    store.undo(token)
    try await Mapper.eventually { try Self.record(a, id)?.keys == [id] }
    try await Mapper.eventually { store.state.billCandidates.contains { $0.id == id } }
    #expect(store.state.billCandidates.contains { $0.id == id })
    #expect(throws: ActionError.notFound) { try store.apply(.dismissCandidate("bd_nope")) }
  }

  @Test func aForkShowsTheReplacedChangeAndReappliesIt() async throws {
    let a = try Mapper.account()
    let seeded = try await Self.store(a, suite: "recurring.fork.seed")
    let id = try Self.bill(seeded, "Netflix").id
    let record = try #require(try Self.record(a, id))
    var mine = try #require(LedgerEditAuthor.draft(record))
    mine.changes = [OpAuthor.BillChangeDraft(from: Self.day(2026, 12, 6), terms: OpAuthor.BillTermsDraft(mode: .fixed(toleranceBp: 200), amountMinor: 63_00))]
    var theirs = try #require(LedgerEditAuthor.draft(record))
    theirs.pauses = [OpAuthor.BillPauseDraft(from: Self.day(2026, 10, 10))]
    let m = mine
    let t = theirs
    let v = record.version
    let blob = try #require(
      try a.observer.stamps.build(try await a.observer.authorContext()) { o throws(AuthorError) in
        try o.setBill(id: id, parentVersion: v, m)
        try o.setBill(id: id, parentVersion: v, t)
      })
    try await a.outbox.enqueue(blob.ops)
    try await a.observer.reproject()
    let loser = blob.ops[0].opID
    #expect(try a.projection.reader.forkNotices(kind: "bill").map(\.loserOp) == [loser])
    await seeded.reload()
    let forked = try Self.bill(seeded, "Netflix")
    #expect(forked.state == .paused)
    let card = try #require(forked.notices.first { $0.id == "fork.\(loser)" })
    #expect(card.kind == .changedOnTwoDevices(summary: "Amount 63.00 from 6 Dec"))
    let token = try #require(try seeded.apply(.reapplyBill(id)))
    #expect(token.title == "Re-applied your change" && seeded.canUndo(token))
    try await Mapper.eventually { try Self.record(a, id)?.changes.isEmpty == false }
    let back = try #require(try Self.record(a, id))
    #expect(back.changes.map(\.amountMinor) == [63_00] && back.pauses.isEmpty)
    try await Mapper.eventually { try Self.bill(seeded, "Netflix").notices.isEmpty }
    #expect(try Self.bill(seeded, "Netflix").notices.isEmpty)
    seeded.undo(token)
    try await Mapper.eventually { try Self.record(a, id)?.pauses.isEmpty == false }
    try await Mapper.eventually { try Self.bill(seeded, "Netflix").notices.contains { $0.id == "fork.\(loser)" } }
    #expect(try Self.bill(seeded, "Netflix").notices.map(\.id) == ["fork.\(loser)"])
  }

  @Test func forkSummariesSayWhatTheReplacedVersionChanged() throws {
    let base = BillEdits.record(Self.draft())
    var loser = base
    #expect(LedgerStateMapper.forkSummary(loser: loser, current: base) == nil)
    loser.status = "cancelled"
    loser.end = "2026-11-06"
    #expect(LedgerStateMapper.forkSummary(loser: loser, current: base) == "Ended 6 Nov")
    loser = base
    loser.status = "dismissed"
    #expect(LedgerStateMapper.forkSummary(loser: loser, current: base) == "Deleted")
    loser = base
    loser.pauses = [BillPause(from: "2026-11-01", until: nil)]
    #expect(LedgerStateMapper.forkSummary(loser: loser, current: base) == "Paused")
    loser = base
    loser.amountMinor = 60_00
    loser.name = "Netflix Premium"
    #expect(LedgerStateMapper.forkSummary(loser: loser, current: base) == "Name Netflix Premium, Amount 60.00")
    loser = base
    loser.category = "entertainment"
    #expect(LedgerStateMapper.forkSummary(loser: loser, current: base) == "Other details")
  }

  @Test func theDerivedBillsStayFastOverThousandsOfRows() async throws {
    let merchants = (0..<20).map { "Merchant \($0)" }
    let a = try await Self.folded { o throws(AuthorError) in
      for (i, name) in merchants.enumerated() {
        var d = Self.gym(start: Self.day(2024, 1, 1 + i))
        d.name = name
        d.keys = [Canon.merchantKey(name)]
        try o.setBill(id: "bm_perf\(i)", d)
      }
      for k in 0..<3_000 {
        let name = merchants[k % merchants.count]
        let day = Self.day(2024, 1, 1).adding(days: k / 3)!
        _ = try o.manualEntry(
          amountMinor: 200_00 + Int64(k % 7), currency: "AED", direction: "debit", localWallMs: try! Self.wall(day.year, day.month, day.day),
          merchant: name, category: "subscriptions")
      }
    }
    let r = a.projection.reader
    var rows = try r.activity(limit: 1_000_000)
    rows += try r.archived(limit: 1_000_000)
    #expect(rows.count > 3_000)
    let records = try r.bills()
    let resolutions = try r.billResolutions()
    let clock = ContinuousClock()
    let started = clock.now
    let derived = LedgerStateMapper.derive(records, resolutions: resolutions, rows: rows, today: Self.day(2026, 10, 10))
    let took = clock.now - started
    #expect(took < .milliseconds(1_500))
    #expect(derived.matched.filter { $0.key.hasPrefix("bm_perf") }.count == 20)
    let live = try LedgerStateMapper.map(r, context: Mapper.context())
    #expect(live.bills.filter { $0.id.hasPrefix("bm_perf") }.allSatisfy { $0.payments.count > 10 })
  }

  static func draft(start: CivilDate = day(2026, 10, 6)) -> OpAuthor.BillDraft {
    OpAuthor.BillDraft(
      name: "Netflix", keys: ["netflix.com"], mode: .fixed(toleranceBp: 200), amountMinor: 56_00, anchor: day(2026, 11, 6),
      start: start)
  }

  @Test func theDraftEditsKeepTheGrammar() throws {
    var d = Self.draft()
    try BillEdits.end(&d, lastPayment: Self.day(2026, 10, 6))
    #expect(d.end == Self.day(2026, 10, 7) && d.status == .cancelled)
    d = Self.draft()
    try BillEdits.pause(&d, today: Self.day(2026, 10, 10), until: nil)
    #expect(throws: LedgerEditAuthor.Failure.self) { try BillEdits.pause(&d, today: Self.day(2026, 10, 11), until: nil) }
    try BillEdits.end(&d, lastPayment: Self.day(2026, 11, 6))
    #expect(d.pauses == [OpAuthor.BillPauseDraft(from: Self.day(2026, 10, 10), until: Self.day(2026, 11, 6))])
    try BillEdits.reactivate(&d, today: Self.day(2026, 11, 6))
    #expect(d.pauses.count == 1 && d.end == nil && d.status == .active)
    d = Self.draft()
    #expect(throws: LedgerEditAuthor.Failure.self) {
      try BillEdits.editAmount(&d, amountMinor: 1, currency: "AED", variable: false, from: Self.day(2026, 11, 7))
    }
    #expect(throws: LedgerEditAuthor.Failure.self) {
      try BillEdits.editAmount(&d, amountMinor: 1, currency: "USD", variable: false, from: Self.day(2026, 11, 6))
    }
    try BillEdits.editAmount(&d, amountMinor: 60_00, currency: "AED", variable: false, from: Self.day(2026, 12, 6))
    try BillEdits.editAmount(&d, amountMinor: 61_00, currency: "AED", variable: false, from: Self.day(2026, 12, 6))
    #expect(d.changes.map(\.terms.amountMinor) == [61_00])
    #expect(BillEdits.nearestUnbounded(d, to: Self.day(2026, 8, 20)) == Self.day(2026, 8, 6))
    #expect(BillEdits.nearestUnbounded(d, to: Self.day(2026, 8, 22)) == Self.day(2026, 9, 6))
    #expect(BillEdits.keys(name: "Gym  Club", given: []) == ["gym club"])
  }
}
