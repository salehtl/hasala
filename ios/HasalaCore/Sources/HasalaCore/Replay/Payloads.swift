// Payload readers shared by every op family (replay.ts "Payloads", ported).
//
// Money is a decimal STRING on the wire and `Int64` here. Every failure throws
// `PayloadError`, which the fold records as an `invalid_payload` anomaly: an op
// whose payload cannot be read is a data condition, never a hard stop.
//
// `nil` from a `JSONObject` subscript is JavaScript's `undefined` (an absent
// key); `.null` is `null`. The v3 readers keep the oracle's distinctions
// exactly, so v1-v3 logs fold to the oracle's state.
import CoreJSON
import CoreMoney
import CoreTime
import CoreWire
import HasalaText

/// A payload the fold cannot read as its type requires. Its message becomes the
/// anomaly detail (Swift-canonical, A-21).
public struct PayloadError: Error, Sendable, Equatable {
  public let message: String
  public init(_ message: String) { self.message = message }
}

enum P {
  static func object(_ op: Op) throws(PayloadError) -> JSONObject {
    guard let o = op.payload.objectValue else { throw PayloadError("payload is not a JSON object") }
    return o
  }

  static func object(_ v: JSONValue?, _ what: String) throws(PayloadError) -> JSONObject {
    guard let o = v?.objectValue else { throw PayloadError("\(what) must be an object, got \(showValue(v))") }
    return o
  }

  // MARK: v3 readers (oracle semantics)

  /// replay.ts `parseMoney`: a decimal-integer string (`^[0-9]+$`), capped at
  /// Int64 (03c §1.3: v3 fields keep v3's grammar plus the Int64 cap).
  static func money(_ v: JSONValue?, _ what: String) throws(PayloadError) -> Int64 {
    guard let s = v?.stringValue else {
      throw PayloadError("\(what) must be a decimal-integer string, got \(showValue(v))")
    }
    do {
      return try MoneyGrammar.parseV3(s)
    } catch {
      switch error {
      case .exceedsInt64: throw PayloadError("\(what): exceeds int64")
      default: throw PayloadError("\(what): want a decimal-integer string, got \(showValue(v))")
      }
    }
  }

  static func positiveMoney(_ v: JSONValue?, _ what: String) throws(PayloadError) -> Int64 {
    let n = try money(v, what)
    if n <= 0 { throw PayloadError("\(what) is \(n), and amounts are always positive") }
    return n
  }

  /// replay.ts `currencyOf`: three ASCII letters, upper-cased at v≤3. At v4 the
  /// fold never normalizes (03c §1, §1.4): only `^[A-Z]{3}$` is accepted.
  static func currency(_ p: JSONObject, _ key: String, v: Int) throws(PayloadError) -> String {
    let raw = p[key]
    guard let s = raw?.stringValue else {
      throw PayloadError("\(key) must be a three-letter currency code, got \(showValue(raw))")
    }
    let u = Array(s.utf8)
    if v >= 4 {
      guard u.count == 3, u.allSatisfy(ASCII.isUpper) else {
        throw PayloadError("\(key) must be a CurrencyCode, got \(showValue(raw))")
      }
      return s
    }
    guard u.count == 3, u.allSatisfy({ ASCII.isUpper($0) || ASCII.isLower($0) }) else {
      throw PayloadError("\(key) must be a three-letter currency code, got \(showValue(raw))")
    }
    return ASCII.uppercased(s)
  }

  static func direction(_ v: JSONValue?) throws(PayloadError) -> String {
    guard let s = v?.stringValue, s == "debit" || s == "credit" else {
      throw PayloadError("direction must be debit or credit, got \(showValue(v))")
    }
    return s
  }

