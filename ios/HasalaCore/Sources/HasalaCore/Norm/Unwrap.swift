// Stage 10 of the normalizer: inline-forward unwrapping, a port of norm/unwrap.ts.
//
// The inner Subject, Date and From of an inline forward become the effective ones. All three
// are read out of body text anyone can author: CONTENT, never trust (trust is CoreMail's
// Authentication-Results verdict). Every pattern the twin writes as a regex is hand-coded here
// as a scanner over scalars, with Go's `(?i)` case folding: ASCII letters fold, and so do the
// two non-ASCII scalars whose simple-fold orbit reaches an ASCII letter, U+017F (long s) onto
// `s` and U+212A (Kelvin sign) onto `k`. The twin gets the same folds from its `/iu` regexes.
import CoreTime

struct Forward {
  var from: String
  var subject: String
  /// The raw inner Date value; empty when none was recovered.
  var date: String
  var body: String
  /// A forward MARKER line was present (not that inner headers were recovered).
  var found: Bool
}

enum Unwrap {
  typealias Line = ArraySlice<Unicode.Scalar>

  static func asciiLower(_ c: Unicode.Scalar) -> Unicode.Scalar {
    c.value >= 0x41 && c.value <= 0x5a ? Unicode.Scalar(UInt8(c.value + 0x20)) : c
  }

  /// The scalar a Go `(?i)` pattern built from lower-case ASCII compares `c` as: ASCII upper
  /// case lowered, and U+017F / U+212A, the only non-ASCII members of an ASCII letter's
  /// `unicode.SimpleFold` orbit, mapped onto `s` / `k`.
  static func foldCI(_ c: Unicode.Scalar) -> Unicode.Scalar {
    switch c.value {
    case 0x17f: "s"
    case 0x212a: "k"
    default: asciiLower(c)
    }
  }

  /// Whether `s` at `i` starts with the lower-case ASCII `word`, case-insensitively as a Go
  /// `(?i)` pattern compares it (see `foldCI`).
  static func hasWordCI(_ s: Line, _ i: Int, _ word: String) -> Bool {
    var k = i
    for w in word.unicodeScalars {
      guard k < s.endIndex, foldCI(s[k]) == w else { return false }
      k += 1
    }
    return true
  }

  static func skip(_ s: Line, _ i: Int, _ c: Unicode.Scalar) -> Int {
    var k = i
    while k < s.endIndex, s[k] == c { k += 1 }
    return k
  }

  /// `/^ *(begin forwarded message:|-+ *forwarded message *-+) *$/i`
  static func isForwardMarker(_ s: Line) -> Bool {
    var i = skip(s, s.startIndex, " ")
    if hasWordCI(s, i, "begin forwarded message:") {
      i += 24
    } else {
      let dashes = skip(s, i, "-")
      guard dashes > i else { return false }
      i = skip(s, dashes, " ")
      guard hasWordCI(s, i, "forwarded message") else { return false }
      i = skip(s, i + 17, " ")
      let dashes2 = skip(s, i, "-")
      guard dashes2 > i else { return false }
      i = dashes2
    }
    return skip(s, i, " ") == s.endIndex
  }

  /// `subject.replace(/^ *(fwd?|fw) *: */i, "")`
  static func stripFwdSubject(_ subject: String) -> String {
    let s = NormText.scalars(subject)[...]
    var i = skip(s, 0, " ")
    guard hasWordCI(s, i, "fw") else { return subject }
    i += 2
    if i < s.endIndex, foldCI(s[i]) == "d" { i += 1 }
    i = skip(s, i, " ")
    guard i < s.endIndex, s[i] == ":" else { return subject }
    i = skip(s, i + 1, " ")
    return NormText.string(s[i...])
  }

  static let headerLabels = ["from", "to", "subject", "date", "reply-to", "cc", "sent"]

  /// `/^ *(from|to|subject|date|reply-to|cc|sent) *: *(.*)$/iu`: the lower-cased label and the
  /// value after the colon and its spaces. The label is the MATCHED text lower-cased as Go's
  /// strings.ToLower does it, not the canonical spelling: `ſubject` matches but lowers to
  /// itself, so it is a header line that sets no field. `.` excludes the four JavaScript line terminators,
  /// and `$` (no `m`) is the end of the line, so a value holding CR, U+2028 or U+2029 is no
  /// match at all.
  static func headerLine(_ s: Line) -> (label: String, value: Line)? {
    let i = skip(s, s.startIndex, " ")
    for label in headerLabels where hasWordCI(s, i, label) {
      var k = skip(s, i + label.unicodeScalars.count, " ")
      guard k < s.endIndex, s[k] == ":" else { continue }
      k = skip(s, k + 1, " ")
      let value = s[k...]
      if value.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\u{2028}" || $0 == "\u{2029}" }) { return nil }
      let matched = s[i..<(i + label.unicodeScalars.count)]
      // ToLower: ASCII lowered, U+212A to `k`; U+017F is already lower case and stays.
      let lowered = matched.map { $0.value == 0x212a ? "k" : asciiLower($0) }
      return (NormText.string(lowered), value)
    }
    return nil
  }

