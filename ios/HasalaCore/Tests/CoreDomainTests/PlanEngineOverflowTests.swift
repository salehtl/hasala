import CoreCategorize
import CoreReplay
import CoreTime
import Testing

@testable import CoreDomain

@Suite("PlanEngine overflow")
struct PlanEngineOverflowTests {
  static let month = CivilMonth(year: 2026, month: 10)!
  static let today = CivilDate(year: 2026, month: 10, day: 15)!
  static let write = PlanWrite(opID: "", writerID: "", atMs: 0)

  static func set(_ plan: inout PlanState, _ c: String, _ v: Int64, moves: Int64 = 0) {
    plan.cells[c, default: [:]][month.wire] = PlanCell(latestSet: v, movesAll: moves, movesSinceSet: moves)
  }

  static func income(_ plan: inout PlanState, _ v: Int64) {
    plan.incomeSources["s"] = IncomeSource(id: "s", name: "Salary", categoryID: "salary", amountMinor: v, payday: 1, active: true, write: write)
  }

  static func spend(_ c: String, _ v: Int64, day: Int = 5) -> MoneyLine {
    MoneyLine(
      txnID: "t\(c)\(v)", category: c, direction: v >= 0 ? "debit" : "credit", localDate: CivilDate(year: 2026, month: 10, day: day)!,
      signedHome: v, flow: v >= 0 ? .spend : .refund, confirmed: true)
  }

  static func bill(_ id: String, _ c: String, _ v: Int64) -> BillExpectation {
    BillExpectation(
      billID: id, categoryID: c, payee: id, expectedDay: CivilDate(year: 2026, month: 10, day: 20)!, amount: v, isEstimate: false, status: .upcoming)
  }

  static func engine(
    _ plan: PlanState, lines: [MoneyLine] = [], bills: [BillExpectation] = [], goals: [(id: String, goal: Goal)] = []
  ) -> PlanEngine {
    PlanEngine(plan: plan, taxonomy: TaxonomyView(TaxonomyV1.builtins), lines: lines, bills: bills, goals: goals, today: today)
  }

  static func screen(_ e: PlanEngine) {
    let m = month
    _ = e.hero(m)
    _ = e.categoryRows(m).map { ($0.left, $0.pace) }
    _ = e.buckets(m).map(\.left)
    _ = e.splitShares(m)
    _ = e.readyToAssign(m)
    _ = e.income(m)
    _ = e.savingsDone(m)
    _ = e.autoAssign(m)
    for g in e.goals { _ = e.goalProgress(id: g.id, g.goal, month: m) }
  }

  @Test("bills at Int64.max and past it clamp the bills to come")
  func billsClamp() {
    var plan = PlanState()
    Self.income(&plan, 1_000_000)
    let e = Self.engine(plan, bills: [Self.bill("a", "rent", .max), Self.bill("b", "utilities", .max), Self.bill("c", "rent", 5)])
    #expect(e.hero(Self.month).billsToCome == .max)
    let auto = e.autoAssign(Self.month)
    #expect(auto.map(\.amount).reduce(Int128(0)) { $0 + Int128($1) } == 1_000_000)
    #expect(auto.first?.category == "rent" && auto.first?.amount == 1_000_000)
    Self.screen(e)
  }

  @Test("assigned near the bounds clamps planned, ready to assign and lefts")
  func assignedClamp() {
    var plan = PlanState()
    Self.income(&plan, .max - 1)
    Self.set(&plan, "groceries", .min + 1)
    Self.set(&plan, "dining", .min, moves: -5)
    Self.set(&plan, "rent", .max, moves: 7)
    let e = Self.engine(plan, lines: [Self.spend("groceries", .max), Self.spend("rent", .max)])
    #expect(e.assigned(Self.month, "dining") == .min)
    #expect(e.assigned(Self.month, "rent") == .max)
    #expect(e.planned(Self.month) == .min)
    #expect(e.readyToAssign(Self.month) == .max)
    let hero = e.hero(Self.month)
    #expect(hero.budget == .min && hero.spent == .max && hero.left == .min)
    let rows = e.categoryRows(Self.month)
    #expect(rows.first { $0.info.id == "groceries" }?.left == .min)
    #expect(rows.first { $0.info.id == "rent" }?.left == 0)
    #expect(e.buckets(Self.month).first { $0.bucket == .need }?.assigned == Int64(0))
    let auto = e.autoAssign(Self.month)
    #expect(auto.allSatisfy { $0.amount > 0 })
    #expect(auto.map(\.amount).reduce(Int128(0)) { $0 + Int128($1) } <= Int128(Int64.max))
    Self.screen(e)
  }

