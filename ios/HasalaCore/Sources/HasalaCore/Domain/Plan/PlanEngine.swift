// `PlanEngine` (spec 03a §6): pure plan math over the folded plan records, the
// counted money lines (03c §3.9.3 `money_line`), the taxonomy, bill
// expectations and `today`. No I/O, no clock. Money is `Int64` minor units
// with `Int128` products; `÷` is floor division over non-negative operands.
import CoreCategorize
import CoreReplay
import CoreTime
import HasalaText

private func planAdd(_ a: Int64, _ b: Int64) -> Int64 { Int64(clamping: Int128(a) + Int128(b)) }

private func planSub(_ a: Int64, _ b: Int64) -> Int64 { Int64(clamping: Int128(a) - Int128(b)) }

private func planSum<S: Sequence>(_ s: S) -> Int64 where S.Element == Int64 {
  Int64(clamping: s.reduce(Int128(0)) { $0 + Int128($1) })
}

/// One `money_line` row (03c §3.9.3).
public struct MoneyLine: Sendable, Equatable {
  public enum Flow: String, Sendable {
    case spend, refund, income, excluded
    case uncategorizedOut = "uncategorized_out"
    case uncategorizedIn = "uncategorized_in"
  }
  public var txnID: String
  public var partIdx: Int
  public var category: String?
  public var direction: String
  public var localDate: CivilDate
  public var signedHome: Int64?
  public var flow: Flow
  public var confirmed: Bool
  public var inPlan: Bool
  public var projectID: String?
  public var displayName: String
  public var postedMs: Int64

  public init(
    txnID: String, partIdx: Int = -1, category: String?, direction: String, localDate: CivilDate, signedHome: Int64?, flow: Flow,
    confirmed: Bool, inPlan: Bool = true, projectID: String? = nil, displayName: String = "", postedMs: Int64 = 0
  ) {
    self.txnID = txnID
    self.partIdx = partIdx
    self.category = category
    self.direction = direction
    self.localDate = localDate
    self.signedHome = signedHome
    self.flow = flow
    self.confirmed = confirmed
    self.inPlan = inPlan
    self.projectID = projectID
    self.displayName = displayName
    self.postedMs = postedMs
  }

  public var localMonth: CivilMonth { localDate.yearMonth }

  /// 03a §6.2 `countsInPlan`.
  public var countsInPlan: Bool { confirmed && signedHome != nil && (flow == .spend || flow == .refund) && inPlan }
}

/// 03b §3.12 `BillExpectation`, as the plan reads it.
public struct BillExpectation: Sendable, Equatable {
  public enum Status: String, Sendable {
    case upcoming, due, late, paid, skipped, cancelled

    var isUnpaid: Bool { self == .upcoming || self == .due || self == .late }
  }
  public var billID: String
  public var categoryID: String
  public var payee: String
  public var expectedDay: CivilDate
  public var amount: Int64
  public var isEstimate: Bool
  public var status: Status
  public var paidDay: CivilDate?
  public var usualDayOfMonth: Int?

  public init(
    billID: String, categoryID: String, payee: String, expectedDay: CivilDate, amount: Int64, isEstimate: Bool, status: Status,
    paidDay: CivilDate? = nil, usualDayOfMonth: Int? = nil
  ) {
    self.billID = billID
    self.categoryID = categoryID
    self.payee = payee
    self.expectedDay = expectedDay
    self.amount = amount
    self.isEstimate = isEstimate
    self.status = status
    self.paidDay = paidDay
    self.usualDayOfMonth = usualDayOfMonth
  }
}

public enum Phase: Sendable, Equatable {
  case past, future
  case current(day: Int, days: Int)
}

public enum PaceVerdict: String, Sendable {
  case onTrack, overPace, overBudget, underBudget, noBudget
  case done, short, inProgress
}

