// UI read models for Home (Paper "Home · Default", spec 10, page 16 §01–02).
//
// They are plain values: `HomeEngine` builds them from the ledger, the Maya mock writes the
// board's figures by hand, and HasalaDesign draws them. Nothing here reads a clock or a
// database.

/// The six hues of the design plus the neutral "other" (spec 04 §14.2).
/// Rose is reserved for late or missed bills and over-budget; never a bucket.
public enum Hue: String, Sendable, Hashable, CaseIterable, Codable {
  case sky, sand, rose, lilac, mint, peach, other
}

/// Budget buckets and the hue each one aliases (Paper `--color-bucket-*`).
public enum Bucket: String, Sendable, Hashable, CaseIterable, Codable {
  case needs, wants, savings, income, project, other

  public var hue: Hue {
    switch self {
    case .needs: .sand
    case .wants: .lilac
    case .savings: .mint
    case .income: .sky
    case .project: .peach
    case .other: .other
    }
  }
}

/// The pace verdict. Colour carries it, and the sentence always says it too.
public enum Verdict: String, Sendable, Hashable, Codable {
  case onTrack, overPace, overBudget, done

  public var label: String {
    switch self {
    case .onTrack: "On track"
    case .overPace: "Over pace"
    case .overBudget: "Over budget"
    case .done: "Done"
    }
  }
}

/// Semantic icons. HasalaDesign maps each to a drawing; models never name an image.
public enum Glyph: String, Sendable, Hashable, Codable {
  case review, insurance, utilities, travel, savingsJar, dining, budgetPie, trendUp, add
  case rent, groceries, transport, shopping, salary, transfer, flag
  // The rest of taxonomy v1 (03c §4.1) and the profile rows.
  case healthcare, entertainment, subscriptions, investments, debt, freelance, refunds
  case bank, tag, bill, wallet, envelope, rule, chat
}

/// The tone of a small status pill ("2 new today", "3 days late", "In 4 days").
public enum StatusTone: String, Sendable, Hashable, Codable {
  case accent, error, warning, success
}

public struct StatusPill: Sendable, Hashable, Codable {
  public var text: String
  public var tone: StatusTone
  /// Paper draws a 7 pt dot before the text on poster pills, not on widget chips.
  public var showsDot: Bool

  public init(_ text: String, tone: StatusTone, showsDot: Bool = true) {
    self.text = text
    self.tone = tone
    self.showsDot = showsDot
  }
}

public struct HeaderState: Sendable, Hashable {
  public var avatarInitial: String

  public init(avatarInitial: String) {
    self.avatarInitial = avatarInitial
  }
}

// MARK: - The hero (Paper "Hero · Spent on needs + wants", page 16 §01–02)

/// One stat tile under the hero bar: Needs, Wants or Savings.
public struct HeroTile: Sendable, Hashable, Identifiable {
  public var id: String { label }
  public var label: String
  public var value: Money
  public var style: MoneyStyle

  public init(_ label: String, _ value: Money, style: MoneyStyle = .exact) {
    self.label = label
    self.value = value
    self.style = style
  }
}

public struct HeroMonthBar: Sendable, Hashable, Identifiable {
  public var id: YearMonth { month }
  public var month: YearMonth
  public var spent: Money
  public var plan: Money
  public var verdict: Verdict

  public init(month: YearMonth, spent: Money, plan: Money, verdict: Verdict) {
    self.month = month
    self.spent = spent
    self.plan = plan
    self.verdict = verdict
  }

  public var label: String { month.shortName }
}

public struct AboutNowRow: Sendable, Hashable, Identifiable {
  public var id: String
  public var title: String
  public var detail: MoneyPhrase
  public var destination: NotificationDestination

  public init(id: String, title: String, detail: MoneyPhrase, destination: NotificationDestination) {
    self.id = id
    self.title = title
    self.detail = detail
    self.destination = destination
  }
}

/// "Am I okay this month?" (page 06 §6.4): what is spent on needs and wants against their
/// combined plan, where spending should be today, and the verdict in words. Savings is never
/// in the figure or on the bar; it has its own tile.
public struct SpendHero: Sendable, Hashable {
  public enum State: Sendable, Hashable {
    /// The month so far, against the plan and today's tick.
    case live
    /// No needs or wants budget yet (S8): the spending still counts, with nothing to measure
    /// it against.
    case noPlan
    /// The first import is running and no transaction has arrived (S9): zero, filling in.
    case syncing
    case ended
    case range
  }

  public var state: State
  /// "Day 10 of 31" (drawn in capitals).
  public var overline: String
  /// Everything spent in the period (`Spending.total`).
  public var spent: Money
  /// Needs + wants budgets this month; zero with no plan.
  public var plan: Money
  /// Planned spend by today: bills paid so far, plus the rest of the plan spread over the days
  /// gone. Nil with no plan.
  public var tick: Money?
  /// On track, ahead of pace (`overPace`) or over the plan (`overBudget`). Nil with no plan.
  public var verdict: Verdict?
  /// "On track", "Ahead of pace", "Over by AED 1,240.00", "No plan yet".
  public var word: MoneyPhrase
  /// "AED 8,711.66 left" (drawn after a "·"); nil when over or with no plan.
  public var fact: MoneyPhrase?
  /// "spent of 19,000 on needs and wants", or "spent on needs and wants" with no plan.
  public var caption: MoneyPhrase
  public var tiles: [HeroTile]
  /// The wash behind the hero: sky on track, sand ahead of pace, rose over.
  public var wash: Hue
  public var bars: [HeroMonthBar]
  public var note: MoneyPhrase?
  public var notCounted: NotCounted?
  public var unrated: TotalMark?

