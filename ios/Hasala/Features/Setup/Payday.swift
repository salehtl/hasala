import Foundation
import HasalaModels

/// The salary day the income step offers (Paper "Setup · 3 of 4 · Monthly income", the day
/// strip): a day of the month, or the last working day.
enum PaydayChoice: Hashable, Sendable {
  case day(Int)
  case lastWorkingDay

  /// What the day strip lists, left to right: the 1st to the 31st, then "Last work day".
  static let all: [PaydayChoice] = (1...31).map(PaydayChoice.day) + [.lastWorkingDay]

  /// Paper's selection, and the strip's start before anything is chosen.
  static let standard = PaydayChoice.day(28)

  /// Where this choice sits on the strip.
  var index: Int {
    switch self {
    case .day(let d): min(max(d, 1), 31) - 1
    case .lastWorkingDay: 31
    }
  }

  /// The day it falls on in `month`: a day the month doesn't have is its last day (the
  /// 31st in September is the 30th), and the last working day is the month's last Monday
  /// to Friday (the UAE weekend is Saturday and Sunday).
  func date(in month: YearMonth) -> LocalDate {
    switch self {
    case .day(let d):
      return LocalDate(month.year, month.month, min(max(d, 1), month.days))
    case .lastWorkingDay:
      var date = LocalDate(month.year, month.month, month.days)
      while date.weekday >= 5 { date = date.adding(days: -1) }
      return date
    }
  }

  /// The next payday: this month's if it hasn't passed, else next month's.
  func next(onOrAfter today: LocalDate) -> LocalDate {
    let this = date(in: today.yearMonth)
    return this >= today ? this : date(in: today.yearMonth.next)
  }

  /// The day the income op carries (`income_source_set` has a day of the month, no "last
  /// working day"): the chosen day, or the day the next last working day falls on. It is
  /// read back as that day after a relaunch, which is the same date this month.
  func opDay(today: LocalDate) -> Int {
    switch self {
    case .day(let d): d
    case .lastWorkingDay: next(onOrAfter: today).day
    }
  }

  /// "28th", "Last work day".
  var spoken: String {
    switch self {
    case .day(let d): "\(d)\(Self.suffix(d))"
    case .lastWorkingDay: "Last work day"
    }
  }

  /// The ordinal ending Paper sets under the selected day ("th").
  static func suffix(_ d: Int) -> String {
    switch (d % 10, d % 100) {
    case (1, let t) where t != 11: "st"
    case (2, let t) where t != 12: "nd"
    case (3, let t) where t != 13: "rd"
    default: "th"
    }
  }

  /// The id of its tile (`income.payday.28`, `income.payday.last`).
  var identifier: String {
    switch self {
    case .day(let d): "income.payday.\(d)"
    case .lastWorkingDay: "income.payday.last"
    }
  }
}

/// Today in the ledger's clock (UTC+04:00 on every iPhone, spec 04 §15.5), for "Next one
/// Wed, 28 Oct" and "October plan ready". The live authoring reads the account runtime's
/// clock and the mock reads Maya's day; anything else falls back to the device's clock in
/// the ledger's zone.
@MainActor
protocol SetupClock: AnyObject {
  func today() -> LocalDate
}

enum LedgerToday {
  /// The ledger's fixed offset from UTC.
  static let offsetSeconds: TimeInterval = 4 * 3600

  /// The device's date in the ledger's zone.
  static func device(_ now: Date = Date()) -> LocalDate {
    LocalDate(ordinal: Int(((now.timeIntervalSince1970 + offsetSeconds) / 86_400).rounded(.down)))
  }

  static let weekdayNames = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]

  /// "Saturday 10 October", as the Lock Screen writes the date.
  static func lockScreenDate(_ d: LocalDate) -> String {
    "\(weekdayNames[d.weekday]) \(d.day) \(d.yearMonth.name)"
  }
}
