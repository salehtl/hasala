// Plan · October (Paper board): Ready to assign, the split, buckets with budget rows,
// goals and projects. Built from `LedgerState` for one month. Plan · Dining (category
// detail) and Plan · Japan trip (project detail) come from the same state.
//
// TODO(03a §6): Ready to assign here is income − budgets for the month; the full
// carry-forward, auto-assign and orphan rules come with CoreDomain's Plan engine.

/// One piece of a budget row's second line, joined with " · ".
public enum PlanDetailPart: Sendable, Hashable {
  case text(MoneyPhrase)
  /// A coloured dot and words ("● Over pace").
  case status(String, StatusTone)
}

public struct PlanRowModel: Sendable, Hashable, Identifiable {
  public enum Trailing: Sendable, Hashable {
    case left(Money)
    case done
    case percent(Int)
  }

  public var id: CategoryID
  public var name: String
  public var glyph: Glyph
  public var hue: Hue
  public var trailing: Trailing
  public var detail: [PlanDetailPart]
  public var progress: Permille
  public var verdict: Verdict
  /// Bills and goals get no tick and no pace.
  public var paced: Bool
  public var budget: Money
  public var spent: Money
}

public struct PlanSection: Sendable, Hashable, Identifiable {
  public var id: Bucket { bucket }
  public var bucket: Bucket
  public var left: Money
  public var budget: Money
  public var done: Bool
  public var rows: [PlanRowModel]
}

public struct SplitShare: Sendable, Hashable, Identifiable {
  public var id: Bucket { bucket }
  public var bucket: Bucket
  /// Of everything planned, for the bar's geometry.
  public var share: Permille
  /// "51%".
  public var label: String
}

public struct PlanProjectModel: Sendable, Hashable, Identifiable {
  public var id: ProjectID
  public var name: String
  public var glyph: Glyph
  /// "14–28 Dec · 65 days to go".
  public var dates: String
  /// "14–28 Dec".
  public var range: String?
  /// "65 days to go", "under way", "finished".
  public var when: String?
  public var left: Money?
  public var budget: Money?
  public var spent: Money
  public var pending: Money
  public var progress: Permille
  public var countInPlan: Bool
  public var complete: Bool
  public var completedOn: LocalDate?
}

public struct PlanSnapshot: Sendable, Hashable {
  public var month: YearMonth
  public var readyToAssign: Money
  /// "Income 25,000 · planned 24,000".
  public var incomeLine: MoneyPhrase
  /// "Started from 50 / 30 / 20".
  public var startedFrom: String
  /// "50/30/20".
  public var splitName: String
  public var split: [SplitShare]
  public var sections: [PlanSection]
  public var projects: [PlanProjectModel]

  public func row(_ id: CategoryID) -> PlanRowModel? {
    sections.lazy.flatMap(\.rows).first { $0.id == id }
  }
}