  public struct NotCounted: Sendable, Hashable {
    public var amount: Money
    public var projects: Int
    public var projectID: ProjectID?
    public var line: MoneyPhrase

    public init(amount: Money, projects: Int, projectID: ProjectID?, line: MoneyPhrase) {
      self.amount = amount
      self.projects = projects
      self.projectID = projectID
      self.line = line
    }
  }

  public init(
    state: State = .live, overline: String, spent: Money, plan: Money, tick: Money?, verdict: Verdict?,
    word: MoneyPhrase, fact: MoneyPhrase?, caption: MoneyPhrase, tiles: [HeroTile], wash: Hue,
    bars: [HeroMonthBar] = [], note: MoneyPhrase? = nil, notCounted: NotCounted? = nil
  ) {
    self.bars = bars
    self.note = note
    self.notCounted = notCounted
    self.state = state
    self.overline = overline
    self.spent = spent
    self.plan = plan
    self.tick = tick
    self.verdict = verdict
    self.word = word
    self.fact = fact
    self.caption = caption
    self.tiles = tiles
    self.wash = wash
  }

  /// What is left of the plan (negative when over).
  public var left: Money { Money(minor: plan.minor.minus(spent.minor), currency: plan.currency) }
}

/// The big figure on a brief card's poster: a count ("6 to sort"), an amount, or a word
/// ("Gmail") when the card is about something with no number.
public enum PosterFigure: Sendable, Hashable {
  case count(Int, unit: String)
  case money(Money)
  case word(String)
}

// MARK: - Widgets (Paper "Widgets · launch set", the Home canvas)

public struct BucketPaceRow: Sendable, Hashable, Codable, Identifiable {
  public var id: Bucket { bucket }
  public var bucket: Bucket
  public var spent: Money
  public var budget: Money
  public var verdict: Verdict

  public init(bucket: Bucket, spent: Money, budget: Money, verdict: Verdict) {
    self.bucket = bucket
    self.spent = spent
    self.budget = budget
    self.verdict = verdict
  }

  public var left: Money { Money(minor: budget.minor.minus(spent.minor), currency: budget.currency) }
  public var progress: Permille { Permille.ratio(spent.minor, of: budget.minor) }
}

public struct BudgetPaceWidget: Sendable, Hashable, Codable {
  /// "32% of October gone".
  public var monthGone: String
  public var rows: [BucketPaceRow]

  public init(monthGone: String, rows: [BucketPaceRow]) {
    self.monthGone = monthGone
    self.rows = rows
  }
}

public struct NextBillWidget: Sendable, Hashable, Codable {
  public var glyph: Glyph
  public var hue: Hue
  public var due: StatusPill
  public var amount: Money
  /// "DEWA · expected Wed".
  public var caption: String

  public init(glyph: Glyph, hue: Hue, due: StatusPill, amount: Money, caption: String) {
    self.glyph = glyph
    self.hue = hue
    self.due = due
    self.amount = amount
    self.caption = caption
  }
}

public struct NetWorthWidget: Sendable, Hashable, Codable {
  public var total: Money
  public var change: MoneyPhrase
  /// Twelve points for the sparkline, as permille of the drawn range (geometry only).
  public var spark: [Permille]
  public var mark: TotalMark?

  public init(total: Money, change: MoneyPhrase, spark: [Permille], mark: TotalMark? = nil) {
    self.total = total
    self.change = change
    self.spark = spark
    self.mark = mark
  }
}

public struct ProjectWidget: Sendable, Hashable, Codable {
  public enum Unit: String, Sendable, Hashable, Codable {
    case left, over, spent
  }

  public var name: String
  public var glyph: Glyph
  public var left: Money
  public var unit: Unit
  /// "of 12,000 · flies 14 Dec".
  public var caption: MoneyPhrase
  public var progress: Permille?

  public init(name: String, glyph: Glyph, left: Money, unit: Unit = .left, caption: MoneyPhrase, progress: Permille?) {
    self.name = name
    self.glyph = glyph
    self.left = left
    self.unit = unit
    self.caption = caption
    self.progress = progress
  }
}

public struct GoalWidget: Sendable, Hashable, Codable {
  public var name: String
  public var glyph: Glyph
  public var progress: Permille
  /// "38,500 of 50,000 · Jan".
  public var caption: MoneyPhrase

  public init(name: String, glyph: Glyph, progress: Permille, caption: MoneyPhrase) {
    self.name = name
    self.glyph = glyph
    self.progress = progress
    self.caption = caption
  }

