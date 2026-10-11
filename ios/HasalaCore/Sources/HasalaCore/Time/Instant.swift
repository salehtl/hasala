// RFC 3339 instants exactly as the v3 wire reads them (wire/op.ts
// `parseInstantMs` and `canonicalTime`, mirroring Go's `parseWireTime` and
// `oplog.canonicalTime`; spec 03c §1.5 `Instant`).
//
//   - Shape: `YYYY-MM-DDTHH:MM:SS[.fraction](Z|±HH:MM)`, four year digits,
//     UPPER-case `T` and `Z` only (Go refuses `t`/`z`).
//   - Ranges checked explicitly: month 1-12, a real day of that month (no
//     roll-over: `02-30` is refused, not March 2), hour ≤ 23 (no `24:00`), minute
//     and second ≤ 59 (no leap second), offset hour ≤ 23 and minute ≤ 59.
//   - Fraction digits past the third are TRUNCATED (Go's
//     `Truncate(time.Millisecond)`), never rounded.
//   - Go's zero time `0001-01-01T00:00:00Z` is refused.
//
// Pinned by conformance/op/manifest.json `authored_at_cases` (15) and
// `authored_at_rejects` (23).

public enum InstantError: Error, Equatable, Sendable {
  /// Not the RFC 3339 shape.
  case notRFC3339
  /// A component out of range (named: "month", "day", "hour", "minute",
  /// "second" or "offset").
  case outOfRange(String)
  /// Go's zero time.
  case zeroTime
  /// The UTC form leaves the four-digit-year range the wire carries (a legal
  /// `9999-12-31T23:59:59-23:59` is year 10000 in UTC).
  case outsideFourDigitYears
}

public enum Instant {
  /// Go's zero `time.Time` in epoch milliseconds.
  public static let goZeroTimeMs: Int64 = -62_135_596_800_000

  /// Epoch milliseconds of a wire timestamp.
  public static func parseMs(_ s: String) throws(InstantError) -> Int64 {
    let u = Array(s.utf8)
    func num(_ a: Int, _ n: Int) throws(InstantError) -> Int64 {
      guard a + n <= u.count else { throw .notRFC3339 }
      var v: Int64 = 0
      for i in a..<(a + n) {
        guard u[i] >= 0x30, u[i] <= 0x39 else { throw .notRFC3339 }
        v = v * 10 + Int64(u[i] - 0x30)
      }
      return v
    }
    func expect(_ i: Int, _ c: UInt8) throws(InstantError) {
      guard i < u.count, u[i] == c else { throw .notRFC3339 }
    }
    let y = try num(0, 4)
    try expect(4, 0x2d)
    let mo = try num(5, 2)
    try expect(7, 0x2d)
    let d = try num(8, 2)
    try expect(10, 0x54)  // T
    let h = try num(11, 2)
    try expect(13, 0x3a)
    let mi = try num(14, 2)
    try expect(16, 0x3a)
    let sec = try num(17, 2)
    var i = 19
    var ms: Int64 = 0
    if i < u.count, u[i] == 0x2e {
      i += 1
      let start = i
      while i < u.count, u[i] >= 0x30, u[i] <= 0x39 { i += 1 }
      guard i > start else { throw .notRFC3339 }
      // First three digits, right-padded: truncation by construction.
      for k in 0..<3 {
        ms = ms * 10 + (start + k < i ? Int64(u[start + k] - 0x30) : 0)
      }
    }
    var offsetMinutes: Int64 = 0
    guard i < u.count else { throw .notRFC3339 }
    if u[i] == 0x5a {  // Z
      i += 1
    } else if u[i] == 0x2b || u[i] == 0x2d {
      let negative = u[i] == 0x2d
      let oh = try num(i + 1, 2)
      try expect(i + 3, 0x3a)
      let om = try num(i + 4, 2)
      i += 6
      if oh > 23 || om > 59 { throw .outOfRange("offset") }
      offsetMinutes = (negative ? -1 : 1) * (oh * 60 + om)
    } else {
      throw .notRFC3339
    }
    guard i == u.count else { throw .notRFC3339 }

    if mo < 1 || mo > 12 { throw .outOfRange("month") }
    if d < 1 || d > Int64(Civil.daysInMonth(year: y, month: Int(mo))) { throw .outOfRange("day") }
    if h > 23 { throw .outOfRange("hour") }
    if mi > 59 { throw .outOfRange("minute") }
    if sec > 59 { throw .outOfRange("second") }

    let days = Civil.daysFromCivil(year: y, month: Int(mo), day: Int(d))
    let epoch = days * Civil.msPerDay + ((h * 60 + mi) * 60 + sec) * 1000 + ms - offsetMinutes * 60_000
    if epoch == goZeroTimeMs { throw .zeroTime }
    return epoch
  }

  /// `YYYY-MM-DDTHH:MM:SS.sssZ` of an epoch-millisecond instant, as
  /// `Date.prototype.toISOString`, for years 0000-9999; `nil` outside them.
  public static func iso(_ epochMs: Int64) -> String? {
    let days = Civil.floorDiv(epochMs, Civil.msPerDay)
    let (y, m, d) = Civil.civilFromDays(days)
    guard y >= 0, y <= 9999 else { return nil }
    let rem = epochMs - days * Civil.msPerDay
    let h = Int(rem / 3_600_000)
    let mi = Int(rem / 60_000 % 60)
    let s = Int(rem / 1000 % 60)
    let ms = Int(rem % 1000)
    return
      "\(Civil.yearText(y))-\(Civil.pad2(m))-\(Civil.pad2(d))T\(Civil.pad2(h)):\(Civil.pad2(mi)):\(Civil.pad2(s)).\(Civil.pad(ms, 3))Z"
  }

  /// The one form both executors read identically: UTC, milliseconds, always
  /// `.sss`. Refuses an input whose UTC form leaves the four-digit years
  /// (canonicalization is closed over the wire grammar).
  public static func canonical(_ s: String) throws(InstantError) -> String {
    guard let out = iso(try parseMs(s)) else { throw .outsideFourDigitYears }
    return out
  }
}

/// wire/op.ts `parseInstantMs`.
public func parseInstantMs(_ s: String) throws(InstantError) -> Int64 { try Instant.parseMs(s) }

/// wire/op.ts `canonicalTime`.
public func canonicalTime(_ s: String) throws(InstantError) -> String { try Instant.canonical(s) }

/// replay/state.ts `utcDay`.
public func utcDay(_ epochMs: Int64) -> String { Civil.utcDay(epochMs) }