public enum PlanEngine {
  public static func snapshot(_ s: LedgerState, now: LocalDateTime) -> PlanSnapshot {
    let month = now.date.yearMonth
    let day = now.date.day
    let days = month.days
    var sections: [PlanSection] = []
    var planned: Int64 = 0

    for bucket in [Bucket.needs, .wants, .savings] {
      var rows: [PlanRowModel] = []
      var bBudget: Int64 = 0
      var bSpent: Int64 = 0
      for c in s.categories(in: bucket) {
        let budget = s.plan.budget(c.id, month).minor
        let spent = s.spent(c.id, in: month).minor
        if let goal = s.goals.first(where: { $0.categoryID == c.id }) {
          rows.append(goalRow(c, goal, budget: budget, spent: spent))
        } else {
          rows.append(row(c, s, month: month, budget: budget, spent: spent, day: day, days: days, now: now))
        }
        bBudget += budget
        bSpent += spent
      }
      planned += bBudget
      let budgetedRows = rows.filter { $0.budget.minor > 0 }
      let done = bucket == .savings && !budgetedRows.isEmpty && budgetedRows.allSatisfy { $0.verdict == .done }
      sections.append(PlanSection(bucket: bucket, left: .aed(bBudget - bSpent), budget: .aed(bBudget), done: done,
                                  rows: rows))
    }

    let split = sections.map { sec in
      SplitShare(bucket: sec.bucket, share: Permille.ratio(sec.budget.minor, of: planned),
                 label: "\(percentRounded(sec.budget.minor, of: planned))%")
    }
    let rta = s.plan.income.minor - planned
    let incomeLine = MoneyPhrase([
      .text("Income "), .amount(s.plan.income, .compact), .text(" · planned "), .amount(.aed(planned), .compact),
    ])
    let projects = s.projects.filter { !$0.complete }.map { projectModel($0, s, today: now.date) }
    return PlanSnapshot(
      month: month, readyToAssign: .aed(rta), incomeLine: incomeLine,
      startedFrom: "Started from " + s.plan.startingSplit.map(String.init).joined(separator: " / "),
      splitName: s.plan.startingSplit.map(String.init).joined(separator: "/"),
      split: split, sections: sections, projects: projects
    )
  }

  /// Whole percent, rounded half up (Needs 12,350 of 24,000 → 51%).
  static func percentRounded(_ part: Int64, of whole: Int64) -> Int64 {
    guard whole > 0 else { return 0 }
    return (part * 200 + whole) / (whole * 2)
  }

  static func row(
    _ c: Category, _ s: LedgerState, month: YearMonth, budget: Int64, spent: Int64, day: Int, days: Int,
    now: LocalDateTime
  ) -> PlanRowModel {
    let paced = c.role == .everyday
    let verdict = Pace.verdict(spent: spent, budget: budget, day: day, days: days, paced: paced)
    // Row figures hide as three dots (spec 03 §16.16).
    let ofBudget = MoneyPhrase([
      .amount(.aed(spent), hidden: 3), .text(" of "), .amount(.aed(budget), .compact, hidden: 3),
    ])
    var detail: [PlanDetailPart] = []
    var trailing = PlanRowModel.Trailing.left(.aed(budget - spent))

    switch c.role {
    case .bill:
      let bills = s.bills.filter { $0.categoryID == c.id && $0.state == .tracked && !$0.isIncome }
      let paidNames = bills.filter { $0.nextDue.yearMonth > month }.map(\.name)
      let late = bills.first { $0.nextDue < now.date && $0.nextDue.yearMonth == month }
      let due = bills.first { $0.nextDue >= now.date && $0.nextDue.yearMonth == month }
      if let late {
        // "AXA · 3 days past usual · usually the 7th" (Paper Plan · October, Insurance).
        let n = late.nextDue.days(until: now.date)
        detail = [.status("\(shortName(late.name)) · \(n) day\(n == 1 ? "" : "s") past usual", .error),
                  .text(MoneyPhrase(stringLiteral: "usually the \(ordinal(late.usualDay))"))]
      } else if budget > 0, spent >= budget, let paid = paymentDate(c.id, s, month: month) {
        detail = [.status("Paid \(paid.dayMonth)", .success), .text("bill")]
      } else {
        if !paidNames.isEmpty, spent > 0, due == nil {
          detail.append(.text(MoneyPhrase(stringLiteral: listed(paidNames) + " paid")))
        }
        detail.append(.text(ofBudget))
        if let due {
          detail.append(.text(MoneyPhrase([
            .text("\(due.name) \(due.approximate ? "~" : "")"), .amount(due.amount, hidden: 3),
            .text(" due \(due.nextDue.weekdayShort)"),
          ])))
        }
      }
    case .saving:
      if budget > 0, spent >= budget {
        trailing = .done
        let via = paymentMerchant(c.id, s, month: month)
        let whole = MoneyPhrase([
          .amount(.aed(spent), .compact, hidden: 3), .text(" of "), .amount(.aed(budget), .compact, hidden: 3),
        ])
        detail = [.text(whole)] + (via.map { [.text(MoneyPhrase(stringLiteral: $0))] } ?? [])
      } else {
        detail = [.text(ofBudget)]
      }
    case .everyday, .none:
      if spent == 0, budget > 0 {
        detail = [.text(MoneyPhrase([
          .text("Nothing yet · "), .amount(.aed(budget), .compact, hidden: 3), .text(" planned"),
        ]))]
      } else {
        detail = [.text(ofBudget)]
        if verdict == .overPace || verdict == .overBudget { detail.append(.status(verdict.label, verdict.tone)) }
      }
    }
    return PlanRowModel(
      id: c.id, name: c.name, glyph: c.glyph, hue: c.hue, trailing: trailing, detail: detail,
      progress: Permille.ratio(spent, of: budget), verdict: verdict, paced: paced,
      budget: .aed(budget), spent: .aed(spent)
    )
  }

