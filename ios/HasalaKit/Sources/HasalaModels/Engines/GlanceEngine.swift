public enum GlanceEngine {
  public static let comingUpDays = 14

  public static func snapshot(
    _ s: LedgerState, now: LocalDateTime, home: HomeSnapshot, amountsHidden: Bool
  ) -> WidgetSnapshot {
    let waiting = s.txns.isEmpty
    var budgetPace: BudgetPaceWidget?
    var nextBill: NextBillWidget?
    var netWorth: NetWorthWidget?
    var projects: [ProjectWidget] = []
    var goals: [GoalWidget] = []
    var today: TodayWidget?
    for w in home.widgets {
      switch w {
      case .budgetPace(let m): budgetPace = m
      case .nextBill(let m): nextBill = m
      case .netWorth(let m): netWorth = m
      case .project(let m): projects.append(m)
      case .goal(let m): goals.append(m)
      case .today(let m): today = m
      case .spentSoFar, .categoryWatch, .comingUp, .toReview: break
      }
    }
    return WidgetSnapshot(
      asOf: now.date,
      amountsHidden: amountsHidden,
      lockScreenDetails: s.prefs.notificationDetail,
      spentSoFar: waiting ? nil : spentSoFar(s, now: now, hero: home.hero),
      budgetPace: waiting ? nil : budgetPace,
      categories: waiting ? [] : categories(s, now: now),
      nextBill: nextBill,
      netWorth: netWorth,
      comingUp: comingUp(s, now: now),
      projects: projects,
      goals: goals,
      toReview: waiting ? nil : toReview(s, now: now),
      today: waiting ? nil : today
    )
  }

  static func spentSoFar(_ s: LedgerState, now: LocalDateTime, hero: SpendHero) -> SpentSoFarWidget? {
    if hero.state == .syncing { return nil }
    let caption: MoneyPhrase
    switch hero.verdict {
    case nil:
      caption = "No plan yet"
    case .overBudget:
      caption = MoneyPhrase([.text("Over by "), .amount(.aed(hero.spent.minor - hero.plan.minor), .rounded, hidden: 3)])
    case .overPace:
      caption = MoneyPhrase([.text("Over pace · "), .amount(hero.left, .rounded, hidden: 3), .text(" left")])
    case .onTrack, .done:
      caption = MoneyPhrase([.text("On track · "), .amount(hero.left, .rounded, hidden: 3), .text(" left")])
    }
    let week = now.date.adding(days: 6)
    let due = s.bills.filter { $0.state == .tracked && !$0.isIncome && $0.nextDue >= now.date && $0.nextDue <= week }
      .sorted { $0.nextDue < $1.nextDue }
    var words: String?
    var named: String?
    if let first = due.first {
      let when = first.nextDue == now.date ? "today" : first.nextDue.weekdayShort
      words = due.count == 1 ? "1 bill due \(when)" : "\(due.count) bills this week"
      named = first.nextDue == now.date ? "\(first.name) today" : "\(first.name) on \(when)"
    }
    return SpentSoFarWidget(
      spent: hero.spent, plan: hero.plan, verdict: hero.verdict,
      progress: Permille.ratio(hero.spent.minor, of: hero.plan.minor),
      tick: hero.tick.map { Permille.ratio($0.minor, of: hero.plan.minor) },
      caption: caption, billWords: words, billNamed: named
    )
  }

  static func categories(_ s: LedgerState, now: LocalDateTime) -> [CategoryWatchWidget] {
    let plan = PlanEngine.snapshot(s, now: now)
    let day = now.date.day
    let days = now.date.yearMonth.days
    let gone = Pace.monthGone(day: day, days: days)
    let month = now.date.yearMonth
    return plan.sections.filter { $0.bucket != .savings }.flatMap(\.rows).filter { $0.budget.minor > 0 }.map { row in
      let spent = Spending.spent(s, category: row.id, in: month)
      let left = row.budget.minor - spent
      let verdict = Pace.verdict(spent: spent, budget: row.budget.minor, day: day, days: days, paced: row.paced)
      return CategoryWatchWidget(
        id: row.id, name: row.name, glyph: row.glyph, hue: row.hue, left: .aed(left),
        perDay: .aed(Pace.perDay(left: left, day: day, days: days) / 100 * 100), verdict: verdict,
        progress: Permille.ratio(spent, of: row.budget.minor), tick: row.paced ? gone : nil
      )
    }
  }

  static func comingUp(_ s: LedgerState, now: LocalDateTime) -> ComingUpWidget? {
    let today = now.date
    let horizon = today.adding(days: comingUpDays)
    let tracked = s.bills.filter { $0.state == .tracked && $0.nextDue <= horizon }
      .filter { s.category($0.categoryID)?.role != .saving }
    let out = tracked.filter { !$0.isIncome }
    let upcoming = out.filter { $0.nextDue >= today }.sorted { $0.nextDue < $1.nextDue }
    let late = out.filter { $0.nextDue < today }.sorted { $0.nextDue < $1.nextDue }
    let income = s.bills.filter { $0.state == .tracked && $0.isIncome && $0.nextDue >= today }
      .min { $0.nextDue < $1.nextDue }.map { [$0] } ?? []
    guard !(upcoming.isEmpty && late.isEmpty && income.isEmpty) else { return nil }
    let rows = (upcoming + late + income).prefix(3).map { b in
      let isLate = !b.isIncome && b.nextDue < today
      let note: String
      if isLate {
        let n = b.nextDue.days(until: today)
        note = "\(n) day\(n == 1 ? "" : "s") past usual"
      } else if b.isIncome {
        note = b.nextDue.short
      } else {
        note = "\(b.nextDue.weekdayShort) · \(ActivityEngine.inDays(today.days(until: b.nextDue)))"
      }
      return ComingUpRow(
        id: b.id, name: b.isIncome ? b.kind : b.name, glyph: ActivityEngine.glyph(b, s), hue: ActivityEngine.hue(b, s), note: note,
        late: isLate, amount: b.amount, isIncome: b.isIncome
      )
    }
    let total = s.homeTotal(out.map(\.amount))
    return ComingUpWidget(days: comingUpDays, total: total.money, rows: Array(rows), mark: total.mark)
  }

  static func toReview(_ s: LedgerState, now: LocalDateTime) -> ToReviewWidget {
    let review = ActivityEngine.reviewSummary(s, now: now)
    return ToReviewWidget(count: review.count, notCounted: review.unplanned)
  }
}
