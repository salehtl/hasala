// Integer civil-date arithmetic (proleptic Gregorian, no Foundation).
//
// Foundation's Gregorian `Calendar` switches to the Julian calendar before
// 1582-10-15, and `DateFormatter`/`ISO8601DateFormatter` carry locale, zone and
// rounding behaviour. Every date computation that reaches the wire or the fold
// is this integer arithmetic instead (Howard Hinnant's `days_from_civil` and
// `civil_from_days`, the algorithm of replay/state.ts `utcDay`).

public enum Civil {
  public static let msPerDay: Int64 = 86_400_000

  public static func isLeapYear(_ y: Int64) -> Bool {
    y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)
  }

  /// Days in `month` (1-12) of year `y`; Go's `daysIn`.
  public static func daysInMonth(year y: Int64, month m: Int) -> Int {
    switch m {
    case 2: isLeapYear(y) ? 29 : 28
    case 4, 6, 9, 11: 30
    default: 31
    }
  }

  /// Days since 1970-01-01 of the civil date `y-m-d` (month 1-12). The raw
  /// algorithm: defined for |year| < 2^53, which every caller in the core
  /// bounds first (`CivilDate` holds 0...9999, the wire parser four digits).
  public static func daysFromCivil(year: Int64, month: Int, day: Int) -> Int64 {
    let y = month <= 2 ? year - 1 : year
    let era = (y >= 0 ? y : y - 399) / 400
    let yoe = y - era * 400  // 0...399
    let mp = Int64((month + 9) % 12)  // March = 0
    let doy = (153 * mp + 2) / 5 + Int64(day) - 1  // 0...365
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy  // 0...146096
    return era * 146_097 + doe - 719_468
  }

  /// The civil date `days` after 1970-01-01. The raw algorithm: defined for
  /// |days| < 2^62 (every `floorDiv(ms, msPerDay)` of an Int64 instant is far
  /// inside); `CivilDate(daysSinceEpoch:)` bounds its input before calling it.
  public static func civilFromDays(_ days: Int64) -> (year: Int64, month: Int, day: Int) {
    let z = days + 719_468
    let era = (z >= 0 ? z : z - 146_096) / 146_097
    let doe = z - era * 146_097  // 0...146096
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365  // 0...399
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)  // 0...365
    let mp = (5 * doy + 2) / 153  // 0...11
    let day = Int(doy - (153 * mp + 2) / 5 + 1)
    let month = Int(mp < 10 ? mp + 3 : mp - 9)
    return (yoe + era * 400 + (month <= 2 ? 1 : 0), month, day)
  }

  /// `floor(a / b)` for `b > 0`.
  public static func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
    let q = a / b
    return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
  }

  /// UTC day of an epoch-millisecond instant as `YYYY-MM-DD` (replay/state.ts
  /// `utcDay`; the v3 fingerprint keeps it, spec 03c §1.5). Years outside
  /// 0000-9999 use the ISO expanded form `±YYYYYY`.
  public static func utcDay(_ epochMs: Int64) -> String {
    let (y, m, d) = civilFromDays(floorDiv(epochMs, msPerDay))
    return "\(yearText(y))-\(pad2(m))-\(pad2(d))"
  }

  static func yearText(_ y: Int64) -> String {
    if y >= 0 && y <= 9999 { return pad(Int(y), 4) }
    let digits = pad(Int(y.magnitude), 6)
    return (y < 0 ? "-" : "+") + digits
  }

  static func pad2(_ n: Int) -> String { pad(n, 2) }

  public static func pad(_ n: Int, _ width: Int) -> String {
    let s = String(n)
    return s.utf8.count >= width ? s : String(repeating: "0", count: width - s.utf8.count) + s
  }
}
