public enum InsightsTarget: Sendable, Hashable {
  case bucket(Bucket)
  case category(CategoryID)
  case merchant(String)
  case unsorted
}

public enum InsightsLens: String, Sendable, Hashable, CaseIterable {
  case buckets, categories, merchants

  public var title: String {
    switch self {
    case .buckets: "Buckets"
    case .categories: "Categories"
    case .merchants: "Merchants"
    }
  }
}

public struct InsightsLine: Sendable, Hashable {
  public enum Kind: Sendable, Hashable {
    case spent
    case saved
    case income
  }

  public var txnID: TxnID
  public var part: Int
  public var merchant: String
  public var postedAt: LocalDateTime
  public var categoryID: CategoryID
  public var bucket: Bucket
  public var kind: Kind
  public var minor: Int64

  public init(txnID: TxnID, part: Int, merchant: String, postedAt: LocalDateTime, categoryID: CategoryID,
              bucket: Bucket, kind: Kind, minor: Int64) {
    self.txnID = txnID
    self.part = part
    self.merchant = merchant
    self.postedAt = postedAt
    self.categoryID = categoryID
    self.bucket = bucket
    self.kind = kind
    self.minor = minor
  }
}

public struct InsightsWindow: Sendable, Hashable {
  public var from: LocalDate
  public var through: LocalDate

  public init(from: LocalDate, through: LocalDate) {
    self.from = from
    self.through = through
  }

  public func contains(_ d: LocalDate) -> Bool { from <= d && d <= through }
}

public struct InsightsDelta: Sendable, Hashable {
  public enum Kind: Sendable, Hashable {
    case up(percent: Int)
    case down(percent: Int)
    case new
    case gone
    case same
  }

  public enum Tone: Sendable, Hashable {
    case neutral, warning, success
  }

  public var kind: Kind
  public var tone: Tone

  public init(kind: Kind, tone: Tone) {
    self.kind = kind
    self.tone = tone
  }

  public static func between(_ current: Int64, _ previous: Int64) -> InsightsDelta? {
    if current == previous { return InsightsDelta(kind: .same, tone: .neutral) }
    if previous <= 0 {
      return current > 0 ? InsightsDelta(kind: .new, tone: .neutral) : nil
    }
    if current <= 0 { return InsightsDelta(kind: .gone, tone: .success) }
    let change = current - previous
    let magnitude = change.magnitude
    let whole = UInt64(previous)
    let percent = Int((magnitude * 200 + whole) / (whole * 2))
    let marked = magnitude * 10 >= whole
    return change > 0
      ? InsightsDelta(kind: .up(percent: percent), tone: marked ? .warning : .neutral)
      : InsightsDelta(kind: .down(percent: percent), tone: marked ? .success : .neutral)
  }

  public var text: String {
    switch kind {
    case .up(let p): "\u{2191} " + (p == 0 ? "<1%" : "\(p)%")
    case .down(let p): "\u{2193} " + (p == 0 ? "<1%" : "\(p)%")
    case .new: "new"
    case .gone: "gone"
    case .same: "same"
    }
  }

  public func spoken(against name: String) -> String {
    switch kind {
    case .up(let p): p == 0 ? "up less than 1 percent from \(name)" : "up \(p) percent from \(name)"
    case .down(let p): p == 0 ? "down less than 1 percent from \(name)" : "down \(p) percent from \(name)"
    case .new: "new since \(name)"
    case .gone: "gone since \(name)"
    case .same: "same as \(name)"
    }
  }
}

public struct InsightsComparison: Sendable, Hashable {
  public var month: YearMonth
  public var throughDay: Int?
  public var window: InsightsWindow

  public init(month: YearMonth, throughDay: Int?, window: InsightsWindow) {
    self.month = month
    self.throughDay = throughDay
    self.window = window
  }

  public var label: String {
    throughDay.map { "vs \(month.shortName) at day \($0)" } ?? "vs \(month.name)"
  }

  public var name: String {
    throughDay.map { "\(month.name) at day \($0)" } ?? month.name
  }

  public var when: String {
    throughDay.map { "by \($0) \(month.shortName)" } ?? "in \(month.name)"
  }
}

public struct InsightsRow: Sendable, Hashable, Identifiable {
  public var id: String
  public var target: InsightsTarget
  public var title: String
  public var glyph: Glyph
  public var hue: Hue
  public var bucket: Bucket
  public var monogram: String?
  public var amount: Money
  public var sharePercent: Int
  public var bar: Permille
  public var count: Int
  public var delta: InsightsDelta?

