import Foundation

enum MerchantWhen {
  static let weekdays =
    "(?:monday|tuesday|wednesday|thursday|friday|saturday|sunday|mon|tues|tue|weds|wed|thurs|thur|thu|fri|sat|sun)"
  static let month = "(?:" + RuleDate.monthPattern + ")"
  static let arWeekdays = "(?:الاثنين|الإثنين|الثلاثاء|الأربعاء|الاربعاء|الخميس|الجمعة|الجمعه|السبت|الأحد|الاحد)"
  static let arMonths =
    "(?:يناير|فبراير|مارس|أبريل|ابريل|إبريل|مايو|يونيو|يوليو|أغسطس|اغسطس|سبتمبر|أكتوبر|اكتوبر|نوفمبر|ديسمبر|كانون الثاني|شباط|آذار|نيسان|أيار|حزيران|تموز|آب|أيلول|تشرين الأول|تشرين الثاني|كانون الأول)"
  static let arDateWords = "(?:بتاريخ|التاريخ|تاريخ|يوم)"
  static let time = RuleDate.time.pattern
  static let year = "(?:[0-9]{4}|[0-9]{2})"

  static let stopEN = "\\s+on\\s+(?:" + weekdays + "(?![a-z])|" + month + "\\.?\\s*\\d)"
  static let stopDate =
    "\\s+(?:[0-9]{1,2}(?:st|nd|rd|th)?[-/ ]" + month + "\\.?,?[-/ ](?:[0-9]{4}|[0-9]{2})(?![0-9])|" + month
    + "\\.?[- ][0-9]{1,2}(?:st|nd|rd|th)?,?[-/ ][0-9]{4}(?![0-9]))"
  static let stopAR = "\\s+" + arDateWords + "(?=\\s*[0-9٠-٩]|\\s+" + arWeekdays + ")"

  static let trailing = RuleText.re(
    "(?:^|\\s+)(?<p>(?:on|dated|date)\\s+)?(?<w>" + weekdays + "(?![a-z])\\.?,?\\s*)?(?:"
      + "(?<d1>[0-9]{1,2})(?:st|nd|rd|th)?[-/ ]" + month + "\\.?(?:,?[-/ ](?<y1>" + year + "))?"
      + "|" + month + "\\.?[- ](?<d2>[0-9]{1,2})(?:st|nd|rd|th)?(?:,?[-/ ](?<y2>" + year + "))?"
      + "|(?<na>[0-9]{1,2})[-/.](?<nb>[0-9]{1,2})[-/.](?<ny>" + year + ")"
      + "|(?<iy>[0-9]{4})[-/](?<im>[0-9]{1,2})[-/](?<id>[0-9]{1,2})"
      + ")?(?:,?\\s*(?:at\\s+|الساعة\\s+)?(?<t>" + time + "))?\\s*$")
  static let trailingWeekday = RuleText.re("(?:^|\\s+)on\\s+" + weekdays + "(?![a-z])\\.?$")
  static let trailingAr = RuleText.re(
    "(?:^|\\s+)(?<p>(?:" + arDateWords + "|في)\\s+)?(?<w>" + arWeekdays + "\\s*[،,]?\\s*)?(?:"
      + "(?<d1>[0-9]{1,2})\\s+" + arMonths + "(?:\\s+(?<y1>[0-9]{4}))?"
      + "|(?<na>[0-9]{1,2})[-/.](?<nb>[0-9]{1,2})[-/.](?<ny>" + year + ")"
      + ")?(?:\\s*[،,]?\\s*(?:الساعة\\s+)?(?<t>" + time + "))?\\s*$")
  static let remnant = RuleText.re(
    "^(?:\\s*(?:on|dated|date|at|" + weekdays + "|" + month + "|" + arDateWords + "|في|" + arWeekdays + "|" + arMonths
      + "|[0-9]{1,4}(?:st|nd|rd|th)?|am|pm)[.,،]?)+\\s*$")
  static let remnantWord = RuleText.re(
    "(?<![a-z])(?:" + weekdays + "|" + month + ")(?![a-z])|" + arDateWords + "|" + arWeekdays + "|" + arMonths)

