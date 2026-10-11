import HasalaMocks
import HasalaModels
import Testing

/// The engines over MayaLedger reproduce the Paper boards' figures (spec 04 §15.3), so the
/// screens agree with one another and with the boards.
@Suite("Maya ledger · Paper parity")
struct MayaLedgerParityTests {
  let s = MayaLedger.state
  let now = MayaLedger.now

  @Test func theClockIsSaturdayTenOctober() {
    #expect(now.date.weekdayShort == "Sat")
    #expect(LocalDate(2026, 10, 14).short == "Wed 14 Oct")
    #expect(LocalDate(2026, 10, 9).short == "Fri 9 Oct")
    #expect(LocalDate(2026, 10, 28).short == "Wed 28 Oct")
    #expect(LocalDate(2026, 11, 1).short == "Sun 1 Nov")
    #expect(LocalDate(2026, 10, 10).adding(days: 65) == LocalDate(2026, 12, 14))
    #expect(YearMonth(2026, 10).days == 31)
    #expect(YearMonth(2028, 2).days == 29)
  }

  @Test func homeDerivedFromTheLedgerIsTheHomeBoard() {
    let home = HomeEngine.snapshot(s, now: now)
    #expect(home.hero == Maya.home.hero)
    #expect(home.needsYou == Maya.home.needsYou)
    #expect(home.header == Maya.home.header)
    #expect(home.widgets == Maya.home.widgets)
  }

  @Test func planMatchesPlanOctober() {
    let plan = PlanEngine.snapshot(s, now: now)
    #expect(plan.readyToAssign == .aed(1_000_00))
    #expect(plan.incomeLine.rendered(hidden: false) == "Income 25,000 · planned 24,000")
    #expect(plan.split.map(\.label) == ["51%", "28%", "21%"])
    #expect(plan.startedFrom == "Started from 50 / 30 / 20")
    let needs = plan.sections[0], wants = plan.sections[1], savings = plan.sections[2]
    #expect(MoneyFormat.string(needs.left.minor) == "3,309.20")
    #expect(MoneyFormat.string(wants.left.minor) == "5,402.46")
    #expect(savings.done)
    #expect(needs.rows.map(\.name) == ["Rent", "Utilities", "Groceries", "Transport", "Healthcare", "Insurance"])
    #expect(wants.rows.map(\.name) == ["Dining", "Entertainment", "Shopping", "Travel", "Subscriptions"])
    #expect(savings.rows.map(\.name) == ["Savings", "Investments", "Emergency fund"])

    func detail(_ id: CategoryID) -> String {
      plan.row(id)!.detail.map { part in
        switch part {
        case .text(let p): p.rendered(hidden: false)
        case .status(let t, _): "● " + t
        }
      }.joined(separator: " · ")
    }
    #expect(detail("rent") == "● Paid 1 Oct · bill")
    #expect(detail("utilities") == "427.90 of 900 · DEWA ~489.15 due Wed")
    #expect(detail("groceries") == "812.40 of 2,200 · ● Over pace")
    #expect(detail("transport") == "214.50 of 900")
    #expect(detail("insurance") == "● AXA Insurance · 3 days late · usually the 7th")
    #expect(detail("dining") == "642.75 of 1,600 · ● Over pace")
    #expect(detail("travel") == "Nothing yet · 2,500 planned")
    #expect(detail("subscriptions") == "Netflix and Spotify paid · 77.99 of 350")
    #expect(detail("savings") == "3,000 of 3,000 · Standing order 2 Oct")
    #expect(detail("emergency-fund") == "38,500 of 50,000 · by Jan 2027")
    #expect(plan.row("groceries")?.trailing == .left(.aed(1_387_60)))
    #expect(plan.row("subscriptions")?.trailing == .left(.aed(272_01)))
    #expect(plan.row("investments")?.trailing == .done)
    #expect(plan.row("emergency-fund")?.trailing == .percent(77))
    #expect(plan.row("rent")?.paced == false)

    let japan = plan.projects[0]
    #expect(japan.dates == "14–28 Dec · 65 days to go")
    #expect(japan.left == .aed(7_140_00))
  }

