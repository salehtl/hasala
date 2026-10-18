// Home · Default (Paper 14O7-0), Over pace (2S7-0), Over budget (18WY-0), September (14W1-0)
// and Last 3 months (1531-0): the hero with its pace, the bell's list and the widget canvas,
// built from `LedgerState` (spec 10 §2, page 06 §6.4, page 16 §01–02).
//
// TODO(spec 04 §16.2 H2): the widget order comes from `prefs.homeWidgets`.

public enum HomeEngine {
  public static func snapshot(_ s: LedgerState, now: LocalDateTime, period: Period? = nil) -> HomeSnapshot {
    let today = now.date.yearMonth
    let header = HeaderState(avatarInitial: s.profile.initial)
    let notifications = NotificationsEngine.snapshot(s, now: now)
    let chosen = period?.clamped(to: today)
    guard let p = chosen, p != .month(today) else {
      let plan = PlanEngine.snapshot(s, now: now)
      return HomeSnapshot(
        header: header, hero: hero(s, now: now, plan: plan), notifications: notifications,
        widgets: widgets(s, now: now, plan: plan))
    }
    if p.isMonth {
      let month = p.first
      let plan = PlanEngine.snapshot(s, now: LocalDateTime(date: month.lastDay, hour: 23, minute: 59))
      return HomeSnapshot(
        header: header, hero: endedHero(s, month: month, plan: plan), notifications: notifications,
        widgets: [.budgetPace(budgetPace(plan, label: "Ended \(month.lastDay.dayMonth)"))],
        period: p, canvasTitle: month.name, aboutNow: aboutNow(s, now: now, review: ReviewWindow(p)))
    }
    return HomeSnapshot(
      header: header, hero: rangeHero(s, period: p, now: now), notifications: notifications, widgets: [],
      period: p, canvasTitle: p.title, aboutNow: aboutNow(s, now: now, review: ReviewWindow(p)))
  }

  // MARK: - The hero

  /// The month as one bar (page 06 §6.4): everything spent (`Spending`) against the needs + wants plan,
  /// the tick where spending should be today, and the verdict against the tick. Integer money
  /// throughout; only the view turns a share into geometry.
  public static func hero(_ s: LedgerState, now: LocalDateTime, plan: PlanSnapshot) -> SpendHero {
    let month = now.date.yearMonth
    let day = now.date.day
    let days = month.days
    func section(_ b: Bucket) -> PlanSection? { plan.sections.first { $0.bucket == b } }
    let needs = section(.needs)
    let wants = section(.wants)
    let savings = section(.savings)
    let total = Spending.total(s, in: month)
    let budget = (needs?.budget.minor ?? 0) + (wants?.budget.minor ?? 0)
    let overline = "Day \(day) of \(days)"
    let tiles = heroTiles(needs: spent(needs), wants: spent(wants), saved: spent(savings))

    // S9: the first import is still running and nothing has arrived this month: the figure
    // fills in as batches land, beside Home's import pill.
    let anyThisMonth = s.txns.contains { $0.postedAt.date.yearMonth == month && !$0.archived }
    if s.mailbox.status == .importing, !anyThisMonth {
      return SpendHero(
        state: .syncing, overline: overline, spent: .aed(0), plan: .aed(budget), tick: nil, verdict: nil,
        word: "Getting your transactions…", fact: nil, caption: "spent this month", tiles: tiles,
        wash: .sky)
    }

    // S8: spending still counts, with nothing to measure it against.
    guard budget > 0 else {
      return SpendHero(
        state: .noPlan, overline: overline, spent: .aed(total), plan: .aed(0), tick: nil, verdict: nil,
        word: "No plan yet", fact: nil, caption: "spent this month", tiles: tiles, wash: .sky)
    }

    let tick = Self.tick(s, month: month, plan: budget, day: day, days: days)
    let verdict: Verdict = total > budget ? .overBudget : (total > tick ? .overPace : .onTrack)
    let left = MoneyPhrase([.text("AED "), .amount(.aed(budget - total), hidden: 3), .text(" left")])
    let word: MoneyPhrase
    let fact: MoneyPhrase?
    switch verdict {
    case .overBudget:
      word = MoneyPhrase([.text("Over by AED "), .amount(.aed(total - budget), hidden: 3)])
      fact = nil
    case .overPace:
      // Home says "Ahead of pace"; cards and rows say "Over pace" (plan decision 9).
      word = "Ahead of pace"
      fact = left
    case .onTrack, .done:
      word = "On track"
      fact = left
    }
    return SpendHero(
      overline: overline, spent: .aed(total), plan: .aed(budget), tick: .aed(tick), verdict: verdict,
      word: word, fact: fact,
      caption: planned(budget),
      tiles: tiles,
      wash: verdict == .overBudget ? .rose : (verdict == .overPace ? .sand : .sky)
    )
  }

