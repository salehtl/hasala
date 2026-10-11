// The translation layer from a stored dialect pattern to an ICU pattern (spec 04 §2.2
// CoreTemplate "ICU engine + translation"; inventory client-core-b §2.3).
//
// The stored pattern is what Go (RE2) and TypeScript (`new RegExp(toJS(p), flags + "u")`)
// run. ICU differs from both by default: `\d` and `\w` are Unicode classes, `$` also matches
// before a final line terminator, case-insensitive matching uses FULL case folding, set syntax
// has operators (`[a--b]`, `[a&&b]`, nested `[...]`), and group names may not contain `_`.
// So the translator does not pass pattern text through. It parses the pattern with
// JavaScript's `u`-mode grammar and re-emits it in a form ICU cannot read differently:
//
//   - every literal is `\x{HEX}` (ASCII letters and digits as themselves);
//   - every class, and every `\d \D \w \W`, becomes an explicit set of code point ranges,
//     computed with JavaScript-`u` semantics (`\d` = [0-9], `\w` = [0-9A-Za-z_]);
//   - with flag `i`, every literal and every set is closed under SIMPLE case folding (the
//     orbit of `k` is {K, k, U+212A}), and ICU compiles case-sensitively;
//   - `$` becomes `\z` (end of input only), `^` stays (start of input without MULTILINE);
//   - `(?P<name>` becomes a plain capture group and the name is kept on the side.
//
// It also refuses what JavaScript refuses under `u` (a lone `]` or `}`, a reversed range, a
// class escape as a range end) and what Go's regexp.Compile refuses (a repetition count over
// 1,000), so `Dialect.validate`'s `not_compilable` backstop rejects the union of both
// engines' compile failures: a pattern either engine cannot run is not loaded here.
import HasalaICU

enum EngineError: Error, Equatable, Sendable {
  /// The pattern does not compile (in JavaScript-`u`, Go or ICU terms).
  case notCompilable
  /// ICU's time or stack limit stopped a match (ReDoS backstop).
  case limitExceeded
}

/// A translated pattern: ICU source and the names of its capture groups.
struct ICUPattern: Equatable {
  /// The ICU pattern text.
  let source: String
  /// `groups[k]` names capture group `k + 1` (nil for an unnamed group), in order.
  let groups: [String?]

  /// Go's regexp/syntax repeat limit (`invalid repeat count` above it).
  static let maxRepeat = 1000

  static func translate(_ pattern: String, caseInsensitive: Bool) throws(EngineError) -> ICUPattern {
    var p = Parser(src: Array(pattern.unicodeScalars), ci: caseInsensitive)
    try p.disjunction()
    guard p.i == p.src.count else { throw .notCompilable }  // an unbalanced `)`
    return ICUPattern(source: p.out, groups: p.groups)
  }

  /// Translates and compiles `pattern`.
  static func compile(_ pattern: String, caseInsensitive: Bool) throws(EngineError) -> ICURegex {
    try ICURegex(try translate(pattern, caseInsensitive: caseInsensitive))
  }

  // MARK: - Sets

  static let digit = CodePointSet(ranges: [0x30...0x39])
  static let word = CodePointSet(ranges: [0x30...0x39, 0x41...0x5A, 0x5F...0x5F, 0x61...0x7A])
  /// JavaScript's WordCharacters under `iu`: also every character whose simple fold is a word
  /// character (U+017F and U+212A), which is what Go's folded `\w` holds too.
  static let wordCI = word.caseClosed
  /// What `.` matches in JavaScript (no `s` flag): anything but the four line terminators.
  /// (Unreachable: the dialect refuses a bare dot before a pattern gets here.)
  static let dot = CodePointSet([0x0A, 0x0D, 0x2028, 0x2029]).complement

  static func hex(_ v: UInt32) -> String { String(v, radix: 16, uppercase: true) }

  static func literal(_ v: UInt32) -> String {
    switch v {
    case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: String(Unicode.Scalar(v)!)
    default: "\\x{\(hex(v))}"
    }
  }

