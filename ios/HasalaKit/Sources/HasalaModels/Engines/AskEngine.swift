public struct AskPeriod: Sendable, Hashable {
  public var from: LocalDate
  public var through: LocalDate
  public var phrase: String
  public var label: String

  public init(from: LocalDate, through: LocalDate, phrase: String, label: String) {
    self.from = from
    self.through = through
    self.phrase = phrase
    self.label = label
  }

  public static func today(_ d: LocalDate) -> AskPeriod {
    AskPeriod(from: d, through: d, phrase: "today", label: "Today")
  }

  public static func yesterday(_ d: LocalDate) -> AskPeriod {
    let y = d.adding(days: -1)
    return AskPeriod(from: y, through: y, phrase: "yesterday", label: "Yesterday")
  }

  public static func thisWeek(_ d: LocalDate) -> AskPeriod {
    AskPeriod(from: d.adding(days: -d.weekday), through: d, phrase: "this week", label: "This week")
  }

  public static func lastWeek(_ d: LocalDate) -> AskPeriod {
    let monday = d.adding(days: -d.weekday - 7)
    return AskPeriod(from: monday, through: monday.adding(days: 6), phrase: "last week", label: "Last week")
  }

  public static func thisMonth(_ d: LocalDate) -> AskPeriod {
    AskPeriod(from: LocalDate(d.year, d.month, 1), through: d, phrase: "this month", label: d.yearMonth.name)
  }

  public static func lastMonth(_ d: LocalDate) -> AskPeriod {
    let m = d.yearMonth.previous
    return AskPeriod(from: LocalDate(m.year, m.month, 1), through: LocalDate(m.year, m.month, m.days),
                     phrase: "last month", label: m.name)
  }

  public static func thisYear(_ d: LocalDate) -> AskPeriod {
    AskPeriod(from: LocalDate(d.year, 1, 1), through: d, phrase: "this year", label: "\(d.year)")
  }

  public static func lastYear(_ d: LocalDate) -> AskPeriod {
    AskPeriod(from: LocalDate(d.year - 1, 1, 1), through: LocalDate(d.year - 1, 12, 31), phrase: "last year",
              label: "\(d.year - 1)")
  }

  public static func month(_ month: Int, year: Int?, today d: LocalDate) -> AskPeriod {
    let y = year ?? (month > d.month ? d.year - 1 : d.year)
    let m = YearMonth(y, month)
    let named = y == d.year ? m.name : m.title
    return AskPeriod(from: LocalDate(y, month, 1), through: LocalDate(y, month, m.days), phrase: "in \(named)",
                     label: named)
  }

  public static func lastDays(_ n: Int, today d: LocalDate) -> AskPeriod {
    AskPeriod(from: d.adding(days: -(n - 1)), through: d, phrase: "in the past \(n) day\(n == 1 ? "" : "s")",
              label: "Past \(n) day\(n == 1 ? "" : "s")")
  }
}

public struct AskFilter: Sendable, Hashable {
  public var merchants: [String]
  public var category: CategoryID?
  public var minimumFils: Int64?
  public var maximumFils: Int64?
  public var period: AskPeriod?
  public var direction: Direction?
  public var asksTotal: Bool

  public init(
    merchants: [String] = [], category: CategoryID? = nil, minimumFils: Int64? = nil, maximumFils: Int64? = nil,
    period: AskPeriod? = nil, direction: Direction? = nil, asksTotal: Bool = false
  ) {
    self.merchants = merchants
    self.category = category
    self.minimumFils = minimumFils
    self.maximumFils = maximumFils
    self.period = period
    self.direction = direction
    self.asksTotal = asksTotal
  }
}

public struct AskAnswer: Sendable, Hashable {
  public var headline: String
  public var scope: [String]
  public var rows: [MiniTxnRow]
  public var total: Money
  public var isIncome: Bool
  public var countLine: String
  public var activity: TxnFilter?
}

