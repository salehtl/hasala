// The v4 fold base types (spec 03c §1, §1.8.1; 03a §1): the op position, the
// keyed record, and the structural grammars every v4 payload decoder checks.
//
// Every check here is a hand-written predicate over bytes or scalars: no regex
// engine, no case folding, no Unicode-table lookup (03c §1.11 rules 1-2), so two
// devices on different OS versions fold the same log to the same state.
import CoreJSON
import CoreMoney
import CoreTime
import HasalaText

/// An op's place in the folded log: the blob's seq, then the op's index inside
/// the blob, ordered lexicographically (03c §1.8.1, 03a §1).
public struct OpPosition: Sendable, Hashable, Comparable, Codable {
  public let seq: Int64
  public let index: Int

  public init(seq: Int64, index: Int) {
    self.seq = seq
    self.index = index
  }

  public static func < (a: OpPosition, b: OpPosition) -> Bool {
    a.seq != b.seq ? a.seq < b.seq : a.index < b.index
  }
}

/// A keyed-record value and the op that installed it (03c §1.8.1). Installed
/// unconditionally: the fold visits ops in position order, so the last write by
/// position wins.
public struct Keyed<V: Sendable & Equatable & Codable>: Sendable, Equatable, Codable {
  public var value: V
  public var opID: String

  public init(_ value: V, opID: String) {
    self.value = value
    self.opID = opID
  }
}

/// The structural grammars of spec 03c §1 and 03a/03b §1, as total predicates.
public enum Grammar {
  /// 03c §1.7 `CategoryId`: a `Token` of at least two bytes.
  public static func isCategoryID(_ s: String) -> Bool { TextRules.isToken(s) && s.utf8.count >= 2 }

  /// 03c §1.7 `IconId`: a `Token`.
  public static func isIconID(_ s: String) -> Bool { TextRules.isToken(s) }

  public static let categoryParents: [(id: String, kind: String, bucket: String?)] = [
    ("rent", "spending", "need"), ("utilities", "spending", "need"), ("groceries", "spending", "need"), ("transport", "spending", "need"),
    ("healthcare", "spending", "need"), ("insurance", "spending", "need"), ("dining", "spending", "want"),
    ("entertainment", "spending", "want"), ("shopping", "spending", "want"), ("travel", "spending", "want"),
    ("subscriptions", "spending", "want"), ("savings", "spending", "saving"), ("investments", "spending", "saving"),
    ("debt", "spending", "saving"), ("salary", "income", nil), ("freelance", "income", nil),
  ]

  public static let categoryParentIDs = categoryParents.map(\.id)

  public static func isCategoryParent(_ s: String) -> Bool { categoryParentIDs.contains { utf8Equal($0, s) } }

  public static func categoryParentClass(_ s: String) -> (kind: String, bucket: String?)? {
    guard let p = categoryParents.first(where: { utf8Equal($0.id, s) }) else { return nil }
    return (p.kind, p.bucket)
  }

  /// 03c §1.7 `EntityId` / `OpId`: a ULID, `^[0-7][0-9A-HJKMNP-TV-Z]{25}$`.
  public static func isULID(_ s: String) -> Bool {
    let u = Array(s.utf8)
    guard u.count == 26, (0x30...0x37).contains(u[0]) else { return false }
    return u.dropFirst().allSatisfy(isCrockford)
  }

  private static func isCrockford(_ b: UInt8) -> Bool {
    if ASCII.isDigit(b) { return true }
    guard ASCII.isUpper(b) else { return false }
    return b != 0x49 && b != 0x4c && b != 0x4f && b != 0x55  // I L O U
  }

  /// 03b §1.2 `Id` (`AccountId`, `BillId`, check-in ids): `^[A-Za-z0-9._-]{1,64}$`.
  public static func isID(_ s: String) -> Bool {
    let u = Array(s.utf8)
    guard (1...64).contains(u.count) else { return false }
    return u.allSatisfy { ASCII.isDigit($0) || ASCII.isUpper($0) || ASCII.isLower($0) || $0 == 0x2e || $0 == 0x5f || $0 == 0x2d }
  }

  /// 03b §1.2 / 03c §3.1 `Bank`: `^[a-z0-9_]{2,32}$`.
  public static func isBank(_ s: String) -> Bool {
    let u = Array(s.utf8)
    guard (2...32).contains(u.count) else { return false }
    return u.allSatisfy { ASCII.isDigit($0) || ASCII.isLower($0) || $0 == 0x5f }
  }

