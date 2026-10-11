// Money as integer minor units (fils), never a float (spec 03c §1.3-§1.4).
//
// Storage and fold state are `Int64`. Every sum, product or ratio goes through
// `Int128` and comes back with an explicit overflow answer: Swift arithmetic
// traps, and a trap in the fold is a bug, never a path (spec 04 §2.4 R9). Money
// on the wire is a JSON STRING of decimal digits.
import HasalaText

public enum MoneyError: Error, Equatable, Sendable {
  /// Not the field's wire grammar.
  case grammar
  /// A value outside Int64 (`"<field>: exceeds int64"`, spec 03c §1.3).
  case exceedsInt64
  /// Out of the type's range (negative for `Minor`, zero for `PositiveMinor`,
  /// Int64.min for `SignedMinor`).
  case outOfRange
  /// An intermediate that does not fit back into Int64.
  case overflow
}

/// `Minor`: `^(0|[1-9][0-9]{0,18})$`, 0 ... Int64.max.
public struct Minor: Sendable, Hashable, Comparable, CustomStringConvertible {
  public let value: Int64

  public init?(_ value: Int64) {
    guard value >= 0 else { return nil }
    self.value = value
  }

  /// Parses the v4 wire form (leading zeros refused).
  public init(wire s: String) throws(MoneyError) {
    let v = try MoneyGrammar.parseV4(s, allowNegative: false)
    self.value = v
  }

  public var wire: String { String(value) }
  public var description: String { wire }
  public static func < (a: Minor, b: Minor) -> Bool { a.value < b.value }
}

/// `PositiveMinor`: a `Minor` greater than zero.
public struct PositiveMinor: Sendable, Hashable, Comparable, CustomStringConvertible {
  public let value: Int64

  public init?(_ value: Int64) {
    guard value > 0 else { return nil }
    self.value = value
  }

  public init(wire s: String) throws(MoneyError) {
    let v = try MoneyGrammar.parseV4(s, allowNegative: false)
    guard v > 0 else { throw .outOfRange }
    self.value = v
  }

  public var minor: Minor { Minor(value)! }
  public var wire: String { String(value) }
  public var description: String { wire }
  public static func < (a: PositiveMinor, b: PositiveMinor) -> Bool { a.value < b.value }
}

/// `SignedMinor`: `^(0|-?[1-9][0-9]{0,18})$`, -Int64.max ... Int64.max (never
/// Int64.min, so negation never overflows).
public struct SignedMinor: Sendable, Hashable, Comparable, CustomStringConvertible {
  public let value: Int64

  public init?(_ value: Int64) {
    guard value != .min else { return nil }
    self.value = value
  }

  public init(wire s: String) throws(MoneyError) {
    let v = try MoneyGrammar.parseV4(s, allowNegative: true)
    guard v != .min else { throw .outOfRange }
    self.value = v
  }

  public var wire: String { String(value) }
  public var description: String { wire }
  public static func < (a: SignedMinor, b: SignedMinor) -> Bool { a.value < b.value }
}

/// The money wire grammars, over bytes (no regex: a regex `$` can match before
/// a final newline, and `\d` can match Arabic-Indic digits).
public enum MoneyGrammar {
  /// v4 fields: `^(0|-?[1-9][0-9]{0,18})$` (sign only when `allowNegative`),
  /// value within Int64. `"007"`, `"-0"`, `"+1"` and `"1.0"` are grammar errors;
  /// `"9223372036854775808"` is ``MoneyError/exceedsInt64``.
  public static func parseV4(_ s: String, allowNegative: Bool) throws(MoneyError) -> Int64 {
    var u = Array(s.utf8)[...]
    var negative = false
    if allowNegative, u.first == 0x2d {
      negative = true
      u = u.dropFirst()
    }
    guard let first = u.first, u.allSatisfy(ASCII.isDigit) else { throw .grammar }
    if first == 0x30 {
      guard u.count == 1, !negative else { throw .grammar }
      return 0
    }
    guard u.count <= 19 else { throw .grammar }
    return try accumulate(u, negative: negative)
  }

  /// Fields inherited from v3 (`amount_minor`, `amount_home_minor`, split
  /// amounts): wire/op.ts `parseDecimal`'s `^[0-9]+$` (leading zeros allowed)
  /// plus the Int64 cap Go has, so v3 fixtures still pass (spec 03c §1.3).
  public static func parseV3(_ s: String) throws(MoneyError) -> Int64 {
    let u = Array(s.utf8)
    guard ASCII.isDecimal(s) else { throw .grammar }
    let significant = u.drop(while: { $0 == 0x30 })
    return significant.isEmpty ? 0 : try accumulate(significant, negative: false)
  }

  private static func accumulate(_ digits: ArraySlice<UInt8>, negative: Bool) throws(MoneyError) -> Int64 {
    guard digits.count <= 19 else { throw .exceedsInt64 }
    var v: Int128 = 0
    for d in digits { v = v * 10 + Int128(d - 0x30) }
    if negative { v = -v }
    guard let out = Int64(exactly: v) else { throw .exceedsInt64 }
    return out
  }
}

/// `CurrencyCode`: `^[A-Z]{3}$` (strictly upper case in v4-new fields; ISO 4217
/// membership is not checked).
public struct CurrencyCode: Sendable, Hashable, CustomStringConvertible {
  public let code: String

  public init?(_ s: String) {
    let u = Array(s.utf8)
    guard u.count == 3, u.allSatisfy(ASCII.isUpper) else { return nil }
    code = s
  }

  public var description: String { code }

  public static let aed = CurrencyCode("AED")!
}

/// Minor-unit exponents for DISPLAY and parsing of typed amounts only, never
/// the fold (spec 03c §1.4). Versioned: a change is an app update, not an op.
public enum MinorExponent {
  /// Table v1: 3 for BHD IQD JOD KWD LYD OMR TND; 0 for BIF CLP DJF GNF ISK
  /// JPY KMF KRW PYG RWF UGX UYI VND VUV XAF XOF XPF; 2 for every other code.
  public static func v1(_ currency: CurrencyCode) -> Int {
    switch currency.code {
    case "BHD", "IQD", "JOD", "KWD", "LYD", "OMR", "TND": 3
    case "BIF", "CLP", "DJF", "GNF", "ISK", "JPY", "KMF", "KRW", "PYG", "RWF", "UGX", "UYI", "VND", "VUV", "XAF",
      "XOF", "XPF":
      0
    default: 2
    }
  }
}
