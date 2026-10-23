import HasalaMocks
import HasalaModels
import Testing

/// Home derived from MayaLedger is the Home board (spec 10, page 06 §6.4). Owned by P5.
@Suite("Maya ledger · Home parity")
struct HomeEngineParityTests {
  let s = MayaLedger.state
  let now = MayaLedger.now

  @Test func homeDerivedFromTheLedgerIsTheHomeBoard() {
    let home = HomeEngine.snapshot(s, now: now)
    #expect(home.hero == Maya.home.hero)
    #expect(home.notifications == Maya.home.notifications)
    #expect(home.header == Maya.home.header)
    #expect(home.widgets == Maya.home.widgets)
  }
}

/// The hero: everything spent against the needs and wants plan, the tick, the verdict and the wash.
@Suite("Home hero")
struct HomeHeroTests {
  let now = MayaLedger.now
  static let october = MayaLedger.october

  /// Maya with her needs + wants plan changed to `budgets` (category → dirhams, others kept).
  static func maya(budgets: [CategoryID: Int64] = [:], change: (inout LedgerState) -> Void = { _ in }) -> LedgerState {
    var s = MayaLedger.state
    for (c, dirhams) in budgets { s.plan.budgets[PlanState.key(c, october)] = .aed(dirhams * 100) }
    change(&s)
    return s
  }

  func hero(_ s: LedgerState) -> SpendHero {
    HomeEngine.hero(s, now: now, plan: PlanEngine.snapshot(s, now: now))
  }

  @Test func mayasMonthIsOnTrack() {
    let h = hero(MayaLedger.state)
    #expect(h.state == .live)
    #expect(h.overline == "Day 10 of 31")
    #expect(MoneyFormat.string(h.spent.minor) == "11,115.62")
    #expect(MoneyFormat.string(h.plan.minor) == "19,000.00")
    #expect(MoneyFormat.string(h.left.minor) == "7,884.38")
    #expect(h.caption.rendered(hidden: false) == "spent of 19,000 planned")
    #expect(h.verdict == .onTrack)
    #expect(h.word.rendered(hidden: false) == "On track")
    #expect(h.fact?.rendered(hidden: false) == "AED 7,884.38 left")
    #expect(h.wash == .sky)
    #expect(h.tiles.map(\.label) == ["Needs", "Wants", "Savings"])
    #expect(h.tiles.map { MoneyFormat.string($0.value.minor, style: $0.style) } == ["9,040.80", "1,247.54", "5,000.00"])
  }

  /// Hidden amounts (page 06 §6.3): the plan in the caption and "left" are three dots; the
  /// verdict word stays.
  @Test func hiddenAmountsKeepTheWords() {
    let h = hero(MayaLedger.state)
    #expect(h.caption.rendered(hidden: true) == "spent of ••• planned")
    #expect(h.fact?.rendered(hidden: true) == "AED ••• left")
    #expect(h.fact?.spoken(hidden: true) == "AED Amount hidden left")
    #expect(h.word.rendered(hidden: true) == "On track")
  }

  /// The tick is the bills paid so far plus the rest of the plan spread over the days gone:
  /// 8,005.89 + (19,000 − 9,045.04) × 10 ÷ 31 = 11,217.17 (Paper page 06 §6.8), 59.0% of
  /// the bar (the board draws it at 213 of 362).
  @Test func theTickCountsTheBillsPaidThenTheDays() {
    let s = MayaLedger.state
    let bills = HomeEngine.billsThisMonth(s, month: Self.october)
    #expect(bills.paid == 8_005_89)
    #expect(bills.toCome == 1_039_15)
    let tick = HomeEngine.tick(s, month: Self.october, plan: 19_000_00, day: 10, days: 31)
    #expect(tick == 11_217_17)
    #expect(hero(s).tick == .aed(11_217_17))
    #expect(Permille.ratio(tick, of: 19_000_00).value == 590)
    // Page 06 §6.8: with every bill of the month paid, day 22 sits at 16,109.85 and day 29 at
    // 18,357.74 (Paper writes 18,357.75: 9,954.96 × 29 ÷ 31 is 9,312.7045, so a fil rounds up
    // there and down here).
    var paid = s
    paid.txns.append(Txn(id: "axa-paid", merchant: "AXA", amount: .aed(550_00), postedAt: LocalDateTime(2026, 10, 9, 9, 0),
                         categoryID: "insurance", billID: "axa"))
    paid.txns.append(Txn(id: "dewa-paid", merchant: "DEWA", amount: .aed(489_15),
                         postedAt: LocalDateTime(2026, 10, 9, 9, 0), categoryID: "utilities", billID: "dewa"))
    for i in paid.bills.indices where ["axa", "dewa"].contains(paid.bills[i].id) {
      paid.bills[i].nextDue = LocalDate(2026, 11, paid.bills[i].usualDay)
    }
    let allPaid = HomeEngine.billsThisMonth(paid, month: Self.october)
    #expect(allPaid.paid == 9_045_04 && allPaid.toCome == 0)
    #expect(HomeEngine.tick(paid, month: Self.october, plan: 19_000_00, day: 22, days: 31) == 16_109_85)
    #expect(HomeEngine.tick(paid, month: Self.october, plan: 19_000_00, day: 29, days: 31) == 18_357_74)
    #expect(HomeEngine.tick(paid, month: Self.october, plan: 19_000_00, day: 31, days: 31) == 19_000_00)
  }

