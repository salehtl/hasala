import HasalaMocks
import HasalaModels
import Testing

/// The Plan engine over MayaLedger reproduces Plan · October. Owned by P7 from Stage P.
@Suite("Maya ledger · Plan parity")
struct PlanEngineParityTests {
  let s = MayaLedger.state
  let now = MayaLedger.now

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
    #expect(detail("insurance") == "● AXA · 3 days past usual · usually the 7th")
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
    #expect(japan.range == "14–28 Dec")
    #expect(japan.when == "65 days to go")
    #expect(japan.left == .aed(7_140_00))
  }

  /// Rows hide their figures as three dots; the words and the verdict stay (spec 03 §16.16).
  @Test func hiddenRowsKeepTheirWords() {
    let plan = PlanEngine.snapshot(s, now: now)
    func hidden(_ id: CategoryID) -> String {
      plan.row(id)!.detail.map { part in
        switch part {
        case .text(let p): p.rendered(hidden: true)
        case .status(let t, _): "● " + t
        }
      }.joined(separator: " · ")
    }
    #expect(hidden("groceries") == "••• of ••• · ● Over pace")
    #expect(hidden("utilities") == "••• of ••• · DEWA ~••• due Wed")
    #expect(hidden("travel") == "Nothing yet · ••• planned")
    #expect(hidden("insurance") == "● AXA · 3 days past usual · usually the 7th")
  }

  /// A bill's short name leads a row's one fact.
  @Test func billsAreNamedShortInRows() {
    #expect(PlanEngine.shortName("AXA Insurance") == "AXA")
    #expect(PlanEngine.shortName("Rent · Al Habtoor") == "Rent")
    #expect(PlanEngine.shortName("DEWA") == "DEWA")
    #expect(PlanEngine.shortName("Savings standing order") == "Savings standing order")
  }
}

/// Plan · Dining and Plan · Japan trip over MayaLedger.
@Suite("Maya ledger · Plan details")
struct PlanDetailParityTests {
  let s = MayaLedger.state
  let now = MayaLedger.now