  public init(id: String, target: InsightsTarget, title: String, glyph: Glyph, hue: Hue, bucket: Bucket,
              monogram: String? = nil, amount: Money, sharePercent: Int, bar: Permille, count: Int,
              delta: InsightsDelta?) {
    self.id = id
    self.target = target
    self.title = title
    self.glyph = glyph
    self.hue = hue
    self.bucket = bucket
    self.monogram = monogram
    self.amount = amount
    self.sharePercent = sharePercent
    self.bar = bar
    self.count = count
    self.delta = delta
  }
}

public struct InsightsChange: Sendable, Hashable, Identifiable {
  public var id: CategoryID { categoryID }
  public var categoryID: CategoryID
  public var title: String
  public var glyph: Glyph
  public var hue: Hue
  public var current: Money
  public var previous: Money
  public var change: Money
  public var delta: InsightsDelta
  public var before: MoneyPhrase

  public init(categoryID: CategoryID, title: String, glyph: Glyph, hue: Hue, current: Money, previous: Money,
              change: Money, delta: InsightsDelta, before: MoneyPhrase) {
    self.categoryID = categoryID
    self.title = title
    self.glyph = glyph
    self.hue = hue
    self.current = current
    self.previous = previous
    self.change = change
    self.delta = delta
    self.before = before
  }
}

public struct InsightsNotice: Sendable, Hashable {
  public var title: String
  public var message: String

  public init(title: String, message: String) {
    self.title = title
    self.message = message
  }
}

public struct InsightsLegendRow: Sendable, Hashable, Identifiable {
  public enum Kind: String, Sendable, Hashable {
    case needs, wants, other, unsorted, savings, unspent
  }

  public var id: Kind { kind }
  public var kind: Kind
  public var title: String
  public var amount: Money
  public var delta: InsightsDelta?
  public var target: InsightsTarget?

  public init(kind: Kind, title: String, amount: Money, delta: InsightsDelta?, target: InsightsTarget?) {
    self.kind = kind
    self.title = title
    self.amount = amount
    self.delta = delta
    self.target = target
  }
}

public struct InsightsSplit: Sendable, Hashable {
  public var needs: Int64
  public var wants: Int64
  public var unsorted: Int64
  public var savings: Int64
  public var unspent: Int64

  public init(needs: Int64, wants: Int64, unsorted: Int64 = 0, savings: Int64, unspent: Int64) {
    self.needs = needs
    self.wants = wants
    self.unsorted = unsorted
    self.savings = savings
    self.unspent = unspent
  }

  public var total: Int64 { max(0, needs) + max(0, wants) + max(0, unsorted) + max(0, savings) + max(0, unspent) }
}

public struct InsightsSummary: Sendable, Hashable {
  public var label: String
  public var figure: Money
  public var isNet: Bool
  public var kept: String?
  public var keptPercent: Int?
  public var income: Money
  public var spent: Money
  public var saved: Money
  public var split: InsightsSplit?
  public var note: MoneyPhrase
  public var legend: [InsightsLegendRow]

  public init(label: String, figure: Money, isNet: Bool, keptPercent: Int?, income: Money, spent: Money,
              saved: Money, split: InsightsSplit?, note: MoneyPhrase, legend: [InsightsLegendRow]) {
    self.label = label
    self.figure = figure
    self.isNet = isNet
    self.keptPercent = keptPercent
    self.kept = keptPercent.map { "\($0)%" }
    self.income = income
    self.spent = spent
    self.saved = saved
    self.split = split
    self.note = note
    self.legend = legend
  }
}

public struct InsightsFlowMonth: Sendable, Hashable, Identifiable {
  public var id: YearMonth { month }
  public var month: YearMonth
  public var income: Money
  public var out: Money
  public var inProgress: Bool
  public var isFocus: Bool

  public init(month: YearMonth, income: Money, out: Money, inProgress: Bool, isFocus: Bool) {
    self.month = month
    self.income = income
    self.out = out
    self.inProgress = inProgress
    self.isFocus = isFocus
  }
}

public struct InsightsFlow: Sendable, Hashable {
  public var span: String
  public var months: [InsightsFlowMonth]
  public var averageOut: Money?
  public var note: MoneyPhrase

  public init(span: String, months: [InsightsFlowMonth], averageOut: Money?, note: MoneyPhrase) {
    self.span = span
    self.months = months
    self.averageOut = averageOut
    self.note = note
  }

  public var isEmpty: Bool { months.isEmpty }
}