  static func goalRow(_ c: Category, _ g: Goal, budget: Int64, spent: Int64) -> PlanRowModel {
    let progress = Permille.ratio(g.saved.minor, of: g.target.minor)
    return PlanRowModel(
      id: c.id, name: g.name, glyph: g.glyph, hue: c.hue, trailing: .percent(progress.value / 10),
      detail: [.text(MoneyPhrase([
        .amount(g.saved, .compact, hidden: 3), .text(" of "), .amount(g.target, .compact, hidden: 3),
        .text(" · by \(g.by.shortName) \(g.by.year)"),
      ]))],
      progress: progress, verdict: progress.value >= 1000 ? .done : .onTrack, paced: false,
      budget: .aed(budget), spent: .aed(spent)
    )
  }

  static func projectModel(_ p: Project, _ s: LedgerState, today: LocalDate) -> PlanProjectModel {
    let txns = projectTxns(p, s)
    let spent = txns.filter { !$0.needsReview }.reduce(Int64(0)) { $0 + projectMinor($1) }
    let pending = txns.filter(\.needsReview).reduce(Int64(0)) { $0 + projectMinor($1) }
    let range = projectRange(p)
    let when = projectWhen(p, today: today)
    return PlanProjectModel(
      id: p.id, name: p.name, glyph: p.glyph, dates: [range, when].compactMap { $0 }.joined(separator: " · "),
      range: range, when: when, left: p.budget.map { .aed($0.minor - spent) }, budget: p.budget,
      spent: .aed(spent), pending: .aed(pending), progress: Permille.ratio(spent, of: p.budget?.minor ?? 0),
      countInPlan: p.countInPlan, complete: p.complete, completedOn: p.completedOn
    )
  }

  static func projectMinor(_ t: Txn) -> Int64 { t.direction == .out ? t.amount.minor : -t.amount.minor }

  static func projectRange(_ p: Project) -> String? {
    switch (p.starts, p.ends) {
    case let (s?, e?) where s == e: s.dayMonth
    case let (s?, e?) where s.year == e.year && s.month == e.month:
      "\(s.day)–\(e.day) \(CivilCalendar.monthShortNames[e.month - 1])"
    case let (s?, e?): "\(s.dayMonth)–\(e.dayMonth)"
    case let (s?, nil): "From \(s.dayMonth)"
    case let (nil, e?): "Until \(e.dayMonth)"
    case (nil, nil): nil
    }
  }

  static func projectWhen(_ p: Project, today: LocalDate) -> String? {
    if p.complete { return p.completedOn.map { "finished \($0.dayMonth)" } ?? "finished" }
    if let s = p.starts, today.days(until: s) > 0 {
      let n = today.days(until: s)
      return n == 1 ? "1 day to go" : "\(n) days to go"
    }
    if let e = p.ends, today > e { return "ended" }
    return p.starts == nil && p.ends == nil ? nil : "under way"
  }

