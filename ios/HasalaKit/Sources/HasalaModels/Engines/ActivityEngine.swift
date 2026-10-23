// Activity · Overview and Activity · Filtered: the register.
// To review first, then what is coming up, then history by local day.

/// What Activity lists (spec 04 §13.2 `.activityFiltered(TxnFilter)`).
public struct TxnFilter: Sendable, Hashable, Codable {
  public enum Kind: String, Sendable, Hashable, Codable, CaseIterable {
    case all, toReview, bills, transfers, income, archived

    public var title: String {
      switch self {
      case .all: "All"
      case .toReview: "To review"
      case .bills: "Bills"
      case .transfers: "Transfers"
      case .income: "Income"
      case .archived: "Archived"
      }
    }
  }

  public var kind: Kind
  public var category: CategoryID?
  public var text: String

  public init(kind: Kind = .all, category: CategoryID? = nil, text: String = "") {
    self.kind = kind
    self.category = category
    self.text = text
  }

  public static let all = TxnFilter()

  public var isSearching: Bool { !text.trimmedSpaces.isEmpty }
}

public struct ActivityChip: Sendable, Hashable, Identifiable {
  public var id: TxnFilter.Kind { kind }
  public var kind: TxnFilter.Kind
  public var count: Int?
  /// The To review badge is the accent; other counts are secondary text.
  public var accentCount: Bool
}

/// A bill or income line (Activity's Coming up, Bills' Upcoming and Recently paid).
public struct BillRowModel: Sendable, Hashable, Identifiable {
  public var id: String
  public var name: String
  public var glyph: Glyph
  public var hue: Hue
  public var detail: [PlanDetailPart]
  public var amount: Money
  public var approximate: Bool
  public var isIncome: Bool
  /// Under the amount: "in 4 days", "● 3 days past usual".
  public var trailingNote: PlanDetailPart?

  public init(
    id: String, name: String, glyph: Glyph, hue: Hue, detail: [PlanDetailPart], amount: Money,
    approximate: Bool = false, isIncome: Bool = false, trailingNote: PlanDetailPart? = nil
  ) {
    self.id = id
    self.name = name
    self.glyph = glyph
    self.hue = hue
    self.detail = detail
    self.amount = amount
    self.approximate = approximate
    self.isIncome = isIncome
    self.trailingNote = trailingNote
  }
}

public struct DayGroup: Sendable, Hashable, Identifiable {
  public var id: Int { date.ordinal }
  public var date: LocalDate
  /// "Today", "Yesterday, Fri 9 Oct", "Thu 8 Oct" (drawn uppercase).
  public var title: String
  public var total: Money
  public var rows: [MiniTxnRow]
}

/// The summary card on a category filter ("Activity · Filtered").
public struct FilterSummary: Sendable, Hashable {
  public var title: String
  /// The category's bucket hue, for its chip's dot.
  public var hue: Hue
  public var count: Int
  public var total: Money
  public var progress: Permille
  public var today: Permille
  public var verdict: Verdict
  /// "40% of Dining's 1,600".
  public var caption: MoneyPhrase
  /// False under All time: no budget to measure against, so no bar and no verdict.
  public var budgeted = true
}

public struct ReviewSummary: Sendable, Hashable {
  public var count: Int
  /// Spending waiting in review: "AED 827.28 still to check".
  public var unplanned: Money
  /// Sorted today, in review, posted today ("2 new today").
  public var newToday: Int
  public var mark: TotalMark? = nil
}

public struct ActivitySnapshot: Sendable, Hashable {
  public var period: Period
  public var isThisMonth: Bool
  /// "26 transactions this month", or "105 transactions · Aug – Oct 2026".
  public var countLine: String
  public var chips: [ActivityChip]
  public var filter: TxnFilter
  public var review: ReviewSummary?
  public var comingUp: [BillRowModel]
  public var days: [DayGroup]
  /// A category filter lists its rows in one card, newest first, without day overlines;
  /// each row says its day ("Sat 10 Oct · 13:20", Paper "Activity · Filtered"). Empty
  /// otherwise.
  public var rows: [MiniTxnRow]
  public var summary: FilterSummary?

  public var rowCount: Int { days.reduce(0) { $0 + $1.rows.count } }
}