/// 03a §6.7 figures (current phase only where marked).
public struct PaceFigures: Sendable, Equatable {
  public var verdict: PaceVerdict
  public var budget: Int64
  public var spent: Int64
  public var left: Int64
  /// `(max(S,0)·100) ÷ B` (current, B > 0).
  public var usedPercent: Int64?
  /// `(d·100) ÷ D` (current).
  public var monthPercent: Int64?
  /// `S ≤ 0 ? 0 : (S·D) ÷ d` (current).
  public var projection: Int64?
  /// `L > 0 ? L ÷ (D − d + 1) : nil` (current).
  public var allowancePerDay: Int64?
  /// `B ÷ D`.
  public var dailyBudget: Int64?
  /// overPace only: `ceil(B·d / S)`.
  public var runOutDay: Int?
  public var daysEarly: Int?
}

public struct EverydayHero: Sendable, Equatable {
  public var month: CivilMonth
  public var phase: Phase
  public var budget: Int64
  public var spent: Int64
  public var left: Int64
  public var pace: PaceFigures
  public var billsPaid: Int64
  /// nil when there is no bill expectation at all for the month ("—").
  public var billsToCome: Int64?
  /// `E == 0 && SE == 0`: the "Set your plan" hero.
  public var isEmpty: Bool { budget == 0 && spent == 0 }
}

public struct BucketFigures: Sendable, Equatable {
  public var bucket: Bucket
  public var assigned: Int64
  public var spent: Int64
  public var left: Int64 { planSub(assigned, spent) }
}

public struct IncomeBreakdown: Sendable, Equatable {
  public var total: Int64
  public var expected: Int64
  public var received: Int64
}

public struct PlanCategoryRow: Sendable, Equatable {
  public var info: CategoryInfo
  /// `everyday` or `bills` for need/want; nil for saving.
  public var role: String?
  public var assigned: Int64
  public var spent: Int64
  public var left: Int64 { planSub(assigned, spent) }
  public var pace: PaceFigures
}

public struct GoalProgress: Sendable, Equatable {
  public var goalID: String
  public var progress: Int64
  public var target: Int64
  public var percent: Int64
  /// 03a §6.9 `required(g, M)`.
  public var required: Int64?
}

public struct PlanEngine: Sendable {
  public let plan: PlanState
  public let taxonomy: TaxonomyView
  public let lines: [MoneyLine]
  public let bills: [BillExpectation]
  public let template: BudgetSplit?
  public let today: CivilDate
  /// Goals (id, record), for auto-assign's goal step.
  public let goals: [(id: String, goal: Goal)]
  /// Every project-linked line, whatever its month (03c §6.1 `spent_net` covers
  /// all months); nil reads `lines`.
  public let projectLines: [MoneyLine]?

  /// 03a §6.20 default roles.
  public static let defaultBills: [String] = ["rent", "utilities", "insurance", "subscriptions"]
  public static let paydayWindow = 4
  static let defaultSplit = BudgetSplit(need: 50, want: 30, saving: 20)

  public init(
    plan: PlanState, taxonomy: TaxonomyView, lines: [MoneyLine], bills: [BillExpectation] = [], template: BudgetSplit? = nil,
    goals: [(id: String, goal: Goal)] = [], today: CivilDate, projectLines: [MoneyLine]? = nil
  ) {
    self.projectLines = projectLines
    self.plan = plan
    self.taxonomy = taxonomy
    self.lines = lines
    self.bills = bills
    self.template = template
    self.goals = goals
    self.today = today
  }

  // MARK: Phase and roles

  public func phase(_ m: CivilMonth) -> Phase {
    if m < today.yearMonth { return .past }
    if today.yearMonth < m { return .future }
    return .current(day: today.day, days: m.daysInMonth)
  }

  /// `role(c) = roles[c] ?? default(c)` (need/want spending only; nil otherwise).
  public func role(_ c: String) -> String? {
    guard let info = taxonomy.info(c), info.kind == .spending, info.bucket == .need || info.bucket == .want else { return nil }
    if let r = plan.roles[c]?.role { return r }
    return Self.defaultBills.contains(c) ? "bills" : "everyday"
  }

  // MARK: Assigned (03a §6.1)