  static func trimExplicit(_ s: Line) -> Line {
    var lo = s.startIndex
    var hi = s.endIndex
    while lo < hi, isTrim(s[lo]) { lo += 1 }
    while hi > lo, isTrim(s[hi - 1]) { hi -= 1 }
    return s[lo..<hi]
  }

  static func isTrim(_ c: Unicode.Scalar) -> Bool {
    switch c.value {
    case 0x09...0x0d, 0x20, 0xa0, 0xfeff: true
    default: false
    }
  }

  /// Runs stage 10 over the joined, normalized text.
  static func unwrapForward(from: String, subject: String, body: String) -> Forward {
    let scalars = NormText.scalars(body)
    let lines = NormText.splitLines(scalars)

    guard let marker = lines.firstIndex(where: isForwardMarker) else {
      // Not a forward: strip a leading Fwd:/FW: so a subject_contains still matches.
      return Forward(from: from, subject: stripFwdSubject(subject), date: "", body: body, found: false)
    }

    var recFrom = ""
    var recSubject = ""
    var recDate = ""
    var end = marker + 1
    var sawHeader = false
    var i = marker + 1
    while i < lines.count {
      guard let m = headerLine(lines[i]) else {
        if sawHeader { break }  // the header block ended; the original body starts here
        i += 1  // preamble noise between the marker and the first header
        continue
      }
      sawHeader = true
      var value = trimExplicit(m.value)
      if value.isEmpty {
        // Apple Mail puts the value on the next non-empty line.
        var j = i + 1
        while j < lines.count && trimExplicit(lines[j]).isEmpty { j += 1 }
        if j < lines.count {
          value = trimExplicit(lines[j])
          i = j
        }
      }
      switch m.label {
      case "from": recFrom = NormText.string(value)
      case "subject": recSubject = NormText.string(value)
      case "date": recDate = NormText.string(value)
      default: break
      }
      i += 1
      end = i
    }

    var out = Forward(from: from, subject: subject, date: recDate, body: body, found: true)
    if !recFrom.isEmpty { out.from = recFrom }
    out.subject = recSubject.isEmpty ? stripFwdSubject(subject) : recSubject
    if sawHeader && end < lines.count {
      var joined: [Unicode.Scalar] = []
      for (k, l) in lines[end...].enumerated() {
        if k > 0 { joined.append("\n") }
        joined.append(contentsOf: l)
      }
      out.body = NormText.string(trimExplicit(joined[...]))
    }
    return out
  }

  // MARK: - Forward dates

