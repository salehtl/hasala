import Foundation

enum RuleDate {
  static let windowDays: Int64 = 31
  static let localOffsetMs: Int64 = 4 * 3_600_000
  static let msPerDay: Int64 = 86_400_000

  static let monthNames: [(String, Int)] = [
    ("january", 1), ("february", 2), ("march", 3), ("april", 4), ("may", 5), ("june", 6), ("july", 7), ("august", 8),
    ("september", 9), ("october", 10), ("november", 11), ("december", 12), ("jan", 1), ("feb", 2), ("mar", 3),
    ("apr", 4), ("jun", 6), ("jul", 7), ("aug", 8), ("sept", 9), ("sep", 9), ("oct", 10), ("nov", 11), ("dec", 12),
  ]

  static let monthPattern = monthNames.map(\.0).joined(separator: "|")

  static let weekdayNames: [(String, Int)] = [
    ("monday", 1), ("tuesday", 2), ("wednesday", 3), ("thursday", 4), ("friday", 5), ("saturday", 6), ("sunday", 7),
    ("mon", 1), ("tues", 2), ("tue", 2), ("weds", 3), ("wed", 3), ("thurs", 4), ("thur", 4), ("thu", 4), ("fri", 5),
    ("sat", 6), ("sun", 7),
  ]

  static let weekdayPattern = weekdayNames.map(\.0).joined(separator: "|")

  static let arabicMonthNames: [(String, Int)] = [
    ("يناير", 1), ("فبراير", 2), ("مارس", 3), ("أبريل", 4), ("إبريل", 4), ("مايو", 5), ("يونيو", 6), ("يونيه", 6),
    ("يوليو", 7), ("يوليه", 7), ("أغسطس", 8), ("سبتمبر", 9), ("أكتوبر", 10), ("نوفمبر", 11), ("ديسمبر", 12),
    ("كانون الثاني", 1), ("شباط", 2), ("آذار", 3), ("نيسان", 4), ("أيار", 5), ("حزيران", 6), ("تموز", 7), ("آب", 8),
    ("أيلول", 9), ("تشرين الأول", 10), ("تشرين الثاني", 11), ("كانون الأول", 12),
  ]

  static let arabicWeekdayNames: [(String, Int)] = [
    ("الإثنين", 1), ("الاثنين", 1), ("الثلاثاء", 2), ("الأربعاء", 3), ("الخميس", 4), ("الجمعة", 5), ("السبت", 6),
    ("الأحد", 7),
  ]

  static let numeric = RuleText.re("(?<![0-9])([0-9]{1,2})[-/.]([0-9]{1,2})[-/.]([0-9]{4})(?![0-9])")
  static let iso = RuleText.re("(?<![0-9])([0-9]{4})[-/]([0-9]{1,2})[-/]([0-9]{1,2})(?![0-9])")
  static let named = RuleText.re(
    "(?<![0-9])([0-9]{1,2})(?:st|nd|rd|th)?[- ]?(\(monthPattern))\\.?[-, ]+([0-9]{4})(?![0-9])")
  static let namedFirst = RuleText.re(
    "(?<![a-z])(\(monthPattern))\\.?[- ]([0-9]{1,2})(?:st|nd|rd|th)?,?[- ]([0-9]{4})(?![0-9])")
  static let time = RuleText.re(
    "(?<![0-9:])([0-9]{1,2}):([0-9]{2})(?::([0-9]{2}))?(?![0-9:])\\s*(am|pm|a\\.m\\.|p\\.m\\.|ص|م)?(?![a-z\\p{L}])")
  static let dateLabel = RuleText.words(["date", "dated", "on"], ["تاريخ", "التاريخ", "بتاريخ"])

  struct Found {
    var year: Int
    var month: Int
    var day: Int
    var end: Int
  }

