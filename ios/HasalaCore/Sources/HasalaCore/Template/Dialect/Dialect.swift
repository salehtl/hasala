// The template regex dialect validator: a port of reference/ledgerd-client/src/tmpl/dialect.ts
// (the mirror of the Go validator, server/internal/tmpl/dialect.go).
//
// A published template is data, run by more than one regex engine (Go's RE2 at publish, a
// backtracking engine on the phone: ICU here). The dialect is the subset of RE2 on which the
// engines were MEASURED to agree, plus cost rules that keep a backtracking engine cheap on
// attacker-writable mail. This gate runs at LOAD time, before a pattern reaches ICU.
//
// Every rejection carries a stable reason code, in scan order, identical to Go's for the same
// pattern: conformance/dialect/patterns.json pins the codes (36 rejected rows, 52 accepted rows
// and a 9,324-pattern generated corpus with its SHA-256). Treat the codes as a wire format.
//
// Offsets are rune (scalar) indices, as in Go, so the scanner works on a scalar array.

/// Cost bounds (counted in runes) and the reason codes. Identical to Go's.
public enum Dialect {
  public static let maxPatternRunes = 512
  public static let maxCaptureGroups = 8
  public static let maxBoundProduct = 64
  public static let maxUnboundedPerBranch = 1
  public static let maxRepetitionWidth = 1024

  public enum Reason: String, Sendable, CaseIterable {
    case emptyPattern = "empty_pattern"
    case patternTooLong = "pattern_too_long"
    case tooManyCaptureGroups = "too_many_capture_groups"
    case escapePerlSpace = "escape_perl_space"
    case escapeWordBoundary = "escape_word_boundary"
    case escapeUnicodeClass = "escape_unicode_class"
    case escapeUnicodeCodepoint = "escape_unicode_codepoint"
    case escapeTextAnchor = "escape_text_anchor"
    case escapeBackreference = "escape_backreference"
    case escapeNotAllowed = "escape_not_allowed"
    case malformedEscape = "malformed_escape"
    case inlineFlags = "inline_flags"
    case lookaround = "lookaround"
    case namedGroupJSSyntax = "named_group_js_syntax"
    case unsupportedGroup = "unsupported_group"
    case invalidGroupName = "invalid_group_name"
    case duplicateGroupName = "duplicate_group_name"
    case unbalancedParen = "unbalanced_paren"
    case bareDot = "bare_dot"
    case groupUnboundedQuantifier = "group_unbounded_quantifier"
    case unboundedInsideQuantifiedGroup = "unbounded_inside_quantified_group"
    case multipleUnboundedQuantifiers = "multiple_unbounded_quantifiers"
    case nestedVariableRepetition = "nested_variable_repetition"
    case repetitionWidthTooLarge = "repetition_width_too_large"
    case boundProductTooLarge = "bound_product_too_large"
    case malformedRepetition = "malformed_repetition"
    case emptyCharClass = "empty_character_class"
    case unterminatedCharClass = "unterminated_character_class"
    case classLiteralBracket = "class_literal_bracket"
    case flagNotAllowed = "flag_not_allowed"
    case duplicateFlag = "duplicate_flag"
    case notCompilable = "not_compilable"
  }

  /// Every way `pattern` (with `flags`) violates the dialect, as reason codes in scan order.
  /// Empty means the pattern is safe to compile and run here.
  public static func validate(_ pattern: String, flags: [String]) -> [Reason] {
    validateAndCompile(pattern, flags: flags).codes
  }

  /// `validate`, and the compiled engine when the pattern passes (so a template compiles each
  /// pattern once).
  static func validateAndCompile(_ pattern: String, flags: [String]) -> (codes: [Reason], regex: ICURegex?) {
    var v = Scanner(pattern)
    v.checkFlags(flags)
    v.scan()
    guard v.codes.isEmpty else { return (v.codes, nil) }
    // The scanner models the dialect, not the whole grammar. The engine's own compile is the
    // backstop for everything else, such as a reversed class range (the mirror of Go handing
    // the pattern to regexp.Compile and TypeScript to `new RegExp`). Flags here are exactly
    // [] or ["i"]: anything else was reported above.
    do {
      return ([], try ICUPattern.compile(pattern, caseInsensitive: !flags.isEmpty))
    } catch {
      v.addOnce(.notCompilable)
      return (v.codes, nil)
    }
  }

  /// The reason codes as their wire strings.
  public static func validatePattern(_ pattern: String, flags: [String]) -> [String] {
    validate(pattern, flags: flags).map(\.rawValue)
  }