  static func paymentDate(_ c: CategoryID, _ s: LedgerState, month: YearMonth) -> LocalDate? {
    s.txns.filter { $0.countsInPlan && $0.categoryID == c && $0.postedAt.date.yearMonth == month }
      .map(\.postedAt.date).max()
  }

  /// "Standing order 2 Oct".
  static func paymentMerchant(_ c: CategoryID, _ s: LedgerState, month: YearMonth) -> String? {
    s.txns.filter { $0.countsInPlan && $0.categoryID == c && $0.postedAt.date.yearMonth == month }
      .max { $0.postedAt < $1.postedAt }
      .map { "\($0.merchant) \($0.postedAt.date.dayMonth)" }
  }

  /// "Netflix and Spotify", "A, B and C".
  public static func listed(_ names: [String]) -> String {
    switch names.count {
    case 0: ""
    case 1: names[0]
    default: names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
    }
  }

  /// "7th", "1st", "22nd".
  public static func ordinal(_ n: Int) -> String {
    let suffix: String
    switch (n % 10, n % 100) {
    case (1, let t) where t != 11: suffix = "st"
    case (2, let t) where t != 12: suffix = "nd"
    case (3, let t) where t != 13: suffix = "rd"
    default: suffix = "th"
    }
    return "\(n)\(suffix)"
  }
}

// MARK: - Category detail (Plan · Dining)

/// One day of a category's month on the Day by day chart.
public struct DaySpend: Sendable, Hashable, Identifiable {
  public var id: Int { day }
  public var day: Int
  public var date: LocalDate
  /// What the day added to the category; a refund-only day counts as nothing.
  public var spent: Money
}

/// Day by day (Paper Plan · Dining): what each day of the month so far added to the category,
/// against the daily budget, with the tallest day named over its bar.
public struct DayByDay: Sendable, Hashable {
  /// The tallest day, named over its bar ("Zuma · 412.00").
  public struct Peak: Sendable, Hashable {
    public var day: Int
    /// The merchant when one payment made the day, else "3 payments".
    public var label: String
    public var total: Money
  }

  /// The first of the month to today.
  public var days: [DaySpend]
  public var today: Int
  /// The budget spread over the month's days (1,600 over 31 days is 51.61), rounded down;
  /// zero for a category without a pace (a bill, savings, a goal), which draws no line.
  public var dailyBudget: Money
  /// "1–10 Oct".
  public var range: String
  public var peak: Peak?
  /// "Zuma on Wed 7 Oct was 64% of this month's dining."; none when one payment is all of it.
  public var caption: String?

  /// The day the chart's height is drawn against: the tallest day or the daily budget.
  public var scaleTop: Money { .aed(max(days.map(\.spent.minor).max() ?? 0, dailyBudget.minor)) }
}

/// A rule that sorts into a category ("talabat", "Merchant contains · 28 matches").
public struct CategoryRule: Sendable, Hashable, Identifiable {
  public var id: RuleID
  /// The patterns, "CAREEM or UBER".
  public var title: String
  /// "Merchant contains · 28 matches"; a paused rule says so first.
  public var detail: String
  public var enabled: Bool
}