  static func trim(_ s: String) -> String {
    var v = s.trimmingCharacters(in: .whitespaces)
    while true {
      let c = cutAll(v)
      if c != v {
        v = tidy(c)
        continue
      }
      let p = tidy(v)
      if p != v {
        let c2 = cutAll(p)
        if c2 != p {
          v = tidy(c2)
          continue
        }
      }
      return v
    }
  }

  static func cutAll(_ s: String) -> String {
    var next = s
    for r in [trailingAr, trailingWeekday, trailing] { next = cut(next, r) }
    return next
  }

  static func tidy(_ s: String) -> String {
    var next = s.trimmingCharacters(in: .whitespaces)
    while let l = next.last, l == "." || l == "," || l == ":" || l == ";" || l == "-" || l == "،" { next.removeLast() }
    return next.trimmingCharacters(in: .whitespaces)
  }

  static func trimmed(_ s: String?) -> String? {
    guard let s else { return nil }
    let t = trim(s)
    return t.isEmpty ? nil : t
  }

  static func reconcile(learned l: String?, rules r: String?) -> String? {
    guard let lm = trimmed(l) else { return r }
    guard let rm = r else { return lm }
    if isRemnant(lm) { return rm }
    if lm.count > rm.count, lm.hasPrefix(rm), let c = lm.dropFirst(rm.count).first, c.isWhitespace,
      isRemnant(String(lm.dropFirst(rm.count)))
    {
      return rm
    }
    let known = Set(rm.split(whereSeparator: \.isWhitespace).map { RuleText.fold(String($0)) })
    let words = lm.split(whereSeparator: \.isWhitespace).map(String.init)
    var keep = words.count
    var dated = false
    while keep > 1 {
      let w = words[keep - 1]
      guard !known.contains(RuleText.fold(w)), RuleText.has(remnant, w) else { break }
      if RuleText.has(remnantWord, w) { dated = true }
      keep -= 1
    }
    guard dated else { return lm }
    let out = tidy(words[..<keep].joined(separator: " "))
    return out.isEmpty ? rm : out
  }

  static func isRemnant(_ s: String) -> Bool {
    RuleText.has(remnant, s) && RuleText.has(remnantWord, s)
  }

  static func cut(_ s: String, _ r: NSRegularExpression) -> String {
    let ns = s as NSString
    guard let m = r.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)), m.range.length > 0 else { return s }
    func g(_ name: String) -> String? {
      let rg = m.range(withName: name)
      return rg.location == NSNotFound ? nil : RuleText.asciiDigits(ns.substring(with: rg))
    }
    func n(_ name: String) -> Int? { g(name).flatMap { Int($0) } }
    let lead = g("p") != nil || g("w") != nil
    let hasTime = g("t").map(validTime) ?? false
    if g("t") != nil && !hasTime { return s }
    var date = false
    var hasYear = false
    if let d = n("d1") ?? n("d2") {
      guard (1...31).contains(d) else { return s }
      date = true
      if let y = g("y1") ?? g("y2") {
        guard validYear(y) else { return s }
        hasYear = true
      }
    } else if let a = n("na"), let b = n("nb"), let y = g("ny") {
      guard validYear(y), ((1...31).contains(a) && (1...12).contains(b)) || ((1...12).contains(a) && (1...31).contains(b)) else {
        return s
      }
      date = true
      hasYear = true
    } else if let y = g("iy"), let mo = n("im"), let d = n("id") {
      guard validYear(y), (1...12).contains(mo), (1...31).contains(d) else { return s }
      date = true
      hasYear = true
    }
    let weekdayOnly = !date && !hasTime && g("w") != nil && g("p") != nil
    if r === trailingAr && !date && !weekdayOnly { return s }
    guard date || hasTime || weekdayOnly || r === trailingWeekday else { return s }
    guard lead || hasYear || hasTime || r === trailingWeekday else { return s }
    return ns.substring(to: m.range.location)
  }

  static func validYear(_ y: String) -> Bool {
    guard let v = Int(y) else { return false }
    return y.count == 2 || (1990...2099).contains(v)
  }

  static func validTime(_ t: String) -> Bool {
    let parts = t.split(separator: ":")
    guard parts.count >= 2, let h = Int(parts[0].filter(\.isNumber)), let mi = Int(parts[1].prefix(2)) else { return false }
    return h <= 24 && mi <= 59
  }
}
