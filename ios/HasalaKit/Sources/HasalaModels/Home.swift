// UI read models for Home (Paper "Home · Default", spec 04 §15.1 `HomeModel`).
//
// They are plain values: an engine (later) or the Maya mock (now) builds them,
// and HasalaDesign draws them. Nothing here reads a clock or a database.

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
}

/// The tone of a small status pill ("2 new today", "3 days late", "In 4 days").
public enum StatusTone: String, Sendable, Hashable, Codable {
  case accent, error, warning, success
}

public struct StatusPill: Sendable, Hashable {
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
  public var unreadNotifications: Int
  public var avatarInitial: String

  public init(unreadNotifications: Int, avatarInitial: String) {
    self.unreadNotifications = unreadNotifications
    self.avatarInitial = avatarInitial
  }
}

public struct HeroStat: Sendable, Hashable, Identifiable {
  public var id: String { label }
  public var label: String
  public var value: Money

  public init(_ label: String, _ value: Money) {
    self.label = label
    self.value = value
  }
}

/// "What's left for everyday spending" (Paper hero, spec 04 §15.1 `EverydayHero`).
public struct EverydayHero: Sendable, Hashable {
  /// "October · day 10 of 31" (drawn uppercase).
  public var overline: String
  public var left: Money
  public var caption: String
  /// How much of the everyday budget is spent.
  public var spent: Permille
  /// How much of the month has gone: the ink tick.
  public var today: Permille
  public var verdict: Verdict
  /// "about AED 337 a day" (the view draws the "·" before it when it sits on the verdict line).
  public var verdictDetail: MoneyPhrase
  public var stats: [HeroStat]
  /// The wash behind the hero: sky on track, sand over pace, rose over budget.
  public var wash: Hue

  public init(
    overline: String, left: Money, caption: String, spent: Permille, today: Permille,
    verdict: Verdict, verdictDetail: MoneyPhrase, stats: [HeroStat], wash: Hue
  ) {
    self.overline = overline
    self.left = left
    self.caption = caption
    self.spent = spent
    self.today = today
    self.verdict = verdict
    self.verdictDetail = verdictDetail
    self.stats = stats
    self.wash = wash
  }
}

/// The big figure on a Needs-you poster: a count ("6 to sort") or an amount.
public enum PosterFigure: Sendable, Hashable {
  case count(Int, unit: String)
  case money(Money)
}

public struct NeedsYouCard: Sendable, Hashable, Identifiable {
  public var id: String
  public var hue: Hue
  public var glyph: Glyph
  public var label: String
  public var status: StatusPill
  public var figure: PosterFigure
  public var title: String
  public var subtitle: MoneyPhrase
  public var primaryAction: String
  public var secondaryAction: String

  public init(
    id: String, hue: Hue, glyph: Glyph, label: String, status: StatusPill, figure: PosterFigure,
    title: String, subtitle: MoneyPhrase, primaryAction: String, secondaryAction: String
  ) {
    self.id = id
    self.hue = hue
    self.glyph = glyph
    self.label = label
    self.status = status
    self.figure = figure
    self.title = title
    self.subtitle = subtitle
    self.primaryAction = primaryAction
    self.secondaryAction = secondaryAction
  }
}

public struct NeedsYouRail: Sendable, Hashable {
  /// The badge count; it may exceed the cards drawn (Paper: badge 4, two cards).
  public var count: Int
  public var subtitle: String
  public var cards: [NeedsYouCard]

  public init(count: Int, subtitle: String, cards: [NeedsYouCard]) {
    self.count = count
    self.subtitle = subtitle
    self.cards = cards
  }
}

// MARK: - Widgets (Paper "Widgets · launch set", the Home canvas)

public struct BucketPaceRow: Sendable, Hashable, Identifiable {
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

  public var left: Money { Money(minor: budget.minor - spent.minor, currency: budget.currency) }
  public var progress: Permille { Permille.ratio(spent.minor, of: budget.minor) }
}