  /// replay.ts `instant`: a wire timestamp, canonicalized, refused when the
  /// canonical form leaves the four-digit-year range.
  static func instant(_ v: JSONValue?, _ what: String) throws(PayloadError) -> String {
    guard let s = v?.stringValue else { throw PayloadError("\(what) must be an RFC3339 timestamp, got \(showValue(v))") }
    do {
      _ = try parseInstantMs(s)
      let c = try canonicalTime(s)
      _ = try parseInstantMs(c)
      return c
    } catch {
      throw PayloadError("\(what): \(showValue(v)) is not a usable timestamp")
    }
  }

  static func requiredString(_ v: JSONValue?, _ what: String) throws(PayloadError) -> String {
    guard let s = v?.stringValue, !s.isEmpty else { throw PayloadError("\(what) is \(showValue(v))") }
    return s
  }

  /// replay.ts `optionalString`: nil when absent; a non-string (null included)
  /// is refused.
  static func optionalString(_ v: JSONValue?, _ what: String) throws(PayloadError) -> String? {
    guard let v else { return nil }
    guard let s = v.stringValue else { throw PayloadError("\(what) must be a string, got \(showValue(v))") }
    return s
  }

  static func nonEmptyString(_ v: JSONValue?, _ what: String) throws(PayloadError) -> String {
    guard let s = v?.stringValue, !s.isEmpty else {
      throw PayloadError("\(what) must be a non-empty string, got \(showValue(v))")
    }
    return s
  }

  static func boolField(_ v: JSONValue?, _ what: String) throws(PayloadError) -> Bool {
    guard let b = v?.boolValue else { throw PayloadError("\(what) must be a boolean, got \(showValue(v))") }
    return b
  }

  /// replay.ts `bool`: the fallback when absent; a non-boolean is refused.
  static func bool(_ v: JSONValue?, _ fallback: Bool) throws(PayloadError) -> Bool {
    guard let v else { return fallback }
    guard let b = v.boolValue else { throw PayloadError("want a boolean, got \(showValue(v))") }
    return b
  }

  /// replay.ts `optionalCategory`: absent, null and `""` are uncategorized.
  static func optionalCategory(_ v: JSONValue?) throws(PayloadError) -> String? {
    guard let v, !v.isNull else { return nil }
    guard let s = v.stringValue else { throw PayloadError("category must be a string or null, got \(showValue(v))") }
    return s.isEmpty ? nil : s
  }

  /// replay.ts `intField`: a JSON number that is a JavaScript safe integer. `1.0`
  /// and `1e2` qualify (JS semantics, kept for v3 parity).
  static func intFieldV3(_ v: JSONValue?, _ what: String) throws(PayloadError) -> Int64 {
    guard case .number(let n)? = v else { throw PayloadError("\(what) must be an integer, got \(showValue(v))") }
    let js = JSNumber.stringify(literal: n.literal)
    guard let i = Int64(js), i >= -JSONNumber.maxSafeInteger, i <= JSONNumber.maxSafeInteger else {
      throw PayloadError("\(what) must be an integer, got \(showValue(v))")
    }
    return i
  }

  // MARK: v4 readers (03c §1)

  /// 03c §1.2 `Int`: a plain integer literal (no fraction, exponent or `-0`)
  /// within ±(2^53-1), then `range`.
  static func intV4(_ v: JSONValue?, _ what: String, _ range: ClosedRange<Int64>) throws(PayloadError) -> Int64 {
    guard case .number(let n)? = v, let i = n.v4Int else {
      throw PayloadError("\(what) must be an integer literal, got \(showValue(v))")
    }
    guard range.contains(i) else { throw PayloadError("\(what) is \(i), outside \(range.lowerBound)...\(range.upperBound)") }
    return i
  }