  static let monthsLong = [
    "january", "february", "march", "april", "may", "june",
    "july", "august", "september", "october", "november", "december",
  ]
  static let monthsShort = monthsLong.map { String($0.unicodeScalars.prefix(3)) }
  static let weekdaysShort = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]

  /// A naive date-time (no zone; read as UTC, as Go's time.Parse does for a zoneless layout).
  struct NaiveDateTime: Equatable {
    let year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int
  }

  /// Field checks of Go's time.Parse. Years are taken literally (0000-9999): the TypeScript
  /// twin's `Date.UTC` would map 0000-0099 to 1900-1999, a JavaScript legacy that Go and this
  /// port do not share.
  static func make(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int) -> NaiveDateTime? {
    if mo < 1 || mo > 12 { return nil }
    if d < 1 || d > Civil.daysInMonth(year: Int64(y), month: mo) { return nil }
    if mi < 0 || mi >= 60 { return nil }
    if s < 0 || s >= 60 { return nil }
    if h < 0 || h >= 24 { return nil }
    return NaiveDateTime(year: y, month: mo, day: d, hour: h, minute: mi, second: s)
  }

  /// A tiny cursor over one candidate, for the four closed layouts.
  struct Cursor {
    let s: [Unicode.Scalar]
    var i = 0

    static func isDigit(_ c: Unicode.Scalar) -> Bool { c.value >= 0x30 && c.value <= 0x39 }
    static func isLetter(_ c: Unicode.Scalar) -> Bool {
      (c.value >= 0x41 && c.value <= 0x5a) || (c.value >= 0x61 && c.value <= 0x7a)
    }

    /// `\d{min,max}` (greedy; the layouts never need it to give digits back).
    mutating func digits(_ min: Int, _ max: Int) -> Int? {
      var n = 0
      var v = 0
      while n < max, i < s.count, Self.isDigit(s[i]) {
        v = v * 10 + Int(s[i].value - 0x30)
        i += 1
        n += 1
      }
      return n >= min ? v : nil
    }

    /// `[A-Za-z]{n}` or, with nil, `[A-Za-z]+`; returned ASCII-lower-cased.
    mutating func letters(_ count: Int?) -> String? {
      var out = String.UnicodeScalarView()
      while i < s.count, Self.isLetter(s[i]), count.map({ out.count < $0 }) ?? true {
        out.append(asciiLower(s[i]))
        i += 1
      }
      if let count, out.count != count { return nil }
      return out.isEmpty ? nil : String(out)
    }

    mutating func lit(_ text: String) -> Bool {
      for c in text.unicodeScalars {
        guard i < s.count, s[i] == c else { return false }
        i += 1
      }
      return true
    }

    mutating func spaces() -> Bool {
      let start = i
      while i < s.count, s[i] == " " { i += 1 }
      return i > start
    }

    mutating func comma() -> Bool { lit(",") && spaces() }

    mutating func at() -> Bool { spaces() && lit("at") && spaces() }

    /// `(AM|PM)`, upper case only (Go's stdPM).
    mutating func ampm() -> String? {
      if lit("AM") { return "AM" }
      if lit("PM") { return "PM" }
      return nil
    }

    var atEnd: Bool { i == s.count }
  }

  static func twelveHour(_ h: Int, _ ampm: String) -> Int? {
    if h < 0 || h > 12 { return nil }  // Go's stdHour12 range check
    if ampm == "PM" && h < 12 { return h + 12 }
    if ampm == "AM" && h == 12 { return 0 }
    return h
  }

  static func layout(_ idx: Int, _ candidate: [Unicode.Scalar]) -> NaiveDateTime? {
    var c = Cursor(s: candidate)
    switch idx {
    case 0:  // Jan 2, 2006 at 3:04 PM
      guard let mon = c.letters(3), c.spaces(), let d = c.digits(1, 2), c.comma(), let y = c.digits(4, 4),
        c.at(), let h = c.digits(1, 2), c.lit(":"), let mi = c.digits(2, 2), c.spaces(),
        let ap = c.ampm(), c.atEnd
      else { return nil }
      guard let month = monthsShort.firstIndex(of: mon), let hh = twelveHour(h, ap) else { return nil }
      return make(y, month + 1, d, hh, mi, 0)
    case 1:  // Mon, Jan 2, 2006 at 3:04 PM
      guard let wd = c.letters(3), c.comma(), let mon = c.letters(3), c.spaces(), let d = c.digits(1, 2),
        c.comma(), let y = c.digits(4, 4), c.at(), let h = c.digits(1, 2), c.lit(":"),
        let mi = c.digits(2, 2), c.spaces(), let ap = c.ampm(), c.atEnd
      else { return nil }
      // Go checks only that the weekday is a known abbreviation, not that it agrees.
      guard weekdaysShort.contains(wd), let month = monthsShort.firstIndex(of: mon), let hh = twelveHour(h, ap)
      else { return nil }
      return make(y, month + 1, d, hh, mi, 0)
    case 2, 3:  // 2 January 2006 at 15:04:05 / 2 January 2006 at 15:04
      guard let d = c.digits(1, 2), c.spaces(), let mon = c.letters(nil), c.spaces(), let y = c.digits(4, 4),
        c.at(), let h = c.digits(1, 2), c.lit(":"), let mi = c.digits(2, 2)
      else { return nil }
      var sec = 0
      if idx == 2 {
        guard c.lit(":"), let s = c.digits(2, 2) else { return nil }
        sec = s
      }
      guard c.atEnd, let month = monthsLong.firstIndex(of: mon) else { return nil }
      return make(y, month + 1, d, h, mi, sec)
    default:
      return nil
    }
  }

  /// Parses a forwarded-header Date value against the four closed layouts, retrying once
  /// without the final space-delimited token (a trailing zone name).
  static func parseForwardDate(_ s: String) -> NaiveDateTime? {
    var normalized = NormText.scalars(NormText.trimExplicit(s))
    for k in normalized.indices where normalized[k] == "\u{202F}" || normalized[k] == "\u{A0}" {
      normalized[k] = " "
    }
    var candidates = [normalized]
    if let lastSpace = normalized.lastIndex(of: " "), lastSpace > 0 {
      candidates.append(Array(trimExplicit(normalized[0..<lastSpace])))
    }
    for c in candidates {
      for i in 0..<4 {
        if let d = layout(i, c) { return d }
      }
    }
    return nil
  }
}
