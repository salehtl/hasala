// Plan · October (Paper board): Ready to assign, the split, buckets with budget rows,
// goals and projects. Built from `LedgerState` for one month.
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
  public var left: Money
  public var budget: Money
  public var progress: Permille
  public var countInPlan: Bool
}

public struct PlanSnapshot: Sendable, Hashable {
  public var month: YearMonth
  public var readyToAssign: Money
  /// "Income 25,000 · planned 24,000".
  public var incomeLine: MoneyPhrase
  /// "Started from 50 / 30 / 20".
  public var startedFrom: String
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
    let ofBudget = MoneyPhrase([.amount(.aed(spent)), .text(" of "), .amount(.aed(budget), .compact)])
    var detail: [PlanDetailPart] = []
    var trailing = PlanRowModel.Trailing.left(.aed(budget - spent))

    switch c.role {
    case .bill:
      let bills = s.bills.filter { $0.categoryID == c.id && $0.state == .tracked && !$0.isIncome }
      let paidNames = bills.filter { $0.nextDue.yearMonth > month }.map(\.name)
      let late = bills.first { $0.nextDue < now.date && $0.nextDue.yearMonth == month }
      let due = bills.first { $0.nextDue >= now.date && $0.nextDue.yearMonth == month }
      if let late {
        let n = late.nextDue.days(until: now.date)
        detail = [.status("\(late.name) · \(n) day\(n == 1 ? "" : "s") late", .error),
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
            .text("\(due.name) \(due.approximate ? "~" : "")"), .amount(due.amount),
            .text(" due \(due.nextDue.weekdayShort)"),
          ])))
        }
      }
    case .saving:
      if budget > 0, spent >= budget {
        trailing = .done
        let via = paymentMerchant(c.id, s, month: month)
        let whole = MoneyPhrase([.amount(.aed(spent), .compact), .text(" of "), .amount(.aed(budget), .compact)])
        detail = [.text(whole)] + (via.map { [.text(MoneyPhrase(stringLiteral: $0))] } ?? [])
      } else {
        detail = [.text(ofBudget)]
      }
    case .everyday, .none:
      if spent == 0, budget > 0 {
        detail = [.text(MoneyPhrase([.text("Nothing yet · "), .amount(.aed(budget), .compact), .text(" planned")]))]
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
        .amount(g.saved, .compact), .text(" of "), .amount(g.target, .compact),
        .text(" · by \(g.by.shortName) \(g.by.year)"),
      ]))],
      progress: progress, verdict: progress.value >= 1000 ? .done : .onTrack, paced: false,
      budget: .aed(budget), spent: .aed(spent)
    )
  }

  static func projectModel(_ p: Project, _ s: LedgerState, today: LocalDate) -> PlanProjectModel {
    let spent = s.txns.filter { $0.projectID == p.id && !$0.archived && $0.direction == .out }
      .reduce(Int64(0)) { $0 + $1.amount.minor }
    let toGo = today.days(until: p.starts)
    let range = p.starts.month == p.ends.month
      ? "\(p.starts.day)–\(p.ends.day) \(CivilCalendar.monthShortNames[p.ends.month - 1])"
      : "\(p.starts.dayMonth)–\(p.ends.dayMonth)"
    let when = toGo > 0 ? "\(toGo) days to go" : (today <= p.ends ? "under way" : "finished")
    return PlanProjectModel(
      id: p.id, name: p.name, glyph: p.glyph, dates: "\(range) · \(when)", left: .aed(p.budget.minor - spent),
      budget: p.budget, progress: Permille.ratio(spent, of: p.budget.minor), countInPlan: p.countInPlan
    )
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