  public func assigned(_ m: CivilMonth, _ c: String) -> Int64 {
    guard let row = plan.cells[c] else { return 0 }
    if let cell = row[m.wire], let set = cell.latestSet { return planAdd(set, cell.movesSinceSet) }
    var base: Int64 = 0
    var best: CivilMonth?
    for (key, cell) in row {
      guard let km = CivilMonth(wire: key), km < m, let onward = cell.onwardSet else { continue }
      if best == nil || best! < km {
        best = km
        base = onward
      }
    }
    return planAdd(base, row[m.wire]?.movesAll ?? 0)
  }

  /// Plan start month: the earliest month holding a set.
  public var planStart: CivilMonth? {
    var out: CivilMonth?
    for (_, row) in plan.cells {
      for (key, cell) in row where cell.latestSet != nil {
        if let km = CivilMonth(wire: key), out == nil || km < out! { out = km }
      }
    }
    return out
  }

  // MARK: Activity (03a §6.2)

  public func activity(_ m: CivilMonth) -> [String: Int64] {
    var out: [String: Int128] = [:]
    for l in lines where l.localMonth == m && l.countsInPlan {
      guard let c = l.category, let v = l.signedHome else { continue }
      out[c, default: 0] += Int128(v)
    }
    return out.mapValues { Int64(clamping: $0) }
  }

  public func spent(_ m: CivilMonth, _ c: String) -> Int64 { activity(m)[c] ?? 0 }

  /// Counted rows with no home amount yet (03a §6.2, PO-17).
  public func unconverted(_ m: CivilMonth) -> Int {
    lines.filter { $0.localMonth == m && $0.confirmed && ($0.flow == .spend || $0.flow == .refund) && $0.signedHome == nil }.count
  }

  // MARK: Income (03a §6.3)

  private func incomeCategories() -> [String] { taxonomy.ordered.filter { $0.kind == .income }.map(\.id) }

  /// The month an income line belongs to, by the payday rule.
  func attributedMonth(_ l: MoneyLine) -> CivilMonth {
    let x = l.localDate
    let xm = x.yearMonth
    var best: (day: CivilDate, month: CivilMonth, dist: Int64)?
    for s in plan.incomeSources.values where s.active && utf8Equal(s.categoryID, l.category ?? "") {
      for off in [-1, 0, 1] {
        guard let y = xm.adding(months: off) else { continue }
        let day = CivilDate(year: y.year, month: y.month, day: min(Int(s.payday), y.daysInMonth))!
        let dist = abs(day.daysSinceEpoch - x.daysSinceEpoch)
        let better: Bool
        if let b = best {
          if dist != b.dist { better = dist < b.dist }
          else if (y == xm) != (b.month == xm) { better = y == xm }
          else { better = y < b.month }
        } else {
          better = true
        }
        if better { best = (day, y, dist) }
      }
    }
    if let b = best, b.month != xm, b.dist <= Int64(Self.paydayWindow) { return b.month }
    return xm
  }

  /// `received_c(M)`: credits +home, debits −home, over income lines attributed to `M`.
  public func received(_ m: CivilMonth, _ c: String) -> Int64 {
    var r: Int128 = 0
    for l in lines where l.flow == .income && l.confirmed && utf8Equal(l.category ?? "", c) {
      guard let v = l.signedHome else { continue }
      if attributedMonth(l) == m { r += Int128(v) }
    }
    return Int64(clamping: r)
  }

  public func expected(_ c: String) -> Int64 {
    planSum(plan.incomeSources.values.filter { $0.active && utf8Equal($0.categoryID, c) }.map(\.amountMinor))
  }

  public func income(_ m: CivilMonth) -> IncomeBreakdown {
    var total: Int128 = 0
    var exp: Int128 = 0
    var rec: Int128 = 0
    let past = phase(m) == .past
    for c in incomeCategories() {
      let r = received(m, c)
      let e = expected(c)
      exp += Int128(e)
      rec += Int128(r)
      total += Int128(past ? r : max(e, r))
    }
    return IncomeBreakdown(total: Int64(clamping: total), expected: Int64(clamping: exp), received: Int64(clamping: rec))
  }

  // MARK: Ready to assign and buckets (03a §6.4-§6.5)