public enum ActivityEngine {
  public static func snapshot(
    _ s: LedgerState, now: LocalDateTime, filter: TxnFilter, period: Period? = nil
  ) -> ActivitySnapshot {
    let today = now.date.yearMonth
    let period = (period ?? .month(today)).clamped(to: today)
    let isThisMonth = period == .month(today)
    let window = period.isAllTime ? ReviewWindow.all : ReviewWindow(period)
    let inPeriod = s.txns.filter { !$0.archived && window.contains($0.postedAt.date) }
    let reviewQueue = inPeriod.filter(\.inReview)
    let billCount = inPeriod.filter { isBill($0, s) && !$0.inReview }.count

    let chips = [
      ActivityChip(kind: .all, count: nil, accentCount: false),
      ActivityChip(kind: .toReview, count: reviewQueue.count, accentCount: true),
      ActivityChip(kind: .bills, count: billCount, accentCount: false),
      ActivityChip(kind: .transfers, count: nil, accentCount: false),
      ActivityChip(kind: .income, count: nil, accentCount: false),
      ActivityChip(kind: .archived, count: nil, accentCount: false),
    ]

    let listed = s.txns.filter { matches($0, filter, s, in: window) }.sorted { $0.postedAt > $1.postedAt }
    let days = group(listed, s, today: now.date)
    let showsOverview = filter.kind == .all && filter.category == nil && !filter.isSearching
    let review = showsOverview ? reviewSummary(s, now: now) : nil
    let n = inPeriod.count
    let noun = "\(n) transaction\(n == 1 ? "" : "s")"

    return ActivitySnapshot(
      period: period,
      isThisMonth: isThisMonth,
      countLine: isThisMonth ? "\(noun) this month" : "\(noun) · \(period.title)",
      chips: chips,
      filter: filter,
      review: review.flatMap { $0.count > 0 ? $0 : nil },
      comingUp: showsOverview && period.contains(today) ? comingUp(s, today: now.date, within: 7) : [],
      days: days,
      rows: filter.category == nil ? [] : listed.map { dated($0, s) },
      summary: filter.category.flatMap { summary($0, listed, s, now: now, period: period) }
    )
  }

  public static func reviewSummary(_ s: LedgerState, now: LocalDateTime, in window: ReviewWindow = .all) -> ReviewSummary {
    let queue = ReviewEngine.queue(s, in: window)
    let out = queue.filter { $0.direction == .out && !$0.isHeldCopy }
    let unplanned = Fils.sum(out) { $0.homeMinor ?? 0 }
    let today = queue.filter { $0.postedAt.date == now.date }.count
    return ReviewSummary(count: queue.count, unplanned: .aed(unplanned), newToday: today, mark: TotalMark.unrated(out))
  }

  static func isBill(_ t: Txn, _ s: LedgerState) -> Bool {
    t.billID != nil || s.category(t.categoryID)?.role == .bill
  }

  static func matches(_ t: Txn, _ f: TxnFilter, _ s: LedgerState, in window: ReviewWindow) -> Bool {
    if f.isSearching {
      let q = f.text.trimmedSpaces.lowercased()
      let hay = [t.title, t.provenance?.rawMerchant ?? "", t.note, s.category(t.categoryID)?.name ?? ""]
        .joined(separator: "\n").lowercased()
      if !hay.contains(q) { return false }
    } else if !window.contains(t.postedAt.date) {
      return false
    }
    if let c = f.category, !t.lines.contains(where: { $0.category == c }) || !Spending.includes(t, in: s) { return false }
    switch f.kind {
    case .all: return !t.archived
    case .toReview: return t.inReview
    case .bills: return !t.archived && !t.inReview && isBill(t, s)
    case .transfers: return !t.archived && t.isTransfer
    // Money that came in and stays in: not a transfer between accounts, not a refund.
    case .income: return !t.archived && !t.inReview && t.direction == .in && !t.isTransfer && !t.isRefund
    case .archived: return t.archived
    }
  }

  static func group(_ txns: [Txn], _ s: LedgerState, today: LocalDate) -> [DayGroup] {
    var groups: [DayGroup] = []
    var index: [LocalDate: Int] = [:]
    for t in txns {
      let d = t.postedAt.date
      let row = row(t, s)
      let signed = t.isHeldCopy ? 0 : t.homeSigned ?? 0
      if let i = index[d] {
        groups[i].rows.append(row)
        groups[i].total.minor.add(signed)
      } else {
        index[d] = groups.count
        groups.append(DayGroup(date: d, title: dayTitle(d, today: today), total: .aed(signed), rows: [row]))
      }
    }
    return groups
  }

  public static func dayTitle(_ d: LocalDate, today: LocalDate) -> String {
    switch today.ordinal - d.ordinal {
    case 0: "Today"
    case 1: "Yesterday, \(d.short)"
    default: d.short
    }
  }

  /// One list row: "Dining · 13:20"; to-review rows read "To review · 18:42".
  public static func row(_ t: Txn, _ s: LedgerState) -> MiniTxnRow {
    let c = t.modelGuessRejected ? nil : s.category(t.categoryID)
    let detail: String
    var spokenDetail: String?
    if let reason = t.activeReviewReason {
      detail = t.joined(reason.label, t.postedTime)
    } else if t.inReview {
      detail = t.joined("To review", t.postedTime)
    } else if !t.splits.isEmpty {
      detail = "Split · \(t.splits.count) categories"
    } else if let source = t.autoSourceLabel, c != nil {
      detail = t.joined(t.joined(c?.name ?? "", source), t.detailOverride ?? t.postedTime)
      spokenDetail = t.autoSourceSpoken.map { t.joined(c?.name ?? "", t.detailOverride ?? t.postedTime) + ", " + $0 }
    } else {
      detail = t.joined(c?.name ?? "Uncategorized", t.detailOverride ?? t.postedTime)
    }
    let glyph = t.isTransfer ? Glyph.transfer : (c?.glyph ?? .review)
    var r = MiniTxnRow(
      id: t.id, merchant: t.title, glyph: glyph, hue: t.inReview ? .other : (c?.hue ?? .other), detail: detail,
      amount: t.amount, isIncome: t.direction == .in,
      monogram: (t.inReview || c == nil) ? String(t.merchant.prefix(1)).uppercased() : nil,
      toReview: t.inReview, reviewReason: t.activeReviewReason,
      project: s.project(t.projectID).map { MiniTxnRow.Project(id: $0.id, name: $0.name) }
    )
    r.spokenDetail = spokenDetail
    r.showHome(t)
    return r
  }