  /// "77%": whole percent, rounded down, so 99.9% never reads as done.
  public var percentLabel: String { "\(progress.value / 10)%" }
}

public struct MiniTxnRow: Sendable, Hashable, Codable, Identifiable {
  public var id: String
  public var merchant: String
  public var glyph: Glyph
  public var hue: Hue
  /// "Dining · 09:05 · DIFC".
  public var detail: String
  public var amount: Money
  public var isIncome: Bool
  /// A merchant's first letter, drawn instead of the glyph for a merchant not sorted yet.
  public var monogram: String?
  /// The to-review variant: an accent dot before the title (Paper "kit Lists and cards").
  public var toReview: Bool
  public var reviewReason: TxnReviewReason?
  public var project: Project?
  public var estimate: Bool = false
  public var notCounted: Bool = false
  public var spokenDetail: String?

  public struct Project: Sendable, Hashable, Codable {
    public var id: ProjectID
    public var name: String

    public init(id: ProjectID, name: String) {
      self.id = id
      self.name = name
    }
  }

  public init(
    id: String, merchant: String, glyph: Glyph, hue: Hue, detail: String, amount: Money,
    isIncome: Bool = false, monogram: String? = nil, toReview: Bool = false, reviewReason: TxnReviewReason? = nil,
    project: Project? = nil
  ) {
    self.id = id
    self.merchant = merchant
    self.glyph = glyph
    self.hue = hue
    self.detail = detail
    self.amount = amount
    self.isIncome = isIncome
    self.monogram = monogram
    self.toReview = toReview
    self.reviewReason = reviewReason
    self.project = project
  }
}

extension MiniTxnRow {
  public var senderUnverified: Bool { reviewReason == .senderUnverified }
}

public struct TodayWidget: Sendable, Hashable, Codable {
  /// "2 transactions · 91.50".
  public var summary: MoneyPhrase
  public var rows: [MiniTxnRow]

  public init(summary: MoneyPhrase, rows: [MiniTxnRow]) {
    self.summary = summary
    self.rows = rows
  }
}

/// One tile on the Home canvas, in the order the person arranged them.
public enum HomeWidget: Sendable, Hashable, Identifiable, CanvasSized {
  case budgetPace(BudgetPaceWidget)
  case nextBill(NextBillWidget)
  case netWorth(NetWorthWidget)
  case project(ProjectWidget)
  case goal(GoalWidget)
  case today(TodayWidget)
  case spentSoFar(SpentSoFarWidget)
  case categoryWatch(CategoryWatchWidget)
  case comingUp(ComingUpWidget)
  case toReview(ToReviewWidget)

  public enum Size: String, Sendable, Hashable, Codable { case small, medium }

  public var kind: HomeWidgetKind {
    switch self {
    case .budgetPace: .budgetPace
    case .nextBill: .nextBill
    case .netWorth: .netWorth
    case .project: .project
    case .goal: .goal
    case .today: .today
    case .spentSoFar: .spentSoFar
    case .categoryWatch: .categoryWatch
    case .comingUp: .comingUp
    case .toReview: .toReview
    }
  }

  public var size: Size { kind.size }

  public var id: String {
    switch self {
    case .budgetPace: "budgetPace"
    case .nextBill: "nextBill"
    case .netWorth: "netWorth"
    case .project(let p): "project." + p.name
    case .goal(let g): "goal." + g.name
    case .today: "today"
    case .spentSoFar: "spentSoFar"
    case .categoryWatch(let c): "categoryWatch." + c.id
    case .comingUp: "comingUp"
    case .toReview: "toReview"
    }
  }
}

/// Everything Home draws at one instant. The bell's list comes with it, so one ledger change
/// recomputes both once.
public struct HomeSnapshot: Sendable, Hashable {
  public var header: HeaderState
  public var hero: SpendHero
  /// What needs a look (the bell's badge and its sheet), from the ledger.
  public var notifications: NotificationsSnapshot
  public var widgets: [HomeWidget]
  public var period: Period?
  public var canvasTitle: String
  public var aboutNow: [AboutNowRow]

  public init(
    header: HeaderState, hero: SpendHero, notifications: NotificationsSnapshot, widgets: [HomeWidget],
    period: Period? = nil, canvasTitle: String = "Your widgets", aboutNow: [AboutNowRow] = []
  ) {
    self.header = header
    self.hero = hero
    self.notifications = notifications
    self.widgets = widgets
    self.period = period
    self.canvasTitle = canvasTitle
    self.aboutNow = aboutNow
  }

  public var isThisMonth: Bool { period == nil }
}

public extension Array where Element: CanvasSized {
  /// Lays the canvas out in rows: a medium widget alone, small widgets in pairs
  /// (an unpaired small widget sits alone at the left), as on Paper's canvas.
  var canvasRows: [[Element]] {
    var rows: [[Element]] = []
    var pending: Element?
    for w in self {
      switch w.size {
      case .medium:
        if let p = pending { rows.append([p]); pending = nil }
        rows.append([w])
      case .small:
        if let p = pending { rows.append([p, w]); pending = nil } else { pending = w }
      }
    }
    if let p = pending { rows.append([p]) }
    return rows
  }
}
