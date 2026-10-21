import CoreCategorize
import CoreDomain
import CoreProjection
import CoreReplay
import CoreTime
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
    try await Mapper.eventually { try Self.bill(store, "Netflix").state == .paused }
    let paused = try Self.bill(store, "Netflix")
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