  /// Rewrites `(?P<name>` to `(?<name>`, class- and escape-aware (Go's `ToJS`, TypeScript's
  /// `toJS`). Kept for parity with the twins' fixture; the ICU translation reads the stored
  /// pattern itself.
  public static func toJS(_ p: String) -> String {
    let r = Array(p.unicodeScalars)
    var out = String.UnicodeScalarView()
    var inClass = false
    var i = 0
    while i < r.count {
      let c = r[i]
      if c == "\\" {
        out.append(c)
        if i + 1 < r.count {
          i += 1
          out.append(r[i])
        }
        i += 1
        continue
      }
      if inClass {
        if c == "]" { inClass = false }
        out.append(c)
        i += 1
        continue
      }
      if c == "[" {
        inClass = true
        out.append(c)
      } else if c == "(" && i + 3 < r.count && r[i + 1] == "?" && r[i + 2] == "P" && r[i + 3] == "<" {
        out.append(contentsOf: "(?<".unicodeScalars)
        i += 3
      } else {
        out.append(c)
      }
      i += 1
    }
    return String(out)
  }

  /// The named capture groups of a stored pattern, in order of appearance (Go's
  /// `SubexpNames`).
  public static func groupNames(_ p: String) -> [String] {
    let r = Array(p.unicodeScalars)
    var out: [String] = []
    var inClass = false
    var i = 0
    while i < r.count {
      let c = r[i]
      if c == "\\" {
        i += 2
        continue
      }
      if inClass {
        if c == "]" { inClass = false }
        i += 1
        continue
      }
      if c == "[" {
        inClass = true
        i += 1
        continue
      }
      if c == "(" && i + 3 < r.count && r[i + 1] == "?" && r[i + 2] == "P" && r[i + 3] == "<" {
        var j = i + 4
        var name = String.UnicodeScalarView()
        while j < r.count && r[j] != ">" {
          name.append(r[j])
          j += 1
        }
        if j < r.count { out.append(String(name)) }
        i = j + 1
        continue
      }
      i += 1
    }
    return out
  }
}

// MARK: - The scanner

/// Saturation caps for the length and width accumulators (Go's `lenCap`, `widthCap`). Both
/// are compared against a yes/no bound, so saturating keeps every executor the same function
/// where Go's int would otherwise wrap.
private let lenCap = 1 << 30
private let widthCap = Dialect.maxRepetitionWidth + 1

private func satAdd(_ a: Int, _ b: Int) -> Int { min(a + b, lenCap) }

private func satMul(_ a: Int, _ b: Int) -> Int {
  if a == 0 || b == 0 { return 0 }
  if a > lenCap / b { return lenCap }
  return a * b
}

/// `a^n`, saturating at `widthCap`; `a^0` is 1.
private func satPow(_ a: Int, _ n: Int) -> Int {
  if a <= 1 { return a == 0 ? 0 : 1 }
  var out = 1
  for _ in 0..<n {
    if out > widthCap / a { return widthCap }
    out *= a
    if out > widthCap { return widthCap }
  }
  return out
}

/// Keeps the running bound product from overflowing.
private func mulCapped(_ a: Int, _ b: Int) -> Int {
  if a > Dialect.maxBoundProduct || b > Dialect.maxBoundProduct { return Dialect.maxBoundProduct + 1 }
  let p = a * b
  return p > Dialect.maxBoundProduct ? Dialect.maxBoundProduct + 1 : p
}

/// One group's accumulated state; every field propagates to the parent when the group closes.
private struct Frame {
  var hasUnbounded = false
  var best = 1
  var branchUnbounded = 0
  var maxUnbounded = 0
  var branchMin = 0
  var branchMax = 0
  var min = 0
  var max = 0
  var folded = false
  var branchWidth = 1
  var width = 0

  var worstBranch: Int { Swift.max(branchUnbounded, maxUnbounded) }
  var isVariable: Bool { min != max }

  /// Closes the branch at a `|` (or the group's end), folding it into the totals.
  mutating func endBranch() {
    maxUnbounded = worstBranch
    branchUnbounded = 0
    min = folded ? Swift.min(min, branchMin) : branchMin
    max = Swift.max(max, branchMax)
    folded = true
    width = satAdd(width, branchWidth)
    branchMin = 0
    branchMax = 0
    branchWidth = 1
  }
}

private struct Quant {
  var present = false
  var unbounded = false
  var min = 1
  var max = 1
}