public struct InsightsReport: Sendable, Hashable, Identifiable {
  public enum Kind: String, Sendable, Hashable, CaseIterable {
    case netWorth, inVsSpent, ageOfMoney, yearOnYear
  }

  public enum Value: Sendable, Hashable {
    case missing
    case money(Money)
    case signedMoney(Money)
    case delta(InsightsDelta)
  }

  public var id: Kind { kind }
  public var kind: Kind
  public var title: String
  public var value: Value
  public var caption: String
  public var opens: Bool

  public init(kind: Kind, title: String, value: Value, caption: String, opens: Bool) {
    self.kind = kind
    self.title = title
    self.value = value
    self.caption = caption
    self.opens = opens
  }
}

public struct InsightsSnapshot: Sendable, Hashable {
  public var months: ClosedRange<YearMonth>
  public var focus: YearMonth
  public var isCurrent: Bool
  public var title: String
  public var status: String
  public var window: InsightsWindow
  public var comparison: InsightsComparison?
  public var lensNote: String
  public var summary: InsightsSummary
  public var buckets: [InsightsRow]
  public var categories: [InsightsRow]
  public var merchants: [InsightsRow]
  public var lensFooter: MoneyPhrase
  public var lensEmpty: String
  public var changes: [InsightsChange]
  public var changesNotice: InsightsNotice?
  public var flow: InsightsFlow
  public var flowEmpty: String?
  public var reports: [InsightsReport]
  public var share: MoneyPhrase

  public init(
    months: ClosedRange<YearMonth>, focus: YearMonth, isCurrent: Bool, title: String, status: String,
    window: InsightsWindow, comparison: InsightsComparison?, lensNote: String, summary: InsightsSummary,
    buckets: [InsightsRow], categories: [InsightsRow], merchants: [InsightsRow], lensFooter: MoneyPhrase,
    lensEmpty: String, changes: [InsightsChange], changesNotice: InsightsNotice?, flow: InsightsFlow,
    flowEmpty: String?, reports: [InsightsReport], share: MoneyPhrase
  ) {
    self.months = months
    self.focus = focus
    self.isCurrent = isCurrent
    self.title = title
    self.status = status
    self.window = window
    self.comparison = comparison
    self.lensNote = lensNote
    self.summary = summary
    self.buckets = buckets
    self.categories = categories
    self.merchants = merchants
    self.lensFooter = lensFooter
    self.lensEmpty = lensEmpty
    self.changes = changes
    self.changesNotice = changesNotice
    self.flow = flow
    self.flowEmpty = flowEmpty
    self.reports = reports
    self.share = share
  }

  public func rows(_ lens: InsightsLens) -> [InsightsRow] {
    switch lens {
    case .buckets: buckets
    case .categories: categories
    case .merchants: merchants
    }
  }
}

public struct InsightsDrillCategory: Sendable, Hashable, Identifiable {
  public var id: CategoryID
  public var title: String
  public var count: Int
  public var amount: Money

  public init(id: CategoryID, title: String, count: Int, amount: Money) {
    self.id = id
    self.title = title
    self.count = count
    self.amount = amount
  }

  public var payments: String { "\(count) payment\(count == 1 ? "" : "s")" }
}

public struct InsightsDrillRow: Sendable, Hashable, Identifiable {
  public var id: String
  public var txnID: TxnID
  public var merchant: String
  public var glyph: Glyph
  public var hue: Hue
  public var detail: String
  public var amount: Money

  public init(id: String, txnID: TxnID, merchant: String, glyph: Glyph, hue: Hue, detail: String, amount: Money) {
    self.id = id
    self.txnID = txnID
    self.merchant = merchant
    self.glyph = glyph
    self.hue = hue
    self.detail = detail
    self.amount = amount
  }
}

public struct InsightsDrill: Sendable, Hashable {
  public var target: InsightsTarget
  public var title: String
  public var total: Money
  public var transactions: Int
  public var line: MoneyPhrase
  public var categories: [InsightsDrillCategory]
  public var rowsTitle: String
  public var rows: [InsightsDrillRow]

  public init(target: InsightsTarget, title: String, total: Money, transactions: Int, line: MoneyPhrase,
              categories: [InsightsDrillCategory], rowsTitle: String, rows: [InsightsDrillRow]) {
    self.target = target
    self.title = title
    self.total = total
    self.transactions = transactions
    self.line = line
    self.categories = categories
    self.rowsTitle = rowsTitle
    self.rows = rows
  }
}