/// Plan · Dining: one category's month in depth (spec 12 §7). Every figure is the plan row's:
/// the hero is what is left, the bar is spent against the budget with today's tick, the verdict
/// says it in words.
public struct CategoryDetail: Sendable, Hashable {
  public var id: CategoryID
  public var name: String
  public var glyph: Glyph
  public var hue: Hue
  public var bucket: Bucket
  public var month: YearMonth
  public var budget: Money
  public var spent: Money
  /// Budget − spent; below zero when the category is over.
  public var left: Money
  /// Spent of the budget, for the bar (it never runs past its track).
  public var progress: Permille
  /// The month gone, where today's tick sits; nil for a category without a pace (bills,
  /// savings, goals), which draws no tick.
  public var tick: Permille?
  public var verdict: Verdict
  /// The verdict's word: "Over pace", "On track", "Paid", "Done", "Over budget".
  public var verdictWord: String
  /// One fact after the word: "on course for 1,992" (whole dirhams, page 06).
  public var verdictFact: MoneyPhrase?
  /// The line under the verdict: "Spend about AED 43 a day to finish on budget".
  public var advice: MoneyPhrase?
  public var chart: DayByDay
  /// This month's payments in the category, newest first.
  public var transactions: [MiniTxnRow]
  public var rules: [CategoryRule]
}

// MARK: - Project detail (Plan · Japan trip)

/// One category a project's money went to ("Travel", "Emirates flights", 4,120.00).
public struct ProjectCategoryRow: Sendable, Hashable, Identifiable {
  public var id: CategoryID
  public var name: String
  public var glyph: Glyph
  public var hue: Hue
  /// What the money paid for: the notes or merchants, "Emirates flights".
  public var detail: String
  public var spent: Money
}

/// Plan · Japan trip: money set aside for one thing, outside the monthly plan (spec 12 §10).
public struct ProjectDetail: Sendable, Hashable {
  public var id: ProjectID
  public var name: String
  public var glyph: Glyph
  public var budget: Money?
  public var spent: Money
  public var left: Money?
  public var pending: Money
  public var progress: Permille
  /// "14–28 Dec".
  public var range: String?
  /// "65 days to go".
  public var when: String?
  public var countInPlan: Bool
  public var complete: Bool
  /// "Trip spending stays out of October's budgets. It comes from the 12,000 you set aside."
  public var explainer: MoneyPhrase
  public var categories: [ProjectCategoryRow]
  /// The project's payments in the order they were made, as Paper lists them ("Mon 14 Sep ·
  /// Travel", then "Sat 19 Sep · Transport"): a project is one story, told from its start.
  public var transactions: [MiniTxnRow]
  public var draft: ProjectDraft
}

public struct ProjectsList: Sendable, Hashable {
  public var active: [PlanProjectModel]
  public var completed: [PlanProjectModel]
  public var isEmpty: Bool { active.isEmpty && completed.isEmpty }
}

public struct ProjectCandidateFilter: Sendable, Hashable {
  public var from: LocalDate?
  public var to: LocalDate?
  public var merchant: String
  public var category: CategoryID?

  public init(from: LocalDate? = nil, to: LocalDate? = nil, merchant: String = "", category: CategoryID? = nil) {
    self.from = from
    self.to = to
    self.merchant = merchant
    self.category = category
  }

  public var narrowed: Bool {
    from != nil || to != nil || !merchant.trimmingCharacters(in: .whitespaces).isEmpty || category != nil
  }
}

