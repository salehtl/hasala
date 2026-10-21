import HasalaMocks
import HasalaModels
import Testing

@MainActor
@Suite("Bills engine · recurring items")
struct RecurringEngineTests {
  let s = MayaLedger.state
  let now = MayaLedger.now
  var today: LocalDate { now.date }

  func appleDraft(_ minor: Int64 = 14_99, approximate: Bool = false) -> BillDraft {
    BillDraft(name: "Apple", keys: ["apple.com"], amount: .aed(minor), approximate: approximate,
              firstDue: LocalDate(2026, 11, 8), categoryID: "subscriptions")
  }

  func gym(_ id: String, _ date: LocalDate, _ minor: Int64 = 300_00) -> Txn {
    Txn(id: id, merchant: "Gym", amount: .aed(minor), postedAt: LocalDateTime(date: date, hour: 7, minute: 0),
        accountID: "enbd", merchantKey: "gym")
  }

  @Test func dueDatesClampAndCrossYears() {
    #expect(BillDueDates.shift(LocalDate(2026, 1, 31), day: 31, cadence: .monthly, every: 1, by: 1)
      == LocalDate(2026, 2, 28))
    #expect(BillDueDates.shift(LocalDate(2026, 1, 15), day: 15, cadence: .monthly, every: 1, by: -1)
      == LocalDate(2025, 12, 15))
    #expect(BillDueDates.shift(LocalDate(2026, 3, 10), day: 10, cadence: .monthly, every: 2, by: -2)
      == LocalDate(2025, 11, 10))
    #expect(BillDueDates.shift(LocalDate(2024, 2, 29), day: 29, cadence: .yearly, every: 1, by: 1)
      == LocalDate(2025, 2, 28))
    #expect(BillDueDates.shift(LocalDate(2026, 10, 10), day: 10, cadence: .weekly, every: 2, by: 1)
      == LocalDate(2026, 10, 24))
    let netflix = s.bill("netflix")!
    #expect(BillDueDates.nearest(netflix, to: LocalDate(2026, 9, 22)) == LocalDate(2026, 10, 6))
    #expect(BillDueDates.nearest(netflix, to: LocalDate(2026, 9, 21)) == LocalDate(2026, 9, 6))
    #expect(BillDueDates.first(netflix, onOrAfter: LocalDate(2026, 10, 7)) == LocalDate(2026, 11, 6))
  }

  @Test func pastPaymentsMatchKeyAndTolerance() {
    let found = BillsEngine.pastPayments(s, for: appleDraft())
    #expect(found.map(\.id) == ["apple"])
    #expect(found.first?.due == LocalDate(2026, 10, 8))
    #expect(found.first?.account == "DIB card")
    #expect(BillsEngine.pastPayments(s, for: appleDraft(15_50)).isEmpty)
    #expect(BillsEngine.pastPayments(s, for: appleDraft(15_29)).map(\.id) == ["apple"])
    #expect(BillsEngine.pastPayments(s, for: appleDraft(29_00, approximate: true)).map(\.id) == ["apple"])
    #expect(BillsEngine.pastPayments(s, for: appleDraft(30_00, approximate: true)).isEmpty)
  }

  @Test func pastPaymentsSkipRowsThatCannotPay() {
    var draft = appleDraft()
    draft.keys = []
    draft.name = "Apple"
    #expect(BillsEngine.pastPayments(s, for: draft).isEmpty)

    let netflix = BillDraft(name: "Netflix", amount: .aed(56_00), firstDue: LocalDate(2026, 11, 6),
                            categoryID: "subscriptions")
    #expect(BillsEngine.pastPayments(s, for: netflix).isEmpty)

    let changes: [(inout Txn) -> Void] = [
      { $0.archived = true }, { $0.isTransfer = true }, { $0.isRefund = true }, { $0.direction = .in },
      { $0.heldCopy = HeldCopy(of: "x", fromOtherInbox: false) },
    ]
    for change in changes {
      var state = s
      let i = state.txns.firstIndex { $0.id == "apple" }!
      change(&state.txns[i])
      #expect(BillsEngine.pastPayments(state, for: appleDraft()).isEmpty)
    }
  }

  @Test func pastPaymentsAreNewestFirstAndCapped() {
    var state = s
    for n in 0..<30 {
      state.txns.append(gym("gym-\(n)", LocalDate(2026, 10, 1).adding(days: -30 * n)))
    }
    let draft = BillDraft(name: "Gym", keys: ["gym"], amount: .aed(300_00), firstDue: LocalDate(2026, 11, 1),
                          categoryID: "subscriptions")
    let found = BillsEngine.pastPayments(state, for: draft)
    #expect(found.count == 24)
    #expect(found.first?.id == "gym-0")
    #expect(found.map(\.date) == found.map(\.date).sorted(by: >))
  }

  @Test func pastPaymentsSkipDuesAlreadyLinkedAndForeignRowsUseTheirHomeAmount() {
    var state = s
    state.txns.append(gym("gym-a", LocalDate(2026, 10, 1)))
    state.txns.append(gym("gym-b", LocalDate(2026, 9, 1)))
    var usd = gym("gym-usd", LocalDate(2026, 8, 1), 81_69)
    usd.amount = Money(minor: 81_69, currency: "USD")
    usd.homeMinor = 300_00
    usd.homeSource = .rate
    state.txns.append(usd)
    var bill = BillsEngine.bill(from: BillDraft(
      name: "Gym", keys: ["gym"], amount: .aed(300_00), firstDue: LocalDate(2026, 11, 1), categoryID: "subscriptions"))
    #expect(BillsEngine.pastPayments(state, for: bill).map(\.id) == ["gym-a", "gym-b", "gym-usd"])
    bill.payments = [BillPayment(due: LocalDate(2026, 10, 1), txnID: "other", amount: .aed(300_00), link: .linked)]
    #expect(BillsEngine.pastPayments(state, for: bill).map(\.id) == ["gym-b", "gym-usd"])
  }

  @Test func aPaymentPrefillsTheDraft() throws {
    let d = try #require(BillsEngine.draft(from: "apple", s, now: now))
    #expect(d.name == "Apple.com")
    #expect(d.keys == ["apple.com"])
    #expect(d.amount == .aed(14_99))
    #expect(d.firstDue == LocalDate(2026, 11, 8))
    #expect(d.categoryID == "subscriptions")
    #expect(d.accountID == "dib")
    let old = try #require(BillsEngine.draft(from: "carrefour-sep13", s, now: LocalDateTime(2027, 1, 20, 9, 0)))
    #expect(old.firstDue == LocalDate(2027, 2, 13))
    #expect(BillsEngine.recentPayments(s, now: now).contains { $0.id == "apple" })
    #expect(!BillsEngine.recentPayments(s, now: now).contains { $0.id == "netflix" })
  }

  @Test func addingWithASuggestedPaymentLinksIt() throws {
    let ledger = InMemoryLedger()
    var d = appleDraft()
    d.linkTxns = BillsEngine.pastPayments(ledger.state, for: d).map(\.id)
    try ledger.apply(.addBill(d))
    let b = try #require(ledger.state.bills.first { $0.name == "Apple" })
    #expect(b.payments.map(\.link) == [.linked])
    let detail = try #require(BillsEngine.detail(ledger.state, now: ledger.now, bill: b.id))
    #expect(detail.source == .manual)
    #expect(detail.footnote == "You added this one. Nothing is shared with Apple.")
    #expect(detail.history.last?.note == "Linked by you")
    #expect(detail.history.last?.amount == .aed(14_99))
    #expect(detail.history.last?.title == "Thu 8 Oct")
    #expect(BillsEngine.pastPayments(ledger.state, for: b).isEmpty)
  }

  @Test func amountStartsOfferTheLatestPaidDueAndSixMore() throws {
    let netflix = try #require(s.bill("netflix"))
    let starts = BillsEngine.amountStarts(netflix, today: today)
    #expect(starts.first == LocalDate(2026, 10, 6))
    #expect(starts.count == 7)
    #expect(starts.last == LocalDate(2027, 4, 6))
    #expect(BillsEngine.defaultAmountStart(netflix, today: today) == LocalDate(2026, 11, 6))
    let ledger = InMemoryLedger()
    for start in starts {
      #expect(throws: Never.self) {
        try ledger.apply(.editBillAmount("netflix", .aed(63_00), approximate: false, from: start))
      }
    }
  }

  @Test func endChoicesDefaultToTheLatestPaidDue() throws {
    let netflix = try #require(s.bill("netflix"))
    #expect(BillsEngine.endChoices(netflix, today: today) == [today, LocalDate(2026, 10, 6)])
    #expect(BillsEngine.defaultEnd(netflix, today: today) == LocalDate(2026, 10, 6))
    let dewa = try #require(s.bill("dewa"))
    #expect(BillsEngine.defaultEnd(dewa, today: today) == LocalDate(2026, 10, 14))
    #expect(BillsEngine.endChoices(dewa, today: today) == [LocalDate(2026, 10, 14)])

    let ledger = InMemoryLedger()
    try ledger.apply(.addBill(appleDraft()))
    let apple = try #require(ledger.state.bills.first { $0.name == "Apple" })
    let end = BillsEngine.defaultEnd(apple, today: today)
    #expect(end == LocalDate(2026, 11, 8))
    #expect(throws: Never.self) { try ledger.apply(.endBill(apple.id, lastPayment: end)) }
  }

  @Test func pausedAndEndedHaveTheirOwnSections() throws {
    let ledger = InMemoryLedger()
    try ledger.apply(.pauseBill("netflix", until: LocalDate(2027, 1, 1)))
    try ledger.apply(.pauseBill("spotify", until: nil))
    try ledger.apply(.endBill("rent", lastPayment: LocalDate(2026, 10, 1)))
    let snap = BillsEngine.snapshot(ledger.state, now: ledger.now)
    #expect(snap.paused.map(\.name) == ["Netflix", "Spotify"])
    #expect(snap.paused.map(\.detail) == [[.text("Paused until 1 Jan")], [.text("Paused")]])
    #expect(snap.ended.map(\.name) == ["Rent · Al Habtoor"])
    #expect(snap.ended.first?.detail == [.text("Ended 1 Oct")])
    #expect(!snap.upcoming.contains { ["netflix", "spotify", "rent"].contains($0.id) })
    #expect(snap.tracked == 6)
  }

  @Test func aPausedOrEndedBillSaysSo() throws {
    let ledger = InMemoryLedger()
    try ledger.apply(.pauseBill("netflix", until: LocalDate(2027, 1, 1)))
    var d = try #require(BillsEngine.detail(ledger.state, now: ledger.now, bill: "netflix"))
    #expect(d.isPaused)
    #expect(d.pill == StatusPill("Paused", tone: .warning))
    #expect(d.banners.map { $0.text.rendered(hidden: false) } == ["Paused since 10 Oct, until 1 Jan."])
    #expect(d.history.allSatisfy { $0.kind == .paid })

    try ledger.apply(.endBill("netflix", lastPayment: LocalDate(2026, 10, 6)))
    d = try #require(BillsEngine.detail(ledger.state, now: ledger.now, bill: "netflix"))
    #expect(d.isEnded)
    #expect(d.nextDue == nil)
    #expect(d.banners.map { $0.text.rendered(hidden: false) } == ["Ended on 6 Oct. No more payments are expected."])

    try ledger.apply(.deleteBill("netflix"))
    #expect(BillsEngine.detail(ledger.state, now: ledger.now, bill: "netflix") == nil)
  }

  @Test func aScheduledPriceShowsWhenItStarts() throws {
    let ledger = InMemoryLedger()
    try ledger.apply(.editBillAmount("netflix", .aed(63_00), approximate: false, from: LocalDate(2026, 12, 6)))
    let d = try #require(BillsEngine.detail(ledger.state, now: ledger.now, bill: "netflix"))
    #expect(d.banners.map(\.id) == ["nextAmount"])
    #expect(d.banners.first?.text.rendered(hidden: false) == "Changes to 63.00 from 6 Dec")
    #expect(d.banners.first?.text.rendered(hidden: true) == "Changes to •••• from 6 Dec")
  }

  @Test func noticesBecomeCards() throws {
    var state = s
    let du = try #require(BillsEngine.detail(state, now: now, bill: "du"))
    #expect(du.noticed == nil)
    #expect(du.hasPriceNotice)
    let price = try #require(du.notices.first)
    #expect(price.body.rendered(hidden: false) == "Charged 38.90 more than usual (389.00) on Mon 5 Oct.")
    #expect(price.primary == .init(title: "Accept from 5 Oct", action: .acceptPrice(.aed(427_90), from: LocalDate(2026, 10, 5))))
    #expect(price.secondary?.action == .dismiss)

    let i = state.bills.firstIndex { $0.id == "netflix" }!
    state.bills[i].notices = [
      BillNotice(id: "afterEnd.x", kind: .chargedAfterEnd(charged: .aed(56_00), on: LocalDate(2026, 11, 6)), txnID: "x"),
      BillNotice(id: "paused.y", kind: .chargedWhilePaused(charged: .aed(56_00), on: LocalDate(2026, 11, 6))),
      BillNotice(id: "fork.z", kind: .changedOnTwoDevices(summary: "Amount 60.00 on the other iPhone")),
    ]
    let netflix = try #require(BillsEngine.detail(state, now: now, bill: "netflix"))
    #expect(netflix.notices.map(\.title) == ["Charged after you ended it", "Charged while paused", "Changed on two iPhones"])
    #expect(netflix.notices.map(\.primary.action) == [.reactivate, .dismiss, .reapply])
    #expect(netflix.notices.map { $0.secondary?.title } == ["It's fine", nil, "Keep"])
  }

  @Test func acceptingAPriceNoticeClearsIt() throws {
    let ledger = InMemoryLedger()
    let card = try #require(BillsEngine.detail(ledger.state, now: ledger.now, bill: "du")?.notices.first)
    guard case .acceptPrice(let amount, let from) = card.primary.action else {
      Issue.record("not a price card")
      return
    }
    try #require(try ledger.apply(.editBillAmount("du", amount, approximate: false, from: from)))
    let d = try #require(BillsEngine.detail(ledger.state, now: ledger.now, bill: "du"))
    #expect(d.notices.isEmpty)
    #expect(d.state == .upcoming)
  }

  @Test func anArchivedLinkedPaymentShowsItsDateOnly() throws {
    var state = s
    let i = state.txns.firstIndex { $0.id == "netflix" }!
    state.txns[i].archived = true
    let d = try #require(BillsEngine.detail(state, now: now, bill: "netflix"))
    let step = try #require(d.history.first { $0.kind == .paid })
    #expect(step.title == "Tue 6 Oct")
    #expect(step.amount == nil)
  }

  @Test func salaryTerms() throws {
    let terms = try #require(BillsEngine.salary(s, bill: "salary"))
    #expect(terms == SalaryTerms(id: "salary", name: "Salary · Acme Gulf", amount: .aed(25_000_00), payday: 28,
                                 active: true))
    #expect(BillsEngine.salary(s, bill: "netflix") == nil)
    let ledger = InMemoryLedger()
    try ledger.apply(.editIncome(id: "salary", amount: .aed(26_000_00), payday: 25, active: false))
    let after = try #require(BillsEngine.salary(ledger.state, bill: "salary"))
    #expect(after.active == false)
    #expect(after.payday == 25)
    #expect(BillsEngine.snapshot(ledger.state, now: ledger.now).ended.map(\.id) == ["salary"])
  }
}
