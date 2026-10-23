extension YearMonth {
  public var index: Int { year * 12 + (month - 1) }

  public init(index: Int) {
    self.init(index >= 0 ? index / 12 : (index - 11) / 12, ((index % 12) + 12) % 12 + 1)
  }

  public func adding(months: Int) -> YearMonth { YearMonth(index: index + months) }

  public func months(until other: YearMonth) -> Int { other.index - index }

  public var firstDay: LocalDate { LocalDate(year, month, 1) }

  public var lastDay: LocalDate { LocalDate(year, month, days) }
}

public struct Period: Sendable, Hashable, Codable, CustomStringConvertible {
  public private(set) var first: YearMonth
  public private(set) var last: YearMonth
  public private(set) var isAllTime = false

  public init(_ a: YearMonth, _ b: YearMonth) {
    first = min(a, b)
    last = max(a, b)
  }

  public static func allTime(since earliest: YearMonth?, today: YearMonth) -> Period {
    var p = Period(min(earliest ?? today, today), today)
    p.isAllTime = true
    return p
  }

  private enum CodingKeys: String, CodingKey {
    case first, last, isAllTime
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.init(try c.decode(YearMonth.self, forKey: .first), try c.decode(YearMonth.self, forKey: .last))
    isAllTime = try c.decodeIfPresent(Bool.self, forKey: .isAllTime) ?? false
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(first, forKey: .first)
    try c.encode(last, forKey: .last)
    if isAllTime { try c.encode(true, forKey: .isAllTime) }
  }

  public init(_ months: ClosedRange<YearMonth>) {
    self.init(months.lowerBound, months.upperBound)
  }

  public static func month(_ m: YearMonth) -> Period { Period(m, m) }

  public var range: ClosedRange<YearMonth> { first...last }

  public var isMonth: Bool { first == last }

  public var count: Int { first.months(until: last) + 1 }

  public var months: [YearMonth] { (0..<count).map { first.adding(months: $0) } }

  public func contains(_ m: YearMonth) -> Bool { first <= m && m <= last }

  public func contains(_ d: LocalDate) -> Bool { contains(d.yearMonth) }

  public func clamped(to today: YearMonth) -> Period {
    if isAllTime { return .allTime(since: first, today: today) }
    return Period(min(first, today), min(last, today))
  }

  public var showsBudgets: Bool { !isAllTime }

  public var title: String {
    if isAllTime { return "All time" }
    if isMonth { return first.title }
    if first.year == last.year { return "\(first.shortName) – \(last.shortName) \(last.year)" }
    return "\(first.shortName) \(first.year) – \(last.shortName) \(last.year)"
  }

  public var span: String {
    if isMonth { return first.title }
    if first.year == last.year { return "\(first.shortName) to \(last.shortName)" }
    return "\(first.shortName) \(first.year) to \(last.shortName) \(last.year)"
  }

  public var description: String {
    if isAllTime { return "all \(first)…\(last)" }
    return isMonth ? "\(first)" : "\(first)…\(last)"
  }

  public func preset(today: YearMonth) -> PeriodPreset? {
    if isAllTime { return .allTime }
    return PeriodPreset.allCases.first { $0.period(today: today) == self }
  }
}

public enum PeriodPreset: String, Sendable, Hashable, CaseIterable, Identifiable {
  case thisMonth, lastMonth, last3Months, thisYear, allTime

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .thisMonth: "This month"
    case .lastMonth: "Last month"
    case .last3Months: "Last 3 months"
    case .thisYear: "This year"
    case .allTime: "All time"
    }
  }

  public func period(today: YearMonth, earliest: YearMonth? = nil) -> Period {
    switch self {
    case .thisMonth: .month(today)
    case .lastMonth: .month(today.previous)
    case .last3Months: Period(today.adding(months: -2), today)
    case .thisYear: Period(YearMonth(today.year, 1), today)
    case .allTime: .allTime(since: earliest, today: today)
    }
  }
}

public struct PeriodPicking: Sendable, Hashable {
  public enum Cell: Sendable, Hashable {
    case open, end, between, future
  }

  public private(set) var period: Period
  public private(set) var year: Int
  public private(set) var anchor: YearMonth?
  public let today: YearMonth
  public let earliest: YearMonth?
  public let earliestYear: Int

  public init(period: Period, today: YearMonth, earliest: YearMonth? = nil) {
    let shown = period.clamped(to: today)
    self.period = shown
    self.today = today
    self.earliest = earliest
    self.year = shown.last.year
    self.earliestYear = min(earliest?.year ?? today.year, shown.first.year)
  }

  public var preset: PeriodPreset? { period.preset(today: today) }

  public mutating func choose(_ preset: PeriodPreset) {
    period = preset.period(today: today, earliest: earliest)
    anchor = nil
    year = period.last.year
  }

  public mutating func tap(_ m: YearMonth) {
    guard m <= today else { return }
    if let a = anchor, a != m {
      period = Period(a, m)
      anchor = nil
    } else {
      period = .month(m)
      anchor = m
    }
  }

  public var canGoBack: Bool { year > earliestYear }
  public var canGoForward: Bool { year < today.year }

  public mutating func previousYear() { if canGoBack { year -= 1 } }
  public mutating func nextYear() { if canGoForward { year += 1 } }

  public var months: [YearMonth] { (1...12).map { YearMonth(year, $0) } }

  public func cell(_ m: YearMonth) -> Cell {
    if m > today { return .future }
    if m == period.first || m == period.last { return .end }
    if period.contains(m) { return .between }
    return .open
  }

  public var hint: String {
    if period.isAllTime { return "Since \(period.first.title). Tap a month to start again." }
    return period.isMonth ? "Tap a month, or two for a range." : "\(period.span). Tap a month to start again."
  }

  public var confirmTitle: String { period.isAllTime ? "Show all time" : "Show \(period.title)" }
}