  static func emit(_ set: CodePointSet) -> String {
    if set.isEmpty { return "[^\\x{0}-\\x{10FFFF}]" }
    var s = "["
    for r in set.ranges {
      s += "\\x{\(hex(r.lowerBound))}"
      if r.upperBound != r.lowerBound { s += "-\\x{\(hex(r.upperBound))}" }
    }
    return s + "]"
  }

  // MARK: - The parser (JavaScript `u`-mode grammar, the dialect's subset)

  struct Parser {
    let src: [Unicode.Scalar]
    let ci: Bool
    var i = 0
    var out = ""
    var groups: [String?] = []

    func peek(_ k: Int = 0) -> Unicode.Scalar? { i + k < src.count ? src[i + k] : nil }

    static func isSyntax(_ c: Unicode.Scalar) -> Bool { "^$\\.*+?()[]{}|".unicodeScalars.contains(c) }
    static func isDigit(_ c: Unicode.Scalar) -> Bool { c.value >= 0x30 && c.value <= 0x39 }
    static func hexValue(_ c: Unicode.Scalar) -> UInt32? {
      switch c.value {
      case 0x30...0x39: c.value - 0x30
      case 0x41...0x46: c.value - 0x41 + 10
      case 0x61...0x66: c.value - 0x61 + 10
      default: nil
      }
    }

    mutating func disjunction() throws(EngineError) {
      try alternative()
      while peek() == "|" {
        out += "|"
        i += 1
        try alternative()
      }
    }

    mutating func alternative() throws(EngineError) {
      while let c = peek(), c != "|", c != ")" { try term() }
    }

    mutating func term() throws(EngineError) {
      switch peek() {
      case "^":
        out += "^"
        i += 1
      case "$":
        out += "\\z"
        i += 1
      default:
        try atom()
        try quantifier()
      }
    }

    mutating func emitLiteral(_ v: UInt32) {
      if ci {
        let orbit = CaseFold.orbit(v)
        if orbit.count > 1 {
          out += ICUPattern.emit(CodePointSet(orbit))
          return
        }
      }
      out += ICUPattern.literal(v)
    }

    mutating func emitSet(_ set: CodePointSet) {
      out += ICUPattern.emit(ci ? set.caseClosed : set)
    }

    /// The set a class escape letter stands for, with `i` taken into account for `\w`/`\W`.
    func classEscape(_ e: Unicode.Scalar) -> CodePointSet? {
      switch e {
      case "d": ICUPattern.digit
      case "D": ICUPattern.digit.complement
      case "w": ci ? ICUPattern.wordCI : ICUPattern.word
      case "W": (ci ? ICUPattern.wordCI : ICUPattern.word).complement
      default: nil
      }
    }

    /// One CharacterEscape after the backslash (not a class escape): its code point.
    mutating func characterEscape(inClass: Bool) throws(EngineError) -> UInt32 {
      guard let e = peek() else { throw .notCompilable }
      i += 1
      switch e {
      case "n": return 0x0A
      case "r": return 0x0D
      case "t": return 0x09
      case "f": return 0x0C
      case "v": return 0x0B
      case "x":
        guard let a = peek(), let b = peek(1), let hi = Self.hexValue(a), let lo = Self.hexValue(b) else {
          throw .notCompilable
        }
        i += 2
        return hi << 4 | lo
      case "-" where inClass:
        return 0x2D
      default:
        // IdentityEscape under `u`: a SyntaxCharacter or `/`, nothing else.
        guard Self.isSyntax(e) || e == "/" else { throw .notCompilable }
        return e.value
      }
    }

