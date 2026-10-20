// Byte and text helpers for the normalizer, each named after the TypeScript (or Go) operation it
// reproduces. Nothing here is a platform default: no `lowercased()`, no `trimmingCharacters`, no
// `String` comparison or search (spec 04 §2.4 R2). Bytes stay bytes ("binary strings" in the
// TypeScript twin, one character per byte) until a stage decodes them.
import HasalaText

// MARK: - Bytes

enum Bytes {
  static let lf: UInt8 = 0x0a
  static let cr: UInt8 = 0x0d
  static let sp: UInt8 = 0x20
  static let tab: UInt8 = 0x09

  /// The first index `>= from` where `needle` starts in `hay`, or nil.
  static func index(of needle: [UInt8], in hay: [UInt8], from: Int = 0) -> Int? {
    if needle.isEmpty { return from <= hay.count ? from : nil }
    guard hay.count >= needle.count, from <= hay.count - needle.count else { return nil }
    let first = needle[0]
    var i = max(0, from)
    let last = hay.count - needle.count
    outer: while i <= last {
      if hay[i] != first {
        i += 1
        continue
      }
      for j in 1..<needle.count where hay[i + j] != needle[j] {
        i += 1
        continue outer
      }
      return i
    }
    return nil
  }

  /// The first index `>= from` of the byte `b`, or nil.
  static func index(of b: UInt8, in hay: [UInt8], from: Int = 0) -> Int? {
    var i = max(0, from)
    while i < hay.count {
      if hay[i] == b { return i }
      i += 1
    }
    return nil
  }

  static func index(of needle: [UInt8], in hay: ArraySlice<UInt8>, from: Int) -> Int? {
    let lo = max(hay.startIndex, from)
    if needle.isEmpty { return lo <= hay.endIndex ? lo : nil }
    guard hay.endIndex - needle.count >= lo else { return nil }
    let first = needle[0]
    var i = lo
    let last = hay.endIndex - needle.count
    outer: while i <= last {
      if hay[i] != first {
        i += 1
        continue
      }
      for j in 1..<needle.count where hay[i + j] != needle[j] {
        i += 1
        continue outer
      }
      return i
    }
    return nil
  }

  static func index(of b: UInt8, in hay: ArraySlice<UInt8>, from: Int) -> Int? {
    var i = max(hay.startIndex, from)
    while i < hay.endIndex {
      if hay[i] == b { return i }
      i += 1
    }
    return nil
  }

  static func hasPrefix(_ hay: ArraySlice<UInt8>, _ needle: [UInt8], at: Int) -> Bool {
    guard at >= hay.startIndex, at + needle.count <= hay.endIndex else { return false }
    for j in 0..<needle.count where hay[at + j] != needle[j] { return false }
    return true
  }

  static func hasPrefix(_ hay: [UInt8], _ needle: [UInt8], at: Int = 0) -> Bool {
    guard at >= 0, at + needle.count <= hay.count else { return false }
    for j in 0..<needle.count where hay[at + j] != needle[j] { return false }
    return true
  }

  static func contains(_ hay: [UInt8], _ needle: [UInt8]) -> Bool { index(of: needle, in: hay) != nil }

  /// JavaScript `toLowerCase()` on a binary string: every character is one byte's code
  /// point (U+0000-U+00FF), so the full mapping reduces to ASCII A-Z plus Latin-1
  /// U+00C0-U+00DE (not U+00D7). Nothing in that range lower-cases outside it.
  static func latin1Lower(_ s: [UInt8]) -> [UInt8] {
    s.map { b in
      if b >= 0x41 && b <= 0x5a { return b + 0x20 }
      if b >= 0xc0 && b <= 0xde && b != 0xd7 { return b + 0x20 }
      return b
    }
  }

  /// `Array("text".utf8)`, for literals.
  static func of(_ s: StaticString) -> [UInt8] {
    s.withUTF8Buffer { Array($0) }
  }

  /// The ASCII-or-Latin-1 text of a binary string (one scalar per byte), for messages and
  /// for the few places the twin turns a binary string into "text" without decoding.
  static func latin1String(_ s: [UInt8]) -> String {
    var out = String.UnicodeScalarView()
    for b in s { out.append(Unicode.Scalar(b)) }
    return String(out)
  }
}

// MARK: - Decoded text

enum NormText {
  /// JavaScript `String.prototype.toLowerCase()`, scalar by scalar (the full mapping, so
  /// U+0130 becomes `i` + U+0307 as in JavaScript). The one context-dependent rule,
  /// Final_Sigma, is not applied: it only touches U+03A3, which no charset label or
  /// media-type value this is used on can usefully carry.
  static func jsLower(_ s: String) -> String {
    var out = String.UnicodeScalarView()
    for c in s.unicodeScalars {
      if c.isASCII {
        out.append(c.value >= 0x41 && c.value <= 0x5a ? Unicode.Scalar(UInt8(c.value + 0x20)) : c)
      } else {
        out.append(contentsOf: c.properties.lowercaseMapping.unicodeScalars)
      }
    }
    return String(out)
  }

  /// unwrap.ts `trimExplicit`: U+0009-U+000D, U+0020, U+00A0, U+FEFF.
  static func trimExplicit(_ s: String) -> String { s.trimming(.unwrapTrim) }

  /// JavaScript `String.prototype.trim()`.
  static func jsTrim(_ s: String) -> String { s.trimming(.jsTrim) }

  /// Scalars of `s` as an array, for index arithmetic.
  @inline(__always) static func scalars(_ s: String) -> [Unicode.Scalar] { Array(s.unicodeScalars) }

  @inline(__always) static func string(_ s: some Sequence<Unicode.Scalar>) -> String {
    var v = String.UnicodeScalarView()
    v.append(contentsOf: s)
    return String(v)
  }

  /// `s.split("\n")` on scalars: keeps empty pieces and a trailing `\r`.
  static func splitLines(_ s: [Unicode.Scalar]) -> [ArraySlice<Unicode.Scalar>] {
    var out: [ArraySlice<Unicode.Scalar>] = []
    var start = 0
    for i in 0..<s.count where s[i] == "\n" {
      out.append(s[start..<i])
      start = i + 1
    }
    out.append(s[start..<s.count])
    return out
  }

  /// WHATWG UTF-8 decode with `ignoreBOM: true` (stage 3): ill-formed input becomes one U+FFFD
  /// per maximal subpart, and a leading U+FEFF is KEPT (the stage-8 trim set removes it
  /// wherever it lands). `String(decoding:as:)` is exactly that; CorePrimitives' `UTF8Text`
  /// strips the BOM and so is not used here.
  static func decodeUTF8(_ bytes: some Collection<UInt8>) -> String {
    String(decoding: bytes, as: UTF8.self)
  }
}