  /// 03c §1.3 `Minor` / `PositiveMinor` / `SignedMinor` (no leading zeros).
  static func minorV4(_ v: JSONValue?, _ what: String, positive: Bool = false, signed: Bool = false)
    throws(PayloadError) -> Int64
  {
    guard let s = v?.stringValue else { throw PayloadError("\(what) must be a decimal string, got \(showValue(v))") }
    let n: Int64
    do {
      n = try MoneyGrammar.parseV4(s, allowNegative: signed)
    } catch {
      switch error {
      case .exceedsInt64: throw PayloadError("\(what): exceeds int64")
      default: throw PayloadError("\(what) is not a minor amount: \(showValue(v))")
      }
    }
    if positive, n <= 0 { throw PayloadError("\(what) must be positive") }
    return n
  }

  /// 03a §3.0 plan money (`0..MAX_MINOR`).
  static func planMinor(_ v: JSONValue?, _ what: String, positive: Bool = false) throws(PayloadError) -> Int64 {
    guard let s = v?.stringValue, let n = Grammar.planMinor(s) else {
      throw PayloadError("\(what) must be a plan amount (0 to 9999999999999), got \(showValue(v))")
    }
    if positive, n <= 0 { throw PayloadError("\(what) must be positive") }
    return n
  }

  static func label(_ v: JSONValue?, _ what: String) throws(PayloadError) -> String {
    guard let s = v?.stringValue else { throw PayloadError("\(what) must be a Label, got \(showValue(v))") }
    if let bad = TextRules.checkLabel(s) { throw PayloadError("\(what) is not a Label (\(bad))") }
    return s
  }

  static func note(_ v: JSONValue?, _ what: String) throws(PayloadError) -> String {
    guard let s = v?.stringValue else { throw PayloadError("\(what) must be a Note, got \(showValue(v))") }
    if let bad = TextRules.checkNote(s) { throw PayloadError("\(what) is not a Note (\(bad))") }
    return s
  }

  static func categoryID(_ v: JSONValue?, _ what: String) throws(PayloadError) -> String {
    guard let s = v?.stringValue, Grammar.isCategoryID(s) else {
      throw PayloadError("\(what) must be a CategoryId, got \(showValue(v))")
    }
    return s
  }

  /// A `CategoryId` or null; at v4 `""` still means null on txn payloads (03c §3.1).
  static func optionalCategoryV4(_ v: JSONValue?, _ what: String) throws(PayloadError) -> String? {
    guard let v, !v.isNull, v.stringValue != "" else { return nil }
    return try categoryID(v, what)
  }

  static func ulid(_ v: JSONValue?, _ what: String) throws(PayloadError) -> String {
    guard let s = v?.stringValue, Grammar.isULID(s) else { throw PayloadError("\(what) must be an EntityId, got \(showValue(v))") }
    return s
  }

  static func id03b(_ v: JSONValue?, _ what: String) throws(PayloadError) -> String {
    guard let s = v?.stringValue, Grammar.isID(s) else { throw PayloadError("\(what) must be an Id, got \(showValue(v))") }
    return s
  }

  static func civilDate(_ v: JSONValue?, _ what: String) throws(PayloadError) -> String {
    guard let s = v?.stringValue, Grammar.civilDate(s) != nil else {
      throw PayloadError("\(what) must be a CivilDate, got \(showValue(v))")
    }
    return s
  }

  static func civilMonth(_ v: JSONValue?, _ what: String) throws(PayloadError) -> String {
    guard let s = v?.stringValue, Grammar.civilMonth(s) != nil else {
      throw PayloadError("\(what) must be a CivilMonth, got \(showValue(v))")
    }
    return s
  }

  /// One of `allowed`.
  static func oneOf(_ v: JSONValue?, _ what: String, _ allowed: [String]) throws(PayloadError) -> String {
    guard let s = v?.stringValue, allowed.contains(where: { utf8Equal($0, s) }) else {
      throw PayloadError("\(what) must be one of \(allowed.joined(separator: "|")), got \(showValue(v))")
    }
    return s
  }

  /// The value when present and not null (absent and null mean the same, 03c §1.1 rule 3).
  static func present(_ v: JSONValue?) -> JSONValue? {
    guard let v, !v.isNull else { return nil }
    return v
  }
}