    mutating func atom() throws(EngineError) {
      guard let c = peek() else { throw .notCompilable }
      switch c {
      case "(":
        i += 1
        if peek() == "?" {
          if peek(1) == ":" {
            i += 2
            out += "(?:"
          } else if peek(1) == "P", peek(2) == "<" {
            i += 3
            var name = String.UnicodeScalarView()
            while let n = peek(), n != ">" {
              name.append(n)
              i += 1
            }
            guard peek() == ">", isGroupName(name) else { throw .notCompilable }
            i += 1
            let text = String(name)
            guard !groups.contains(where: { $0?.utf8.elementsEqual(text.utf8) == true }) else { throw .notCompilable }
            groups.append(text)
            out += "("
          } else {
            throw .notCompilable  // lookaround, inline flags, comments: not in the dialect
          }
        } else {
          groups.append(nil)
          out += "("
        }
        try disjunction()
        guard peek() == ")" else { throw .notCompilable }
        i += 1
        out += ")"
      case "[":
        i += 1
        out += ICUPattern.emit(try charClass())  // already case-closed and negated
      case "\\":
        i += 1
        guard let e = peek() else { throw .notCompilable }
        if let set = classEscape(e) {
          i += 1
          emitSet(set)
        } else {
          emitLiteral(try characterEscape(inClass: false))
        }
      case ".":
        i += 1
        emitSet(ICUPattern.dot)
      default:
        // `* + ? { } ] ) |` here are JavaScript-`u` SyntaxErrors ("nothing to repeat",
        // "lone quantifier brackets").
        guard !Self.isSyntax(c) else { throw .notCompilable }
        i += 1
        emitLiteral(c.value)
      }
    }

    func isGroupName(_ name: String.UnicodeScalarView) -> Bool {
      guard let f = name.first else { return false }
      func word(_ c: Unicode.Scalar) -> Bool {
        (c.value >= 0x41 && c.value <= 0x5a) || (c.value >= 0x61 && c.value <= 0x7a) || c == "_"
      }
      return word(f) && name.dropFirst().allSatisfy { word($0) || Self.isDigit($0) }
    }

    /// One ClassAtom: a single code point, or a class escape's set.
    enum ClassAtom {
      case char(UInt32)
      case set(CodePointSet)
    }

    mutating func classAtom() throws(EngineError) -> ClassAtom {
      guard let c = peek() else { throw .notCompilable }
      if c == "\\" {
        i += 1
        guard let e = peek() else { throw .notCompilable }
        if let set = classEscape(e) {
          i += 1
          return .set(set)
        }
        return .char(try characterEscape(inClass: true))
      }
      i += 1
      return .char(c.value)
    }

    /// The body of `[...]` after the `[`, through the `]`: the set it matches. With `i` the
    /// members are closed under simple case folding BEFORE a `^` negates them (JavaScript's
    /// CharSetMatcher with invert, and Go's folded-then-negated class).
    mutating func charClass() throws(EngineError) -> CodePointSet {
      var negate = false
      if peek() == "^" {
        negate = true
        i += 1
      }
      var ranges: [ClosedRange<UInt32>] = []
      var set = CodePointSet.empty
      while true {
        guard let c = peek() else { throw .notCompilable }  // unterminated
        if c == "]" {
          i += 1
          break
        }
        let a = try classAtom()
        if peek() == "-", let after = peek(1), after != "]" {
          i += 1
          let b = try classAtom()
          guard case .char(let lo) = a, case .char(let hi) = b, lo <= hi else { throw .notCompilable }
          ranges.append(lo...hi)
          continue
        }
        switch a {
        case .char(let v): ranges.append(v...v)
        case .set(let s): set = set.union(s)
        }
      }
      var result = set.union(CodePointSet(ranges: ranges))
      if ci { result = result.caseClosed }
      if negate { result = result.complement }
      return result
    }

    mutating func count() -> Int? {
      var v = 0
      var n = 0
      while let c = peek(), Self.isDigit(c) {
        v = min(v * 10 + Int(c.value - 0x30), Int(Int32.max))
        i += 1
        n += 1
      }
      return n > 0 ? v : nil
    }

    mutating func quantifier() throws(EngineError) {
      guard let c = peek() else { return }
      switch c {
      case "*", "+", "?":
        i += 1
        out.unicodeScalars.append(c)
      case "{":
        i += 1
        guard let lo = count() else { throw .notCompilable }
        var text = "{\(lo)"
        if peek() == "," {
          i += 1
          text += ","
          if let hi = count() {
            guard hi >= lo, hi <= ICUPattern.maxRepeat else { throw .notCompilable }
            text += "\(hi)"
          }
        }
        guard lo <= ICUPattern.maxRepeat, peek() == "}" else { throw .notCompilable }
        i += 1
        out += text + "}"
      default:
        return
      }
      if peek() == "?" {
        i += 1
        out += "?"
      }
    }
  }
}

// MARK: - The compiled engine