public struct BudgetPaceWidget: Sendable, Hashable {
  /// "32% of October gone".
  public var monthGone: String
  public var rows: [BucketPaceRow]

  public init(monthGone: String, rows: [BucketPaceRow]) {
    self.monthGone = monthGone
    self.rows = rows
  }
}

public struct NextBillWidget: Sendable, Hashable {
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

public struct NetWorthWidget: Sendable, Hashable {
  public var total: Money
  public var change: MoneyPhrase
  /// Twelve points for the sparkline, as permille of the drawn range (geometry only).
  public var spark: [Permille]

  public init(total: Money, change: MoneyPhrase, spark: [Permille]) {
    self.total = total
    self.change = change
    self.spark = spark
  }
}

public struct ProjectWidget: Sendable, Hashable {
  public var name: String
  public var glyph: Glyph
  public var left: Money
  /// "of 12,000 · flies 14 Dec".
  public var caption: MoneyPhrase
  public var progress: Permille

  public init(name: String, glyph: Glyph, left: Money, caption: MoneyPhrase, progress: Permille) {
    self.name = name
    self.glyph = glyph
    self.left = left
    self.caption = caption
    self.progress = progress
  }
}

public struct GoalWidget: Sendable, Hashable {
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

public struct MiniTxnRow: Sendable, Hashable, Identifiable {
  public var id: String
  public var merchant: String
  public var glyph: Glyph
  public var hue: Hue
  /// "Dining · 09:05 · DIFC".
  public var detail: String
  public var amount: Money
  public var isIncome: Bool

  public init(
    id: String, merchant: String, glyph: Glyph, hue: Hue, detail: String, amount: Money,
    isIncome: Bool = false
  ) {
    self.id = id
    self.merchant = merchant
    self.glyph = glyph
    self.hue = hue
    self.detail = detail
    self.amount = amount
    self.isIncome = isIncome
  }
}

public struct TodayWidget: Sendable, Hashable {
  /// "2 transactions · 91.50".
  public var summary: MoneyPhrase
  public var rows: [MiniTxnRow]

  public init(summary: MoneyPhrase, rows: [MiniTxnRow]) {
    self.summary = summary
    self.rows = rows
  }
}

/// One tile on the Home canvas, in the order the person arranged them.
public enum HomeWidget: Sendable, Hashable, Identifiable {
  case budgetPace(BudgetPaceWidget)
  case nextBill(NextBillWidget)
  case netWorth(NetWorthWidget)
  case project(ProjectWidget)
  case goal(GoalWidget)
  case today(TodayWidget)

  public enum Size: Sendable { case small, medium }

  public var size: Size {
    switch self {
    case .budgetPace, .today: .medium
    case .nextBill, .netWorth, .project, .goal: .small
    }
  }

  public var id: String {
    switch self {
    case .budgetPace: "budgetPace"
    case .nextBill: "nextBill"
    case .netWorth: "netWorth"
    case .project(let p): "project." + p.name
    case .goal(let g): "goal." + g.name
    case .today: "today"
    }
  }
}

/// Everything Home draws at one instant.
public struct HomeSnapshot: Sendable, Hashable {
  public var header: HeaderState
  public var hero: EverydayHero
  public var needsYou: NeedsYouRail
  public var widgets: [HomeWidget]

  public init(header: HeaderState, hero: EverydayHero, needsYou: NeedsYouRail, widgets: [HomeWidget]) {
    self.header = header
    self.hero = hero
    self.needsYou = needsYou
    self.widgets = widgets
  }
}

public extension Array where Element == HomeWidget {
  /// Lays the canvas out in rows: a medium widget alone, small widgets in pairs
  /// (an unpaired small widget sits alone at the left), as on Paper's canvas.
  var canvasRows: [[HomeWidget]] {
    var rows: [[HomeWidget]] = []
    var pending: HomeWidget?
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
