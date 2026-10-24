import Foundation

enum MerchantWhen {
  static let month = "(?:" + RuleDate.monthPattern + ")"
  static let weekdays = "(?:" + RuleDate.weekdayPattern + ")"
  static let arWeekdays =
    "(?:" + Set(RuleDate.arabicWeekdayNames.flatMap { [$0.0, RuleText.fold($0.0)] }).sorted().joined(separator: "|") + ")"
  static let arDateWords = "(?:بتاريخ|التاريخ|تاريخ|يوم)"

  static let stopEN = "\\s+on\\s+(?:" + weekdays + "(?![a-z])|" + month + "\\.?\\s*\\d)"
  static let stopDate =
    "\\s+(?:[0-9]{1,2}(?:st|nd|rd|th)?[-/ ]" + month + "\\.?,?[-/ ](?:[0-9]{4}|[0-9]{2})(?![0-9])|" + month
    + "\\.?[- ][0-9]{1,2}(?:st|nd|rd|th)?,?[-/ ][0-9]{4}(?![0-9]))"
  static let stopAR = "\\s+" + arDateWords + "(?=\\s*[0-9]|\\s+" + arWeekdays + ")"

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
  static let meridiems: Set<String> = ["am", "pm", "a.m.", "p.m.", "a.m", "p.m", "ص", "م"]

  struct Word {
    var key: String
    var comma: Bool
  }

  static func words(_ s: String) -> [Word] {
    RuleText.asciiDigits(s).split(whereSeparator: \.isWhitespace).map { raw in
      var k = RuleText.fold(String(raw))
      var comma = false
      while let l = k.last, l == "," || l == "،" || l == ";" || l == ":" || (l == "." && !k.hasSuffix(".m.")) {
        if l == "," || l == "،" { comma = true }
        k.removeLast()
      }
      return Word(key: k, comma: comma)
    }
  }

  static func trim(_ s: String) -> String {
    let parts = s.split(whereSeparator: \.isWhitespace)
    guard parts.count > 1 else { return s.trimmingCharacters(in: .whitespaces) }
    let ws = words(s)
    let lo = max(1, ws.count - maxRun)
    for start in lo..<ws.count where isWhen(ws[start...]) {
      let out = tidy(parts[..<start].joined(separator: " "))
      return out.isEmpty ? s.trimmingCharacters(in: .whitespaces) : out
    }
    return s.trimmingCharacters(in: .whitespaces)
  }

  static func trimmed(_ s: String?) -> String? {
    guard let s else { return nil }
    let t = trim(s)
    return t.isEmpty ? nil : t
  }

  static func isDateOnly(_ s: String) -> Bool {
    let ws = words(s)
    return !ws.isEmpty && ws.count <= maxRun && isWhen(ws[...])
  }

  static func tidy(_ s: String) -> String {
    var next = s.trimmingCharacters(in: .whitespaces)
    while let l = next.last, l == "." || l == "," || l == ":" || l == ";" || l == "-" || l == "،" { next.removeLast() }
    return next.trimmingCharacters(in: .whitespaces)
  }

  static func isWhen(_ run: ArraySlice<Word>) -> Bool {
    let w = Array(run)
    var i = 0
    var lead = false
    if i < w.count, leadsEN.contains(w[i].key) || leadsAR.contains(w[i].key) {
      lead = true
      i += 1
    }
    var weekday = false
    var strongWeekday = false
    if i < w.count, weekdaysEN.contains(w[i].key) || weekdaysAR.contains(w[i].key) {
      weekday = true
      strongWeekday = w[i].comma || weekdayFull.contains(w[i].key) || weekdaysAR.contains(w[i].key)
      if !strongWeekday && !lead { return false }
      i += 1
    }
    var date = false
    var year = false
    if let (n, y) = dateAt(w, i) {
      date = true
      year = y
      i += n
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
    guard i == w.count, date || time || (weekday && lead && strongWeekday) else { return false }
    return lead || year || time || (weekday && strongWeekday)
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
    func yearAt(_ j: Int) -> Bool { j < w.count && anyYear(w[j].key) }
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
    guard anyYear(p[2]), let a = small(p[0]), (1...31).contains(a) else { return false }
    if monthWord(p[1]) != nil { return true }
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
    if !mer, i + 1 < w.count, meridiems.contains(w[i + 1].key) {
      mer = true
      n = 2
    }
    guard mer ? (1...12).contains(h) : (0...23).contains(h) else { return nil }
    return n
  }

  static func reconcile(learned l: String?, rules r: String?, text: String = "") -> String? {
    guard let lm = trimmed(l) else { return r }
    let parts = lm.split(whereSeparator: \.isWhitespace).map(String.init)
    var keep = parts.count
    while keep > 0 {
      let k = words(parts[keep - 1]).first?.key ?? ""
      guard monthWord(k) != nil || weekdaysEN.contains(k) || weekdaysAR.contains(k) || leadsEN.contains(k) else { break }
      keep -= 1
    }
    guard keep < parts.count, followedByDay(lm, in: text) else { return lm }
    if keep == 0 { return r ?? lm }
    let out = tidy(parts[..<keep].joined(separator: " "))
    return out.isEmpty ? (r ?? lm) : out
  }

  static func followedByDay(_ s: String, in text: String) -> Bool {
    let t = RuleText.asciiDigits(text)
    let needle = RuleText.asciiDigits(s)
    guard !needle.isEmpty else { return false }
    var from = t.startIndex
    while let r = t.range(of: needle, options: [.caseInsensitive], range: from..<t.endIndex) {
      var i = r.upperBound
      if i < t.endIndex, t[i] == "." || t[i] == "," || t[i] == "،" { i = t.index(after: i) }
      var spaced = false
      while i < t.endIndex, t[i] == " " {
        spaced = true
        i = t.index(after: i)
      }
      if spaced, i < t.endIndex, t[i].isASCII, t[i].isNumber { return true }
      from = r.upperBound
    }
    return false
  }
}