  /// 03a §3.0 income-source id: `^[a-z0-9][a-z0-9_-]{0,63}$`.
  public static func isPlanRecordID(_ s: String) -> Bool {
    let u = Array(s.utf8)
    guard (1...64).contains(u.count), ASCII.isDigit(u[0]) || ASCII.isLower(u[0]) else { return false }
    return u.allSatisfy { ASCII.isDigit($0) || ASCII.isLower($0) || $0 == 0x5f || $0 == 0x2d }
  }

  /// 03c §3.2.1 `DictBundle`: `^[0-9]{4}\.[0-9]{2}\.[0-9]{2}-[0-9]{1,3}$`.
  public static func isDictBundle(_ s: String) -> Bool {
    let u = Array(s.utf8)
    guard (12...14).contains(u.count), u[4] == 0x2e, u[7] == 0x2e, u[10] == 0x2d else { return false }
    for (i, b) in u.enumerated() where i != 4 && i != 7 && i != 10 {
      guard ASCII.isDigit(b) else { return false }
    }
    return true
  }

  /// 03c §3.2.1 `ModelTag`: `^[a-z0-9][a-z0-9./-]{0,31}$`.
  public static func isModelTag(_ s: String) -> Bool {
    let u = Array(s.utf8)
    guard (1...32).contains(u.count), ASCII.isDigit(u[0]) || ASCII.isLower(u[0]) else { return false }
    return u.allSatisfy { ASCII.isDigit($0) || ASCII.isLower($0) || $0 == 0x2e || $0 == 0x2f || $0 == 0x2d }
  }

  /// 03c §7.1 sender domain: lower-case ASCII labels of `[a-z0-9-]`, no label
  /// starting or ending with `-`, each 1-63 bytes, at least two labels, at most
  /// 253 bytes, no trailing dot.
  public static func isDomain(_ s: String) -> Bool {
    let u = Array(s.utf8)
    guard (1...253).contains(u.count) else { return false }
    let labels = u.split(separator: 0x2e, omittingEmptySubsequences: false)
    guard labels.count >= 2 else { return false }
    for l in labels {
      guard (1...63).contains(l.count), let f = l.first, let z = l.last else { return false }
      guard f != 0x2d, z != 0x2d else { return false }
      guard l.allSatisfy({ ASCII.isDigit($0) || ASCII.isLower($0) || $0 == 0x2d }) else { return false }
    }
    return true
  }

  /// 03c §1.5 `CivilDate` (year 2000-2099, a real date).
  public static func civilDate(_ s: String) -> CivilDate? { CivilDate(wire: s) }

  /// 03c §1.5 `CivilMonth` (year 2000-2099).
  public static func civilMonth(_ s: String) -> CivilMonth? { CivilMonth(wire: s) }

  /// 03a §3.0 plan money: `^(0|[1-9][0-9]{0,12})$` (at most `MAX_MINOR`).
  public static func planMinor(_ s: String) -> Int64? {
    let u = Array(s.utf8)
    guard (1...13).contains(u.count), u.allSatisfy(ASCII.isDigit) else { return nil }
    if u[0] == 0x30 { return u.count == 1 ? 0 : nil }
    return Int64(s)
  }

  /// 03a §3.0 `MAX_MINOR`.
  public static let maxPlanMinor: Int64 = 9_999_999_999_999

  /// 03c §5.1 rule pattern: 1-128 scalars, no forbidden scalar, and none of
  /// U+000A-U+000D or U+0085.
  public static func isRulePattern(_ s: String) -> Bool {
    let scalars = s.unicodeScalars
    guard (1...128).contains(scalars.count) else { return false }
    return !scalars.contains { ScalarSet.forbidden.contains($0) || (0x0a...0x0d).contains($0.value) || $0.value == 0x85 }
  }

  /// 03c §3.6 `merchant_key`: 1-256 scalars, no forbidden scalar.
  public static func isMerchantKey(_ s: String) -> Bool {
    let scalars = s.unicodeScalars
    guard (1...256).contains(scalars.count) else { return false }
    return !scalars.contains { ScalarSet.forbidden.contains($0) }
  }

  /// 03b §1.2 `Key`: 2-64 scalars, no forbidden scalar, no leading or trailing
  /// U+0020, no run of two U+0020.
  public static func isBillKey(_ s: String) -> Bool {
    let scalars = Array(s.unicodeScalars)
    guard (2...64).contains(scalars.count) else { return false }
    if scalars.first == " " || scalars.last == " " { return false }
    for (i, c) in scalars.enumerated() {
      if ScalarSet.forbidden.contains(c) { return false }
      if c == " ", i > 0, scalars[i - 1] == " " { return false }
    }
    return true
  }

  /// `^[0-9]{4}$` (03b card `last4`).
  public static func isLast4(_ s: String) -> Bool {
    let u = Array(s.utf8)
    return u.count == 4 && u.allSatisfy(ASCII.isDigit)
  }
}
