// Home · Default (Paper 14O7-0), Over pace (2S7-0), Over budget (18WY-0): the hero "spent on
// needs and wants" with its pace, the bell's list and the widget canvas, built from
// `LedgerState` (spec 10 §2, page 06 §6.4, page 16 §01–02).
//
// TODO(spec 10 §2.7–2.8): a closed month and a range ("Month ended", "Still about now") come
// with the period picker (plan D.2).
// TODO(spec 04 §16.2 H2): the widget order comes from `prefs.homeWidgets`.

public enum HomeEngine {
  public static func snapshot(_ s: LedgerState, now: LocalDateTime) -> HomeSnapshot {
    let plan = PlanEngine.snapshot(s, now: now)
    return HomeSnapshot(
      header: HeaderState(avatarInitial: s.profile.initial),
      hero: hero(s, now: now, plan: plan),
      notifications: NotificationsEngine.snapshot(s, now: now),
      widgets: widgets(s, now: now, plan: plan)
    )
  }

  // MARK: - The hero

  /// The month as one bar (page 06 §6.4): needs + wants spent against the needs + wants plan,
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
    func spent(_ sec: PlanSection?) -> Int64 { sec.map { $0.budget.minor - $0.left.minor } ?? 0 }

    let needsSpent = spent(needs)
    let wantsSpent = spent(wants)
    let total = needsSpent + wantsSpent
    let budget = (needs?.budget.minor ?? 0) + (wants?.budget.minor ?? 0)
    let overline = "Day \(day) of \(days)"
    let tiles = heroTiles(needs: needsSpent, wants: wantsSpent, saved: spent(savings),
                          savingsPlan: savings?.budget.minor ?? 0)

    // S9: the first import is still running and nothing has arrived this month: the figure
    // fills in as batches land, beside Home's import pill.
    let anyThisMonth = s.txns.contains { $0.postedAt.date.yearMonth == month && !$0.archived }
    if s.mailbox.status == .importing, !anyThisMonth {
      return SpendHero(
        state: .syncing, overline: overline, spent: .aed(0), plan: .aed(budget), tick: nil, verdict: nil,
        word: "Getting your transactions…", fact: nil, caption: "spent on needs and wants", tiles: tiles,
        wash: .sky)
    }

    // S8: spending still counts, with nothing to measure it against.
    guard budget > 0 else {
      return SpendHero(
        state: .noPlan, overline: overline, spent: .aed(total), plan: .aed(0), tick: nil, verdict: nil,
        word: "No plan yet", fact: nil, caption: "spent on needs and wants", tiles: tiles, wash: .sky)
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
      caption: MoneyPhrase([.text("spent of "), .amount(.aed(budget), .rounded, hidden: 3), .text(" on needs and wants")]),
      tiles: tiles,
      wash: verdict == .overBudget ? .rose : (verdict == .overPace ? .sand : .sky)
    )
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

  /// Needs and Wants show spent this month; Savings shows saved this month: "5,000.00" once
  /// the plan is met, "2,000 of 5,000" part way (page 06 §6.4).
  static func heroTiles(needs: Int64, wants: Int64, saved: Int64, savingsPlan: Int64) -> [HeroTile] {
    let savingsTile: HeroTile
    if savingsPlan > 0, saved < savingsPlan {
      savingsTile = HeroTile("Savings", .aed(saved), style: .compact, of: .aed(savingsPlan))
    } else {
      savingsTile = HeroTile("Savings", .aed(saved))
    }
    return [HeroTile("Needs", .aed(needs)), HeroTile("Wants", .aed(wants)), savingsTile]
  }

  // MARK: - Widgets (whole dirhams: the views round every figure, page 06 rule 5)

  static func widgets(_ s: LedgerState, now: LocalDateTime, plan: PlanSnapshot) -> [HomeWidget] {
    let month = now.date.yearMonth
    var out: [HomeWidget] = []

    // Budget pace: one row per bucket, no tick; over is full rose, savings met is "Done".
    let pct = Pace.monthGone(day: now.date.day, days: month.days).value / 10
    out.append(.budgetPace(BudgetPaceWidget(
      monthGone: "\(pct)% of \(month.name) gone",
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