  public func planned(_ m: CivilMonth) -> Int64 {
    planSum(taxonomy.ordered.filter { $0.kind == .spending }.map { assigned(m, $0.id) })
  }

  public func readyToAssign(_ m: CivilMonth) -> Int64 { planSub(income(m).total, planned(m)) }

  public func buckets(_ m: CivilMonth) -> [BucketFigures] {
    let act = activity(m)
    return Bucket.allCases.map { b in
      let cats = taxonomy.ordered.filter { $0.kind == .spending && $0.bucket == b }
      return BucketFigures(
        bucket: b, assigned: planSum(cats.map { assigned(m, $0.id) }), spent: planSum(cats.map { act[$0.id] ?? 0 }))
    }
  }

  /// 03a §6.5 split shares by largest remainder; nil when hidden.
  public func splitShares(_ m: CivilMonth) -> [Bucket: Int64]? {
    let bs = buckets(m)
    let p = bs.reduce(Int128(0)) { $0 + Int128($1.assigned) }
    guard p > 0, bs.allSatisfy({ $0.assigned >= 0 }) else { return nil }
    let weights = bs.map { Int128($0.assigned) * 100 }
    let parts = Self.largestRemainder(total: 100, weights: weights, divisor: p)
    var out: [Bucket: Int64] = [:]
    for (i, b) in bs.enumerated() { out[b.bucket] = parts[i] }
    return out
  }

  /// `q_i = w_i ÷ P`; the `total − Σq` largest remainders get +1, ties to the earlier index.
  static func largestRemainder(total: Int64, weights: [Int128], divisor: Int128) -> [Int64] {
    var q = weights.map { Int64(clamping: $0 / divisor) }
    let r = weights.map { $0 % divisor }
    let left = Int128(total) - q.reduce(Int128(0)) { $0 + Int128($1) }
    let order = r.indices.sorted { r[$0] != r[$1] ? r[$0] > r[$1] : $0 < $1 }
    guard left > 0, !order.isEmpty else { return q }
    let each = left / Int128(order.count)
    let extra = left % Int128(order.count)
    for (k, idx) in order.enumerated() {
      q[idx] = Int64(clamping: Int128(q[idx]) + each + (Int128(k) < extra ? 1 : 0))
    }
    return q
  }

  // MARK: Pace (03a §6.7)

  public enum PaceKind: Sendable { case everyday, bills, saving }

  public func pace(budget b: Int64, spent s: Int64, phase: Phase, kind: PaceKind) -> PaceFigures {
    var f = PaceFigures(verdict: .onTrack, budget: b, spent: s, left: planSub(b, s))
    switch kind {
    case .bills:
      f.verdict = s > b ? .overBudget : .onTrack
      return f
    case .saving:
      if b > 0 && s >= b { f.verdict = .done } else if phase == .past && s < b { f.verdict = .short } else { f.verdict = .inProgress }
      return f
    case .everyday:
      break
    }
    if b <= 0 {
      f.verdict = s > 0 ? .overBudget : .noBudget
    } else if s > b {
      f.verdict = .overBudget
    } else {
      switch phase {
      case .future: f.verdict = .onTrack
      case .past: f.verdict = .underBudget
      case .current(let d, let dd):
        f.verdict = Int128(s) * Int128(dd) > Int128(b) * Int128(d) ? .overPace : .onTrack
      }
    }
    if case .current(let d, let dd) = phase {
      if b > 0 { f.usedPercent = Int64(clamping: Int128(max(s, 0)) * 100 / Int128(b)) }
      f.monthPercent = Int64(d * 100 / dd)
      f.projection = s <= 0 ? 0 : Int64(clamping: Int128(s) * Int128(dd) / Int128(d))
      f.allowancePerDay = f.left > 0 ? f.left / Int64(dd - d + 1) : nil
      f.dailyBudget = b / Int64(dd)
      if f.verdict == .overPace, s > 0 {
        let num = Int128(b) * Int128(d)
        let day = Int(clamping: (num + Int128(s) - 1) / Int128(s))
        f.runOutDay = day
        f.daysEarly = dd - day
      }
    }
    return f
  }

  // MARK: The everyday hero (03a §6.6)

