// Checked money arithmetic with Int128 intermediates (spec 03c §1.3; spec 04
// §2.4 R9). Nothing here traps: every result that might not fit Int64 is an
// optional or a thrown `MoneyError.overflow`.

public enum MoneyMath {
  /// `a + b`, or `nil` when the sum leaves Int64.
  public static func add(_ a: Int64, _ b: Int64) -> Int64? {
    let (r, o) = a.addingReportingOverflow(b)
    return o ? nil : r
  }

  /// `a - b`, or `nil` when the difference leaves Int64.
  public static func subtract(_ a: Int64, _ b: Int64) -> Int64? {
    let (r, o) = a.subtractingReportingOverflow(b)
    return o ? nil : r
  }

  /// `a × b`, or `nil` when the product leaves Int64.
  public static func multiply(_ a: Int64, _ b: Int64) -> Int64? {
    let (r, o) = a.multipliedReportingOverflow(by: b)
    return o ? nil : r
  }

  /// The exact sum in Int128 (cannot overflow for fewer than 2^64 terms).
  public static func wideSum(_ values: some Sequence<Int64>) -> Int128 {
    values.reduce(Int128(0)) { $0 + Int128($1) }
  }

  /// The sum, or `nil` when the TOTAL leaves Int64 (intermediate partial sums
  /// may; only the result has to fit, as at a storage boundary).
  public static func sum(_ values: some Sequence<Int64>) -> Int64? { Int64(exactly: wideSum(values)) }

  /// `floor(a / b)` in Int128, `b != 0`.
  public static func floorDiv(_ a: Int128, _ b: Int128) -> Int128 {
    precondition(b != 0, "floorDiv by zero")
    let q = a / b
    return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
  }

  /// Apportions a home-currency total `home` across parts by cumulative floor
  /// (spec 03c §1.3; v3 `projection.ts:writeSplits`): with native total
  /// `N = Σ parts` and cumulative `c_i`, `home_i = floor(H·c_i / N) -
  /// floor(H·c_{i-1} / N)`. The shares sum to `home` exactly, the last part
  /// absorbing the remainder. `nil` when `home` is `nil` or `N ≤ 0`, and also
  /// when an intermediate leaves Int128 or a share leaves Int64 (only possible
  /// when the parts are not a split of anything Int64 can hold; the caller
  /// treats it as `money_overflow`, spec 03c §1.3).
  public static func apportion(home: Int64?, parts: [Int64]) -> [Int64]? {
    guard let home else { return nil }
    let n = wideSum(parts)
    guard n > 0 else { return nil }
    let h = Int128(home)
    var cumulative: Int128 = 0
    var previous: Int128 = 0
    var out: [Int64] = []
    out.reserveCapacity(parts.count)
    for p in parts {
      cumulative += Int128(p)
      let (product, overflow) = h.multipliedReportingOverflow(by: cumulative)
      if overflow { return nil }
      let here = floorDiv(product, n)
      // |share| ≤ |H·p/N| + 1 and |p| ≤ N·k for sane inputs; a share that does
      // not fit Int64 means the parts were not a split of N.
      guard let share = Int64(exactly: here - previous) else { return nil }
      out.append(share)
      previous = here
    }
    return out
  }

  /// Percent change from `b` to `a`, `100·(a − b)/b` rounded half away from
  /// zero (spec 03c §1.3 `pctChange`): `nil` when `b == 0`; otherwise with
  /// `d = a − b`, `q = (|d|·200 + |b|) / (2·|b|)` and the result
  /// `sign(d)·sign(b)·q`.
  ///
  /// For `b > 0` this is the spec's formula exactly. The spec writes it for a
  /// positive base only; for `b < 0` (signed spend totals) its literal text
  /// gives the sign of `d/b` with truncating rather than half-up rounding
  /// (`pctChange(-5, -10)` = −49.5 → −49). This keeps the sign of `d/b` and
  /// rounds the same way as for a positive base: `pctChange(-5, -10) == -50`,
  /// `pctChange(-15, -10) == 50`. PENDING the 03c owner's confirmation.
  ///
  /// `nil` also when the result does not fit Int64 (e.g. `pctChange(.max, 1)`,
  /// about 9.2e20 percent). The Int128 intermediates cannot overflow:
  /// `|d| < 2^64`, so `|d|·200 + |b| < 2^73`.
  public static func pctChange(_ a: Int64, _ b: Int64) -> Int64? {
    guard b != 0 else { return nil }
    let d = Int128(a) - Int128(b)
    let base = Int128(b).magnitude
    let q = (d.magnitude * 200 + base) / (2 * base)
    guard let qq = Int128(exactly: q) else { return nil }
    let negative = (d < 0) != (b < 0)
    return Int64(exactly: negative ? -qq : qq)
  }
}
