import HasalaMocks
import HasalaModels
import Testing

/// Bills, one bill, Accounts and Profile over MayaLedger reproduce their boards. Owned by P8
/// from Stage P.
@Suite("Maya ledger · Bills and profile parity")
struct BillsProfileEngineParityTests {
  let s = MayaLedger.state
  let now = MayaLedger.now

  @Test func billsMatchComingUpAndFound() {
    let b = BillsEngine.snapshot(s, now: now)
    #expect(b.next14 == .aed(1_039_15))
    #expect(b.incomeLine?.rendered(hidden: false) == "+25,000.00 expected Wed 28 Oct")
    #expect(b.income == BillsIncome(label: "Salary", amount: .aed(25_000_00), expected: "expected Wed 28 Oct"))
    #expect(b.needsALook.map(\.name) == ["AXA Insurance", "du"])
    #expect(b.needsALook.map(\.pill.text) == ["3 days past usual", "Price change"])
    #expect(b.needsALook.map(\.billKind) == ["Car insurance", "Mobile and internet"])
    #expect(b.needsALook[0].body.rendered(hidden: false) == "Car insurance usually arrives on the 7th. No bank email yet.")
    #expect(b.needsALook[1].body.rendered(hidden: false) == "Charged 38.90 more than usual (389.00) on Mon 5 Oct.")
    #expect(b.needsALook[1].body.rendered(hidden: true) == "Charged •••• more than usual (••••) on Mon 5 Oct.")
    #expect(b.upcoming.map(\.name) ==
      ["AXA Insurance", "DEWA", "Salary · Acme Gulf", "Rent · Al Habtoor", "Netflix", "Spotify"])
    #expect(b.upcoming[0].detail == [.status("Expected the 7th", .error)])
    #expect(b.upcoming[1].detail == [.text("Wed 14 Oct · in 4 days")])
    #expect(b.recentlyPaid.map(\.name) == ["Spotify", "Netflix", "du", "Rent · Al Habtoor"])
    #expect(b.recentlyPaid.map { $0.detail } == [
      [.text("Thu 8 Oct · DIB card")], [.text("Tue 6 Oct · DIB card")], [.text("Mon 5 Oct · Emirates NBD")],
      [.text("Thu 1 Oct · Emirates NBD")],
    ])
    #expect(b.tags == ["du": StatusPill("Price change", tone: .warning, showsDot: false)])
    #expect(b.paidThisMonth == .aed(8_005_89))
    #expect(b.found.first?.evidence == ["Seen 5×", "Every ~30 days", "Last on 8 Oct"])
    #expect(b.tracked == 9)
  }

  /// Bills · AXA Insurance (late): the hero, what we noticed, the history and the note.
  @Test func aLateBillSaysWhatWeNoticed() throws {
    let d = try #require(BillsEngine.detail(s, now: now, bill: "axa"))
    #expect(d.isLate)
    #expect(d.kind == "Car insurance")
    #expect(d.pill == StatusPill("3 days past usual", tone: .error))
    #expect(d.amount == .aed(550_00))
    #expect(d.hue == .sand)
    #expect(d.cadence == "every month · usually the 7th · Emirates NBD")
    #expect(d.noticed?.rendered(hidden: false)
      == "Your last 6 payments arrived between the 6th and 8th. This month there's no bank email yet.")
    #expect(d.history.map(\.title) ==
      ["Wed 7 Oct", "Mon 7 Sep", "Fri 7 Aug", "Mon 6 Jul", "Mon 8 Jun", "Thu 7 May", "Tue 7 Apr"])
    #expect(d.history.first?.kind == .expected(late: true))
    #expect(d.history.first?.note == "Expected · no bank email yet")
    #expect(d.history.dropFirst().allSatisfy { $0.kind == .paid && $0.amount == .aed(550_00) })
    #expect(d.historyNote == "6 on time")
    #expect(d.footnote == "Recurring payments are found from your history. Nothing is shared with AXA Insurance.")
  }

  /// The other bills open the same page: a price change leads with its news, an upcoming bill
  /// with when it's due, income with when it's expected; a bill no longer tracked is gone.
  @Test func everyTrackedBillHasADetail() throws {
    let du = try #require(BillsEngine.detail(s, now: now, bill: "du"))
    #expect(du.isPriceChange)
    #expect(du.notices.first?.body.rendered(hidden: false) == "Charged 38.90 more than usual (389.00) on Mon 5 Oct.")
    #expect(du.history.map(\.amount) == [.aed(427_90), .aed(389_00)])
    #expect(du.history.allSatisfy { $0.kind == .paid })

    let dewa = try #require(BillsEngine.detail(s, now: now, bill: "dewa"))
    #expect(dewa.state == .upcoming)
    #expect(dewa.pill == StatusPill("Due in 4 days", tone: .accent))
    #expect(dewa.approximate)
    #expect(dewa.noticed == nil)
    #expect(dewa.history.map(\.note) == ["Expected · in 4 days"])
    #expect(dewa.historyNote == nil)

    let salary = try #require(BillsEngine.detail(s, now: now, bill: "salary"))
    #expect(salary.isIncome)
    #expect(salary.pill.text == "Expected in 18 days")
    #expect(salary.footnote.hasSuffix("Nothing is shared with Acme Gulf."))

    var stopped = s
    stopped.bills[0].state = .dismissed
    #expect(BillsEngine.detail(stopped, now: now, bill: "axa") == nil)
    #expect(BillsEngine.detail(s, now: now, bill: "nope") == nil)
  }

  /// Accounts · Net worth: 41,823.50 − 4,210.50 + 550.00 = 38,163.00 everyday; + 189,405.00
  /// tracking = 227,568.00.
  @Test func accountsAddUpToNetWorth() throws {
    let a = AccountsEngine.snapshot(s, now: now)
    #expect(a.netWorth == .aed(227_568_00))
    #expect(a.everydayTotal == .aed(38_163_00))
    #expect(a.monthChange == .aed(2_140_00))
    #expect(a.everyday.map(\.name) == ["Emirates NBD Current", "DIB Credit Card", "Cash"])
    #expect(a.everyday.map(\.plate) == [.initials("ENBD"), .initials("DIB"), .cash])
    #expect(a.everyday.map(\.hue) == [.sky, .sand, .mint])
    #expect(a.everyday.map(\.detail) ==
      ["···4412 · checked in 3 days ago · 6 since", "···8891 · statement due Sun 18 Oct", "Updated by you"])
    #expect(a.everyday[1].balance == .aed(-4_210_50))
    #expect(a.tracking.map(\.name) == ["Sarwa portfolio"])
    #expect(a.tracking.first?.plate == .initials("S"))
    #expect(a.tracking.first?.hue == .lilac)
    let chart = try #require(a.chart)
    #expect(chart.months == ["N", "D", "J", "F", "M", "A", "M", "J", "J", "A", "S", "O"])
    #expect(chart.points.count == 11)
    #expect(a.count == 4)
    #expect(a.hasBalances)
  }

  /// Live has no net worth history yet: no chart, no change line; no check-in, no balances.
  @Test func accountsWithoutHistoryDrawNoChart() {
    var live = s
    live.netWorth = NetWorthHistory()
    let a = AccountsEngine.snapshot(live, now: now)
    #expect(a.chart == nil)
    #expect(a.monthChange == nil)
    for i in live.accounts.indices { live.accounts[i].balance = .aed(0) }
    #expect(!AccountsEngine.snapshot(live, now: now).hasBalances)
    #expect(!ProfileEngine.snapshot(live, now: now).accountsKnown)
  }

  @Test func profileCounts() {
    let p = ProfileEngine.snapshot(s, now: now)
    #expect(p.accounts.rendered(hidden: false) == "4 · net worth 227,568")
    #expect(p.accounts.rendered(hidden: true) == "4 · net worth ••••")
    #expect(p.accountsKnown)
    #expect(p.bills == "9 tracked · 1 new found")
    #expect(p.newBills == 1)
    #expect(p.categoriesAndRules == "18 categories · 6 rules")
    #expect(p.projects.rendered(hidden: false) == "1 active")
    #expect(p.emailLine == "maya@example.com · Verified")
    #expect(p.swipeSummary == "← Want · Need →")
    #expect(p.swipeSpoken == "Swipe left for Want, right for Need")
  }

  /// Categories and rules: most used first, curly quotes, the match line in two parts so a
  /// long one can break where Paper breaks it.
  @Test func rulesAreMostUsedFirst() {
    let rules = ProfileEngine.rules(s)
    #expect(rules.first?.pattern == "\u{201C}carrefour\u{201D}")
    #expect(rules.map(\.matches) == rules.map(\.matches).sorted(by: >))
    let careem = rules.first { $0.id == "r-careem" }
    #expect(careem?.pattern == "\u{201C}CAREEM\u{201D} or \u{201C}UBER\u{201D}")
    #expect(careem?.match == "Starts with · Transport")
    #expect(careem?.detail == "Starts with · Transport · \(careem?.matchesLabel ?? "")")
    #expect(rules.first { $0.id == "r-netflix" }?.match == "Exact match · Subscriptions")
  }
}