  private func categories(role r: String) -> [CategoryInfo] {
    taxonomy.ordered.filter { $0.kind == .spending && ($0.bucket == .need || $0.bucket == .want) && role($0.id) == r }
  }

  public func everydayCategories() -> [CategoryInfo] { categories(role: "everyday") }

  public func billsCategories() -> [CategoryInfo] { categories(role: "bills") }

  public func hero(_ m: CivilMonth) -> EverydayHero {
    let act = activity(m)
    let everyday = everydayCategories()
    let e = planSum(everyday.map { assigned(m, $0.id) })
    let se = planSum(everyday.map { act[$0.id] ?? 0 })
    let billsPaid = planSum(billsCategories().map { act[$0.id] ?? 0 })
    let monthBills = bills.filter { $0.expectedDay.yearMonth == m }
    let toCome =
      monthBills.isEmpty
      ? nil
      : planSum(monthBills.filter { $0.status.isUnpaid && role($0.categoryID) == "bills" }.map(\.amount))
    let ph = phase(m)
    return EverydayHero(
      month: m, phase: ph, budget: e, spent: se, left: planSub(e, se), pace: pace(budget: e, spent: se, phase: ph, kind: .everyday),
      billsPaid: billsPaid, billsToCome: toCome)
  }

  // MARK: Category rows (03a §6.7-§6.9, §6.19)

  /// The spending rows shown for `m`: active with A ≠ 0 or S ≠ 0, or retired with either.
  public func categoryRows(_ m: CivilMonth) -> [PlanCategoryRow] {
    let act = activity(m)
    let ph = phase(m)
    var out: [PlanCategoryRow] = []
    for info in taxonomy.ordered where info.kind == .spending {
      let a = assigned(m, info.id)
      let s = act[info.id] ?? 0
      if a == 0 && s == 0 { continue }
      let r = role(info.id)
      let kind: PaceKind = info.bucket == .saving ? .saving : (r == "bills" ? .bills : .everyday)
      out.append(PlanCategoryRow(info: info, role: r, assigned: a, spent: s, pace: pace(budget: a, spent: s, phase: ph, kind: kind)))
    }
    return out
  }

  /// 03a §6.5 "✓ Done": every saving category with A > 0 has S ≥ A, and one has A > 0.
  public func savingsDone(_ m: CivilMonth) -> Bool {
    let act = activity(m)
    let funded = taxonomy.ordered.filter { $0.kind == .spending && $0.bucket == .saving && assigned(m, $0.id) > 0 }
    return !funded.isEmpty && funded.allSatisfy { (act[$0.id] ?? 0) >= assigned(m, $0.id) }
  }

  // MARK: Goals (03a §6.9)

  /// Q-GOAL-SAVED: confirmed spend/refund lines of `category` with `since ≤ local_date ≤ until`.
  public func goalSaved(category: String, since: CivilDate, until: CivilDate) -> Int64 {
    planSum(
      lines.filter {
        $0.confirmed && ($0.flow == .spend || $0.flow == .refund) && utf8Equal($0.category ?? "", category)
          && since <= $0.localDate && $0.localDate <= until
      }.map { $0.signedHome ?? 0 })
  }

  public func goalProgress(id: String, _ g: Goal, month m: CivilMonth) -> GoalProgress {
    var progress: Int64 = 0
    var required: Int64?
    if g.source.kind == "category", let c = g.source.categoryID, let since = g.source.since.flatMap(CivilDate.init(wire:)) {
      progress = planAdd(g.startingMinor, goalSaved(category: c, since: since, until: m.lastDay))
      if let t = g.targetMonth.flatMap(CivilMonth.init(wire:)), !(t < m), let prev = m.adding(months: -1) {
        let before = planAdd(g.startingMinor, goalSaved(category: c, since: since, until: prev.lastDay))
        let remaining = max(0, planSub(g.targetMinor, before))
        let monthsLeft = Int64(monthsBetween(m, t) + 1)
        required = Int64(clamping: (Int128(remaining) + Int128(monthsLeft) - 1) / Int128(monthsLeft))
      }
    }
    let pct = g.targetMinor > 0 ? min(100, Int64(clamping: Int128(max(progress, 0)) * 100 / Int128(g.targetMinor))) : 0
    return GoalProgress(goalID: id, progress: progress, target: g.targetMinor, percent: pct, required: required)
  }

