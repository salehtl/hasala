public struct SpentSoFarWidget: Sendable, Hashable, Codable {
  public var spent: Money
  public var plan: Money
  public var verdict: Verdict?
  public var progress: Permille
  public var tick: Permille?
  public var caption: MoneyPhrase
  public var billWords: String?
  public var billNamed: String?

  public init(
    spent: Money, plan: Money, verdict: Verdict?, progress: Permille, tick: Permille?, caption: MoneyPhrase,
    billWords: String?, billNamed: String?
  ) {
    self.spent = spent
    self.plan = plan
    self.verdict = verdict
    self.progress = progress
    self.tick = tick
    self.caption = caption
    self.billWords = billWords
    self.billNamed = billNamed
  }

  public var verdictWord: String { verdict?.label ?? "No plan yet" }
}

public struct CategoryWatchWidget: Sendable, Hashable, Codable, Identifiable {
  public var id: CategoryID
  public var name: String
  public var glyph: Glyph
  public var hue: Hue
  public var left: Money
  public var perDay: Money
  public var verdict: Verdict
  public var progress: Permille
  public var tick: Permille?

  public init(
    id: CategoryID, name: String, glyph: Glyph, hue: Hue, left: Money, perDay: Money, verdict: Verdict,
    progress: Permille, tick: Permille?
  ) {
    self.id = id
    self.name = name
    self.glyph = glyph
    self.hue = hue
    self.left = left
    self.perDay = perDay
    self.verdict = verdict
    self.progress = progress
    self.tick = tick
  }

  public var isOver: Bool { left.minor < 0 }

  public var caption: MoneyPhrase {
    if isOver { return MoneyPhrase(stringLiteral: "\(name) · over budget") }
    if perDay.minor <= 0 { return MoneyPhrase(stringLiteral: "\(name) · nothing left") }
    return MoneyPhrase([.text("\(name) · "), .amount(perDay, .rounded, hidden: 3), .text(" a day fits")])
  }
}

public struct ComingUpRow: Sendable, Hashable, Codable, Identifiable {
  public var id: String
  public var name: String
  public var glyph: Glyph
  public var hue: Hue
  public var note: String
  public var late: Bool
  public var amount: Money
  public var isIncome: Bool

  public init(
    id: String, name: String, glyph: Glyph, hue: Hue, note: String, late: Bool, amount: Money, isIncome: Bool
  ) {
    self.id = id
    self.name = name
    self.glyph = glyph
    self.hue = hue
    self.note = note
    self.late = late
    self.amount = amount
    self.isIncome = isIncome
  }
}

public struct ComingUpWidget: Sendable, Hashable, Codable {
  public var days: Int
  public var total: Money
  public var rows: [ComingUpRow]

  public init(days: Int, total: Money, rows: [ComingUpRow]) {
    self.days = days
    self.total = total
    self.rows = rows
  }

  public var title: String { "Coming up · \(days) days" }
}

public struct ToReviewWidget: Sendable, Hashable, Codable {
  public var count: Int
  public var notCounted: Money

  public init(count: Int, notCounted: Money) {
    self.count = count
    self.notCounted = notCounted
  }

  public var caption: MoneyPhrase {
    count == 0
      ? "Nothing to sort"
      : MoneyPhrase([.amount(notCounted, .rounded, hidden: 3), .text(" not counted yet")])
  }
}

public struct WidgetSnapshot: Sendable, Hashable, Codable {
  public static let currentVersion = 1

  public var version: Int
  public var amountsHidden: Bool
  public var lockScreenDetails: Bool
  public var spentSoFar: SpentSoFarWidget?
  public var budgetPace: BudgetPaceWidget?
  public var categories: [CategoryWatchWidget]
  public var nextBill: NextBillWidget?
  public var netWorth: NetWorthWidget?
  public var comingUp: ComingUpWidget?
  public var projects: [ProjectWidget]
  public var goals: [GoalWidget]
  public var toReview: ToReviewWidget?
  public var today: TodayWidget?

  public init(
    amountsHidden: Bool, lockScreenDetails: Bool, spentSoFar: SpentSoFarWidget?, budgetPace: BudgetPaceWidget?,
    categories: [CategoryWatchWidget], nextBill: NextBillWidget?, netWorth: NetWorthWidget?,
    comingUp: ComingUpWidget?, projects: [ProjectWidget], goals: [GoalWidget], toReview: ToReviewWidget?,
    today: TodayWidget?
  ) {
    version = Self.currentVersion
    self.amountsHidden = amountsHidden
    self.lockScreenDetails = lockScreenDetails
    self.spentSoFar = spentSoFar
    self.budgetPace = budgetPace
    self.categories = categories
    self.nextBill = nextBill
    self.netWorth = netWorth
    self.comingUp = comingUp
    self.projects = projects
    self.goals = goals
    self.toReview = toReview
    self.today = today
  }

  public var lockShowsAmounts: Bool { lockScreenDetails && !amountsHidden }

  public func category(_ id: CategoryID?) -> CategoryWatchWidget? {
    if let id, let c = categories.first(where: { $0.id == id }) { return c }
    return categories.first { $0.verdict == .overPace || $0.verdict == .overBudget } ?? categories.first
  }

  public func project(_ name: String?) -> ProjectWidget? {
    if let name, let p = projects.first(where: { $0.name == name }) { return p }
    return projects.first
  }

  public func goal(_ name: String?) -> GoalWidget? {
    if let name, let g = goals.first(where: { $0.name == name }) { return g }
    return goals.first
  }
}

public extension MoneyFormat {
  static func short(_ minor: Int64) -> String {
    let dirhams = (minor.magnitude + 50) / 100
    if dirhams < 1_000 { return grouped(dirhams) }
    if dirhams < 100_000 {
      let tenths = (dirhams + 50) / 100
      return "\(tenths / 10)" + (tenths % 10 == 0 ? "" : ".\(tenths % 10)") + "K"
    }
    if dirhams < 1_000_000 { return "\((dirhams + 500) / 1_000)K" }
    let tenths = (dirhams + 50_000) / 100_000
    return "\(tenths / 10)" + (tenths % 10 == 0 ? "" : ".\(tenths % 10)") + "M"
  }
}