  /// With no bills the tick is the plan × day ÷ days; savings bills never move it.
  @Test func withoutBillsTheTickIsTheShareOfTheMonth() {
    var s = MayaLedger.state
    s.txns.removeAll { $0.billID != nil }
    s.bills.removeAll()
    #expect(HomeEngine.tick(s, month: Self.october, plan: 31_000_00, day: 10, days: 31) == 10_000_00)
    var savingsOnly = MayaLedger.state
    savingsOnly.txns.removeAll { $0.billID != nil && !["standing-order", "sarwa"].contains($0.id) }
    savingsOnly.bills.removeAll { !["savings-so", "sarwa-so"].contains($0.id) }
    let savingsBills = HomeEngine.billsThisMonth(savingsOnly, month: Self.october)
    #expect(savingsBills.paid == 0 && savingsBills.toCome == 0)
  }

  /// Past the tick and under the plan: "Ahead of pace", the sand wash, money still left.
  @Test func pastTheTickIsAheadOfPace() {
    // Travel to 0 and Shopping to 100: the plan is 15,000 and the tick 8,005.89 + 5,954.96 ×
    // 10 ÷ 31 = 9,926.84.
    let h = hero(Self.maya(budgets: ["travel": 0, "shopping": 100]))
    #expect(h.plan == .aed(15_000_00))
    #expect(h.tick == .aed(9_926_84))
    #expect(h.verdict == .overPace)
    #expect(h.word.rendered(hidden: false) == "Ahead of pace")
    #expect(h.fact?.rendered(hidden: false) == "AED 3,884.38 left")
    #expect(h.wash == .sand)
  }

  /// The `home.overPace` screen's plan: 12,000 with needs and wants each still under, so the
  /// widget stays blue while the hero is well past the tick (amber from 74.7% to 92.6%).
  @Test func aTighterPlanIsAheadOfPaceWithMoneyLeft() {
    let s = Self.maya(budgets: [
      "groceries": 0, "transport": 50, "travel": 0, "shopping": 0, "entertainment": 0, "dining": 2_350,
    ])
    let h = hero(s)
    #expect(h.plan == .aed(12_000_00))
    #expect(h.tick == .aed(8_959_10))
    #expect(h.verdict == .overPace && h.wash == .sand)
    #expect(h.fact?.rendered(hidden: false) == "AED 884.38 left")
    guard case .budgetPace(let pace) = HomeEngine.snapshot(s, now: now).widgets[0] else {
      Issue.record("no Budget pace")
      return
    }
    #expect(pace.rows.map(\.verdict) == [.onTrack, .onTrack, .done])
    #expect(pace.rows.map { MoneyFormat.string($0.left.minor, style: .rounded) } == ["259", "1,452", "0"])
  }