  // MARK: Projects (03c §6.1 roll-ups, as 03a §6.10 shows them)

  /// `spent_net`: confirmed lines linked to the project, flows spend, refund and
  /// uncategorized_out (debit +, credit −), over `projectLines` (every month)
  /// or, without them, the months in `lines`.
  public func projectSpent(_ projectID: String) -> Int64 {
    planSum(
      (projectLines ?? lines).filter {
        $0.confirmed && $0.projectID.map { utf8Equal($0, projectID) } == true
          && ($0.flow == .spend || $0.flow == .refund || $0.flow == .uncategorizedOut)
      }.map { $0.signedHome ?? 0 })
  }

  // MARK: Auto-assign (03a §6.11)

  /// The allocations that bring Ready to assign to 0: bill shortfalls, goal
  /// targets, template deficits, the remainder by the template, then within
  /// each bucket by cumulative floor over the assigned amounts. Empty for a
  /// past month or when Ready to assign is not positive.
  public func autoAssign(_ m: CivilMonth) -> [(category: String, amount: Int64)] {
    let ph = phase(m)
    var r = readyToAssign(m)
    guard ph != .past, r > 0 else { return [] }
    var a: [String: Int64] = [:]
    var touched: [String] = []
    func give(_ c: String, _ v: Int64) {
      guard v > 0 else { return }
      if a[c] == nil { touched.append(c) }
      a[c] = planAdd(a[c] ?? 0, v)
    }
    let act = activity(m)
    // 1. Bill shortfalls, by earliest unpaid expected day, then sortKey.
    let monthBills = bills.filter { $0.expectedDay.yearMonth == m }
    let billCats = billsCategories().map { info -> (CategoryInfo, CivilDate?) in
      (info, monthBills.filter { utf8Equal($0.categoryID, info.id) && $0.status.isUnpaid }.map(\.expectedDay).min())
    }.sorted { x, y in
      switch (x.1, y.1) {
      case (let p?, let q?) where p != q: return p < q
      case (.some, nil): return true
      case (nil, .some): return false
      default: return x.0.sortKey < y.0.sortKey
      }
    }
    for (info, _) in billCats where r > 0 {
      let claim = planSum(monthBills.filter { utf8Equal($0.categoryID, info.id) && $0.status.isUnpaid }.map(\.amount))
      let short = max(0, Int64(clamping: Int128(act[info.id] ?? 0) + Int128(claim) - Int128(assigned(m, info.id))))
      let g = min(r, short)
      give(info.id, g)
      r = planSub(r, g)
    }
    // 2. Goal targets, grouped by funding category, in (target_month, id) order.
    var needByFund: [(String, Int64)] = []
    let sortedGoals = goals.filter { $0.goal.status == "active" && $0.goal.source.kind == "category" }
      .sorted { x, y in
        let tx = x.goal.targetMonth ?? "9999-99", ty = y.goal.targetMonth ?? "9999-99"
        return tx != ty ? compareUTF8(tx, ty) < 0 : compareUTF8(x.id, y.id) < 0
      }
    for g in sortedGoals {
      guard let f = g.goal.source.categoryID, let req = goalProgress(id: g.id, g.goal, month: m).required else { continue }
      if let i = needByFund.firstIndex(where: { $0.0 == f }) { needByFund[i].1 = planAdd(needByFund[i].1, req) } else { needByFund.append((f, req)) }
    }
    for (f, req) in needByFund where r > 0 {
      let need = max(0, Int64(clamping: Int128(req) - Int128(assigned(m, f)) - Int128(a[f] ?? 0)))
      let g = min(r, need)
      give(f, g)
      r = planSub(r, g)
    }
    // 3. Template deficits; 4. the remainder by the template.
    let t = template ?? Self.defaultSplit
    let pct: [Bucket: Int64] = [.need: t.need, .want: t.want, .saving: t.saving]
    let inc = income(m).total
    var giveB: [Bucket: Int64] = [:]
    var defs: [Int64] = []
    for b in Bucket.allCases {
      let target = Int64(clamping: Int128(inc) * Int128(pct[b]!) / 100)
      let cur = taxonomy.ordered.filter { $0.kind == .spending && $0.bucket == b }.reduce(Int128(0)) {
        $0 + Int128(assigned(m, $1.id)) + Int128(a[$1.id] ?? 0)
      }
      defs.append(Int64(clamping: max(0, Int128(target) - cur)))
    }
    let sumDef = defs.reduce(Int128(0)) { $0 + Int128($1) }
    if sumDef > 0 {
      let parts = sumDef <= Int128(r) ? defs : Self.largestRemainder(total: r, weights: defs.map { Int128($0) * Int128(r) }, divisor: sumDef)
      for (i, b) in Bucket.allCases.enumerated() { giveB[b] = planAdd(giveB[b] ?? 0, parts[i]) }
      r = Int64(clamping: Int128(r) - parts.reduce(Int128(0)) { $0 + Int128($1) })
    }
    if r > 0 {
      let parts = Self.largestRemainder(total: r, weights: Bucket.allCases.map { Int128(r) * Int128(pct[$0]!) }, divisor: 100)
      for (i, b) in Bucket.allCases.enumerated() { giveB[b] = planAdd(giveB[b] ?? 0, parts[i]) }
      r = 0
    }
    // 5. Within each bucket, by cumulative floor over A(M,c) in sortKey order.
    for b in Bucket.allCases {
      let total = giveB[b] ?? 0
      guard total > 0 else { continue }
      let pool = taxonomy.ordered.filter {
        $0.kind == .spending && $0.bucket == b && (b == .saving || role($0.id) == "everyday")
      }
      var recipients = pool.filter { assigned(m, $0.id) > 0 }.map { ($0.id, assigned(m, $0.id)) }
      if recipients.isEmpty { recipients = pool.filter(\.active).map { ($0.id, Int64(1)) } }
      let w = recipients.reduce(Int128(0)) { $0 + Int128($1.1) }
      guard w > 0 else { continue }
      var cum: Int128 = 0
      for (c, wi) in recipients {
        let before = Int128(total) * cum / w
        cum += Int128(wi)
        give(c, Int64(clamping: Int128(total) * cum / w - before))
      }
    }
    // 6. In order of first touch.
    return touched.map { ($0, a[$0]!) }
  }