  @Test func diningIsPlanDining() throws {
    let d = try #require(PlanEngine.category("dining", s, now: now))
    #expect(d.name == "Dining" && d.hue == .lilac && d.bucket == .wants)
    #expect(d.left == .aed(957_25) && d.budget == .aed(1_600_00) && d.spent == .aed(642_75))
    // 642.75 of 1,600 is 145 of Paper's 362; the tick at day 10 of 31 is 116.
    #expect(d.progress == Permille(401))
    #expect(d.tick == Permille(320))
    #expect(d.verdict == .overPace && d.verdictWord == "Over pace")
    #expect(d.verdictFact?.rendered(hidden: false) == "on course for 1,992")
    #expect(d.verdictFact?.rendered(hidden: true) == "on course for •••")
    #expect(d.advice?.rendered(hidden: false) == "Spend about AED 43 a day to finish on budget")

    let chart = d.chart
    #expect(chart.range == "1–10 Oct")
    #expect(chart.today == 10)
    #expect(chart.days.count == 10)
    #expect(chart.dailyBudget == .aed(51_61))
    #expect(chart.days.filter { $0.spent.minor > 0 }.map(\.day) == [3, 6, 7, 10])
    #expect(chart.days.map(\.spent.minor) == [0, 0, 58_25, 0, 0, 81_00, 412_00, 0, 0, 91_50])
    #expect(chart.peak?.day == 7 && chart.peak?.label == "Zuma" && chart.peak?.total == .aed(412_00))
    #expect(chart.caption == "\u{2068}Zuma\u{2069} on Wed 7 Oct was 64% of this month's dining.")
    #expect(chart.scaleTop == .aed(412_00))

    #expect(d.transactions.map(\.merchant) == ["Talabat", "Starbucks DIFC", "Zuma", "Common Grounds", "Talabat"])
    #expect(d.transactions.map(\.detail) == [
      "Sat 10 Oct · 13:20", "Sat 10 Oct · 09:05", "Wed 7 Oct · 21:30", "Tue 6 Oct · 10:15", "Sat 3 Oct · 20:45",
    ])
    #expect(d.transactions.map(\.amount.minor) == [64_50, 27_00, 412_00, 81_00, 58_25])
    #expect(d.transactions.reduce(Int64(0)) { $0 + $1.amount.minor } == d.spent.minor)

    #expect(d.rules.map(\.title) == ["talabat", "zuma"])
    #expect(d.rules.map(\.detail) == ["Merchant contains · 2 matches", "Merchant contains · 1 match"])
  }

  @Test func eachKindOfCategorySaysItsOwnVerdict() throws {
    let groceries = try #require(PlanEngine.category("groceries", s, now: now))
    #expect(groceries.verdictFact?.rendered(hidden: false) == "on course for 2,518")

    let transport = try #require(PlanEngine.category("transport", s, now: now))
    #expect(transport.verdict == .onTrack && transport.verdictWord == "On track")

    // A bill has no pace: no tick, no projection, no daily budget line, and paid reads
    // "Paid". Its one payment is all of the month, so no caption says so.
    let rent = try #require(PlanEngine.category("rent", s, now: now))
    #expect(rent.tick == nil && rent.verdictWord == "Paid" && rent.verdictFact == nil && rent.advice == nil)
    #expect(rent.chart.dailyBudget == .aed(0))
    #expect(rent.chart.peak?.day == 1)
    #expect(rent.chart.caption == nil)

    // Nothing spent yet: an empty chart with no peak and no caption.
    let travel = try #require(PlanEngine.category("travel", s, now: now))
    #expect(travel.chart.peak == nil && travel.chart.caption == nil && travel.transactions.isEmpty)

    #expect(PlanEngine.category("no-such-category", s, now: now) == nil)
  }

  @Test func overBudgetSaysByHowMuch() throws {
    var state = s
    state.plan.budgets[PlanState.key("dining", MayaLedger.october)] = .aed(600_00)
    let d = try #require(PlanEngine.category("dining", state, now: now))
    #expect(d.verdict == .overBudget && d.verdictWord == "Over budget")
    #expect(d.left == .aed(-42_75))
    #expect(d.verdictFact?.rendered(hidden: false) == "42.75 over")
    #expect(d.advice == nil)
  }

  @Test func japanTripIsPlanJapanTrip() throws {
    let p = try #require(PlanEngine.project("japan", s, now: now))
    #expect(p.name == "Japan trip")
    #expect(p.left == .aed(7_140_00) && p.spent == .aed(4_860_00) && p.budget == .aed(12_000_00))
    #expect(p.progress == Permille(405))
    #expect(p.range == "14–28 Dec" && p.when == "65 days to go")
    #expect(!p.countInPlan)
    #expect(p.explainer.rendered(hidden: false)
      == "Trip spending stays out of October's budgets. It comes from the 12,000 you set aside.")
    #expect(p.categories.map(\.name) == ["Travel", "Transport"])
    #expect(p.categories.map(\.detail) == ["Emirates flights", "JR Pass"])
    #expect(p.categories.map(\.spent) == [.aed(4_120_00), .aed(740_00)])
    #expect(p.transactions.map(\.merchant) == ["Emirates", "JR Pass via Klook"])
    #expect(p.transactions.map(\.detail) == ["Mon 14 Sep · Travel", "Sat 19 Sep · Transport"])
    #expect(PlanEngine.project("no-such-project", s, now: now) == nil)
  }

  /// Paper's "Trip spending" is the kind of project, not its name; any other project says
  /// "Project spending", and one counted in the plan says so.
  @Test func aProjectExplainerNamesItsKind() throws {
    var state = s
    let i = try #require(state.projects.firstIndex { $0.id == "japan" })
    state.projects[i].glyph = .flag
    let other = try #require(PlanEngine.project("japan", state, now: now))
    #expect(other.explainer.rendered(hidden: false)
      == "Project spending stays out of October's budgets. It comes from the 12,000 you set aside.")
    let dots = MoneyFormat.hidden(count: 3)
    #expect(other.explainer.rendered(hidden: true)
      == "Project spending stays out of October's budgets. It comes from the \(dots) you set aside.")
    state.projects[i].countInPlan = true
    let counted = try #require(PlanEngine.project("japan", state, now: now))
    #expect(counted.explainer.rendered(hidden: false) == "Project spending counts in October's budgets.")
  }
}

@Suite("Plan · worst cases")
struct PlanWorstCaseTests {
  let s = MayaLedger.state
  let now = MayaLedger.now

