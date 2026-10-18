// Money for the UI layer: integer minor units (fils), never a float.
//
// This is a stand-in until HasalaCore's CoreMoney exists (spec 04 §2.5); it holds
// only what the screens need to *show* an amount. Formatting is integer-only and
// always uses Western digits and comma grouping (spec 04 §14.9).

/// An amount in minor units of a currency (AED: 100 fils to the dirham).
public struct Money: Sendable, Hashable, Codable {
  public var minor: Int64
  public var currency: String

  public init(minor: Int64, currency: String = "AED") {
    self.minor = minor
    self.currency = currency
  }

  /// `Money.aed(7_417_55)`: the literal is written in fils.
  public static func aed(_ minor: Int64) -> Money { Money(minor: minor, currency: "AED") }

  public var isZero: Bool { minor == 0 }
  public var isNegative: Bool { minor < 0 }
}

/// How many fraction digits an amount is shown with.
public enum MoneyStyle: String, Sendable, Hashable, Codable {
  /// Always two decimals: `2,282.45`, `0.00`.
  case exact
  /// Whole units when there are no fils, two decimals otherwise: `12,350`, `9,040.80`.
  case compact
  /// Rounded half away from zero to whole units: `337`.
  case rounded
}

public enum MoneyFormat {
  /// The glyph shown in place of every hidden figure (Paper "Home · Amounts hidden").
  public static let hiddenGlyph = "•"

  /// Formats the absolute value of `minor`; the sign is the caller's job (`MoneyText`).
  public static func string(_ minor: Int64, style: MoneyStyle = .exact) -> String {
    let magnitude = minor.magnitude
    switch style {
    case .exact:
      return grouped(magnitude / 100) + "." + twoDigits(magnitude % 100)
    case .compact:
      let fils = magnitude % 100
      return fils == 0 ? grouped(magnitude / 100) : grouped(magnitude / 100) + "." + twoDigits(fils)
    case .rounded:
      return grouped((magnitude + 50) / 100)
    }
  }

  /// A run of hidden-figure glyphs, as Paper draws them (four in tiles and rows).
  public static func hidden(count: Int = 4) -> String {
    String(repeating: hiddenGlyph, count: max(1, count))
  }

  /// `1234567` -> `1,234,567`.
  public static func grouped(_ value: UInt64) -> String {
    let digits = String(value)
    var out = ""
    out.reserveCapacity(digits.count + digits.count / 3)
    for (i, ch) in digits.enumerated() {
      if i > 0, (digits.count - i) % 3 == 0 { out.append(",") }
      out.append(ch)
    }
    return out
  }

  private static func twoDigits(_ value: UInt64) -> String {
    value < 10 ? "0" + String(value) : String(value)
  }
}

/// Parts-per-thousand, for bars and paces without floating point in the model.
public struct Permille: Sendable, Hashable, Comparable, Codable {
  public var value: Int

  public init(_ value: Int) { self.value = value }

  /// `part / whole` in permille, rounded down; zero when `whole` is zero.
  public static func ratio(_ part: Int64, of whole: Int64) -> Permille {
    guard whole > 0 else { return Permille(0) }
    return Permille(Int(part.clamped(to: 0...Int64.max) * 1000 / whole))
  }

  public static func < (lhs: Permille, rhs: Permille) -> Bool { lhs.value < rhs.value }

  /// The fraction for drawing only (geometry may use a float; money never does).
  public var fraction: Double { Double(value) / 1000 }
}

extension Comparable {
  func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}

public extension MoneyFormat {
  /// Parses a typed amount ("297", "45.15", "1,800.5") into minor units without a float
  /// (spec 04 §14.6 `parseMinorDraft`). Nil for anything else: letters, a second point,
  /// more than two decimals, a sign, or nothing at all.
  static func parseMinor(_ draft: String) -> Int64? {
    var whole: Int64 = 0
    var fils: Int64 = 0
    var decimals = -1
    var digits = 0
    for ch in draft where ch != "," && ch != " " {
      if ch == "." {
        guard decimals < 0 else { return nil }
        decimals = 0
        continue
      }
      guard let d = ch.wholeNumberValue, ch.isASCII else { return nil }
      digits += 1
      if decimals >= 0 {
        decimals += 1
        guard decimals <= 2 else { return nil }
        fils = fils * 10 + Int64(d)
      } else {
        guard whole < 100_000_000_000 else { return nil }
        whole = whole * 10 + Int64(d)
      }
    }
    guard digits > 0 else { return nil }
    if decimals == 1 { fils *= 10 }
    return whole * 100 + fils
  }

  /// The editable form of an amount: "297.00" (no grouping), for a field's first value.
  static func draft(_ minor: Int64) -> String {
    let m = minor.magnitude
    return "\(m / 100)." + (m % 100 < 10 ? "0" : "") + "\(m % 100)"
  }
}