public enum AskEngine {
  public static func answer(_ s: LedgerState, filter f: AskFilter) -> AskAnswer {
    let found = s.txns.filter { matches($0, f, s) }.sorted { $0.postedAt > $1.postedAt }
    let isIncome = f.direction == .in || (f.direction == nil && !found.isEmpty && found.allSatisfy { $0.direction == .in })
    let total: Int64 = found.reduce(0) { sum, t in
      if isIncome { return t.direction == .in && !t.isRefund ? sum + t.amount.minor : sum }
      if t.isTransfer { return sum }
      return t.direction == .out ? sum + t.amount.minor : (t.isRefund ? sum - t.amount.minor : sum)
    }
    let rows = found.map { t in
      var r = ActivityEngine.row(t, s)
      r.detail = "\(s.category(t.categoryID)?.name ?? "To review") · \(t.postedAt.date.short)"
      return r
    }
    let activity: TxnFilter? =
      if f.merchants.count == 1 { TxnFilter(text: f.merchants[0]) }
      else if f.merchants.isEmpty, let c = f.category { TxnFilter(category: c) }
      else { nil }
    return AskAnswer(
      headline: headline(f, s, isIncome: isIncome), scope: scope(f, s), rows: rows, total: .aed(max(total, 0)),
      isIncome: isIncome, countLine: "\(found.count) transaction\(found.count == 1 ? "" : "s")", activity: activity)
  }

  public static func matches(_ t: Txn, _ f: AskFilter, _ s: LedgerState) -> Bool {
    if t.archived { return false }
    if let d = f.direction, t.direction != d || t.isTransfer { return false }
    if let p = f.period, t.postedAt.date < p.from || t.postedAt.date > p.through { return false }
    if let lo = f.minimumFils, t.amount.minor < lo { return false }
    if let hi = f.maximumFils, t.amount.minor > hi { return false }
    if let c = f.category, !t.lines.contains(where: { $0.category == c }) { return false }
    if !f.merchants.isEmpty {
      let hay = [t.title, t.provenance?.rawMerchant ?? ""].joined(separator: "\n").lowercased()
      if !f.merchants.contains(where: { hay.contains($0.lowercased()) }) { return false }
    }
    return true
  }

  static func subject(_ f: AskFilter, _ s: LedgerState) -> String? {
    switch f.merchants.count {
    case 0: return s.category(f.category)?.name
    case 1: return f.merchants[0]
    case 2: return "\(f.merchants[0]) and \(f.merchants[1])"
    default: return "\(f.merchants[0]) and \(f.merchants.count - 1) more"
    }
  }

  static func headline(_ f: AskFilter, _ s: LedgerState, isIncome: Bool) -> String {
    let lead: String
    if let who = subject(f, s) {
      lead = f.merchants.isEmpty ? who : (isIncome ? "From \(who)" : "At \(who)")
    } else {
      lead = isIncome ? "Money in" : (f.direction == .out ? "Spending" : "Transactions")
    }
    var words = [lead]
    if let lo = f.minimumFils, let hi = f.maximumFils {
      words.append("between \(MoneyFormat.string(lo, style: .compact)) and \(MoneyFormat.string(hi, style: .compact))")
    } else if let lo = f.minimumFils {
      words.append("over \(MoneyFormat.string(lo, style: .compact))")
    } else if let hi = f.maximumFils {
      words.append("under \(MoneyFormat.string(hi, style: .compact))")
    }
    if let p = f.period { words.append(p.phrase) }
    return words.joined(separator: " ")
  }

  static func scope(_ f: AskFilter, _ s: LedgerState) -> [String] {
    var out = f.merchants
    if let c = s.category(f.category) { out.append(c.name) }
    if let p = f.period { out.append(p.label) }
    if let lo = f.minimumFils { out.append("≥ \(MoneyFormat.string(lo, style: .compact))") }
    if let hi = f.maximumFils { out.append("≤ \(MoneyFormat.string(hi, style: .compact))") }
    if let d = f.direction { out.append(d == .in ? "Money in" : "Spent") }
    return out
  }
}