  static func spent(_ sec: PlanSection?) -> Int64 { sec.map { $0.budget.minor - $0.left.minor } ?? 0 }

  static func planned(_ budget: Int64) -> MoneyPhrase {
    MoneyPhrase([.text("spent of "), .amount(.aed(budget), .rounded, hidden: 3), .text(" planned")])
  }

  public static func endedHero(_ s: LedgerState, month: YearMonth, plan: PlanSnapshot) -> SpendHero {
    func section(_ b: Bucket) -> PlanSection? { plan.sections.first { $0.bucket == b } }
    let needs = section(.needs)
    let wants = section(.wants)
    let total = Spending.total(s, in: month)
    let budget = (needs?.budget.minor ?? 0) + (wants?.budget.minor ?? 0)
    let tiles = heroTiles(needs: spent(needs), wants: spent(wants), saved: spent(section(.savings)))
    let note = topWant(s, month: month)
    guard budget > 0 else {
      return SpendHero(
        state: .ended, overline: "Month ended", spent: .aed(total), plan: .aed(0), tick: nil, verdict: nil,
        word: MoneyPhrase([.text("No plan for \(month.name)")]), fact: nil,
        caption: MoneyPhrase([.text("spent in \(month.name)")]), tiles: tiles, wash: .sky,
        note: note)
    }
    let over = total > budget
    return SpendHero(
      state: .ended, overline: "Month ended", spent: .aed(total), plan: .aed(budget), tick: nil,
      verdict: over ? .overBudget : .onTrack,
      word: MoneyPhrase([.text("Ended "), .amount(.aed(abs(budget - total)), hidden: 3), .text(over ? " over" : " under")]),
      fact: nil, caption: planned(budget), tiles: tiles, wash: over ? .rose : .sky, note: note)
  }

  public static func rangeHero(_ s: LedgerState, period: Period, now: LocalDateTime) -> SpendHero {
    let today = now.date.yearMonth
    var bars: [HeroMonthBar] = []
    var needs: Int64 = 0
    var wants: Int64 = 0
    var saved: Int64 = 0
    for m in period.months {
      let spent = Spending.total(s, in: m)
      let budget = bucketBudget(s, .needs, m) + bucketBudget(s, .wants, m)
      bars.append(HeroMonthBar(month: m, spent: .aed(spent), plan: .aed(budget),
                               verdict: budget > 0 && spent > budget ? .overBudget : .onTrack))
      needs += bucketSpent(s, .needs, m)
      wants += bucketSpent(s, .wants, m)
      saved += bucketSpent(s, .savings, m)
    }
    let total = bars.reduce(Int64(0)) { $0 + $1.spent.minor }
    let budget = bars.reduce(Int64(0)) { $0 + $1.plan.minor }
    let full = bars.filter { $0.month < today }
    let fullTotal = full.reduce(Int64(0)) { $0 + $1.spent.minor }
    let n = Int64(full.count)
    let average = n > 0 ? (fullTotal * 2 + (fullTotal >= 0 ? n : -n)) / (n * 2) : 0
    let overline = "\(period.count) months" + (period.contains(today) ? " · \(today.shortName) to day \(now.date.day)" : "")
    return SpendHero(
      state: .range, overline: overline, spent: .aed(total), plan: .aed(budget), tick: nil, verdict: nil,
      word: n > 0 ? MoneyPhrase([.text("Average "), .amount(.aed(average), hidden: 3)]) : "",
      fact: n > 0 ? "full months only" : nil,
      caption: budget > 0 ? planned(budget) : "spent",
      tiles: [
        HeroTile("Needs", .aed(needs), style: .rounded), HeroTile("Wants", .aed(wants), style: .rounded),
        HeroTile("Savings", .aed(saved), style: .rounded),
      ],
      wash: .sky, bars: bars)
  }