public extension PlanEngine {
  /// Plan · Dining for `id` in the month of `now`; nil when the category is gone.
  static func category(_ id: CategoryID, _ s: LedgerState, now: LocalDateTime) -> CategoryDetail? {
    guard let c = s.category(id) else { return nil }
    let month = now.date.yearMonth
    let (day, days) = (now.date.day, month.days)
    let budget = s.plan.budget(c.id, month).minor
    let spent = s.spent(c.id, in: month).minor
    let left = budget - spent
    let goal = s.goals.first { $0.categoryID == c.id }
    let paced = c.role == .everyday && goal == nil
    let verdict = Pace.verdict(spent: spent, budget: budget, day: day, days: days, paced: paced)

    var word = verdict.label
    var fact: MoneyPhrase?
    var advice: MoneyPhrase?
    switch verdict {
    case .onTrack, .overPace:
      if paced, budget > 0 {
        // Projections are whole dirhams, rounded down (page 06): "on course for 1,992".
        let projected = Pace.projected(spent, day: day, days: days) / 100 * 100
        fact = MoneyPhrase([.text("on course for "), .amount(.aed(projected), .compact, hidden: 3)])
        let perDay = Pace.perDay(left: left, day: day, days: days) / 100 * 100
        if perDay > 0 {
          advice = MoneyPhrase([
            .text("Spend about AED "), .amount(.aed(perDay), .compact, hidden: 3), .text(" a day to finish on budget"),
          ])
        }
      }
    case .done:
      word = c.role == .bill ? "Paid" : "Done"
    case .overBudget:
      fact = MoneyPhrase([.amount(.aed(-left), .compact, hidden: 3), .text(" over")])
    }

    return CategoryDetail(
      id: c.id, name: c.name, glyph: c.glyph, hue: c.hue, bucket: c.bucket, month: month,
      budget: .aed(budget), spent: .aed(spent), left: .aed(left), progress: Permille.ratio(spent, of: budget),
      tick: paced ? Pace.monthGone(day: day, days: days) : nil, verdict: verdict, verdictWord: word,
      verdictFact: fact, advice: advice, chart: dayByDay(c, s, now: now, budget: budget, spent: spent, paced: paced),
      transactions: monthRows(c, s, month: month), rules: rules(c, s)
    )
  }

  /// Day by day from the first of the month to today.
  static func dayByDay(
    _ c: Category, _ s: LedgerState, now: LocalDateTime, budget: Int64, spent: Int64, paced: Bool
  ) -> DayByDay {
    let month = now.date.yearMonth
    let today = now.date.day
    // Each day's payments in the category, as the plan counts them.
    var byDay: [Int: [(txn: Txn, minor: Int64)]] = [:]
    for (t, minor) in lines(c.id, s, month: month) where t.postedAt.date.day <= today {
      byDay[t.postedAt.date.day, default: []].append((t, minor))
    }
    let days = (1...max(1, today)).map { d in
      DaySpend(day: d, date: LocalDate(month.year, month.month, d),
               spent: .aed(max(0, byDay[d]?.reduce(Int64(0)) { $0 + $1.minor } ?? 0)))
    }
    var peak: DayByDay.Peak?
    if let top = days.max(by: { ($0.spent.minor, -$0.day) < ($1.spent.minor, -$1.day) }), top.spent.minor > 0 {
      let payments = (byDay[top.day] ?? []).filter { $0.minor > 0 }
      peak = DayByDay.Peak(
        day: top.day, label: payments.count == 1 ? payments[0].txn.merchant : "\(payments.count) payments",
        total: top.spent)
    }
    // The month's largest payment and its share of what the category spent.
    var caption: String?
    let payments = byDay.values.joined()
    if spent > 0, let big = payments.max(by: { ($0.minor, $1.txn.postedAt) < ($1.minor, $0.txn.postedAt) }),
       big.minor > 0
    {
      let share = percentRounded(big.minor, of: spent)
      if share < 100 {
        caption = "\(big.txn.merchant) on \(big.txn.postedAt.date.short) was \(share)% of this month's "
          + "\(c.name.lowercased())."
      }
    }
    let short = CivilCalendar.monthShortNames[month.month - 1]
    return DayByDay(
      days: days, today: today, dailyBudget: .aed(paced ? max(0, budget) / Int64(month.days) : 0),
      range: today == 1 ? "1 \(short)" : "1–\(today) \(short)", peak: peak, caption: caption)
  }

  /// This month's payments in the category, newest first, each for its share of the
  /// category ("Talabat", "Sat 10 Oct · 13:20", 64.50). A refund reads as money in.
  static func monthRows(_ c: Category, _ s: LedgerState, month: YearMonth) -> [MiniTxnRow] {
    lines(c.id, s, month: month)
      .sorted { $0.txn.postedAt > $1.txn.postedAt }
      .map { t, minor in
        MiniTxnRow(
          id: t.id, merchant: t.title, glyph: c.glyph, hue: c.hue,
          detail: "\(t.postedAt.date.short) · \(t.postedAt.time)", amount: .aed(abs(minor)), isIncome: minor < 0,
          project: s.project(t.projectID).map { MiniTxnRow.Project(id: $0.id, name: $0.name) })
      }
  }

