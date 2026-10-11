// Ordering, counting and case helpers that never touch `Character`,
// `String <` or locale-aware APIs (spec 04 §2.4 R2).
//
// Swift's `String` comparison and equality are Unicode canonical equivalence
// over grapheme clusters: NFC and NFD spellings compare equal, and the order is
// not byte order. Go's `strings.Compare` and the reference's `compareUTF8` are
// byte order. Everything that orders or matches stored text goes through these.

/// Three-way comparison of the UTF-8 bytes of `a` and `b` (Go's
/// `strings.Compare`; wire/op.ts `compareUTF8`). Negative, zero or positive.
public func compareUTF8(_ a: String, _ b: String) -> Int {
  var x = a.utf8.makeIterator()
  var y = b.utf8.makeIterator()
  while true {
    switch (x.next(), y.next()) {
    case (nil, nil): return 0
    case (nil, _): return -1
    case (_, nil): return 1
    case (let p?, let q?): if p != q { return p < q ? -1 : 1 }
    }
  }
}

/// Three-way comparison by Unicode scalar value. For well-formed text this is
/// the same order as ``compareUTF8(_:_:)`` (UTF-8 preserves scalar order); it is
/// NOT the UTF-16 code-unit order of JavaScript's `<`, which sorts a
/// supplementary-plane scalar below U+E000.
public func compareScalars(_ a: String, _ b: String) -> Int {
  var x = a.unicodeScalars.makeIterator()
  var y = b.unicodeScalars.makeIterator()
  while true {
    switch (x.next(), y.next()) {
    case (nil, nil): return 0
    case (nil, _): return -1
    case (_, nil): return 1
    case (let p?, let q?): if p != q { return p.value < q.value ? -1 : 1 }
    }
  }
}

/// Byte equality (no canonical equivalence: `"é"` NFC and NFD differ).
public func utf8Equal(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }

/// Length in Unicode scalars ("runes"), never `String.count` (graphemes) or
/// UTF-16 units.
public func runeCount(_ s: String) -> Int { s.unicodeScalars.count }

/// The first `n` scalars of `s` (all of it when shorter). Never splits a scalar.
public func truncateRunes(_ s: String, _ n: Int) -> String {
  guard n > 0 else { return "" }
  let scalars = s.unicodeScalars
  let end = scalars.index(scalars.startIndex, offsetBy: n, limitedBy: scalars.endIndex) ?? scalars.endIndex
  return String(scalars[scalars.startIndex..<end])
}

// MARK: - ASCII

public enum ASCII {
  /// `A-Z` lowered, every other scalar unchanged (never Unicode case mapping).
  public static func lowercased(_ s: String) -> String {
    String(decoding: s.utf8.map { $0 >= 0x41 && $0 <= 0x5a ? $0 + 0x20 : $0 }, as: UTF8.self)
  }

  /// `a-z` raised, every other scalar unchanged.
  public static func uppercased(_ s: String) -> String {
    String(decoding: s.utf8.map { $0 >= 0x61 && $0 <= 0x7a ? $0 - 0x20 : $0 }, as: UTF8.self)
  }

  public static func isDigit(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x39 }
  public static func isUpper(_ b: UInt8) -> Bool { b >= 0x41 && b <= 0x5a }
  public static func isLower(_ b: UInt8) -> Bool { b >= 0x61 && b <= 0x7a }
  public static func isLowerHexDigit(_ b: UInt8) -> Bool { isDigit(b) || (b >= 0x61 && b <= 0x66) }

  /// `^[0-9]+$` over bytes: no sign, no space, not empty. (A regex `$` can
  /// match before a final `\n`; this cannot.)
  public static func isDecimal(_ s: String) -> Bool {
    !s.utf8.isEmpty && s.utf8.allSatisfy(isDigit)
  }

  /// `^[0-9a-f]{n}$` over bytes.
  public static func isLowerHex(_ s: String, count n: Int) -> Bool {
    s.utf8.count == n && s.utf8.allSatisfy(isLowerHexDigit)
  }
}

// MARK: - Go's simple lower-case mapping

public enum GoCase {
  /// One scalar lower-cased as Go's `unicode.ToLower` (Unicode SIMPLE case
  /// mapping, no context). Swift exposes only the FULL mapping, which expands
  /// U+0130 to `i` + U+0307; the first scalar of the full mapping is the simple
  /// one for every case Unicode defines, and it is what the reference's
  /// `lowerCodePoint` takes too. Depends on the OS's Unicode tables, so it is
  /// for categorization canon only and never inside the fold (spec 03c §1.11).
  public static func lower(_ s: Unicode.Scalar) -> Unicode.Scalar {
    if s.isASCII {
      return s.value >= 0x41 && s.value <= 0x5a ? Unicode.Scalar(UInt8(s.value + 0x20)) : s
    }
    return s.properties.lowercaseMapping.unicodeScalars.first ?? s
  }

  /// Go's `strings.ToLower`, scalar by scalar (so no Final_Sigma context).
  public static func lower(_ s: String) -> String {
    var out = String.UnicodeScalarView()
    for c in s.unicodeScalars { out.append(lower(c)) }
    return String(out)
  }
}