private struct Scanner {
  let src: [Unicode.Scalar]
  var codes: [Dialect.Reason] = []
  var stack: [Frame] = []
  var captures = 0
  var names: [String] = []
  var reported: [String] = []

  init(_ p: String) { src = Array(p.unicodeScalars) }

  /// Reports `code` at most once per offset.
  mutating func add(_ offset: Int, _ code: Dialect.Reason) {
    let key = "\(code.rawValue)@\(offset)"
    if reported.contains(key) { return }
    reported.append(key)
    codes.append(code)
  }

  /// Reports a whole-pattern bound at most once.
  mutating func addOnce(_ code: Dialect.Reason) {
    let key = "once:\(code.rawValue)"
    if reported.contains(key) { return }
    reported.append(key)
    codes.append(code)
  }

  mutating func checkFlags(_ flags: [String]) {
    var seen: [String] = []
    for (i, f) in flags.enumerated() {
      let isI = f.utf8.elementsEqual("i".utf8)
      if !isI {
        add(i, .flagNotAllowed)
      } else if seen.contains(where: { $0.utf8.elementsEqual(f.utf8) }) {
        add(i, .duplicateFlag)
      }
      seen.append(f)
    }
  }

  mutating func scan() {
    if src.isEmpty {
      add(0, .emptyPattern)
      return
    }
    if src.count > Dialect.maxPatternRunes {
      add(Dialect.maxPatternRunes, .patternTooLong)
      return
    }

    stack = [Frame()]
    var i = 0
    while i < src.count {
      let c = src[i]
      switch c {
      case "\\":
        i = quantify(escape(i, inClass: false), group: nil)
      case "[":
        i = quantify(charClass(i), group: nil)
      case "(":
        i = openGroup(i)
      case ")":
        if stack.count == 1 {
          add(i, .unbalancedParen)
          i += 1
          continue
        }
        var child = stack.removeLast()
        child.endBranch()
        i = quantify(i + 1, group: child)
      case ".":
        add(i, .bareDot)
        i = quantify(i + 1, group: nil)
      case "*", "+", "?", "{":
        // A quantifier is consumed with its atom, so reaching one here means it applies to
        // nothing (or to another quantifier, a possessive form).
        add(i, .malformedRepetition)
        i += 1
      case "|":
        stack[stack.count - 1].endBranch()
        i += 1
      case "^", "$":
        i += 1
      default:
        i = quantify(i + 1, group: nil)
      }
    }

    if stack.count > 1 { add(src.count, .unbalancedParen) }
    stack[0].endBranch()
    if stack[0].best > Dialect.maxBoundProduct { addOnce(.boundProductTooLarge) }
    if stack[0].width > Dialect.maxRepetitionWidth { addOnce(.repetitionWidthTooLarge) }
  }

  /// Reads the quantifier at `next`, applies the nesting rules, folds the atom's cost into the
  /// enclosing frame, and returns the index past the quantifier. `group` is the closed child
  /// frame when the atom is a group.
  mutating func quantify(_ next: Int, group child: Frame?) -> Int {
    let (q, after) = readQuant(next)
    let childBest = child?.best ?? 1
    let childUnbounded = child?.hasUnbounded ?? false

    if q.present && child != nil {
      if q.unbounded {
        add(next, .groupUnboundedQuantifier)
      } else if childUnbounded {
        add(next, .unboundedInsideQuantifiedGroup)
      }
    }
    // A group that can repeat more than once re-splits a variable-length interior on every
    // repeat. `?` and `{0,1}` are exempt (one repetition multiplies nothing).
    if let child, q.present, !q.unbounded, q.max >= 2, child.isVariable {
      add(next, .nestedVariableRepetition)
    }

    var cur = stack[stack.count - 1]
    if q.present && q.unbounded { cur.hasUnbounded = true }
    if childUnbounded { cur.hasUnbounded = true }

    var added = 0
    if q.present && q.unbounded { added += 1 }
    if let child { added += child.worstBranch }
    var tooMany = false
    if added > 0 {
      cur.branchUnbounded += added
      if cur.branchUnbounded > Dialect.maxUnboundedPerBranch { tooMany = true }
    }

    var prod = childBest
    if q.present && !q.unbounded { prod = mulCapped(childBest, q.max) }
    if prod > cur.best { cur.best = prod }

    let atomMin = child?.min ?? 1
    let atomMax = child?.max ?? 1
    let atomWidth = child?.width ?? 1
    var addMin = atomMin
    var addMax = atomMax
    var addWidth = atomWidth
    if q.present {
      if q.unbounded {
        addMin = satMul(q.min, atomMin)
        addMax = lenCap
      } else {
        addMin = satMul(q.min, atomMin)
        addMax = satMul(q.max, atomMax)
        addWidth = satMul(satPow(atomWidth, q.max), q.max - q.min + 1)
      }
    }
    cur.branchMin = satAdd(cur.branchMin, addMin)
    cur.branchMax = satAdd(cur.branchMax, addMax)
    cur.branchWidth = satMul(cur.branchWidth, addWidth)
    stack[stack.count - 1] = cur
    if tooMany { addOnce(.multipleUnboundedQuantifiers) }
    return after
  }