  /// The transactions that count in the category this month, each with its line's amount
  /// (the same set `LedgerState.spent(_:in:)` sums).
  static func lines(_ c: CategoryID, _ s: LedgerState, month: YearMonth) -> [(txn: Txn, minor: Int64)] {
    var out: [(txn: Txn, minor: Int64)] = []
    for t in s.txns where t.countsInPlan && t.postedAt.date.yearMonth == month {
      if let p = s.project(t.projectID), !p.countInPlan { continue }
      let minor = t.lines.filter { $0.category == c }.reduce(Int64(0)) { $0 + $1.minor }
      if t.lines.contains(where: { $0.category == c }) { out.append((t, minor)) }
    }
    return out
  }

  /// The rules that sort into the category, the busiest first.
  static func rules(_ c: Category, _ s: LedgerState) -> [CategoryRule] {
    s.rules.filter { $0.categoryID == c.id }
      .map { r -> (CategoryRule, Int) in
        let n = s.txns.filter { r.matches($0.merchant) || r.matches($0.provenance?.rawMerchant ?? "") }.count
        let how = switch r.match {
        case .contains: "Merchant contains"
        case .startsWith: "Merchant starts with"
        case .exact: "Merchant is"
        }
        let detail = (r.enabled ? "" : "Paused · ") + "\(how) · \(n) match\(n == 1 ? "" : "es")"
        return (CategoryRule(id: r.id, title: r.patterns.joined(separator: " or "), detail: detail,
                             enabled: r.enabled), n)
      }
      .sorted { $0.1 > $1.1 }
      .map(\.0)
  }

  /// Plan · Japan trip for `id`; nil when the project is gone.
  static func project(_ id: ProjectID, _ s: LedgerState, now: LocalDateTime) -> ProjectDetail? {
    guard let p = s.project(id) else { return nil }
    let card = projectModel(p, s, today: now.date)
    let txns = projectTxns(p, s).sorted { $0.postedAt < $1.postedAt }
    var order: [CategoryID] = []
    var byCategory: [CategoryID: [Txn]] = [:]
    for t in txns where !t.needsReview {
      let key = t.categoryID ?? ""
      if byCategory[key] == nil { order.append(key) }
      byCategory[key, default: []].append(t)
    }
    let categories = order.compactMap { key -> ProjectCategoryRow? in
      guard let ts = byCategory[key] else { return nil }
      let c = s.category(key)
      var names: [String] = []
      for t in ts {
        let n = t.note.isEmpty ? t.merchant : t.note
        if !names.contains(n) { names.append(n) }
      }
      let detail = names.count <= 2 ? listed(names) : "\(names[0]), \(names[1]) and \(names.count - 2) more"
      return ProjectCategoryRow(
        id: key, name: c?.name ?? "Not sorted", glyph: c?.glyph ?? .tag, hue: c?.hue ?? .other, detail: detail,
        spent: .aed(ts.reduce(Int64(0)) { $0 + projectMinor($1) }))
    }.sorted { $0.spent.minor > $1.spent.minor }
    let monthName = now.date.yearMonth.name
    let kind = spendingKind(p)
    let explainer: MoneyPhrase
    if p.countInPlan {
      explainer = MoneyPhrase(stringLiteral: "\(kind) spending counts in \(monthName)'s budgets.")
    } else if let budget = p.budget {
      explainer = MoneyPhrase([
        .text("\(kind) spending stays out of \(monthName)'s budgets. It comes from the "),
        .amount(budget, .compact, hidden: 3), .text(" you set aside."),
      ])
    } else {
      explainer = MoneyPhrase(stringLiteral: "\(kind) spending stays out of \(monthName)'s budgets.")
    }
    return ProjectDetail(
      id: p.id, name: p.name, glyph: p.glyph, budget: p.budget, spent: card.spent, left: card.left,
      pending: card.pending, progress: card.progress, range: card.range, when: card.when,
      countInPlan: p.countInPlan, complete: p.complete, explainer: explainer, categories: categories,
      transactions: txns.map { t in
        let c = s.category(t.categoryID)
        return MiniTxnRow(
          id: t.id, merchant: t.title, glyph: c?.glyph ?? .tag, hue: c?.hue ?? .other,
          detail: "\(t.postedAt.date.short)" + (c.map { " · \($0.name)" } ?? ""), amount: t.amount,
          isIncome: t.direction == .in, toReview: t.needsReview)
      },
      draft: p.draft)
  }

