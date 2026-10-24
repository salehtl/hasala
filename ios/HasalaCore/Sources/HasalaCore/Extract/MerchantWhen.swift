import Foundation

enum MerchantWhen {
  static let month = "(?:" + RuleDate.monthPattern + ")"
  static let weekdays = "(?:" + RuleDate.weekdayPattern + ")"
  static let arWeekdays =
    "(?:" + Set(RuleDate.arabicWeekdayNames.flatMap { [$0.0, RuleText.fold($0.0)] }).sorted().joined(separator: "|") + ")"
  static let arDateWords = "(?:بتاريخ|التاريخ|تاريخ|يوم)"

  static let weekdaysLong = "(?:" + RuleDate.weekdayNames.map(\.0).filter { $0.count > 5 }.joined(separator: "|") + ")"
  static let arMonthsRe =
    "(?:" + Set(RuleDate.arabicMonthNames.flatMap { [$0.0, RuleText.fold($0.0)] }).sorted { $0.count > $1.count }.joined(
      separator: "|") + ")"

  static let stopEN =
    "\\s+on\\s+(?:" + weekdaysLong + "(?![a-z])|" + weekdays + "(?=,|\\s+[0-9]|\\.?\\s*$|\\.\\s|\\s*;)|" + month
    + "\\.?\\s+[0-9]{1,2}(?:st|nd|rd|th)?(?![a-z0-9])(?=,?\\s+[0-9]{4}(?![0-9])|\\s*[,.;]|\\s*$|\\s+(?:at\\s+)?[0-9]{1,2}:[0-9]{2}))"
  static let dayRe = "[0-9]{1,2}(?:st|nd|rd|th)?"
  static let monthShort = "(?:" + RuleDate.monthNames.map(\.0).filter { $0.count <= 4 }.joined(separator: "|") + ")"
  static let stopDate =
    "\\s+(?:" + dayRe + "[-/ ]" + month + "\\.?,?[-/ ][0-9]{4}(?![0-9])|[0-9]{1,2}-" + month + "-[0-9]{2}(?![0-9])|" + month
    + "\\.?[- ]" + dayRe + ",?[-/ ][0-9]{4}(?![0-9]))"
  static let stopWeekdayDate =
    "\\s+(?:" + weekdays + "(?![a-z])\\.?,|" + weekdaysLong + "(?![a-z]))\\s+(?=" + dayRe + "[-/ ]" + month + "(?![a-z])|" + month
    + "\\.?[- ][0-9]{1,2}(?![0-9])|[0-9]{1,2}[-/.][0-9]{1,2}[-/.][0-9]{4}(?![0-9]))"
  static let stopDayMonthEnd = "\\s+" + dayRe + "[-/ ]" + monthShort + "\\.?(?=\\s*[.;]?\\s*$|\\.\\s)"
  static let stopAR =
    "\\s+" + arDateWords + "(?=\\s*[0-9]{1,2}\\s+" + arMonthsRe + "|\\s*[0-9]{1,2}[-/.][0-9]{1,2}[-/.](?:[0-9]{4}|[0-9]{2})(?![0-9])|\\s+"
    + arWeekdays + ")"

  static let maxRun = 10

  static let months: [String: Int] = {
    var out: [String: Int] = [:]
    for (n, v) in RuleDate.monthNames { out[n] = v }
    for (n, v) in RuleDate.arabicMonthNames where !n.contains(" ") { out[RuleText.fold(n)] = v }
    return out
  }()
  static let arabicMonthPairs: [String: Int] = {
    var out: [String: Int] = [:]
    for (n, v) in RuleDate.arabicMonthNames where n.contains(" ") { out[RuleText.fold(n)] = v }
    return out
  }()
  static let weekdayFull: Set<String> = Set(RuleDate.weekdayNames.filter { $0.0.count > 5 }.map(\.0))
  static let weekdaysEN: Set<String> = Set(RuleDate.weekdayNames.map(\.0))
  static let weekdaysAR: Set<String> = Set(RuleDate.arabicWeekdayNames.map { RuleText.fold($0.0) })
  static let leadsEN: Set<String> = ["on", "dated", "date", "at"]
  static let leadsAR: Set<String> = Set(["يوم", "تاريخ", "التاريخ", "بتاريخ", "في", "الساعة"].map(RuleText.fold))
  static let connectors: Set<String> = Set(["at", "الساعة"].map(RuleText.fold))
  static let arabicMeridiems: Set<String> = ["ص", "م"]
  static let meridiems: Set<String> = ["am", "pm", "a.m.", "p.m.", "a.m", "p.m", "ص", "م"]

  struct Word {
    var key: String
    var comma: Bool
  }