  /// Past the plan: "Over by AED …" in one run (it hides like any amount), no "left", rose.
  @Test func pastThePlanIsOverBy() {
    let h = hero(Self.maya(budgets: ["travel": 0, "rent": 0]))
    #expect(h.plan == .aed(9_000_00))
    #expect(h.verdict == .overBudget)
    #expect(h.word.rendered(hidden: false) == "Over by AED 2,115.62")
    #expect(h.word.rendered(hidden: true) == "Over by AED •••")
    #expect(h.word.spoken(hidden: true) == "Over by AED Amount hidden")
    #expect(h.fact == nil)
    #expect(h.wash == .rose)
    // The bills are more than the plan: the rest of the plan is nothing, so the tick is the
    // bills paid.
    #expect(h.tick == .aed(8_005_89))
  }

  /// S8: no needs or wants budget: the spending still counts, nothing to measure it against.
  @Test func noPlanYet() {
    let s = Self.maya { s in
      for key in s.plan.budgets.keys { s.plan.budgets[key] = .aed(0) }
    }
    let h = hero(s)
    #expect(h.state == .noPlan)
    #expect(h.spent == .aed(11_115_62))
    #expect(h.tick == nil && h.verdict == nil && h.fact == nil)
    #expect(h.word.rendered(hidden: false) == "No plan yet")
    #expect(h.caption.rendered(hidden: false) == "spent so far")
    #expect(h.wash == .sky)
    #expect(h.tiles[2].value == .aed(5_000_00))
  }

  /// S9: the first import runs and nothing has arrived this month: zero that fills in.
  @Test func theFirstImportFillsInFromZero() {
    let s = Self.maya { s in
      s.mailbox.status = .importing
      s.txns.removeAll { $0.postedAt.date.yearMonth == MayaLedger.october }
    }
    let h = hero(s)
    #expect(h.state == .syncing)
    #expect(h.word.rendered(hidden: false) == "Getting your transactions…")
    #expect(h.spent == .aed(0))
    #expect(h.tiles.map(\.label) == ["Needs", "Wants", "Savings"])
    #expect(h.tiles.allSatisfy { $0.value.minor == 0 }, "\(h.tiles)")
    // Once a transaction is in, the month shows (the import may still be running).
    var arrived = s
    arrived.txns.append(MayaLedger.state.txns[0])
    #expect(hero(arrived).state == .live)
  }

  /// Savings part way shows only what was saved, so the tile never truncates.
  @Test func savingsPartWayShowsWhatWasSaved() {
    let s = Self.maya { s in s.txns.removeAll { $0.id == "standing-order" } }
    let tile = hero(s).tiles[2]
    #expect(MoneyFormat.string(tile.value.minor, style: tile.style) == "2,000.00")
  }
}

/// The bell's list (spec 10 §4): what needs a look, newest first, from the ledger.
@Suite("Notifications")
struct NotificationsEngineTests {
  let now = MayaLedger.now