  @Test("income near max with assigned near min auto-assigns without a trap")
  func autoAssignExtreme() {
    var plan = PlanState()
    Self.income(&plan, .max)
    Self.set(&plan, "groceries", .min)
    Self.set(&plan, "savings", 1)
    let goal = Goal(
      name: "Car", targetMinor: .max, targetMonth: "2026-12", source: GoalSource(kind: "category", categoryID: "savings", since: "2026-01-01"),
      startingMinor: .min, status: "active", createdAt: "2026-01-01", version: 1)
    let e = Self.engine(plan, bills: [Self.bill("a", "rent", .max), Self.bill("b", "rent", .max)], goals: [("g", goal)])
    #expect(e.readyToAssign(Self.month) == .max)
    let auto = e.autoAssign(Self.month)
    #expect(auto.first?.category == "rent" && auto.first?.amount == .max)
    #expect(auto.map(\.amount).reduce(Int128(0)) { $0 + Int128($1) } == Int128(Int64.max))
    let gp = e.goalProgress(id: "g", goal, month: Self.month)
    #expect(gp.required == Int64.max / 3 + 1 && gp.percent == 0)
    Self.screen(e)
  }

  @Test("spent lines past the bounds clamp; used percent clamps")
  func spentClamp() {
    var plan = PlanState()
    Self.set(&plan, "groceries", 1)
    Self.set(&plan, "dining", 1)
    let e = Self.engine(plan, lines: [Self.spend("groceries", .max), Self.spend("groceries", .max), Self.spend("dining", .min, day: 6), Self.spend("dining", -1, day: 7)])
    #expect(e.spent(Self.month, "groceries") == .max)
    #expect(e.spent(Self.month, "dining") == .min)
    let row = e.categoryRows(Self.month).first { $0.info.id == "groceries" }
    #expect(row?.pace.usedPercent == .max && row?.pace.left == .min + 2)
    let dining = e.categoryRows(Self.month).first { $0.info.id == "dining" }
    #expect(dining?.left == .max)
    let p = e.pace(budget: 1, spent: .max, phase: .current(day: 15, days: 31), kind: .everyday)
    #expect(p.usedPercent == .max && p.projection == .max && p.left == .min + 2)
    let q = e.pace(budget: .max, spent: .min, phase: .current(day: 15, days: 31), kind: .everyday)
    #expect(q.left == .max && q.usedPercent == 0)
    Self.screen(e)
  }

  @Test("goal progress with extreme start and target stays clamped")
  func goalClamp() {
    let goal = Goal(
      name: "Big", targetMinor: 1, targetMonth: "2026-10", source: GoalSource(kind: "category", categoryID: "savings", since: "2026-01-01"),
      startingMinor: .max, status: "active", createdAt: "2026-01-01", version: 1)
    let e = Self.engine(PlanState(), lines: [Self.spend("savings", .max)], goals: [("g", goal)])
    let gp = e.goalProgress(id: "g", goal, month: Self.month)
    #expect(gp.progress == .max && gp.percent == 100 && gp.required == 0)
    #expect(e.goalSaved(category: "savings", since: CivilDate(year: 2026, month: 1, day: 1)!, until: Self.today) == .max)
    Self.screen(e)
  }

  @Test("an overflowing intermediate with an in-range total keeps the exact total")
  func exactTotals() {
    var plan = PlanState()
    Self.set(&plan, "groceries", 10)
    let e = Self.engine(plan, lines: [Self.spend("groceries", .max), Self.spend("groceries", 1, day: 6), Self.spend("groceries", -1, day: 7)])
    #expect(e.spent(Self.month, "groceries") == .max)
    var lines = [Self.spend("groceries", .max)]
    lines.append(Self.spend("groceries", .max, day: 6))
    lines.append(Self.spend("groceries", .min, day: 7))
    lines.append(Self.spend("groceries", .min, day: 8))
    let e2 = Self.engine(plan, lines: lines)
    #expect(e2.spent(Self.month, "groceries") == -2)
  }

  @Test("largest remainder and seeding handle extreme totals")
  func remainderAndSeed() {
    #expect(PlanEngine.largestRemainder(total: 100, weights: [1, 1, 1], divisor: 3) == [34, 33, 33])
    #expect(PlanEngine.largestRemainder(total: .max, weights: [0, 0, 0], divisor: 1) == [Int64.max / 3 + 1, Int64.max / 3, Int64.max / 3])
    let parts = PlanEngine.largestRemainder(total: .max, weights: [Int128(Int64.max) * 50, Int128(Int64.max) * 30, Int128(Int64.max) * 20], divisor: 100)
    #expect(parts.reduce(Int128(0)) { $0 + Int128($1) } == Int128(Int64.max))
    let s = PlanEngine.seed(income: .max, split: nil)
    #expect(s.buckets.values.reduce(Int128(0)) { $0 + Int128($1) } == Int128(Int64.max))
    _ = PlanEngine.seed(income: .min, split: nil)
  }
}