  static func stated(_ input: ExtractInput) -> ExtractStatedDate? {
    let receipt = floorDiv(input.receivedAtMs + localOffsetMs, msPerDay)
    let lines = RuleText.cleanLines(input.text)
    var unlabelled: ExtractStatedDate?
    for (i, line) in lines.enumerated() {
      let folded = RuleText.fold(line)
      for f in dates(folded) {
        let d = daysFromCivil(f.year, f.month, f.day)
        guard d <= receipt, receipt - d <= windowDays else { continue }
        let rest = (folded as NSString).substring(from: f.end)
        let minute = minuteOfDay(rest) ?? followingTime(lines, after: i)
        let out = ExtractStatedDate(year: f.year, month: f.month, day: f.day, minuteOfDay: minute)
        let previous = i > 0 ? RuleText.fold(lines[i - 1]) : ""
        if RuleText.has(dateLabel, folded) || RuleText.has(dateLabel, previous) { return out }
        if unlabelled == nil { unlabelled = out }
      }
    }
    return unlabelled
  }

  static func dates(_ s: String) -> [Found] {
    let ns = s as NSString
    let range = NSRange(location: 0, length: ns.length)
    var out: [(Int, Found)] = []
    func int(_ m: NSTextCheckingResult, _ g: Int) -> Int? { Int(ns.substring(with: m.range(at: g))) }
    func month(_ m: NSTextCheckingResult, _ g: Int) -> Int? {
      let name = ns.substring(with: m.range(at: g)).lowercased()
      return monthNames.first { $0.0 == name }?.1
    }
    func add(_ m: NSTextCheckingResult, _ y: Int?, _ mo: Int?, _ d: Int?) {
      guard let y, let mo, let d, valid(y, mo, d) else { return }
      out.append((m.range.location, Found(year: y, month: mo, day: d, end: m.range.location + m.range.length)))
    }
    for m in numeric.matches(in: s, range: range) {
      guard let a = int(m, 1), let b = int(m, 2), let y = int(m, 3) else { continue }
      if valid(y, b, a) { add(m, y, b, a) } else { add(m, y, a, b) }
    }
    for m in iso.matches(in: s, range: range) { add(m, int(m, 1), int(m, 2), int(m, 3)) }
    for m in named.matches(in: s, range: range) { add(m, int(m, 3), month(m, 2), int(m, 1)) }
    for m in namedFirst.matches(in: s, range: range) { add(m, int(m, 3), month(m, 1), int(m, 2)) }
    return out.sorted { $0.0 < $1.0 }.map(\.1)
  }

  static func minuteOfDay(_ s: String) -> Int? {
    let ns = s as NSString
    guard let m = time.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)),
      var h = Int(ns.substring(with: m.range(at: 1))), let mi = Int(ns.substring(with: m.range(at: 2))), mi < 60
    else { return nil }
    if m.range(at: 3).location != NSNotFound, let sec = Int(ns.substring(with: m.range(at: 3))), sec >= 60 { return nil }
    if m.range(at: 4).location != NSNotFound {
      let mark = ns.substring(with: m.range(at: 4)).lowercased()
      guard (1...12).contains(h) else { return nil }
      let pm = mark.hasPrefix("p") || mark == "م"
      if h == 12 { h = 0 }
      if pm { h += 12 }
    }
    guard (0...23).contains(h) else { return nil }
    return h * 60 + mi
  }

  static func followingTime(_ lines: [String], after i: Int) -> Int? {
    var seen = 0
    for line in lines[(i + 1)...] where !line.isEmpty {
      seen += 1
      if seen > 3 { return nil }
      let folded = RuleText.fold(line)
      let ns = folded as NSString
      if let m = time.firstMatch(in: folded, range: NSRange(location: 0, length: ns.length)),
        m.range.location == 0, m.range.length == ns.length
      {
        return minuteOfDay(folded)
      }
    }
    return nil
  }

  static func valid(_ y: Int, _ m: Int, _ d: Int) -> Bool {
    guard (2000...2099).contains(y), (1...12).contains(m), d >= 1 else { return false }
    let leap = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0
    let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    return d <= days[m - 1]
  }

  static func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
    let q = a / b
    return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
  }

  static func daysFromCivil(_ year: Int, _ month: Int, _ day: Int) -> Int64 {
    let y = Int64(month <= 2 ? year - 1 : year)
    let era = (y >= 0 ? y : y - 399) / 400
    let yoe = y - era * 400
    let m = Int64(month)
    let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + Int64(day) - 1
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
    return era * 146_097 + doe - 719_468
  }
}