  @Test func mayaHasFourThingsToLookAt() {
    let n = NotificationsEngine.snapshot(MayaLedger.state, now: now)
    #expect(n.count == 4)
    #expect(n.needsALook.map(\.id) == ["review", "bill.axa", "found.apple-bill", "price.du"])
    #expect(n.needsALook.map(\.title) == [
      "6 transactions to sort", "AXA Insurance may be late", "Found a bill: Apple.com/bill", "du has a new price",
    ])
    #expect(n.needsALook.map { $0.line.rendered(hidden: false) } == [
      "AED 827.28 still to check", "Usually on the 7th · no email yet", "Seen 5× · every ~30 days",
      "427.90 from 389.00 · accept or check",
    ])
    #expect(n.needsALook.map(\.when) == ["Today", "Thu", "Thu", "Mon"])
    #expect(n.needsALook.map(\.status) == [nil, .error, nil, nil])
    #expect(n.needsALook.map(\.destination) == [.review(.allTime), .bill("axa"), .bills, .bill("du")])
  }

  @Test func hiddenAmountsAreThreeDots() {
    let n = NotificationsEngine.snapshot(MayaLedger.state, now: now)
    #expect(n.needsALook[0].line.rendered(hidden: true) == "AED ••• still to check")
    #expect(n.needsALook[3].line.rendered(hidden: true) == "••• from ••• · accept or check")
  }

  /// Sorting everything, paying AXA, accepting du's price and dismissing the found bill leaves
  /// nothing to look at (Home · Notifications (all clear)).
  @MainActor
  @Test func nothingNeedsYouOnceEachIsDealtWith() throws {
    let ledger = InMemoryLedger(state: Scenario.mayaCaughtUp.state)
    #expect(NotificationsEngine.snapshot(ledger.state, now: now).count == 3)
    try ledger.apply(.markBillPaid("axa"))
    try ledger.apply(.acceptBillAmount("du"))
    try ledger.apply(.dismissCandidate("apple-bill"))
    #expect(NotificationsEngine.snapshot(ledger.state, now: now).needsALook.isEmpty)
  }

  @Test func oneTransactionIsSingular() {
    var s = MayaLedger.state
    var first = true
    for i in s.txns.indices where s.txns[i].needsReview {
      if first {
        first = false
      } else {
        s.txns[i].needsReview = false
        s.txns[i].categoryID = "groceries"
        s.txns[i].categorySource = .user
      }
    }
    #expect(NotificationsEngine.snapshot(s, now: now).needsALook[0].title == "1 transaction to sort")
  }

  @Test func reviewItemCountsTheDeckItOpens() {
    var s = MayaLedger.state
    let queue = ReviewEngine.queue(s, in: .month(now.date.yearMonth))
    #expect(queue.count == 6)
    s.skippedReview = [queue[0].id]
    var old = queue[1]
    old.id = "old-review"
    old.postedAt = LocalDateTime(date: now.date.yearMonth.previous.firstDay, hour: 9, minute: 0)
    s.txns.append(old)
    let window = ReviewWindow.month(now.date.yearMonth)
    let n = NotificationsEngine.snapshot(s, now: now, review: window)
    #expect(n.needsALook[0].title == "\(ReviewEngine.queue(s, in: window).count) transactions to sort")
    #expect(n.needsALook[0].title == "5 transactions to sort")
    #expect(n.needsALook[0].destination == .review(nil))
    let all = NotificationsEngine.snapshot(s, now: now).needsALook[0]
    #expect(all.title == "6 transactions to sort")
    #expect(all.destination == .review(.allTime))
  }

  @Test func whenReadsLikeTheSheet() {
    let today = LocalDate(2026, 10, 10)
    #expect(NotificationsEngine.when(today, today: today) == "Today")
    #expect(NotificationsEngine.when(LocalDate(2026, 10, 9), today: today) == "Yesterday")
    #expect(NotificationsEngine.when(LocalDate(2026, 10, 8), today: today) == "Thu")
    #expect(NotificationsEngine.when(LocalDate(2026, 10, 4), today: today) == "Sun")
    #expect(NotificationsEngine.when(LocalDate(2026, 10, 3), today: today) == "3 Oct")
    #expect(NotificationsEngine.when(LocalDate(2026, 9, 28), today: today) == "28 Sep")
  }
}

/// Widgets show whole dirhams (page 06 rule 5).
@Suite("Home widgets")
struct HomeWidgetEngineTests {
  let home = HomeEngine.snapshot(MayaLedger.state, now: MayaLedger.now)

  func widget(_ id: String) -> HomeWidget? { home.widgets.first { $0.id == id } }

  @Test func figuresAreWholeDirhams() throws {
    guard case .today(let today)? = widget("today"), case .project(let trip)? = widget("project.Japan trip"),
      case .goal(let goal)? = widget("goal.Emergency fund"), case .nextBill(let bill)? = widget("nextBill"),
      case .budgetPace(let pace)? = widget("budgetPace")
    else {
      Issue.record("a widget is missing")
      return
    }
    #expect(today.summary.rendered(hidden: false) == "4 transactions · 189")
    #expect(today.summary.rendered(hidden: true) == "4 transactions · •••")
    #expect(trip.caption.rendered(hidden: false) == "of 12,000 · flies 14 Dec")
    #expect(trip.caption.rendered(hidden: true) == "of •••• · flies 14 Dec")
    #expect(goal.caption.rendered(hidden: false) == "38,500 of 50,000 · Jan")
    #expect(goal.percentLabel == "77%")
    #expect(MoneyFormat.string(bill.amount.minor, style: .rounded) == "489")
    #expect(bill.caption == "DEWA · expected Wed")
    #expect(pace.monthGone == "32% of October gone")
    #expect(pace.rows.map { MoneyFormat.string($0.left.minor, style: .rounded) } == ["3,309", "5,402", "0"])
    #expect(pace.rows.map(\.verdict) == [.onTrack, .onTrack, .done])
  }