  @Test func activityMatchesTheOverview() {
    let a = ActivityEngine.snapshot(s, now: now, filter: .all)
    #expect(a.countLine == "26 transactions this month")
    #expect(a.review?.count == 6)
    #expect(a.review?.unplanned == .aed(827_28))
    #expect(a.chips.first { $0.kind == .toReview }?.count == 6)
    #expect(a.comingUp.map(\.name) == ["DEWA", "AXA Insurance"])
    let days = a.days.prefix(4)
    #expect(days.map(\.title) == ["Today", "Yesterday, Fri 9 Oct", "Thu 8 Oct", "Wed 7 Oct"])
    #expect(days.map { MoneyFormat.string($0.total.minor) } == ["91.50", "388.15", "116.99", "601.00"])
    #expect(a.days[0].rows.map(\.merchant) == ["Talabat", "Starbucks DIFC"])
    #expect(a.days[0].rows.map(\.detail) == ["Dining · 13:20", "Dining · 09:05"])
    #expect(a.days[2].rows[1].detail == "Subscriptions · monthly bill")
  }

  @Test func filteringByDiningMatchesTheFilteredBoard() {
    let a = ActivityEngine.snapshot(s, now: now, filter: TxnFilter(category: "dining"))
    #expect(a.rowCount == 5)
    #expect(a.summary?.total == .aed(642_75))
    #expect(a.summary?.caption.rendered(hidden: false) == "40% of Dining's 1,600")
    #expect(a.summary?.verdict == .overPace)
    #expect(a.review == nil)
    let groceries = ActivityEngine.snapshot(s, now: now, filter: TxnFilter(category: "groceries"))
    #expect(groceries.summary?.caption.rendered(hidden: false) == "36% of Groceries' 2,200")
  }

  @Test func searchingFindsAcrossMonthsAndRawMerchants() {
    let a = ActivityEngine.snapshot(s, now: now, filter: TxnFilter(text: "carre"))
    #expect(a.rowCount == 3)
    let raw = ActivityEngine.snapshot(s, now: now, filter: TxnFilter(text: "marina"))
    #expect(raw.days.flatMap(\.rows).map(\.merchant).contains("Lulu Hypermarket"))
  }

  @Test func transactionSheetMatchesCarrefour() throws {
    let d = try #require(TransactionEngine.detail("carrefour", s, now: now))
    #expect(d.meta == "Fri 9 Oct, 19:12 · Emirates NBD ···4412")
    #expect(d.pace?.left == .aed(1_387_60))
    #expect(d.pace?.verdict == .overPace)
    #expect(d.pace?.projection?.rendered(hidden: false) == "on course for 2,518")
    #expect(d.sortedBy == SortedBy(title: "Sorted by your rule", detail: "carrefour → Groceries"))
    #expect(d.provenance?.rawMerchant == "CARREFOUR MALL OF EMIRATES")
  }