  // MARK: Setup 2 seeding (03a §6.12)

  public static let seedWeights: [(Bucket, [(String, Int64)])] = [
    (.need, [("rent", 6000), ("utilities", 700), ("groceries", 1800), ("transport", 700), ("healthcare", 300), ("insurance", 500)]),
    (.want, [("dining", 2400), ("entertainment", 900), ("shopping", 2200), ("travel", 3500), ("subscriptions", 1000)]),
    (.saving, [("savings", 6000), ("investments", 4000), ("debt", 0)]),
  ]

  /// Bucket amounts by largest remainder over the template, then category seeds
  /// by cumulative floor over the weights. Zero-weight categories are omitted.
  public static func seed(income: Int64, split: BudgetSplit?) -> (buckets: [Bucket: Int64], categories: [(String, Int64)]) {
    let s = split ?? defaultSplit
    let parts = largestRemainder(
      total: income, weights: [s.need, s.want, s.saving].map { Int128(income) * Int128($0) }, divisor: 100)
    var buckets: [Bucket: Int64] = [:]
    var cats: [(String, Int64)] = []
    for (i, (b, weights)) in seedWeights.enumerated() {
      let give = Int128(parts[i])
      buckets[b] = parts[i]
      let w = weights.reduce(Int128(0)) { $0 + Int128($1.1) }
      var cum: Int128 = 0
      for (c, wi) in weights {
        let before = give * cum / w
        cum += Int128(wi)
        let part = Int64(clamping: give * cum / w - before)
        if wi > 0 { cats.append((c, part)) }
      }
    }
    return (buckets, cats)
  }
}
