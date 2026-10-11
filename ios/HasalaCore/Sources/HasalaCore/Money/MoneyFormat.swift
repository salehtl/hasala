// Display and typed-entry money text: a port of the PWA's lib/minorMoney.ts
// (`formatMinor`, `formatMoney`, `signedMinor`, `parseMinorDraft`,
// `minorToDraft`) and lib/flowBars.ts `compactMinor`.
//
// Integer arithmetic only, no Number/Double, no `NumberFormatter` (locale
// grouping and rounding are exactly what this must not inherit). The reference
// pins two minor digits; `exponent` (spec 03c §1.4 `MinorExponent.v1`)
// generalizes it and defaults to 2. Refusal reasons are codes, not sentences:
// the copy belongs to the app's string catalogue.
import CoreText

public enum MoneyFormat {
  /// U+2212 MINUS SIGN, the reference's negative glyph.
  public static let minus = "\u{2212}"

  /// Grouped magnitude with a fixed fraction: `1,234.56`, `0.05`, `−1,234.56`.
  /// Zero is `0.00` however it was reached (there is no negative zero).
  public static func formatMinor(_ minor: Int64, exponent: Int = 2) -> String {
    let body = groupedBody(minor.magnitude, exponent: exponent)
    return minor < 0 ? minus + body : body
  }

  /// `AED 1,234.56`: the code, never a symbol; bare when the currency is unknown.
  public static func formatMoney(_ minor: Int64, currency: String, exponent: Int = 2) -> String {
    currency.isEmpty ? formatMinor(minor, exponent: exponent) : "\(currency) \(formatMinor(minor, exponent: exponent))"
  }

  public enum Direction: Sendable { case debit, credit, unparsed }
  public enum Flow: Sendable, Equatable { case `in`, out, none }

  /// A transaction amount with its direction on the glyph (`+5,000.00`,
  /// `−24.50`). An unparsed row prints an em dash, never a zero purchase.
  public static func signedMinor(_ direction: Direction, _ minor: Int64, exponent: Int = 2) -> (text: String, flow: Flow)
  {
    switch direction {
    case .unparsed: return ("\u{2014}", .none)
    case .credit: return ("+" + groupedBody(minor.magnitude, exponent: exponent), .in)
    case .debit: return (minus + groupedBody(minor.magnitude, exponent: exponent), .out)
    }
  }

  /// Signed compact major units for small labels: `+820`, `−140`, `+1.2k`,
  /// `+1.5m`; zero unsigned. Rounds half-up in integers (Int128, so values near
  /// Int64.max do not overflow). Assumes two minor digits, like the reference.
  public static func compactMinor(_ minor: Int64) -> String {
    let sign = minor > 0 ? "+" : (minor < 0 ? minus : "")
    let a = Int128(minor.magnitude)
    let body: String
    if a < 100_000 {
      body = String((a + 50) / 100)
    } else if a < 100_000_000 {
      body = tenths((a + 5_000) / 10_000) + "k"
    } else {
      body = tenths((a + 5_000_000) / 10_000_000) + "m"
    }
    return sign + body
  }

  /// A stored amount as the text a money field opens on: `12000.00`, never
  /// grouped (the inverse of ``parseMinorDraft(_:exponent:)``). `""` for `nil`.
  public static func minorToDraft(_ minor: Int64?, exponent: Int = 2) -> String {
    guard let minor else { return "" }
    let body = plainBody(minor.magnitude, exponent: exponent)
    return minor < 0 ? "-" + body : body
  }

  /// What a money field's text means.
  public enum Draft: Sendable, Equatable {
    /// Nothing typed (not zero: an empty total is "no total").
    case empty
    case amount(Int64)
    case refused(DraftRefusal)
  }

  public enum DraftRefusal: Sendable, Equatable {
    /// A leading `-` or `−`.
    case negative
    /// More fraction digits than the currency has.
    case tooPrecise
    /// Not digits with an optional point and fraction.
    case notAnAmount
    /// More than Int64 minor units (the reference's BigInt has no bound).
    case tooLarge
  }

  /// Major-unit text to minor units, exactly, or a refusal; never a rounded or
  /// clamped rewrite of what was typed. Trimmed with JavaScript's `trim` set.
  /// `12.` reads as `12.00` (a real mid-keystroke state); a leading zero is
  /// honoured (`007` is 7.00).
  public static func parseMinorDraft(_ text: String, exponent: Int = 2) -> Draft {
    let t = Array(text.trimming(.jsTrim).utf8)
    if t.isEmpty { return .empty }
    if t.first == 0x2d || t.starts(with: Array(minus.utf8)) { return .refused(.negative) }
    let point = t.firstIndex(of: 0x2e)
    let whole = t[..<(point ?? t.endIndex)]
    let fraction = point.map { t[(t.index(after: $0))...] } ?? []
    guard !whole.isEmpty, whole.allSatisfy(ASCII.isDigit), fraction.allSatisfy(ASCII.isDigit) else {
      return .refused(.notAnAmount)
    }
    if fraction.count > exponent {
      // The reference refuses 3+ digits as "too precise" only when the whole
      // text is digits.digits; that is every case reaching here.
      return .refused(.tooPrecise)
    }
    var v: Int128 = 0
    for d in whole {
      v = v * 10 + Int128(d - 0x30)
      if v > Int128(Int64.max) { return .refused(.tooLarge) }
    }
    for _ in 0..<exponent { v *= 10 }
    var frac: Int128 = 0
    for k in 0..<exponent {
      frac = frac * 10 + (k < fraction.count ? Int128(fraction[fraction.startIndex + k] - 0x30) : 0)
    }
    guard let out = Int64(exactly: v + frac) else { return .refused(.tooLarge) }
    return .amount(out)
  }

  // MARK: - Helpers

  private static func split(_ magnitude: UInt64, exponent: Int) -> (whole: String, fraction: String) {
    guard exponent > 0 else { return (String(magnitude), "") }
    var scale: UInt64 = 1
    for _ in 0..<exponent { scale *= 10 }
    let frac = String(magnitude % scale)
    return (String(magnitude / scale), String(repeating: "0", count: exponent - frac.utf8.count) + frac)
  }

  private static func groupedBody(_ magnitude: UInt64, exponent: Int) -> String {
    let (whole, fraction) = split(magnitude, exponent: exponent)
    let g = group(whole)
    return fraction.isEmpty ? g : "\(g).\(fraction)"
  }

  private static func plainBody(_ magnitude: UInt64, exponent: Int) -> String {
    let (whole, fraction) = split(magnitude, exponent: exponent)
    return fraction.isEmpty ? whole : "\(whole).\(fraction)"
  }

  /// Three digits at a time from the right, comma-separated.
  private static func group(_ digits: String) -> String {
    let u = Array(digits.utf8)
    var out = [UInt8]()
    for (i, d) in u.enumerated() {
      if i > 0 && (u.count - i) % 3 == 0 { out.append(0x2c) }
      out.append(d)
    }
    return String(decoding: out, as: UTF8.self)
  }

  /// One decimal place, a trailing `.0` dropped. Input is tenths.
  private static func tenths(_ t: Int128) -> String {
    let whole = t / 10
    let f = t % 10
    return f == 0 ? String(whole) : "\(whole).\(f)"
  }
}