  @Test func reviewDeckHasSixCards() {
    let cards = ReviewEngine.cards(s)
    #expect(cards.count == 6)
    let lulu = cards.first { $0.id == "lulu" }
    #expect(lulu?.meta == "Spent · Fri 9 Oct, 18:42 · DIB card ···8891")
    #expect(lulu?.suggestion?.name == "Groceries")
    #expect(lulu?.isNewMerchant == true)
    #expect(ReviewEngine.options(for: .need, s).map(\.name).prefix(3) == ["Rent", "Utilities", "Groceries"])
    let incoming = s.txn("transfer-in")
    #expect(ReviewEngine.options(for: .transfer, s, txn: incoming).map(\.name) ==
      ["Salary", "Freelance", "Transfer", "Refunds"])
  }

  @Test func billsMatchComingUpAndFound() {
    let b = BillsEngine.snapshot(s, now: now)
    #expect(b.next14 == .aed(1_039_15))
    #expect(b.incomeLine?.rendered(hidden: false) == "+25,000.00 expected Wed 28 Oct")
    #expect(b.needsALook.map(\.name) == ["AXA Insurance", "du"])
    #expect(b.needsALook[1].body.rendered(hidden: false) == "Charged 38.90 more than usual (389.00) on Mon 5 Oct.")
    #expect(b.upcoming.map(\.name) ==
      ["AXA Insurance", "DEWA", "Salary · Acme Gulf", "Rent · Al Habtoor", "Netflix", "Spotify"])
    #expect(b.recentlyPaid.map(\.name) == ["Spotify", "Netflix", "du", "Rent · Al Habtoor"])
    #expect(b.paidThisMonth == .aed(8_005_89))
    #expect(b.found.first?.evidence == ["Seen 5×", "Every ~30 days", "Last on 8 Oct"])
    #expect(b.tracked == 9)
  }

  @Test func profileCounts() {
    let p = ProfileEngine.snapshot(s, now: now)
    #expect(p.accounts.rendered(hidden: false) == "4 · net worth 227,568")
    #expect(p.bills == "9 tracked · 1 new found")
    #expect(p.categoriesAndRules.hasPrefix("18 categories"))
    #expect(p.projects?.rendered(hidden: false) == "Japan trip · 7,140.00 left")
    #expect(p.emailLine == "maya@example.com · Verified")
  }
}

@Suite("Swipe physics")
struct SwipePhysicsTests {
  @Test func shortDragsDoNotCommit() {
    #expect(SwipePhysics.commit(dx: 60, dy: 10, vx: 100, vy: 0) == nil)
    #expect(SwipePhysics.detect(dx: 70, dy: 10) == nil)
  }

  @Test func farDragsCommitOnTheStrongerAxis() {
    #expect(SwipePhysics.commit(dx: 120, dy: 30, vx: 0, vy: 0) == .right)
    #expect(SwipePhysics.commit(dx: -101, dy: 0, vx: 0, vy: 0) == .left)
    #expect(SwipePhysics.commit(dx: 110, dy: 140, vx: 0, vy: 0) == .down)
    #expect(SwipePhysics.commit(dx: 0, dy: -100, vx: 0, vy: 0) == .up)
  }

  @Test func flicksCommitWithLittleTravel() {
    #expect(SwipePhysics.commit(dx: 30, dy: 0, vx: 600, vy: 0) == .right)
    // Too short to be intentional, or flung back against the drag.
    #expect(SwipePhysics.commit(dx: 20, dy: 0, vx: 900, vy: 0) == nil)
    #expect(SwipePhysics.commit(dx: 40, dy: 0, vx: -900, vy: 0) == nil)
  }

  @Test func previewIsQuantised() {
    #expect(SwipePhysics.progress(dx: 47, dy: 0) == 0.5)
    #expect(SwipePhysics.progress(dx: 250, dy: 0) == 1)
    #expect(SwipePhysics.preview(dx: 25, dy: 5) == .right)
  }

  @Test func directionsFollowThePreference() {
    #expect(SwipePhysics.choice(for: .right) == .need)
    #expect(SwipePhysics.choice(for: .left) == .want)
    #expect(SwipePhysics.choice(for: .right, needOnRight: false) == .want)
    #expect(SwipePhysics.choice(for: .down) == .save)
    #expect(SwipePhysics.choice(for: .up) == .transfer)
    #expect(SwipePhysics.edge(for: .need, needOnRight: false) == .left)
  }
}