  /// Reads a quantifier at `i`, including its optional lazy `?`.
  mutating func readQuant(_ i: Int) -> (Quant, Int) {
    guard i < src.count else { return (Quant(), i) }
    switch src[i] {
    case "*": return (Quant(present: true, unbounded: true, min: 0, max: 0), skipLazy(i + 1))
    case "+": return (Quant(present: true, unbounded: true, min: 1, max: 0), skipLazy(i + 1))
    case "?": return (Quant(present: true, unbounded: false, min: 0, max: 1), skipLazy(i + 1))
    case "{": return readBraceQuant(i)
    default: return (Quant(), i)
    }
  }

  func skipLazy(_ i: Int) -> Int { i < src.count && src[i] == "?" ? i + 1 : i }

  static func isDigit(_ c: Unicode.Scalar) -> Bool { c.value >= 0x30 && c.value <= 0x39 }
  static func isHex(_ c: Unicode.Scalar) -> Bool {
    isDigit(c) || (c.value >= 0x61 && c.value <= 0x66) || (c.value >= 0x41 && c.value <= 0x46)
  }

  /// A repetition count as Go's strconv.Atoi reads it: nil when it overflows Int64.
  func count(_ lo: Int, _ hi: Int) -> Int? {
    var v = 0
    for k in lo..<hi {
      let (m, o1) = v.multipliedReportingOverflow(by: 10)
      let (s, o2) = m.addingReportingOverflow(Int(src[k].value - 0x30))
      if o1 || o2 { return nil }
      v = s
    }
    return v
  }

  /// `{n}`, `{n,}` and `{n,m}`; anything else is malformed. A count Go's strconv.Atoi cannot
  /// hold is malformed too (Go's reading; JavaScript would take it as a huge number).
  mutating func readBraceQuant(_ i: Int) -> (Quant, Int) {
    var j = i + 1
    let start = j
    while j < src.count && Self.isDigit(src[j]) { j += 1 }
    if j == start {
      add(i, .malformedRepetition)
      return (Quant(), i + 1)
    }
    guard let lo = count(start, j) else {
      add(i, .malformedRepetition)
      return (Quant(), i + 1)
    }
    if j < src.count && src[j] == "}" {
      return (Quant(present: true, unbounded: false, min: lo, max: lo), skipLazy(j + 1))
    }
    if j >= src.count || src[j] != "," {
      add(i, .malformedRepetition)
      return (Quant(), i + 1)
    }
    j += 1
    let hiStart = j
    while j < src.count && Self.isDigit(src[j]) { j += 1 }
    if j >= src.count || src[j] != "}" {
      add(i, .malformedRepetition)
      return (Quant(), i + 1)
    }
    if hiStart == j { return (Quant(present: true, unbounded: true, min: lo, max: 0), skipLazy(j + 1)) }
    guard let hi = count(hiStart, j) else {
      add(i, .malformedRepetition)
      return (Quant(), i + 1)
    }
    if hi < lo {
      add(i, .malformedRepetition)
      return (Quant(), skipLazy(j + 1))
    }
    return (Quant(present: true, unbounded: false, min: lo, max: hi), skipLazy(j + 1))
  }

  /// The single-character escapes measured identical in RE2 and JavaScript-with-`u`: a
  /// whitelist, so an escape nobody thought about fails closed.
  static let escapeWhitelist = Array("nrtfvdDwW\\.+*?()[]{}|^$/".unicodeScalars)