  /// A bucket past its plan is over budget on the widget (full rose, "x over").
  @Test func aBucketPastItsPlanIsOver() {
    var s = MayaLedger.state
    s.plan.budgets[PlanState.key("dining", MayaLedger.october)] = .aed(0)
    s.plan.budgets[PlanState.key("travel", MayaLedger.october)] = .aed(0)
    s.plan.budgets[PlanState.key("shopping", MayaLedger.october)] = .aed(0)
    s.plan.budgets[PlanState.key("entertainment", MayaLedger.october)] = .aed(0)
    guard case .budgetPace(let pace) = HomeEngine.snapshot(s, now: MayaLedger.now).widgets[0] else {
      Issue.record("no Budget pace")
      return
    }
    #expect(pace.rows[1].verdict == .overBudget)
    #expect(MoneyFormat.string(-pace.rows[1].left.minor, style: .rounded) == "898")
  }
}

@Suite("Home hero · not counted")
struct HomeNotCountedTests {
  let now = MayaLedger.now
  let september = YearMonth(2026, 9)

  func ended(_ s: LedgerState) -> SpendHero {
    HomeEngine.endedHero(s, month: september, plan: PlanEngine.snapshot(s, now: LocalDateTime(2026, 9, 30, 23, 59)))
  }

  func live(_ s: LedgerState) -> SpendHero {
    HomeEngine.hero(s, now: now, plan: PlanEngine.snapshot(s, now: now))
  }

  func withSecondProject(countInPlan: Bool) -> LedgerState {
    var s = MayaLedger.state
    s.projects.append(Project(id: "move", name: "Moving", glyph: .flag, budget: nil, starts: nil, ends: nil,
                              countInPlan: countInPlan))
    let i = s.txns.firstIndex { $0.id == "carrefour" }!
    s.txns[i].projectID = "move"
    return s
  }

  @Test func noProjectSpendInThePeriodShowsNoLine() {
    #expect(live(MayaLedger.state).notCounted == nil)
    #expect(HomeEngine.snapshot(MayaLedger.state, now: now).hero.notCounted == nil)
  }

  @Test func oneProjectNamesItAndOpensIt() throws {
    let line = try #require(ended(MayaLedger.state).notCounted)
    #expect(line.amount == .aed(4_860_00))
    #expect(line.projects == 1)
    #expect(line.projectID == "japan")
    #expect(line.line.rendered(hidden: false) == "Not counted: AED 4,860.00 on Japan trip")
    #expect(line.line.rendered(hidden: true) == "Not counted: AED ••• on Japan trip")
    let snapshot = HomeEngine.snapshot(MayaLedger.state, now: now, period: .month(september))
    #expect(snapshot.hero.notCounted == line)
  }

  @Test func twoProjectsCountThem() throws {
    var s = withSecondProject(countInPlan: false)
    let i = s.txns.firstIndex { $0.id == "emirates" }!
    s.txns[i].postedAt = LocalDateTime(2026, 10, 2, 10, 0)
    let line = try #require(live(s).notCounted)
    #expect(line.amount == .aed(4_120_00 + 342_15))
    #expect(line.projects == 2)
    #expect(line.projectID == nil)
    #expect(line.line.rendered(hidden: false) == "Not counted: AED 4,462.15 on 2 projects")
  }

  @Test func aProjectThatCountsIsLeftOut() throws {
    let counted = withSecondProject(countInPlan: true)
    #expect(live(counted).notCounted == nil)
    let carved = withSecondProject(countInPlan: false)
    let line = try #require(live(carved).notCounted)
    #expect(line.amount == .aed(342_15))
    #expect(line.projectID == "move")
    #expect(live(carved).spent.minor + 342_15 == live(counted).spent.minor)
  }

  @Test func aRangeAddsUpEveryMonth() throws {
    let s = withSecondProject(countInPlan: false)
    let range = Period(YearMonth(2026, 8), YearMonth(2026, 10))
    let line = try #require(HomeEngine.snapshot(s, now: now, period: range).hero.notCounted)
    #expect(line.amount == .aed(4_860_00 + 342_15))
    #expect(line.projects == 2)
    #expect(line.line.rendered(hidden: false) == "Not counted: AED 5,202.15 on 2 projects")
  }
}
