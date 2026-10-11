// The v4 text grammars of spec 03c §1.6: `Label`, `Note` and `Token`.
//
// These are STRUCTURAL checks only, the ones the fold may run: lengths in
// scalars and UTF-8 bytes, a fixed forbidden-scalar list and a fixed edge-space
// list. Nothing here depends on the OS's Unicode tables (no NFC check, no
// category lookup), so every device and every OS version agrees (03c §1.11).
// NFC normalization and trimming are the author's job, before these run.

/// Why a text value is not in its grammar.
public enum TextViolation: Error, Equatable, Sendable {
  case empty
  case tooManyScalars(max: Int)
  case tooManyBytes(max: Int)
  case forbiddenScalar(UInt32)
  case edgeSpace
  case notToken
}

public enum TextRules {
  public static let labelMaxScalars = 64
  public static let labelMaxBytes = 256
  public static let noteMaxScalars = 500
  public static let noteMaxBytes = 2000

  /// `Label`: 1-64 scalars, at most 256 UTF-8 bytes, no forbidden scalar, and
  /// neither the first nor the last scalar in `EDGE_SPACE`.
  public static func checkLabel(_ s: String) -> TextViolation? {
    let scalars = s.unicodeScalars
    guard let first = scalars.first, let last = scalars.last else { return .empty }
    if scalars.count > labelMaxScalars { return .tooManyScalars(max: labelMaxScalars) }
    if s.utf8.count > labelMaxBytes { return .tooManyBytes(max: labelMaxBytes) }
    if let bad = scalars.first(where: { ScalarSet.forbidden.contains($0) }) { return .forbiddenScalar(bad.value) }
    if ScalarSet.edgeSpace.contains(first) || ScalarSet.edgeSpace.contains(last) { return .edgeSpace }
    return nil
  }

  /// `Note`: 0-500 scalars (`""` clears), at most 2000 UTF-8 bytes, no forbidden
  /// scalar except U+000A.
  public static func checkNote(_ s: String) -> TextViolation? {
    if s.unicodeScalars.count > noteMaxScalars { return .tooManyScalars(max: noteMaxScalars) }
    if s.utf8.count > noteMaxBytes { return .tooManyBytes(max: noteMaxBytes) }
    if let bad = s.unicodeScalars.first(where: { $0.value != 0x0a && ScalarSet.forbidden.contains($0) }) {
      return .forbiddenScalar(bad.value)
    }
    return nil
  }

  /// `Token`: `^[a-z][a-z0-9_]{0,31}$`, checked over bytes (no regex engine).
  public static func isToken(_ s: String) -> Bool {
    let u = Array(s.utf8)
    guard (1...32).contains(u.count), ASCII.isLower(u[0]) else { return false }
    return u.dropFirst().allSatisfy { ASCII.isLower($0) || ASCII.isDigit($0) || $0 == 0x5f }
  }
}
