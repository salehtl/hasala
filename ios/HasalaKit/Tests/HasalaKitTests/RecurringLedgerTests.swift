import Foundation
import HasalaMocks
import HasalaModels
import Testing

@MainActor
@Suite("In-memory ledger · recurring items")
struct RecurringLedgerTests {
  let today = MayaLedger.now.date

  @Test func mayaBillsCarryKeysPaymentsAndNotices() throws {
    let s = MayaLedger.state
    let netflix = try #require(s.bill("netflix"))
    #expect(netflix.keys == ["netflix"])
    #expect(netflix.payments == [BillPayment(due: LocalDate(2026, 10, 6), txnID: "netflix", amount: .aed(56_00),
                                             link: .matched)])
    #expect(s.bill("axa")?.payments.first == BillPayment(due: LocalDate(2026, 9, 7), amount: .aed(550_00), link: .marked))
    #expect(s.bill("axa")?.payments.contains { $0.due == LocalDate(2026, 7, 7) } == true)
    #expect(s.bill("du")?.notices.map(\.id) == ["priceChange.du"])
    #expect(s.txn("rent")?.merchantKey == "al habtoor")
    #expect(s.bill("rent")?.keys == ["al habtoor"])
  }

  @Test func pauseThenResume() throws {
    let ledger = InMemoryLedger()
    let token = try #require(try ledger.apply(.pauseBill("netflix", until: nil)))
    #expect(token.title == "Paused Netflix")
    #expect(ledger.state.bill("netflix")?.state == .paused)
    #expect(ledger.state.bill("netflix")?.pausedSince == today)
    #expect(throws: ActionError.invalidBill) { try ledger.apply(.pauseBill("netflix", until: nil)) }
    try ledger.apply(.resumeBill("netflix"))
    let b = try #require(ledger.state.bill("netflix"))
    #expect(b.state == .tracked)
    #expect(b.pausedSince == nil && b.pausedUntil == nil)
    #expect(b.nextDue == LocalDate(2026, 11, 6))
    #expect(throws: ActionError.invalidBill) { try ledger.apply(.resumeBill("netflix")) }
  }

  @Test func pauseStartsAfterADueAlreadyPaid() throws {
    let ledger = InMemoryLedger()
    try ledger.apply(.markBillPaid("dewa"))
    #expect(ledger.state.bill("dewa")?.payments.first?.due == LocalDate(2026, 10, 14))
    #expect(throws: ActionError.invalidBill) { try ledger.apply(.pauseBill("dewa", until: LocalDate(2026, 11, 14))) }
    try ledger.apply(.pauseBill("dewa", until: nil))
    let b = try #require(ledger.state.bill("dewa"))
    #expect(b.state == .paused && b.pausedSince == LocalDate(2026, 11, 14))
    #expect(b.payments.first?.due == LocalDate(2026, 10, 14))
  }

  @Test func acceptNeedsAPriceNotice() throws {
    let ledger = InMemoryLedger()
    try ledger.apply(.dismissBillNotice("du", noticeID: "priceChange.du"))
    #expect(throws: ActionError.notFound) { try ledger.apply(.acceptBillAmount("du")) }
    #expect(throws: ActionError.notFound) { try ledger.apply(.acceptBillAmount("netflix")) }
  }

  @Test func pauseUntilADateAndUndo() throws {
    let ledger = InMemoryLedger()
    #expect(throws: ActionError.invalidBill) { try ledger.apply(.pauseBill("netflix", until: today)) }
    let token = try #require(try ledger.apply(.pauseBill("netflix", until: LocalDate(2027, 1, 1))))
    #expect(ledger.state.bill("netflix")?.pausedUntil == LocalDate(2027, 1, 1))
    ledger.undo(token)
    #expect(ledger.state.bill("netflix") == MayaLedger.state.bill("netflix"))
  }

  @Test func endThenReactivateTracksFromThatDay() throws {
    let ledger = InMemoryLedger()
    #expect(throws: ActionError.invalidBill) { try ledger.apply(.endBill("netflix", lastPayment: LocalDate(2026, 1, 1))) }
    try ledger.apply(.pauseBill("netflix", until: nil))
    try #require(try ledger.apply(.endBill("netflix", lastPayment: LocalDate(2026, 10, 6))))
    var b = try #require(ledger.state.bill("netflix"))
    #expect(b.state == .ended)
    #expect(b.endedOn == LocalDate(2026, 10, 6))
    #expect(b.pausedSince == nil)
    #expect(throws: ActionError.invalidBill) { try ledger.apply(.endBill("netflix", lastPayment: today)) }
    #expect(throws: ActionError.invalidBill) { try ledger.apply(.pauseBill("netflix", until: nil)) }
    ledger.setNow(LocalDateTime(2027, 1, 20, 9, 0))
    let token = try #require(try ledger.apply(.reactivateBill("netflix")))
    #expect(token.title == "Tracking Netflix again")
    b = try #require(ledger.state.bill("netflix"))
    #expect(b.state == .tracked)
    #expect(b.endedOn == nil)
    #expect(b.nextDue == LocalDate(2027, 2, 6))
    #expect(b.trackingSince == LocalDate(2027, 1, 20))
    #expect(b.payments.map(\.due) == [LocalDate(2026, 10, 6)])
    #expect(throws: ActionError.invalidBill) { try ledger.apply(.reactivateBill("netflix")) }
  }

  @Test func stopTrackingEndsToday() throws {
    let ledger = InMemoryLedger()
    try ledger.apply(.stopTrackingBill("spotify"))
    #expect(ledger.state.bill("spotify")?.state == .ended)
    #expect(ledger.state.bill("spotify")?.endedOn == today)
    #expect(BillsEngine.snapshot(ledger.state, now: ledger.now).tracked == 8)
  }

  @Test func deleteDismissesAndUndoBringsItBack() throws {
    let ledger = InMemoryLedger()
    let token = try #require(try ledger.apply(.deleteBill("spotify")))
    #expect(token.title == "Spotify is not a bill")
    #expect(ledger.state.bill("spotify")?.state == .dismissed)
    #expect(throws: ActionError.notFound) { try ledger.apply(.deleteBill("spotify")) }
    #expect(throws: ActionError.notFound) { try ledger.apply(.pauseBill("spotify", until: nil)) }
    #expect(throws: ActionError.invalidBill) { try ledger.apply(.deleteBill("salary")) }
    ledger.undo(token)
    #expect(ledger.state.bill("spotify")?.state == .tracked)
  }

  @Test func editAmountFromTheNextDueKeepsPastPayments() throws {
    let ledger = InMemoryLedger()
    let token = try #require(try ledger.apply(.editBillAmount("netflix", .aed(63_00), approximate: false,
                                                              from: LocalDate(2026, 11, 6))))
    let b = try #require(ledger.state.bill("netflix"))
    #expect(b.amount == .aed(63_00))
    #expect(b.nextAmount == nil)
    #expect(b.payments.first?.amount == .aed(56_00))
    #expect(b.history == [LocalDate(2026, 10, 6)])
    ledger.undo(token)
    #expect(ledger.state.bill("netflix")?.amount == .aed(56_00))
  }

  @Test func editAmountFromALaterDueIsScheduled() throws {
    let ledger = InMemoryLedger()
    try ledger.apply(.editBillAmount("netflix", .aed(63_00), approximate: false, from: LocalDate(2026, 12, 6)))
    let b = try #require(ledger.state.bill("netflix"))
    #expect(b.amount == .aed(56_00))
    #expect(b.nextAmount == .aed(63_00))
    #expect(b.nextAmountFrom == LocalDate(2026, 12, 6))
  }

  @Test func editAmountFromAPaidDueClearsThePriceChange() throws {
    let ledger = InMemoryLedger()
    try ledger.apply(.editBillAmount("du", .aed(427_90), approximate: false, from: LocalDate(2026, 10, 5)))
    let b = try #require(ledger.state.bill("du"))
    #expect(b.priceChangeFrom == nil)
    #expect(b.notices.isEmpty)
    #expect(b.payments.first { $0.due == LocalDate(2026, 10, 5) }?.amount == .aed(427_90))
  }

  @Test func editAmountRefusals() {
    let ledger = InMemoryLedger()
    #expect(throws: ActionError.invalidAmount) {
      try ledger.apply(.editBillAmount("netflix", .aed(0), approximate: false, from: LocalDate(2026, 11, 6)))
    }
    #expect(throws: ActionError.invalidAmount) {
      try ledger.apply(.editBillAmount("netflix", Money(minor: 15_00, currency: "USD"), approximate: false,
                                       from: LocalDate(2026, 11, 6)))
    }
    #expect(throws: ActionError.invalidBill) {
      try ledger.apply(.editBillAmount("netflix", .aed(63_00), approximate: false, from: LocalDate(2026, 11, 7)))
    }
    #expect(throws: ActionError.invalidBill) {
      try ledger.apply(.editBillAmount("netflix", .aed(63_00), approximate: false, from: LocalDate(2025, 11, 6)))
    }
    #expect(throws: ActionError.notFound) {
      try ledger.apply(.editBillAmount("nope", .aed(63_00), approximate: false, from: LocalDate(2026, 11, 6)))
    }
    #expect(throws: ActionError.invalidBill) {
      try ledger.apply(.editBillAmount("salary", .aed(63_00), approximate: false, from: LocalDate(2026, 10, 28)))
    }
  }

  @Test func linkPastPayments() throws {
    let ledger = InMemoryLedger(state: MayaHistory.state)
    let token = try #require(try ledger.apply(.linkBillPayments("netflix", ["h-netflix-8", "h-netflix-9"])))
    #expect(token.title == "Linked 2 payments")
    let b = try #require(ledger.state.bill("netflix"))
    #expect(b.payments.map(\.due) == [LocalDate(2026, 10, 6), LocalDate(2026, 9, 6), LocalDate(2026, 8, 6)])
    #expect(b.payments.filter { $0.link == .linked }.map(\.txnID) == ["h-netflix-9", "h-netflix-8"])
    #expect(ledger.state.txn("h-netflix-8")?.billID == "netflix")
    #expect(b.nextDue == LocalDate(2026, 11, 6))
    ledger.undo(token)
    #expect(ledger.state.txn("h-netflix-8")?.billID == nil)
    #expect(ledger.state.bill("netflix")?.payments.count == 1)
  }

  @Test func linkRefusals() {
    let ledger = InMemoryLedger(state: MayaHistory.state)
    #expect(throws: ActionError.invalidBill) { try ledger.apply(.linkBillPayments("netflix", [])) }
    #expect(throws: ActionError.notFound) { try ledger.apply(.linkBillPayments("netflix", ["nope"])) }
    #expect(throws: ActionError.invalidBill) { try ledger.apply(.linkBillPayments("netflix", ["spotify"])) }
    #expect(throws: ActionError.invalidBill) { try ledger.apply(.linkBillPayments("netflix", ["transfer-in"])) }
    #expect(throws: ActionError.invalidBill) {
      try ledger.apply(.linkBillPayments("netflix", ["h-netflix-8", "h-netflix-8"]))
    }
    #expect(throws: ActionError.invalidBill) {
      try ledger.apply(.linkBillPayments("netflix", ["h-netflix-8", "h-vox-8"]))
    }
    #expect(ledger.state.bill("netflix") == MayaHistory.state.bill("netflix"))
  }

  @Test func addAManualBillAndLinkAnEarlierPayment() throws {
    let ledger = InMemoryLedger(state: MayaHistory.state)
    let draft = BillDraft(name: "  Cinema club ", amount: .aed(110_00), firstDue: LocalDate(2026, 11, 2),
                          categoryID: "entertainment", linkTxns: ["h-vox-8"])
    let token = try #require(try ledger.apply(.addBill(draft)))
    #expect(token.title == "Added Cinema club")
    let b = try #require(ledger.state.bills.last)
    #expect(b.name == "Cinema club")
    #expect(b.source == .manual)
    #expect(b.state == .tracked)
    #expect(b.keys == ["cinema club"])
    #expect(b.nextDue == LocalDate(2026, 11, 2))
    #expect(b.trackingSince == today)
    #expect(b.payments == [BillPayment(due: LocalDate(2026, 8, 2), txnID: "h-vox-8", amount: .aed(110_00), link: .linked)])
    ledger.undo(token)
    #expect(ledger.state.bills.count == MayaHistory.state.bills.count)
  }

  @Test func addABillFromALaterDayTracksFromThatDay() throws {
    let ledger = InMemoryLedger()
    try ledger.apply(.addBill(BillDraft(name: "Gym", keys: ["FITNESS FIRST"], amount: .aed(300_00), cadence: .weekly,
                                        every: 2, firstDue: LocalDate(2026, 11, 15), categoryID: "healthcare")))
    let b = try #require(ledger.state.bills.last)
    #expect(b.keys == ["fitness first"])
    #expect(b.cadence == .weekly && b.every == 2)
    #expect(b.trackingSince == LocalDate(2026, 11, 15))
  }

  @Test func addBillRefusals() {
    let ledger = InMemoryLedger()
    let ok = BillDraft(name: "Gym", amount: .aed(300_00), firstDue: LocalDate(2026, 11, 15), categoryID: "healthcare")
    var d = ok
    d.name = "  "
    #expect(throws: ActionError.invalidMerchant) { try ledger.apply(.addBill(d)) }
    d = ok
    d.name = String(repeating: "a", count: 81)
    #expect(throws: ActionError.invalidMerchant) { try ledger.apply(.addBill(d)) }
    d = ok
    d.amount = .aed(0)
    #expect(throws: ActionError.invalidAmount) { try ledger.apply(.addBill(d)) }
    d = ok
    d.every = 25
    #expect(throws: ActionError.invalidBill) { try ledger.apply(.addBill(d)) }
    d.cadence = .weekly
    #expect(d.refusal == nil)
    d.cadence = .yearly
    #expect(d.refusal == .invalidBill)
    d = ok
    d.categoryID = "nope"
    #expect(throws: ActionError.notFound) { try ledger.apply(.addBill(d)) }
    d = ok
    d.linkTxns = ["spotify"]
    #expect(throws: ActionError.invalidBill) { try ledger.apply(.addBill(d)) }
    #expect(ledger.state.bills == MayaLedger.state.bills)
  }

  @Test func editIncomeAppliesFromThisMonth() throws {
    let ledger = InMemoryLedger()
    let token = try #require(try ledger.apply(.editIncome(id: "salary", amount: .aed(26_000_00), payday: 25,
                                                          active: true)))
    #expect(token.title == "Income updated")
    #expect(ledger.state.plan.income == .aed(26_000_00))
    #expect(ledger.state.plan.payday == 25)
    #expect(ledger.state.bill("salary")?.amount == .aed(26_000_00))
    #expect(ledger.state.bill("salary")?.nextDue == LocalDate(2026, 10, 25))
    ledger.undo(token)
    #expect(ledger.state.plan.income == .aed(25_000_00))
    #expect(ledger.state.plan.payday == 28)
    #expect(ledger.state.bill("salary") == MayaLedger.state.bill("salary"))
  }

  @Test func editIncomeRefusalsAndInactive() throws {
    let ledger = InMemoryLedger()
    #expect(throws: ActionError.notFound) {
      try ledger.apply(.editIncome(id: "netflix", amount: .aed(1_00), payday: 1, active: true))
    }
    #expect(throws: ActionError.invalidAmount) {
      try ledger.apply(.editIncome(id: "salary", amount: .aed(0), payday: 1, active: true))
    }
    #expect(throws: ActionError.invalidBill) {
      try ledger.apply(.editIncome(id: "salary", amount: .aed(1_00), payday: 32, active: true))
    }
    try ledger.apply(.editIncome(id: "salary", amount: .aed(25_000_00), payday: 28, active: false))
    #expect(ledger.state.bill("salary")?.state == .ended)
    #expect(ledger.state.plan.income == .aed(0))
  }

  @Test func noticesAreDismissedOnThisDevice() throws {
    let ledger = InMemoryLedger()
    #expect(throws: ActionError.notFound) { try ledger.apply(.dismissBillNotice("du", noticeID: "nope")) }
    #expect(try ledger.apply(.dismissBillNotice("du", noticeID: "priceChange.du")) == nil)
    #expect(ledger.state.bill("du")?.notices.isEmpty == true)
  }

  @Test func reapplyNeedsAForkNotice() throws {
    #expect(throws: ActionError.notFound) { try InMemoryLedger().apply(.reapplyBill("netflix")) }
    var s = MayaLedger.state
    let i = try #require(s.bills.firstIndex { $0.id == "netflix" })
    s.bills[i].notices = [BillNotice(id: "changedOnTwoDevices.op-1",
                                     kind: .changedOnTwoDevices(summary: "AED 56.00 monthly"))]
    let ledger = InMemoryLedger(state: s)
    let token = try #require(try ledger.apply(.reapplyBill("netflix")))
    #expect(ledger.state.bill("netflix")?.notices.isEmpty == true)
    ledger.undo(token)
    #expect(ledger.state.bill("netflix")?.notices.count == 1)
  }

  @Test func trackingACandidateRecordsHowItWasFound() throws {
    let ledger = InMemoryLedger()
    try ledger.apply(.trackCandidate("apple-bill"))
    let b = try #require(ledger.state.bill("bill-apple-bill"))
    #expect(b.source == .detected)
    #expect(b.cadence == .monthly)
    #expect(b.keys == ["apple.com/bill"])
    #expect(b.trackingSince == today)
    #expect(b.payments.map(\.due) == [LocalDate(2026, 10, 8)])
  }

  @Test func markingPaidRecordsAMarkedPayment() throws {
    let ledger = InMemoryLedger()
    try ledger.apply(.markBillPaid("axa"))
    #expect(ledger.state.bill("axa")?.payments.first == BillPayment(due: LocalDate(2026, 10, 7), amount: .aed(550_00),
                                                                    link: .marked))
  }

  @Test func billsDecodeWithoutTheNewKeys() throws {
    let old = #"{"id":"x","name":"X","kind":"K","categoryID":"c","amount":{"minor":100,"currency":"AED"},"approximate":false,"isIncome":false,"usualDay":3,"nextDue":{"year":2026,"month":11,"day":3},"state":"tracked","history":[]}"#
    let b = try JSONDecoder().decode(Bill.self, from: Data(old.utf8))
    #expect(b.source == .detected)
    #expect(b.cadence == .monthly && b.every == 1)
    #expect(b.payments.isEmpty && b.notices.isEmpty && b.keys.isEmpty)
    var du = try #require(MayaLedger.state.bill("du"))
    du.state = .paused
    du.pausedSince = LocalDate(2026, 10, 10)
    let back = try JSONDecoder().decode(Bill.self, from: JSONEncoder().encode(du))
    #expect(back == du)
  }
}
