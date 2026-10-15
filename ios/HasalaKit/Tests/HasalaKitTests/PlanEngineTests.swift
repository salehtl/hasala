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
}