@MainActor
@Suite("In-memory ledger edits")
struct InMemoryLedgerTests {
  @Test func sortingACardMovesItIntoThePlanAndUndoPutsItBack() throws {
    let ledger = InMemoryLedger()
    let token = try #require(try ledger.apply(.categorize("lulu", "groceries", learnRule: true, project: nil)))
    #expect(token.title == "Sorted into Groceries")
    #expect(ReviewEngine.queue(ledger.state).count == 5)
    #expect(ledger.state.spent("groceries", in: MayaLedger.october) == .aed(1_026_70))
    #expect(ledger.state.rules.contains { $0.patterns == ["lulu hypermarket"] && $0.learnedToday })
    ledger.undo(token)
    #expect(ReviewEngine.queue(ledger.state).count == 6)
    #expect(ledger.state.spent("groceries", in: MayaLedger.october) == .aed(812_40))
    #expect(!ledger.state.rules.contains { $0.learnedToday })
  }

  @Test func aSplitMustAddUp() throws {
    let ledger = InMemoryLedger()
    let bad = [SplitLine(id: 0, categoryID: "groceries", amount: .aed(300_00)),
               SplitLine(id: 1, categoryID: "shopping", amount: .aed(45_00))]
    #expect(throws: ActionError.splitDoesNotAddUp) { try ledger.apply(.split("carrefour", bad)) }
    let good = [SplitLine(id: 0, categoryID: "groceries", amount: .aed(297_00)),
                SplitLine(id: 1, categoryID: "shopping", amount: .aed(45_15), note: "Kitchen towels and batteries")]
    try ledger.apply(.split("carrefour", good))
    #expect(ledger.state.spent("shopping", in: MayaLedger.october) == .aed(476_95))
    #expect(ledger.state.spent("groceries", in: MayaLedger.october) == .aed(767_25))
  }

  @Test func movingMoneyFromReadyToAssign() throws {
    let ledger = InMemoryLedger()
    let token = try #require(try ledger.apply(.moveMoney(from: nil, to: "groceries", MayaLedger.october, .aed(318_00))))
    let plan = PlanEngine.snapshot(ledger.state, now: ledger.now)
    #expect(plan.readyToAssign == .aed(682_00))
    #expect(ledger.state.plan.budget("groceries", MayaLedger.october) == .aed(2_518_00))
    #expect(throws: ActionError.insufficientFunds) {
      try ledger.apply(.moveMoney(from: nil, to: "dining", MayaLedger.october, .aed(5_000_00)))
    }
    #expect(throws: ActionError.insufficientFunds) {
      try ledger.apply(.moveMoney(from: "entertainment", to: "dining", MayaLedger.october, .aed(506_00)))
    }
    ledger.undo(token)
    #expect(PlanEngine.snapshot(ledger.state, now: ledger.now).readyToAssign == .aed(1_000_00))
  }

  @Test func renamingRenamesEveryTransactionOfTheMerchant() throws {
    let ledger = InMemoryLedger()
    try ledger.apply(.renameMerchant("talabat", "Talabat Food"))
    #expect(ledger.state.txns.filter { $0.merchant == "Talabat Food" }.count == 2)
  }

  @Test func billsCanBeTrackedPaidAndDismissed() throws {
    let ledger = InMemoryLedger()
    try ledger.apply(.trackCandidate("apple-bill"))
    #expect(BillsEngine.snapshot(ledger.state, now: ledger.now).tracked == 10)
    #expect(ledger.state.billCandidates.isEmpty)
    try ledger.apply(.markBillPaid("axa"))
    #expect(ledger.state.bill("axa")?.nextDue == LocalDate(2026, 11, 7))
    #expect(BillsEngine.snapshot(ledger.state, now: ledger.now).needsALook.map(\.name) == ["du"])
    try ledger.apply(.acceptBillAmount("du"))
    #expect(BillsEngine.snapshot(ledger.state, now: ledger.now).needsALook.isEmpty)
  }

  @Test func archivingTakesATransactionOutOfThePlan() throws {
    let ledger = InMemoryLedger()
    try ledger.apply(.archive("zuma", true))
    #expect(ledger.state.spent("dining", in: MayaLedger.october) == .aed(230_75))
    let archived = ActivityEngine.snapshot(ledger.state, now: ledger.now, filter: TxnFilter(kind: .archived))
    #expect(archived.rowCount == 1)
  }
}