  /// A row of a category's list: the day takes the category's place ("Sat 10 Oct · 13:20").
  public static func dated(_ t: Txn, _ s: LedgerState) -> MiniTxnRow {
    var r = row(t, s)
    if !t.inReview && t.splits.isEmpty {
      r.detail = t.joined(t.postedAt.date.short, t.detailOverride ?? t.postedTime)
      r.spokenDetail = nil
    }
    return r
  }

  /// Bills and income due within `days` of today, and late ones (`within` 7 on Activity).
  public static func comingUp(_ s: LedgerState, today: LocalDate, within days: Int) -> [BillRowModel] {
    let horizon = today.adding(days: days)
    let bills = s.bills.filter { $0.state == .tracked && !$0.isIncome && $0.nextDue <= horizon }
    let upcoming = bills.filter { $0.nextDue >= today }.sorted { $0.nextDue < $1.nextDue }
    let late = bills.filter { $0.nextDue < today }.sorted { $0.nextDue < $1.nextDue }
    return upcoming.map { b in
      let n = today.days(until: b.nextDue)
      return BillRowModel(
        id: b.id, name: b.name, glyph: glyph(b, s), hue: hue(b, s),
        detail: [.text(MoneyPhrase(stringLiteral: "\(b.kind) · \(b.nextDue.short)"))],
        amount: b.amount, approximate: b.approximate, isIncome: false,
        trailingNote: .text(MoneyPhrase(stringLiteral: inDays(n)))
      )
    } + late.map { b in
      let n = b.nextDue.days(until: today)
      return BillRowModel(
        id: b.id, name: b.name, glyph: glyph(b, s), hue: hue(b, s),
        detail: [.text(MoneyPhrase(stringLiteral: "Usually the \(PlanEngine.ordinal(b.usualDay))"))],
        amount: b.amount, approximate: b.approximate, isIncome: false,
        // Paper's words for a bill that hasn't come yet: past its usual day, never "late"
        // (spec 01 §07: Hasala can't know for sure).
        trailingNote: .status("\(n) day\(n == 1 ? "" : "s") past usual", .error)
      )
    }
  }

  public static func inDays(_ n: Int) -> String {
    switch n {
    case 0: "today"
    case 1: "tomorrow"
    default: "in \(n) days"
    }
  }

  static func glyph(_ b: Bill, _ s: LedgerState) -> Glyph {
    if b.isIncome { return .salary }
    return s.category(b.categoryID)?.glyph ?? .utilities
  }

  static func hue(_ b: Bill, _ s: LedgerState) -> Hue {
    if b.isIncome { return .sky }
    return s.category(b.categoryID)?.hue ?? .sand
  }

  static func summary(
    _ c: CategoryID, _ txns: [Txn], _ s: LedgerState, now: LocalDateTime, period: Period
  ) -> FilterSummary? {
    guard let cat = s.category(c) else { return nil }
    let total = Spending.spent(s, category: c, in: period)
    guard period.showsBudgets else {
      return FilterSummary(
        title: cat.name, hue: cat.hue, count: txns.count, total: .aed(total), progress: Permille(0),
        today: Permille(0), verdict: .onTrack,
        caption: MoneyPhrase([.text("All time · since \(period.first.shortName) \(period.first.year)")]),
        budgeted: false)
    }
    let budget = Fils.sum(period.months) { s.plan.budget(c, $0).minor }
    let (day, days) = elapsed(period, today: now.date)
    let verdict = Pace.verdict(spent: total, budget: budget, day: day, days: days, paced: cat.role == .everyday)
    let pct = Fils.mulDiv(total, 100, budget)
    return FilterSummary(
      title: cat.name, hue: cat.hue, count: txns.count, total: .aed(total), progress: Permille.ratio(total, of: budget),
      today: Pace.monthGone(day: day, days: days), verdict: verdict,
      caption: MoneyPhrase([
        .text("\(pct)% of \(cat.name)\(cat.name.hasSuffix("s") ? "'" : "'s") "), .amount(.aed(budget), .compact),
      ])
    )
  }

  public static func elapsed(_ period: Period, today: LocalDate) -> (day: Int, days: Int) {
    var day = 0
    var days = 0
    for m in period.months {
      days += m.days
      if m < today.yearMonth {
        day += m.days
      } else if m == today.yearMonth {
        day += today.day
      }
    }
    return (day, days)
  }
}