  static func clean(_ s: String) -> String {
    var out = String.UnicodeScalarView()
    for u in RuleText.asciiDigits(s).unicodeScalars {
      if u.properties.generalCategory == .format || u.value == 0x061C { continue }
      out.append(u)
    }
    return String(out)
  }

  static func tokens(_ s: String) -> [(part: String, word: Word)] {
    clean(s).split(whereSeparator: \.isWhitespace).map { raw in (String(raw), word(String(raw))) }
  }

  static func word(_ raw: String) -> Word {
    var k = RuleText.fold(raw)
    var comma = false
    while let l = k.last, l == "," || l == "،" || l == ";" || l == ":" || (l == "." && !k.hasSuffix(".m.")) {
      if l == "," || l == "،" { comma = true }
      k.removeLast()
    }
    return Word(key: k, comma: comma)
  }

  static func words(_ s: String) -> [Word] {
    tokens(s).map(\.word)
  }

  static func trim(_ s: String) -> String {
    let original = s.trimmingCharacters(in: .whitespaces)
    let toks = tokens(s)
    guard toks.count > 1 else { return original }
    let ws = toks.map(\.word)
    let lo = max(1, ws.count - maxRun)
    for start in lo..<ws.count where parse(ws[start...], introduced: ws[start - 1].comma, atStart: false) == ws.count - start {
      let out = tidy(toks[..<start].map(\.part).joined(separator: " "))
      return out.isEmpty ? original : out
    }
    return original
  }

  static func trimmed(_ s: String?) -> String? {
    guard let s else { return nil }
    let t = trim(s)
    return t.isEmpty ? nil : t
  }

  static func isDateOnly(_ s: String) -> Bool {
    let ws = words(s)
    return !ws.isEmpty && ws.count <= maxRun && parse(ws[...], introduced: false, atStart: true) == ws.count
  }

  static func tidy(_ s: String) -> String {
    var next = s.trimmingCharacters(in: .whitespaces)
    while let l = next.last, l == "." || l == "," || l == ":" || l == ";" || l == "-" || l == "،" { next.removeLast() }
    return next.trimmingCharacters(in: .whitespaces)
  }

  static func parse(_ run: ArraySlice<Word>, introduced: Bool, atStart: Bool) -> Int? {
    let w = Array(run)
    var i = 0
    var lead = false
    if i < w.count, leadsEN.contains(w[i].key) || leadsAR.contains(w[i].key) {
      lead = true
      i += 1
    }
    let open = lead || introduced
    var weekday = false
    var strongWeekday = false
    if i < w.count, weekdaysEN.contains(w[i].key) || weekdaysAR.contains(w[i].key) {
      strongWeekday = w[i].comma || weekdayFull.contains(w[i].key) || weekdaysAR.contains(w[i].key)
      guard open || (atStart && strongWeekday) else { return nil }
      weekday = true
      i += 1
    }
    var date = false
    var year = false
    if let (n, y) = dateAt(w, i) {
      date = true
      year = y
      let monthFirst = monthWord(w[i].key) != nil
      i += n
      if monthFirst, !(open || weekday || atStart || (n == 3 && y) || timeFollows(w, i)) { return nil }
    }
    var time = false
    if i < w.count {
      var j = i
      if date || weekday, connectors.contains(w[j].key) { j += 1 }
      if let n = timeAt(w, j) {
        time = true
        i = j + n
      }
    }
    guard date || time || (weekday && lead && strongWeekday) else { return nil }
    guard lead || year || time || (weekday && strongWeekday) else { return nil }
    return i
  }

  static func timeFollows(_ w: [Word], _ i: Int) -> Bool {
    guard i < w.count else { return false }
    let j = connectors.contains(w[i].key) ? i + 1 : i
    return timeAt(w, j) != nil
  }

  static func day(_ k: String) -> Int? {
    var d = k
    for suf in ["st", "nd", "rd", "th"] where d.hasSuffix(suf) {
      d.removeLast(2)
      break
    }
    guard (1...2).contains(d.count), d.allSatisfy(\.isASCII), let v = Int(d), (1...31).contains(v) else { return nil }
    return v
  }

  static func monthWord(_ k: String) -> Int? {
    let m = k.hasSuffix(".") ? String(k.dropLast()) : k
    return months[m]
  }

  static func fullYear(_ k: String) -> Bool {
    guard k.count == 4, k.allSatisfy(\.isASCII), let v = Int(k) else { return false }
    return (1990...2099).contains(v)
  }

  static func anyYear(_ k: String) -> Bool {
    fullYear(k) || (k.count == 2 && k.allSatisfy { $0.isASCII && $0.isNumber })
  }

