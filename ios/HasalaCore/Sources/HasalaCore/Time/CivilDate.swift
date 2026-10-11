// `CivilDate` (= 03a/03b `LocalDay`), `CivilMonth` (= 03a `YearMonth`) and the
// fixed local clock (spec 03c §1.5).
//
// The local clock is ONE fixed offset, UTC+04:00 (Asia/Dubai, no DST), on every
// device whatever its time zone: two devices in different zones must put a
// transaction in the same budget month. `today` is read once per query or
// render, and never inside the fold or the projection.
import Foundation

/// A calendar day with no zone.
public struct CivilDate: Sendable, Hashable, Comparable, CustomStringConvertible {
  public let year: Int
  public let month: Int
  public let day: Int

  /// A real proleptic-Gregorian date in years 0...9999; `nil` otherwise.
  public init?(year: Int, month: Int, day: Int) {
    guard (0...9999).contains(year), (1...12).contains(month),
      day >= 1, day <= Civil.daysInMonth(year: Int64(year), month: month)
    else { return nil }
    self.year = year
    self.month = month
    self.day = day
  }

  /// The wire grammar: `^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$`, a real
  /// date, and year 2000-2099. `nil` otherwise.
  public init?(wire s: String) {
    let u = Array(s.utf8)
    guard u.count == 10, u[4] == 0x2d, u[7] == 0x2d,
      let y = CivilDate.digits(u[0..<4]), let m = CivilDate.digits(u[5..<7]), let d = CivilDate.digits(u[8..<10]),
      (2000...2099).contains(y)
    else { return nil }
    self.init(year: y, month: m, day: d)
  }

  /// The civil date `days` after 1970-01-01, when it lies in years 0...9999.
  public init?(daysSinceEpoch days: Int64) {
    let (y, m, d) = Civil.civilFromDays(days)
    guard (0...9999).contains(y) else { return nil }
    self.init(year: Int(y), month: m, day: d)
  }

  /// Days since 1970-01-01.
  public var daysSinceEpoch: Int64 { Civil.daysFromCivil(year: Int64(year), month: month, day: day) }

  /// `YYYY-MM-DD`.
  public var wire: String { "\(Civil.pad(year, 4))-\(Civil.pad2(month))-\(Civil.pad2(day))" }
  public var description: String { wire }

  public var yearMonth: CivilMonth { CivilMonth(validYear: year, month: month) }

  /// ISO weekday, Monday = 1 ... Sunday = 7 (the UAE week is Monday-first).
  public var isoWeekday: Int {
    // 1970-01-01 was a Thursday (4).
    let r = (daysSinceEpoch + 3) % 7
    return Int(r < 0 ? r + 7 : r) + 1
  }

  /// The date `n` days later (earlier for negative `n`); `nil` past year 9999 or
  /// before year 0.
  public func adding(days n: Int) -> CivilDate? { CivilDate(daysSinceEpoch: daysSinceEpoch + Int64(n)) }

  public static func < (a: CivilDate, b: CivilDate) -> Bool { a.daysSinceEpoch < b.daysSinceEpoch }

  static func digits(_ s: ArraySlice<UInt8>) -> Int? {
    var v = 0
    for c in s {
      guard c >= 0x30, c <= 0x39 else { return nil }
      v = v * 10 + Int(c - 0x30)
    }
    return v
  }
}

/// A calendar month.
public struct CivilMonth: Sendable, Hashable, Comparable, CustomStringConvertible {
  public let year: Int
  public let month: Int

  /// Years 0...9999, month 1...12; `nil` otherwise.
  public init?(year: Int, month: Int) {
    guard (0...9999).contains(year), (1...12).contains(month) else { return nil }
    self.init(validYear: year, month: month)
  }

  init(validYear: Int, month: Int) {
    year = validYear
    self.month = month
  }

  /// The wire grammar `^[0-9]{4}-(0[1-9]|1[0-2])$`, year 2000-2099.
  public init?(wire s: String) {
    let u = Array(s.utf8)
    guard u.count == 7, u[4] == 0x2d, let y = CivilDate.digits(u[0..<4]), let m = CivilDate.digits(u[5..<7]),
      (2000...2099).contains(y)
    else { return nil }
    self.init(year: y, month: m)
  }

  /// The month `index` (`year * 12 + month - 1`) names, in years 0...9999.
  public init?(index: Int) {
    let y = index >= 0 ? index / 12 : (index - 11) / 12
    self.init(year: y, month: index - y * 12 + 1)
  }

  /// `year * 12 + (month - 1)` (spec 03a `YearMonth.index`).
  public var index: Int { year * 12 + month - 1 }

  public var daysInMonth: Int { Civil.daysInMonth(year: Int64(year), month: month) }
  public var firstDay: CivilDate { CivilDate(year: year, month: month, day: 1)! }
  public var lastDay: CivilDate { CivilDate(year: year, month: month, day: daysInMonth)! }

  /// `YYYY-MM`.
  public var wire: String { "\(Civil.pad(year, 4))-\(Civil.pad2(month))" }
  public var description: String { wire }

  public func adding(months n: Int) -> CivilMonth? { CivilMonth(index: index + n) }

  public static func < (a: CivilMonth, b: CivilMonth) -> Bool { a.index < b.index }
}

/// Whole months from `a` to `b` (`b.index - a.index`; negative when `b` is earlier).
public func monthsBetween(_ a: CivilMonth, _ b: CivilMonth) -> Int { b.index - a.index }

/// The fixed local clock: UTC+04:00 on every device (spec 03c §1.5).
public enum LocalClock {
  public static let offsetMinutes: Int64 = 240
  public static let offsetMs: Int64 = offsetMinutes * 60_000

  /// The local civil date of an instant: `civilFromDays(floor((ms + 4 h) / 1 day))`.
  /// `nil` only outside years 0...9999.
  public static func localDate(_ epochMs: Int64) -> CivilDate? {
    CivilDate(daysSinceEpoch: Civil.floorDiv(epochMs + offsetMs, Civil.msPerDay))
  }

  /// The local month of an instant.
  public static func localMonth(_ epochMs: Int64) -> CivilMonth? { localDate(epochMs)?.yearMonth }

  /// The instant of local midnight starting `date` (that day's 00:00 at +04:00,
  /// i.e. 20:00Z the day before).
  public static func startOfDay(_ date: CivilDate) -> Int64 {
    date.daysSinceEpoch * Civil.msPerDay - offsetMs
  }
}

/// The wall clock, behind a protocol so nothing above reads it directly
/// (spec 04 §2.4 R1, R8). Tests use a fixed clock (CoreTestSupport).
public protocol Clock: Sendable {
  /// Milliseconds since the Unix epoch.
  func nowMs() -> Int64
}

/// The system clock. The one place outside CorePrimitives allowed `Date()`.
public struct SystemClock: Clock {
  public init() {}
  public func nowMs() -> Int64 {
    // lint-allow: Date CoreTime's clock adapter is the sanctioned reader of the wall clock (R8).
    Int64((Date().timeIntervalSince1970 * 1000).rounded(.down))
  }
}
