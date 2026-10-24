// Explicit Unicode scalar sets and the trims built on them.
//
// Every whitespace or trim set in the oracle is a FIXED list, written out, and
// none of them is Foundation's `CharacterSet.whitespaces(AndNewlines)` (which
// differs from all of them). One named set per call site of the TypeScript or
// Go source, so a port reads the set it means (spec 03c §1.6).

/// A fixed set of Unicode scalars, independent of the OS's Unicode tables.
public struct ScalarSet: Sendable, Hashable {
  private let sorted: [UInt32]

  public init(_ values: [UInt32]) {
    sorted = Array(Set(values)).sorted()
  }

  public func contains(_ scalar: Unicode.Scalar) -> Bool { contains(scalar.value) }

  public func contains(_ value: UInt32) -> Bool {
    var lo = 0
    var hi = sorted.count
    while lo < hi {
      let mid = (lo + hi) / 2
      if sorted[mid] == value { return true }
      if sorted[mid] < value { lo = mid + 1 } else { hi = mid }
    }
    return false
  }

  /// The members, ascending.
  public var members: [UInt32] { sorted }

  // MARK: - Named sets

  /// Go's `unicode.IsSpace` (25 scalars): the Latin-1 fast path (`\t \n \v \f \r`,
  /// space, U+0085, U+00A0) plus `unicode.White_Space` beyond Latin-1. U+0085 is
  /// in it and U+FEFF is not, the reverse of JavaScript's `\s`
  /// (conformance/dict/matching.json pins Go's verdicts).
  public static let goSpace = ScalarSet([
    0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x20, 0x85, 0xa0, 0x1680,
    0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2007, 0x2008, 0x2009, 0x200a,
    0x2028, 0x2029, 0x202f, 0x205f, 0x3000,
  ])

  /// The six-byte ASCII cutset `" \t\n\v\f\r"` (tmpl/exec.ts `trimCapture`; Go
  /// `strings.Trim(s, " \t\n\v\f\r")`).
  public static let asciiSpace = ScalarSet([0x20, 0x09, 0x0a, 0x0b, 0x0c, 0x0d])

  /// Space and tab only (norm/mime.ts `trimSpaceTab`, go-message's `trim`).
  public static let spaceTab = ScalarSet([0x20, 0x09])

  /// norm/unwrap.ts `trimExplicit`: ASCII space and controls, NBSP and BOM.
  public static let unwrapTrim = ScalarSet([0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x20, 0xa0, 0xfeff])

  /// What JavaScript's `String.prototype.trim` removes: ECMAScript WhiteSpace
  /// (TAB, VT, FF, ZWNBSP, every Zs scalar) and LineTerminator (LF, CR, LS, PS),
  /// written out for the Zs members as of Unicode 15/16.
  public static let jsTrim = ScalarSet([
    0x09, 0x0b, 0x0c, 0x20, 0xa0, 0xfeff, 0x1680,
    0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2007, 0x2008, 0x2009, 0x200a,
    0x202f, 0x205f, 0x3000, 0x0a, 0x0d, 0x2028, 0x2029,
  ])

  /// Spec 03c §1.6 `EDGE_SPACE`: a `Label` may not start or end with one.
  public static let edgeSpace = ScalarSet([
    0x20, 0xa0, 0x1680, 0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2007,
    0x2008, 0x2009, 0x200a, 0x202f, 0x205f, 0x3000,
  ])

  /// Spec 03c §1.6 forbidden scalars: C0, DEL, C1, LS, PS, the bidi embeddings
  /// and overrides (U+202A-202E) and isolates (U+2066-2069), BOM, U+FFFE, U+FFFF.
  /// LRM, RLM and ALM (U+200E, U+200F, U+061C) are allowed for Arabic.
  public static let forbidden = ScalarSet(
    Array(0x00...0x1f) + [0x7f] + Array(0x80...0x9f) + [0x2028, 0x2029]
      + Array(0x202a...0x202e) + Array(0x2066...0x2069) + [0xfeff, 0xfffe, 0xffff])
}

extension BidirectionalCollection where Element == Unicode.Scalar {
  /// `self` with every leading and trailing scalar in `set` removed. Interior
  /// scalars are untouched.
  @inlinable
  public func trimming(_ set: ScalarSet) -> SubSequence {
    var lo = startIndex
    var hi = endIndex
    while lo < hi, set.contains(self[lo]) { lo = index(after: lo) }
    while hi > lo {
      let prev = index(before: hi)
      guard set.contains(self[prev]) else { break }
      hi = prev
    }
    return self[lo..<hi]
  }
}

extension String {
  /// `self` with every leading and trailing scalar in `set` removed. Interior
  /// scalars are untouched.
  public func trimming(_ set: ScalarSet) -> String { String(unicodeScalars.trimming(set)) }

  /// Go's `strings.TrimSpace`.
  public var trimmingGoSpace: String { trimming(.goSpace) }

  /// Go's `strings.Fields(s)` joined by one ASCII space: trimmed, and every run of
  /// Go whitespace collapsed to a single U+0020. No case change, no
  /// normalization (that is the canonicalizer's choice, not this helper's).
  public var collapsingGoSpace: String {
    var out = String.UnicodeScalarView()
    var pendingSpace = false
    for s in unicodeScalars {
      if ScalarSet.goSpace.contains(s) {
        pendingSpace = !out.isEmpty
        continue
      }
      if pendingSpace {
        out.append(" ")
        pendingSpace = false
      }
      out.append(s)
    }
    return String(out)
  }
}