  static func dateAt(_ w: [Word], _ i: Int) -> (Int, Bool)? {
    guard i < w.count else { return nil }
    if compound(w[i].key) { return (1, true) }
    func arMonth(_ j: Int) -> Int? {
      guard j < w.count else { return nil }
      if j + 1 < w.count, arabicMonthPairs[w[j].key + " " + w[j + 1].key] != nil { return 2 }
      return monthWord(w[j].key) != nil ? 1 : nil
    }
    func yearAt(_ j: Int) -> Bool { j < w.count && fullYear(w[j].key) }
    if day(w[i].key) != nil, let n = arMonth(i + 1) {
      let after = i + 1 + n
      if yearAt(after) { return (n + 2, true) }
      return (n + 1, false)
    }
    if monthWord(w[i].key) != nil, i + 1 < w.count, day(w[i + 1].key) != nil {
      if i + 2 < w.count, fullYear(w[i + 2].key) { return (3, true) }
      return (2, false)
    }
    return nil
  }

  static func compound(_ k: String) -> Bool {
    let seps: Set<Character> = ["-", "/", "."]
    guard k.contains(where: { seps.contains($0) }) else { return false }
    let p = k.split(omittingEmptySubsequences: false, whereSeparator: { seps.contains($0) }).map(String.init)
    guard p.count == 3 else { return false }
    func small(_ x: String) -> Int? {
      guard (1...2).contains(x.count), x.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
      return Int(x)
    }
    if fullYear(p[0]), let mo = small(p[1]), (1...12).contains(mo), let d = small(p[2]), (1...31).contains(d) { return true }
    guard let a = small(p[0]), (1...31).contains(a) else { return false }
    if monthWord(p[1]) != nil { return anyYear(p[2]) }
    guard fullYear(p[2]) else { return false }
    guard let b = small(p[1]) else { return false }
    return (1...12).contains(b) || ((1...12).contains(a) && (1...31).contains(b))
  }

  static func timeAt(_ w: [Word], _ i: Int) -> Int? {
    guard i < w.count else { return nil }
    var k = w[i].key
    var mer = false
    for m in ["a.m.", "p.m.", "am", "pm"] where k.hasSuffix(m) && k.count > m.count {
      k.removeLast(m.count)
      mer = true
      break
    }
    let p = k.split(separator: ":", omittingEmptySubsequences: false)
    guard (2...3).contains(p.count), p.allSatisfy({ !$0.isEmpty && $0.count <= 2 && $0.allSatisfy { $0.isASCII && $0.isNumber } }),
      let h = Int(p[0]), let mi = Int(p[1]), p[1].count == 2, mi <= 59
    else { return nil }
    if p.count == 3 { guard let sec = Int(p[2]), sec <= 59, p[2].count == 2 else { return nil } }
    var n = 1
    var arabic = false
    if !mer, i + 1 < w.count, meridiems.contains(w[i + 1].key) {
      arabic = arabicMeridiems.contains(w[i + 1].key)
      mer = !arabic
      n = 2
    }
    guard mer ? (1...12).contains(h) : (0...23).contains(h) else { return nil }
    return n
  }

  static func reconcile(learned l: String?, rules r: String?, text: String = "") -> String? {
    guard let lm = l else { return r }
    let parts = tokens(lm).map(\.part)
    var keep = parts.count
    while keep > 0, keep > parts.count - 3 {
      let k = word(parts[keep - 1]).key
      guard monthWord(k) != nil || weekdaysEN.contains(k) || weekdaysAR.contains(k) || leadsEN.contains(k) || leadsAR.contains(k)
      else { break }
      keep -= 1
    }
    guard keep < parts.count else { return lm }
    let tail = parts[keep...].joined(separator: " ")
    let tailCount = parts.count - keep
    let prevComma = keep > 0 && word(parts[keep - 1]).comma
    guard let after = following(lm, in: text) else { return lm }
    let run = words(tail + " " + after)
    guard let n = parse(run[...], introduced: prevComma, atStart: keep == 0), n > tailCount else { return lm }
    if keep == 0 { return r ?? lm }
    let out = tidy(parts[..<keep].joined(separator: " "))
    return out.isEmpty ? (r ?? lm) : out
  }

  static func following(_ s: String, in text: String) -> String? {
    let t = RuleText.asciiDigits(text)
    let needle = RuleText.asciiDigits(s)
    guard !needle.isEmpty, let r = t.range(of: needle, options: [.caseInsensitive]) else { return nil }
    let rest = t[r.upperBound...].prefix { $0 != "\n" }
    guard let first = rest.first, first.isWhitespace || first == "," || first == "." || first == "،" else { return nil }
    let next = rest.split(whereSeparator: \.isWhitespace).prefix(5).joined(separator: " ")
    return next.isEmpty ? nil : next
  }
}
