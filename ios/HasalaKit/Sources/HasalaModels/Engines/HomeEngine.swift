// Home · Default, Over pace ("Home · Over pace"): the everyday hero, Needs you and the
// widget canvas, built from `LedgerState` (spec 04 §15.1 `HomeModel`).
//
// TODO(spec 04 §16.1 "Home · Over pace"): the over-pace Needs-you cards ("Dining · Runs out Sat",
// "Ready to assign · Give it a job") and their subtitle come with CoreSignals' ranking.
// TODO(spec 04 §16.2 H2): the widget order comes from `prefs.homeWidgets`.

public enum HomeEngine {
  public static func snapshot(_ s: LedgerState, now: LocalDateTime) -> HomeSnapshot {
    let month = now.date.yearMonth
    let day = now.date.day
    let days = month.days

    // Everyday: categories whose role is everyday, bills and savings kept out.
    let everyday = s.categories.filter { $0.role == .everyday && $0.kind == .spending }
    let budget = everyday.reduce(Int64(0)) { $0 + s.plan.budget($1.id, month).minor }
    let spent = everyday.reduce(Int64(0)) { $0 + s.spent($1.id, in: month).minor }
    let left = budget - spent
    let verdict = Pace.verdict(spent: spent, budget: budget, day: day, days: days, paced: true)
    let billCats = s.categories.filter { $0.role == .bill }
    let billsPaid = billCats.reduce(Int64(0)) { $0 + s.spent($1.id, in: month).minor }
    let billsToCome = s.bills.filter {
      $0.state == .tracked && !$0.isIncome && $0.nextDue.yearMonth <= month
    }.reduce(Int64(0)) { $0 + $1.amount.minor }

    let hero = EverydayHero(
      overline: "\(month.name) · day \(day) of \(days)",
      left: .aed(left),
      caption: left >= 0 ? "left for everyday spending" : "over your everyday budget",
      spent: Permille.ratio(spent, of: budget),
      today: Pace.monthGone(day: day, days: days),
      verdict: verdict,
      verdictDetail: MoneyPhrase([
        .text("about AED "), .amount(.aed(Pace.perDay(left: left, day: day, days: days)), .rounded, hidden: 3),
        .text(" a day"),
      ]),
      stats: [
        HeroStat("Spent", .aed(spent)),
        HeroStat("Bills paid", .aed(billsPaid)),
        HeroStat("Bills to come", .aed(billsToCome)),
      ],
      wash: verdict == .overBudget ? .rose : (verdict == .overPace ? .sand : .sky)
    )

    return HomeSnapshot(
      header: HeaderState(unreadNotifications: s.unreadNotifications, avatarInitial: s.profile.initial),
      hero: hero,
      needsYou: needsYou(s, now: now),
      widgets: widgets(s, now: now)
    )
  }

  static func needsYou(_ s: LedgerState, now: LocalDateTime) -> NeedsYouRail {
    var cards: [NeedsYouCard] = []
    let review = ActivityEngine.reviewSummary(s, now: now)
    if review.count > 0 {
      cards.append(NeedsYouCard(
        id: "review", hue: .sky, glyph: .review, label: "To review",
        status: StatusPill(review.newToday > 0 ? "\(review.newToday) new today" : "Waiting", tone: .accent),
        figure: .count(review.count, unit: "to sort"),
        title: "Sort new transactions",
        subtitle: MoneyPhrase([.text("AED "), .amount(review.unplanned), .text(" isn't in your plan yet")]),
        primaryAction: "Start", secondaryAction: "Later"
      ))
    }
    let tracked = s.bills.filter { $0.state == .tracked && !$0.isIncome }
    let late = tracked.filter { $0.nextDue < now.date }.sorted { $0.nextDue < $1.nextDue }
    for b in late {
      let n = b.nextDue.days(until: now.date)
      cards.append(NeedsYouCard(
        id: "bill.\(b.id)", hue: .rose, glyph: s.category(b.categoryID)?.glyph ?? .utilities, label: b.name,
        status: StatusPill("\(n) day\(n == 1 ? "" : "s") late", tone: .error),
        figure: .money(b.amount),
        title: "\(b.kind) didn't arrive",
        subtitle: MoneyPhrase(stringLiteral: "Usually on the \(PlanEngine.ordinal(b.usualDay)) · no email yet"),
        primaryAction: "I paid it", secondaryAction: "Details"
      ))
    }
    let priceChanges = tracked.filter { $0.priceChangeFrom != nil }.count
    let count = cards.count + priceChanges + s.billCandidates.count
    let subtitle: String
    if !late.isEmpty {
      subtitle = "\(late.count) bill\(late.count == 1 ? "" : "s") look\(late.count == 1 ? "s" : "") late"
    } else if review.count > 0 {
      subtitle = "\(review.count) to sort"
    } else {
      subtitle = "All caught up"
    }
    return NeedsYouRail(count: count, subtitle: subtitle, cards: cards)
  }

  static func widgets(_ s: LedgerState, now: LocalDateTime) -> [HomeWidget] {
    let month = now.date.yearMonth
    let plan = PlanEngine.snapshot(s, now: now)
    var out: [HomeWidget] = []

    let pct = Pace.monthGone(day: now.date.day, days: month.days).value / 10
    out.append(.budgetPace(BudgetPaceWidget(
      monthGone: "\(pct)% of \(month.name) gone",
      rows: plan.sections.map { sec in
        let spent = sec.budget.minor - sec.left.minor
        let verdict: Verdict = sec.bucket == .savings
          ? (spent >= sec.budget.minor && sec.budget.minor > 0 ? .done : .onTrack)
          : Pace.verdict(spent: spent, budget: sec.budget.minor, day: now.date.day, days: month.days, paced: false)
        return BucketPaceRow(bucket: sec.bucket, spent: .aed(spent), budget: sec.budget,
                             verdict: verdict == .done && sec.bucket != .savings ? .onTrack : verdict)
      }
    )))

    if let next = s.bills.filter({ $0.state == .tracked && !$0.isIncome && $0.nextDue >= now.date })
      .min(by: { $0.nextDue < $1.nextDue })
    {
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
          .text("of "), .amount(p.budget, .compact), .text(" · \(p.startVerb) \(p.starts.dayMonth)"),
        ]),
        progress: m.progress
      )))
    }

    for g in s.goals {
      out.append(.goal(GoalWidget(
        name: g.name, glyph: g.glyph, progress: Permille.ratio(g.saved.minor, of: g.target.minor),
        caption: MoneyPhrase([
          .amount(g.saved, .compact), .text(" of "), .amount(g.target, .compact), .text(" · \(g.by.shortName)"),
        ])
      )))
    }

    let today = s.txns.filter { $0.postedAt.date == now.date && $0.countsInPlan }
      .sorted { $0.postedAt > $1.postedAt }
    let todayTotal = today.reduce(Int64(0)) { $0 + ($1.direction == .out ? $1.amount.minor : -$1.amount.minor) }
    out.append(.today(TodayWidget(
      summary: MoneyPhrase([
        .text("\(today.count) transaction\(today.count == 1 ? "" : "s") · "), .amount(.aed(todayTotal), hidden: 3),
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
