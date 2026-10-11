// Code point sets and simple case folding for the ICU translation.
//
// Case-insensitive matching is NOT left to ICU's UREGEX_CASE_INSENSITIVE, which applies FULL
// case folding (so a pattern "ss" would match "ß" and "fi" would match the ligature U+FB01).
// Go's `(?i)` and JavaScript's `iu` both use SIMPLE case folding (CaseFolding.txt statuses C
// and S): a character matches when its simple fold equals the pattern character's. The
// translator therefore expands every case-insensitive literal and class into the explicit
// set of characters that share its simple fold (its "orbit": `k` is {K, k, U+212A}, `s` is
// {S, s, U+017F}), and compiles the result case-sensitively.
import HasalaICU

/// A set of Unicode code points as sorted, disjoint, non-adjacent closed ranges.
struct CodePointSet: Equatable, Sendable {
  private(set) var ranges: [ClosedRange<UInt32>]

  static let maxCodePoint: UInt32 = 0x10FFFF
  static let empty = CodePointSet(ranges: [])
  static let all = CodePointSet(ranges: [0...maxCodePoint])

  init(ranges: [ClosedRange<UInt32>]) {
    self.ranges = Self.normalized(ranges)
  }

  init(_ scalars: [UInt32]) {
    self.init(ranges: scalars.map { $0...$0 })
  }

  private static func normalized(_ input: [ClosedRange<UInt32>]) -> [ClosedRange<UInt32>] {
    let sorted = input.sorted { $0.lowerBound < $1.lowerBound }
    var out: [ClosedRange<UInt32>] = []
    for r in sorted {
      if let last = out.last, r.lowerBound <= last.upperBound &+ 1 {
        out[out.count - 1] = last.lowerBound...max(last.upperBound, r.upperBound)
      } else {
        out.append(r)
      }
    }
    return out
  }

  var isEmpty: Bool { ranges.isEmpty }

  func contains(_ c: UInt32) -> Bool {
    var lo = 0
    var hi = ranges.count
    while lo < hi {
      let mid = (lo + hi) / 2
      if ranges[mid].upperBound < c {
        lo = mid + 1
      } else if ranges[mid].lowerBound > c {
        hi = mid
      } else {
        return true
      }
    }
    return false
  }

  func union(_ other: CodePointSet) -> CodePointSet { CodePointSet(ranges: ranges + other.ranges) }

  /// Everything in U+0000-U+10FFFF not in this set.
  var complement: CodePointSet {
    var out: [ClosedRange<UInt32>] = []
    var next: UInt32 = 0
    for r in ranges {
      if r.lowerBound > next { out.append(next...(r.lowerBound - 1)) }
      next = r.upperBound &+ 1
    }
    if next <= Self.maxCodePoint && !(ranges.last?.upperBound == Self.maxCodePoint) {
      out.append(next...Self.maxCodePoint)
    }
    return CodePointSet(ranges: out)
  }

  /// The set closed under simple case folding: every character that shares a simple fold
  /// with a member is added (JavaScript's `iu` CharSetMatcher; Go's folded classes).
  var caseClosed: CodePointSet {
    var extra: [UInt32] = []
    for orbit in CaseFold.orbits where orbit.contains(where: contains) {
      extra.append(contentsOf: orbit)
    }
    return extra.isEmpty ? self : union(CodePointSet(extra))
  }
}

enum CaseFold {
  /// ICU's simple case folding (u_foldCase with U_FOLD_CASE_DEFAULT).
  static func fold(_ c: UInt32) -> UInt32 { UInt32(bitPattern: u_foldCase(Int32(bitPattern: c), 0)) }

  /// Every non-trivial orbit (characters sharing one simple fold, two or more of them),
  /// computed once from ICU's tables over the whole code space.
  static let orbits: [[UInt32]] = {
    var byFold: [UInt32: [UInt32]] = [:]
    var c: UInt32 = 0
    while c <= CodePointSet.maxCodePoint {
      if c == 0xD800 { c = 0xE000 }
      let f = fold(c)
      if f != c { byFold[f, default: [f]].append(c) }
      c += 1
    }
    return byFold.keys.sorted().map { byFold[$0]!.sorted() }
  }()

  /// The orbit of `c` (just `[c]` when nothing else folds with it).
  static let orbitIndex: [UInt32: Int] = {
    var idx: [UInt32: Int] = [:]
    for (i, o) in orbits.enumerated() {
      for m in o { idx[m] = i }
    }
    return idx
  }()

  static func orbit(_ c: UInt32) -> [UInt32] {
    if let i = orbitIndex[c] { return orbits[i] }
    return [c]
  }
}