  @Test func splitPercentsAlwaysAddUpToAHundred() {
    #expect(PlanEngine.largestRemainderPercents([1, 1, 1]) == [34, 33, 33])
    #expect(PlanEngine.largestRemainderPercents([12_350, 6_650, 5_000]) == [51, 28, 21])
    #expect(PlanEngine.largestRemainderPercents([98, 2, 0]) == [98, 2, 0])
    #expect(PlanEngine.largestRemainderPercents([0, 0, 0]) == [0, 0, 0])
    #expect(PlanEngine.largestRemainderPercents([1, 1, 1, 1, 1, 1]).reduce(0, +) == 100)
    var state = s
    for c in ["rent", "utilities", "groceries", "transport", "healthcare", "insurance", "dining", "entertainment",
              "shopping", "travel", "subscriptions", "savings", "investments"]
    {
      state.plan.budgets[PlanState.key(c, MayaLedger.october)] = .aed(0)
    }
    state.plan.budgets[PlanState.key("groceries", MayaLedger.october)] = .aed(100_00)
    state.plan.budgets[PlanState.key("dining", MayaLedger.october)] = .aed(100_00)
    state.plan.budgets[PlanState.key("savings", MayaLedger.october)] = .aed(100_00)
    let plan = PlanEngine.snapshot(state, now: now)
    #expect(plan.split.map(\.label) == ["34%", "33%", "33%"])
  }

  @Test func aZeroBudgetWithSpendingIsAFullOverBudgetBar() throws {
    var state = s
    state.plan.budgets[PlanState.key("dining", MayaLedger.october)] = .aed(0)
    let row = try #require(PlanEngine.snapshot(state, now: now).row("dining"))
    #expect(row.progress == Permille(1000))
    #expect(row.verdict == .overBudget)
    guard case .text(let first) = row.detail.first else { Issue.record("no text first"); return }
    #expect(first.rendered(hidden: false) == "No budget · 642.75 spent")
    #expect(row.detail.contains(.status("Over budget", .error)))
    let detail = try #require(PlanEngine.category("dining", state, now: now))
    #expect(detail.progress == Permille(1000))
  }

  @Test func aLongPaidListIsCapped() {
    #expect(PlanEngine.paidList(["Netflix"]) == "Netflix")
    #expect(PlanEngine.paidList(["Netflix", "Spotify"]) == "Netflix and Spotify")
    #expect(PlanEngine.paidList(["Netflix", "Spotify", "OSN+", "Anghami", "Shahid"]) == "Netflix and 4 more")
  }

  @Test func theChartCaptionKeepsACustomNameAsTyped() throws {
    var state = s
    let i = try #require(state.categories.firstIndex { $0.id == "dining" })
    state.categories[i].name = "DEWA & du"
    state.categories[i].builtin = false
    let d = try #require(PlanEngine.category("dining", state, now: now))
    #expect(d.chart.caption == "\u{2068}Zuma\u{2069} on Wed 7 Oct was 64% of this month's \u{2068}DEWA & du\u{2069}.")
  }

  @Test func nothingPlannedOffersLastMonth() {
    let plan = PlanEngine.snapshot(s, now: now)
    #expect(!plan.nothingPlanned)
    #expect(plan.planned == .aed(24_000_00))
    #expect(plan.lastMonthBudgets["dining"] == .aed(1_600_00))
    let empty = PlanEngine.snapshot(MayaWorst.empty, now: now)
    #expect(empty.nothingPlanned)
    #expect(empty.lastMonthBudgets.isEmpty)
    #expect(empty.split.map(\.label) == ["0%", "0%", "0%"])
  }

  @Test func aProjectNameKeepsToTheOpLimit() {
    let ok = String(repeating: "a", count: 64)
    #expect(ProjectDraft(name: ok).refusal == nil)
    #expect(ProjectDraft(name: ok + "a").refusal == "Use 64 characters or fewer for the name")
    #expect(ProjectDraft(name: "  " + ok + "  ").refusal == nil)
    #expect(ProjectDraft.capped(ok + "bc") == ok)
    let flags = String(repeating: "\u{1F1E6}\u{1F1EA}", count: 33)
    #expect(ProjectDraft.capped(flags).unicodeScalars.count == 64)
  }
}