  /// Validates the escape at `i` (the backslash); returns the index past it.
  mutating func escape(_ i: Int, inClass: Bool) -> Int {
    if i + 1 >= src.count {
      add(i, .malformedEscape)
      return i + 1
    }
    let c = src[i + 1]
    switch c {
    case "s", "S": add(i, .escapePerlSpace)
    case "b", "B": add(i, .escapeWordBoundary)
    case "p", "P": add(i, .escapeUnicodeClass)
    case "u": add(i, .escapeUnicodeCodepoint)
    case "x": return hexEscape(i)
    case "A", "z", "Z": add(i, .escapeTextAnchor)
    case "k": add(i, .escapeBackreference)
    default:
      if Self.isDigit(c) {
        add(i, .escapeBackreference)
      } else if Self.escapeWhitelist.contains(c) {
        // measured identical in both engines
      } else if inClass && c == "-" {
        // `\-` is a valid ClassEscape in JavaScript, and only inside a class
      } else {
        add(i, .escapeNotAllowed)
      }
    }
    return i + 2
  }

  /// `\xHH` is one code point in both engines; `\x{...}` is a SyntaxError in JavaScript.
  mutating func hexEscape(_ i: Int) -> Int {
    if i + 2 < src.count && src[i + 2] == "{" {
      add(i, .escapeUnicodeCodepoint)
      for j in (i + 2)..<src.count where src[j] == "}" { return j + 1 }
      return src.count
    }
    if i + 3 >= src.count || !Self.isHex(src[i + 2]) || !Self.isHex(src[i + 3]) {
      add(i, .malformedEscape)
      return i + 2
    }
    return i + 4
  }

  /// Validates the class at `i` (the `[`); returns the index past it.
  mutating func charClass(_ i: Int) -> Int {
    var j = i + 1
    if j < src.count && src[j] == "^" { j += 1 }
    if j < src.count && src[j] == "]" {
      add(i, .emptyCharClass)
      return j + 1
    }
    while j < src.count {
      switch src[j] {
      case "\\": j = escape(j, inClass: true)
      case "[":
        add(j, .classLiteralBracket)
        j += 1
      case "]": return j + 1
      default: j += 1
      }
    }
    add(i, .unterminatedCharClass)
    return src.count
  }

  /// Validates the group opener at `i`, pushes its frame, returns the index past the opener.
  mutating func openGroup(_ i: Int) -> Int {
    func capture(_ s: inout Scanner) {
      s.captures += 1
      if s.captures > Dialect.maxCaptureGroups { s.addOnce(.tooManyCaptureGroups) }
    }
    if i + 1 >= src.count || src[i + 1] != "?" {
      capture(&self)
      stack.append(Frame())
      return i + 1
    }
    if i + 2 >= src.count {
      add(i, .unsupportedGroup)
      stack.append(Frame())
      return i + 2
    }
    switch src[i + 2] {
    case ":":
      stack.append(Frame())
      return i + 3
    case "=", "!":
      add(i, .lookaround)
      stack.append(Frame())
      return i + 3
    case "<":
      if i + 3 < src.count && (src[i + 3] == "=" || src[i + 3] == "!") {
        add(i, .lookaround)
        stack.append(Frame())
        return i + 4
      }
      add(i, .namedGroupJSSyntax)
      stack.append(Frame())
      return i + 3
    case "P":
      if i + 3 < src.count && src[i + 3] == "<" {
        capture(&self)
        let next = groupName(i + 4)
        stack.append(Frame())
        return next
      }
      add(i, .unsupportedGroup)
      stack.append(Frame())
      return i + 3
    case "#":
      add(i, .unsupportedGroup)
      stack.append(Frame())
      return i + 3
    default:
      add(i, .inlineFlags)
      stack.append(Frame())
      return i + 3
    }
  }

  static func isGroupName(_ name: ArraySlice<Unicode.Scalar>) -> Bool {
    guard let first = name.first else { return false }
    func word(_ c: Unicode.Scalar) -> Bool {
      (c.value >= 0x41 && c.value <= 0x5a) || (c.value >= 0x61 && c.value <= 0x7a) || c == "_"
    }
    guard word(first) else { return false }
    return name.dropFirst().allSatisfy { word($0) || isDigit($0) }
  }

  /// Validates the name starting at `i` (just past `(?P<`).
  mutating func groupName(_ i: Int) -> Int {
    var j = i
    while j < src.count && src[j] != ">" { j += 1 }
    if j >= src.count {
      add(i, .invalidGroupName)
      return src.count
    }
    let name = src[i..<j]
    if !Self.isGroupName(name) { add(i, .invalidGroupName) }
    let text = String(String.UnicodeScalarView(name))
    if names.contains(where: { $0.utf8.elementsEqual(text.utf8) }) { add(i, .duplicateGroupName) }
    names.append(text)
    return j + 1
  }
}
