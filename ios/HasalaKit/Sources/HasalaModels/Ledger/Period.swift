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

  public init(_ a: YearMonth, _ b: YearMonth) {
    first = min(a, b)
    last = max(a, b)
  }

  public static func month(_ m: YearMonth) -> Period { Period(m, m) }

  public var isMonth: Bool { first == last }

  public var count: Int { first.months(until: last) + 1 }

  public var months: [YearMonth] { (0..<count).map { first.adding(months: $0) } }

  public func contains(_ m: YearMonth) -> Bool { first <= m && m <= last }

  public func contains(_ d: LocalDate) -> Bool { contains(d.yearMonth) }

  public func clamped(to today: YearMonth) -> Period {
    Period(min(first, today), min(last, today))
  }

  public var title: String {
    if isMonth { return first.title }
    if first.year == last.year { return "\(first.shortName) – \(last.shortName) \(last.year)" }
    return "\(first.shortName) \(first.year) – \(last.shortName) \(last.year)"
  }

  public var span: String {
    if isMonth { return first.title }
    if first.year == last.year { return "\(first.shortName) to \(last.shortName)" }
    return "\(first.shortName) \(first.year) to \(last.shortName) \(last.year)"
  }

  public var description: String { isMonth ? "\(first)" : "\(first)…\(last)" }

  public func preset(today: YearMonth) -> PeriodPreset? {
    PeriodPreset.allCases.first { $0.period(today: today) == self }
  }
}

public enum PeriodPreset: String, Sendable, Hashable, CaseIterable, Identifiable {
  case thisMonth, lastMonth, last3Months, thisYear

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .thisMonth: "This month"
    case .lastMonth: "Last month"
    case .last3Months: "Last 3 months"
    case .thisYear: "This year"
    }
  }

  public func period(today: YearMonth) -> Period {
    switch self {
    case .thisMonth: .month(today)
    case .lastMonth: .month(today.previous)
    case .last3Months: Period(today.adding(months: -2), today)
    case .thisYear: Period(YearMonth(today.year, 1), today)
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
  public let earliestYear: Int

  public init(period: Period, today: YearMonth, earliest: YearMonth? = nil) {
    let shown = period.clamped(to: today)
    self.period = shown
    self.today = today
    self.year = shown.last.year
    self.earliestYear = min(earliest?.year ?? today.year, shown.first.year)
  }

  public var preset: PeriodPreset? { period.preset(today: today) }

  public mutating func choose(_ preset: PeriodPreset) {
    period = preset.period(today: today)
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
    period.isMonth ? "Tap a month, or two for a range." : "\(period.span). Tap a month to start again."
  }

  public var confirmTitle: String { "Show \(period.title)" }
}