  static func bucketSpent(_ s: LedgerState, _ b: Bucket, _ m: YearMonth) -> Int64 {
    s.categories(in: b).reduce(Int64(0)) { $0 + s.spent($1.id, in: m).minor }
  }

  static func bucketBudget(_ s: LedgerState, _ b: Bucket, _ m: YearMonth) -> Int64 {
    s.categories(in: b).reduce(Int64(0)) { $0 + s.plan.budget($1.id, m).minor }
  }

  static func topWant(_ s: LedgerState, month: YearMonth) -> MoneyPhrase? {
    let top = s.categories(in: .wants).map { ($0, s.spent($0.id, in: month).minor) }
      .filter { $0.1 > 0 }.max { $0.1 < $1.1 }
    guard let (c, spent) = top else { return nil }
    return MoneyPhrase([.text("\(c.name) "), .amount(.aed(spent), hidden: 3), .text(" · your top want")])
  }

  static func aboutNow(_ s: LedgerState, now: LocalDateTime, review: ReviewWindow) -> [AboutNowRow] {
    var rows: [AboutNowRow] = []
    if let next = nextBill(s, now: now) {
      let n = now.date.days(until: next.nextDue)
      let when = n == 0 ? "today" : (n == 1 ? "tomorrow" : "in \(n) days")
      rows.append(AboutNowRow(
        id: "nextBill", title: "Next bill · \(next.name)",
        detail: MoneyPhrase([.text(next.approximate ? "~" : ""), .amount(next.amount, hidden: 3), .text(" · \(when)")]),
        destination: .bills))
    }
    let waiting = ReviewEngine.queue(s, in: review).count
    if waiting > 0 {
      rows.append(AboutNowRow(id: "review", title: "To review", detail: MoneyPhrase([.text("\(waiting) waiting")]), destination: .review))
    }
    return rows
  }

  static func nextBill(_ s: LedgerState, now: LocalDateTime) -> Bill? {
    s.bills.filter { $0.state == .tracked && !$0.isIncome && $0.nextDue >= now.date }
      .min { $0.nextDue < $1.nextDue }
  }

  /// Planned spend by today (page 06 §6.4): bills due so far + (plan − all bills this month) ×
  /// day ÷ days, rounded to the fil. Rent on the 1st moves the tick with it, so a bill never
  /// reads as overspending.
  ///
  /// "Due so far" counts the bills already charged this month: Paper's own figures do (Maya's
  /// day-10 tick 11,217.17 is the 8,005.89 paid plus 3,211.28, with AXA three days late and
  /// unpaid), and a late bill then moves the tick and the spending together when it lands, so
  /// its arrival never flips the verdict. "All bills" adds the bills still to come this month,
  /// late ones included. Only needs and wants bills count: savings are off the bar.
  public static func tick(_ s: LedgerState, month: YearMonth, plan: Int64, day: Int, days: Int) -> Int64 {
    let bills = billsThisMonth(s, month: month)
    let rest = max(0, plan - bills.paid - bills.toCome)
    let share = days > 0 ? (rest * Int64(day) * 2 + Int64(days)) / (Int64(days) * 2) : rest
    return bills.paid + share
  }

  /// Needs and wants bills this month: charged so far (transactions that paid a bill) and still
  /// to come (tracked bills due this month or earlier and not paid).
  public static func billsThisMonth(_ s: LedgerState, month: YearMonth) -> (paid: Int64, toCome: Int64) {
    func onTheBar(_ c: CategoryID?) -> Bool {
      guard let cat = s.category(c) else { return false }
      return cat.kind == .spending && (cat.bucket == .needs || cat.bucket == .wants)
    }
    var paid: Int64 = 0
    for t in s.txns where t.billID != nil && t.countsInPlan && t.postedAt.date.yearMonth == month {
      if let p = s.project(t.projectID), !p.countInPlan { continue }
      for line in t.lines where onTheBar(line.category) { paid += line.minor }
    }
    let toCome = s.bills.filter {
      $0.state == .tracked && !$0.isIncome && $0.nextDue.yearMonth <= month && onTheBar($0.categoryID)
    }.reduce(Int64(0)) { $0 + $1.amount.minor }
    return (paid, toCome)
  }

