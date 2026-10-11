// Merchant canonicalization (categorize/canon.ts, ported; spec 03c §5.2, §8.2):
// split on Go's `unicode.IsSpace` set, rejoin with one U+0020, then lower-case
// scalar by scalar with Go's simple mapping (U+0130 → `i`, no Final_Sigma
// context). No Unicode normalization: NFC and NFD spellings stay different.
//
// Byte-exact module (spec 04 §2.4 R2): no `lowercased()`, no `String ==` on
// content, no Character iteration. It depends on the OS's case tables, so it
// runs in the pipeline and the author, never inside the fold (03c §1.11).
import HasalaText

public enum Canon {
  /// The longest subject the matcher reads, in scalars.
  public static let maxSubjectRunes = 512

  /// Go's `unicode.IsSpace`.
  public static func isGoSpace(_ s: Unicode.Scalar) -> Bool { ScalarSet.goSpace.contains(s) }

  /// canon.ts `foldCase`: each scalar's simple lower-case mapping.
  public static func foldCase(_ s: String) -> String { GoCase.lower(s) }

  /// canon.ts `canonical`.
  public static func canonical(_ s: String) -> String { foldCase(s.collapsingGoSpace) }

  /// Scalars in `s`.
  public static func runeLength(_ s: String) -> Int { s.unicodeScalars.count }

  /// The first `n` scalars of `s`.
  public static func truncateRunes(_ s: String, _ n: Int) -> String { HasalaText.truncateRunes(s, n) }

  /// rules.ts `subjectOf`: what every rule and dictionary entry is matched against.
  public static func subject(_ merchantRaw: String) -> String {
    truncateRunes(canonical(merchantRaw), maxSubjectRunes)
  }

  /// 03c §3.6 `merchant_key`: `truncateRunes(canonical(raw), 256)`.
  public static func merchantKey(_ merchantRaw: String) -> String {
    truncateRunes(canonical(merchantRaw), 256)
  }
}
