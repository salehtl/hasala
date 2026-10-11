// Civil time for the screens: a wall-clock date and time in the ledger's fixed local
// clock (UTC+04:00 on every device, spec 04 §15.5). No Foundation calendars and no
// device zone: two iPhones put a transaction on the same day.
//
// TODO(spec 04 §2.5): take CoreTime's LocalDate/YearMonth from HasalaCore once
// HasalaModels depends on it; these mirror only what the screens need.

/// A calendar month, e.g. October 2026.
public struct YearMonth: Sendable, Hashable, Comparable, Codable, CustomStringConvertible {
  public var year: Int
  public var month: Int

  public init(_ year: Int, _ month: Int) {
    self.year = year
    self.month = month
  }

  public static func < (a: YearMonth, b: YearMonth) -> Bool {
    (a.year, a.month) < (b.year, b.month)
  }

  public var days: Int { CivilCalendar.daysIn(year: year, month: month) }

  /// "October".
  public var name: String { CivilCalendar.monthNames[month - 1] }
  /// "Oct".
  public var shortName: String { CivilCalendar.monthShortNames[month - 1] }
  /// "October 2026".
  public var title: String { "\(name) \(year)" }
  /// `2026-10`.
  public var description: String { "\(year)-\(month < 10 ? "0" : "")\(month)" }

  public var previous: YearMonth { month == 1 ? YearMonth(year - 1, 12) : YearMonth(year, month - 1) }
  public var next: YearMonth { month == 12 ? YearMonth(year + 1, 1) : YearMonth(year, month + 1) }
}

/// A local date in the ledger clock.
public struct LocalDate: Sendable, Hashable, Comparable, Codable {
  public var year: Int
  public var month: Int
  public var day: Int

  public init(_ year: Int, _ month: Int, _ day: Int) {
    self.year = year
    self.month = month
    self.day = day
  }

  public var yearMonth: YearMonth { YearMonth(year, month) }

  /// Days since 1970-01-01 (proleptic Gregorian).
  public var ordinal: Int { CivilCalendar.daysFromCivil(year, month, day) }

  public init(ordinal: Int) {
    let (y, m, d) = CivilCalendar.civilFromDays(ordinal)
    self.init(y, m, d)
  }

  public func adding(days: Int) -> LocalDate { LocalDate(ordinal: ordinal + days) }

  public func days(until other: LocalDate) -> Int { other.ordinal - ordinal }

  /// 0 = Monday … 6 = Sunday (weeks start on Monday, spec 04 §15.5).
  public var weekday: Int { ((ordinal % 7) + 7 + 3) % 7 }

  /// "Fri".
  public var weekdayShort: String { CivilCalendar.weekdayShortNames[weekday] }

  /// "Fri 9 Oct".
  public var short: String { "\(weekdayShort) \(day) \(CivilCalendar.monthShortNames[month - 1])" }

  /// "9 Oct".
  public var dayMonth: String { "\(day) \(CivilCalendar.monthShortNames[month - 1])" }

  public static func < (a: LocalDate, b: LocalDate) -> Bool { a.ordinal < b.ordinal }
}

/// A local date and minute in the ledger clock.
public struct LocalDateTime: Sendable, Hashable, Comparable, Codable {
  public var date: LocalDate
  public var hour: Int
  public var minute: Int

  public init(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) {
    self.date = LocalDate(year, month, day)
    self.hour = hour
    self.minute = minute
  }

  public init(date: LocalDate, hour: Int, minute: Int) {
    self.date = date
    self.hour = hour
    self.minute = minute
  }

  /// "13:20".
  public var time: String {
    (hour < 10 ? "0" : "") + "\(hour):" + (minute < 10 ? "0" : "") + "\(minute)"
  }

  public static func < (a: LocalDateTime, b: LocalDateTime) -> Bool {
    (a.date.ordinal, a.hour, a.minute) < (b.date.ordinal, b.hour, b.minute)
  }
}

public enum CivilCalendar {
  public static let monthNames = [
    "January", "February", "March", "April", "May", "June",
    "July", "August", "September", "October", "November", "December",
  ]
  public static let monthShortNames = [
    "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
  ]
  public static let weekdayShortNames = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

  public static func isLeap(_ y: Int) -> Bool { (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 }

  public static func daysIn(year: Int, month: Int) -> Int {
    switch month {
    case 2: isLeap(year) ? 29 : 28
    case 4, 6, 9, 11: 30
    default: 31
    }
  }

  /// Howard Hinnant's days_from_civil.
  public static func daysFromCivil(_ y0: Int, _ m: Int, _ d: Int) -> Int {
    let y = m <= 2 ? y0 - 1 : y0
    let era = (y >= 0 ? y : y - 399) / 400
    let yoe = y - era * 400
    let mp = (m + 9) % 12
    let doy = (153 * mp + 2) / 5 + d - 1
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
    return era * 146_097 + doe - 719_468
  }

  public static func civilFromDays(_ z0: Int) -> (Int, Int, Int) {
    let z = z0 + 719_468
    let era = (z >= 0 ? z : z - 146_096) / 146_097
    let doe = z - era * 146_097
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
    let y = yoe + era * 400
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
    let mp = (5 * doy + 2) / 153
    let d = doy - (153 * mp + 2) / 5 + 1
    let m = mp < 10 ? mp + 3 : mp - 9
    return (m <= 2 ? y + 1 : y, m, d)
  }
}

extension String {
  /// Without leading and trailing spaces and tabs (no Foundation in this module).
  public var trimmedSpaces: String {
    let isSpace: (Character) -> Bool = { $0 == " " || $0 == "\t" || $0 == "\n" }
    return String(drop(while: isSpace).reversed().drop(while: isSpace).reversed())
  }
}