  static func heroTiles(needs: Int64, wants: Int64, saved: Int64) -> [HeroTile] {
    [HeroTile("Needs", .aed(needs)), HeroTile("Wants", .aed(wants)), HeroTile("Savings", .aed(saved))]
  }

  // MARK: - Widgets (whole dirhams: the views round every figure, page 06 rule 5)

  static func budgetPace(_ plan: PlanSnapshot, label: String) -> BudgetPaceWidget {
    BudgetPaceWidget(
      monthGone: label,
      rows: plan.sections.map { sec in
        let spent = sec.budget.minor - sec.left.minor
        let verdict: Verdict
        if sec.bucket == .savings {
          verdict = sec.budget.minor > 0 && spent >= sec.budget.minor ? .done : .onTrack
        } else {
          verdict = spent > sec.budget.minor ? .overBudget : .onTrack
        }
        return BucketPaceRow(bucket: sec.bucket, spent: .aed(spent), budget: sec.budget, verdict: verdict)
      }
    )
  }

  static func widgets(_ s: LedgerState, now: LocalDateTime, plan: PlanSnapshot) -> [HomeWidget] {
    let month = now.date.yearMonth
    var out: [HomeWidget] = []

    let pct = Pace.monthGone(day: now.date.day, days: month.days).value / 10
    out.append(.budgetPace(budgetPace(plan, label: "\(pct)% of \(month.name) gone")))

    if let next = nextBill(s, now: now) {
      let n = now.date.days(until: next.nextDue)
      out.append(.nextBill(NextBillWidget(
        glyph: s.category(next.categoryID)?.glyph ?? .utilities, hue: s.category(next.categoryID)?.hue ?? .sand,
        due: StatusPill(n == 0 ? "Today" : (n == 1 ? "Tomorrow" : "In \(n) days"), tone: .warning, showsDot: false),
        amount: next.amount,
        caption: "\(next.name) · expected \(next.nextDue.weekdayShort)"
      )))
    }

    if !s.accounts.isEmpty {
      let total = s.accounts.reduce(Int64(0)) { $0 + $1.balance.minor }
      out.append(.netWorth(NetWorthWidget(
        total: .aed(total),
        change: MoneyPhrase([
          .signedMoney(s.netWorth.monthChange, style: .rounded, hiddenGlyphs: 3), .text(" this month"),
        ]),
        spark: s.netWorth.spark.map(Permille.init)
      )))
    }

    for p in s.projects where !p.complete {
      guard let m = plan.projects.first(where: { $0.id == p.id }) else { continue }
      out.append(.project(ProjectWidget(
        name: p.name, glyph: p.glyph, left: m.left,
        caption: MoneyPhrase([
          .text("of "), .amount(p.budget, .rounded, hidden: 4), .text(" · \(p.startVerb) \(p.starts.dayMonth)"),
        ]),
        progress: m.progress
      )))
    }

    for g in s.goals {
      out.append(.goal(GoalWidget(
        name: g.name, glyph: g.glyph, progress: Permille.ratio(g.saved.minor, of: g.target.minor),
        caption: MoneyPhrase([
          .amount(g.saved, .rounded), .text(" of "), .amount(g.target, .rounded), .text(" · \(g.by.shortName)"),
        ])
      )))
    }

    let today = s.txns.filter { $0.postedAt.date == now.date && $0.countsInPlan }
      .sorted { $0.postedAt > $1.postedAt }
    let todayTotal = today.reduce(Int64(0)) { $0 + ($1.direction == .out ? $1.amount.minor : -$1.amount.minor) }
    out.append(.today(TodayWidget(
      summary: MoneyPhrase([
        .text("\(today.count) transaction\(today.count == 1 ? "" : "s") · "), .amount(.aed(todayTotal), .rounded, hidden: 3),
      ]),
      rows: today.prefix(3).map { t in
        let c = s.category(t.categoryID)
        let detail = "\(c?.name ?? "Uncategorized") · \(t.postedAt.time)" + (t.place.map { " · \($0)" } ?? "")
        return MiniTxnRow(id: "t.\(t.id)", merchant: t.merchant, glyph: c?.glyph ?? .review, hue: c?.hue ?? .other,
                          detail: detail, amount: t.amount, isIncome: t.direction == .in)
      }
    )))
    return out
  }
}