  static func projects(_ s: LedgerState, now: LocalDateTime) -> ProjectsList {
    let all = s.projects.map { projectModel($0, s, today: now.date) }
    let completed = all.filter(\.complete).sorted {
      ($0.completedOn ?? LocalDate(1970, 1, 1)) > ($1.completedOn ?? LocalDate(1970, 1, 1))
    }
    return ProjectsList(active: all.filter { !$0.complete }, completed: completed)
  }

  static func projectCandidates(_ project: ProjectID, _ s: LedgerState, filter: ProjectCandidateFilter) -> [MiniTxnRow] {
    let term = filter.merchant.trimmingCharacters(in: .whitespaces).lowercased()
    return s.txns.filter { t in
      guard t.projectID != project, !t.archived, !t.isTransfer, !t.isHeldCopy else { return false }
      if let f = filter.from, t.postedAt.date < f { return false }
      if let to = filter.to, t.postedAt.date > to { return false }
      if let c = filter.category, t.categoryID != c, !t.splits.contains(where: { $0.categoryID == c }) { return false }
      if !term.isEmpty, !t.title.lowercased().contains(term), !t.note.lowercased().contains(term) { return false }
      return true
    }
    .sorted { $0.postedAt > $1.postedAt }
    .map { t in
      let c = s.category(t.categoryID)
      let other = s.project(t.projectID).map { " · in \($0.name)" } ?? ""
      return MiniTxnRow(
        id: t.id, merchant: t.title, glyph: c?.glyph ?? .tag, hue: c?.hue ?? .other,
        detail: "\(t.postedAt.date.short)" + (c.map { " · \($0.name)" } ?? "") + other, amount: t.amount,
        toReview: t.needsReview)
    }
  }

  /// What a project's spending is called in its explainer: "Trip" for a trip (Paper's words on
  /// Japan trip, 5JD-0), "Project" for any other. Never the name itself, which already heads
  /// the screen and may not read as a noun ("Dad's 60th spending").
  static func spendingKind(_ p: Project) -> String {
    p.glyph == .travel ? "Trip" : "Project"
  }

  /// What a project spent: its payments, not archived and not transfers.
  static func projectTxns(_ p: Project, _ s: LedgerState) -> [Txn] {
    s.txns.filter { $0.projectID == p.id && !$0.archived && !$0.isTransfer && !$0.isHeldCopy }
  }

  /// A bill's short name for a row's one fact: "AXA" for "AXA Insurance", "Rent" for
  /// "Rent · Al Habtoor". A name led by a brand in capitals keeps the brand; any other name
  /// keeps what comes before " · ".
  static func shortName(_ name: String) -> String {
    let head = name.firstRange(of: " · ").map { String(name[..<$0.lowerBound]) } ?? name
    let words = head.split(separator: " ")
    if words.count > 1, let first = words.first, first.count >= 2,
       first.allSatisfy({ $0.isUppercase || $0.isNumber })
    {
      return String(first)
    }
    return head
  }
}