/// A compiled ICU regular expression. The prototype is never matched against directly: every
/// match runs on a clone (cheap: the compiled pattern is shared), so one compiled template can
/// serve concurrent callers.
final class ICURegex: @unchecked Sendable {
  // @unchecked: `proto` is written once in init, only ever read by uregex_clone (which ICU
  // documents as safe to call on a shared original) and closed in deinit.
  private let proto: OpaquePointer
  let groups: [String?]

  /// ICU's processing limit per search (uregex_setTimeLimit), in its time units of 10,000
  /// match-engine operations each. It counts operations, not wall time, so the verdict is the
  /// same on every device.
  ///
  /// The dialect bounds a pattern's SHAPE, not its cost on a given body, and ICU backtracks
  /// roughly ten times slower than V8, where the dialect's costs were calibrated. Measured on
  /// an Apple M-series Mac (2026-10-11, release build): the dialect-accepted
  /// `[0-9]{1,32}[0-9]{1,32}z` takes 24 s on a 2 MB digit run and `[0-9]+z` 11.9 s on 50,000
  /// digits, unlimited; one unit is about 90 µs there. 10,000 units (about 10^8 operations,
  /// about 0.9 s on that Mac) is the smallest round limit under which every shipping template
  /// completes on every hostile body in CoreTemplateTests up to `maxBodyBytes` (the slowest,
  /// enbd.alert.v1's amount anchor on 2 MB of digits, needs between 5,000 and 10,000), so
  /// their verdicts stay the oracle's; a pattern that would run longer is stopped and the
  /// message refused as `too_large`. Re-measure on the oldest test iPhone before TestFlight
  /// (inventory client-core-b §2.3).
  static let timeLimit: Int32 = 10_000

  init(_ p: ICUPattern) throws(EngineError) {
    var status: HasalaUErrorCode = 0
    let units = Array(p.source.utf16)
    let re = units.withUnsafeBufferPointer { buf in
      uregex_open(buf.baseAddress, Int32(buf.count), 0, nil, &status)
    }
    guard status <= 0, let re else {
      if let re { uregex_close(re) }
      throw .notCompilable
    }
    var gstatus: HasalaUErrorCode = 0
    let count = uregex_groupCount(re, &gstatus)
    guard gstatus <= 0, Int(count) == p.groups.count else {
      uregex_close(re)
      throw .notCompilable
    }
    proto = re
    groups = p.groups
  }

  deinit { uregex_close(proto) }

  /// A match: UTF-16 ranges of the whole match and of each capture group (nil when the group
  /// did not participate).
  struct Match: Equatable {
    let range: Range<Int>
    let groups: [Range<Int>?]
  }

  /// The leftmost match in `text` (UTF-16), or nil. Throws `.limitExceeded` when ICU's time or
  /// stack limit stops the search.
  func firstMatch(in text: [UInt16], timeLimit: Int32 = ICURegex.timeLimit) throws(EngineError) -> Match? {
    var status: HasalaUErrorCode = 0
    guard let re = uregex_clone(proto, &status), status <= 0 else { throw .notCompilable }
    defer { uregex_close(re) }
    uregex_setTimeLimit(re, timeLimit, &status)
    // ICU refuses a NULL text pointer, which an empty array would hand over.
    let buffer = text.isEmpty ? [0] : text
    let result: Match?? = buffer.withUnsafeBufferPointer { buf -> Match?? in
      uregex_setText(re, buf.baseAddress, Int32(text.count), &status)
      guard status <= 0 else { return .none }
      let found = uregex_find(re, 0, &status)
      guard status <= 0 else { return .none }
      guard found != 0 else { return .some(nil) }
      func span(_ g: Int32) -> Range<Int>? {
        var s: HasalaUErrorCode = 0
        let start = uregex_start(re, g, &s)
        let end = uregex_end(re, g, &s)
        guard s <= 0, start >= 0, end >= start else { return nil }
        return Int(start)..<Int(end)
      }
      guard let whole = span(0) else { return .none }
      let gs = (0..<groups.count).map { span(Int32($0 + 1)) }
      return .some(Match(range: whole, groups: gs))
    }
    guard let result else { throw .limitExceeded }
    return result
  }
}
