import Foundation

struct RuleMoney {
  var line: Int
  var start: Int
  var end: Int
  var minor: Int64
  var currency: String
  var explicit: Bool
  var grouped: Bool
  var decimals: Int
  var badScale: Bool
}

enum RuleMoneyParser {
  static let codes: [String: Int] = [
    "AED": 2, "USD": 2, "EUR": 2, "GBP": 2, "SAR": 2, "QAR": 2, "KWD": 3, "BHD": 3, "OMR": 3, "JOD": 3, "IQD": 3, "LYD": 3,
    "TND": 3, "JPY": 0, "KRW": 0, "VND": 0, "CLP": 0, "ISK": 0, "UGX": 0, "XOF": 0, "XAF": 0, "INR": 2, "PKR": 2, "LKR": 2,
    "NPR": 2, "BDT": 2, "EGP": 2, "LBP": 2, "MAD": 2, "TRY": 2, "CHF": 2, "CAD": 2, "AUD": 2, "NZD": 2, "SGD": 2, "HKD": 2,
    "CNY": 2, "THB": 2, "PHP": 2, "MYR": 2, "IDR": 2, "ZAR": 2, "SEK": 2, "NOK": 2, "DKK": 2, "PLN": 2, "CZK": 2, "HUF": 2,
    "RUB": 2, "BRL": 2, "MXN": 2, "KES": 2, "NGN": 2, "GEL": 2, "AZN": 2, "KZT": 2, "UZS": 2, "TWD": 2, "MVR": 2, "SCR": 2,
    "MUR": 2, "ILS": 2, "RON": 2, "BGN": 2, "UAH": 2, "ARS": 2, "COP": 2, "PEN": 2, "ETB": 2, "TZS": 2, "GHS": 2, "SYP": 2,
    "YER": 2, "SDG": 2, "AFN": 2, "IRR": 2, "AMD": 2, "CNH": 2,
  ]

  static let words: [(String, String)] = [
    ("د.إ.", "AED"), ("د.إ", "AED"), ("دراهم", "AED"), ("درهم", "AED"), ("dhs.", "AED"), ("dhs", "AED"), ("dh.", "AED"),
    ("dh", "AED"), ("dirhams", "AED"), ("dirham", "AED"), ("us$", "USD"), ("$", "USD"), ("€", "EUR"), ("£", "GBP"), ("₹", "INR"),
    ("¥", "JPY"), ("دولار امريكي", "USD"), ("دولار أمريكي", "USD"), ("دولار", "USD"), ("يورو", "EUR"), ("جنيه استرليني", "GBP"),
    ("ريال سعودي", "SAR"), ("ريال قطري", "QAR"), ("ريال عماني", "OMR"), ("دينار كويتي", "KWD"), ("دينار بحريني", "BHD"),
    ("دينار أردني", "JOD"), ("روبية", "INR"), ("ريال", "SAR"), ("دينار", "KWD"),
  ]

  static let number = try! NSRegularExpression(
    pattern: "(?<![\\d.,/:\\-*#])(\\d{1,3}(?:,\\d{3})+(?:\\.\\d+)?|\\d+(?:\\.\\d+)?)(?![\\d%/*#]|[.,]\\d|:\\d|-\\d)")

  static let codeBefore = try! NSRegularExpression(pattern: "(?:^|[^A-Za-z])([A-Za-z]{3})\\.?\\s{0,2}$")
  static let codeAfter = try! NSRegularExpression(pattern: "^\\s{0,2}([A-Za-z]{3})(?![A-Za-z])")

  static let code3 = try! NSRegularExpression(pattern: "(?<![A-Za-z])([A-Za-z]{3})(?![A-Za-z])")

  static func exponent(_ c: String) -> Int { codes[c] ?? 2 }

  static func currencyBefore(_ s: String) -> String? {
    let t = s.trimmingTrailing()
    if s.count - t.count > 2 { return nil }
    let ns = s as NSString
    if let m = codeBefore.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) {
      let c = ns.substring(with: m.range(at: 1)).uppercased()
      if codes[c] != nil { return c }
    }
    let low = t.lowercased()
    for (w, c) in words where low.hasSuffix(w) {
      let head = low.dropLast(w.count)
      if w.first!.isLetter && w.first!.isASCII, let p = head.last, p.isLetter { continue }
      return c
    }
    return nil
  }

  static func currencyAfter(_ s: String) -> String? {
    let ns = s as NSString
    if let m = codeAfter.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) {
      let c = ns.substring(with: m.range(at: 1)).uppercased()
      if codes[c] != nil { return c }
    }
    let low = s.trimmingLeading().lowercased()
    guard s.count - low.count <= 2 else { return nil }
    for (w, c) in words where low.hasPrefix(w) {
      let tail = low.dropFirst(w.count)
      if w.first!.isASCII && w.first!.isLetter, let n = tail.first, n.isLetter { continue }
      return c
    }
    return nil
  }

  static func scan(_ text: String, line: Int, labelCurrency: String?) -> [RuleMoney] {
    let ns = text as NSString
    var out: [RuleMoney] = []
    for m in number.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
      let r = m.range(at: 1)
      let before = ns.substring(to: r.location)
      let after = ns.substring(from: r.location + r.length)
      var cur = currencyBefore(before)
      if cur == nil { cur = currencyAfter(after) }
      if cur == nil {
        if let p = before.last, p.isLetter { continue }
        if let n = after.first, n.isLetter { continue }
      }
      let raw = ns.substring(with: r)
      let grouped = raw.contains(",")
      let parts = raw.replacingOccurrences(of: ",", with: "").split(separator: ".", omittingEmptySubsequences: false)
      let intPart = String(parts[0])
      let frac = parts.count > 1 ? String(parts[1]) : ""
      if intPart.count > 13 { continue }
      let explicit = cur != nil
      let c = cur ?? labelCurrency ?? "AED"
      let e = exponent(c)
      var f = frac
      var bad = false
      if f.count > e {
        let extra = f.dropFirst(e)
        if extra.contains(where: { $0 != "0" }) { bad = true }
        f = String(f.prefix(e))
      }
      while f.count < e { f += "0" }
      guard let iv = Int64(intPart) else { continue }
      var scale: Int64 = 1
      for _ in 0..<e { scale *= 10 }
      let fv = f.isEmpty ? 0 : (Int64(f) ?? 0)
      out.append(
        RuleMoney(
          line: line, start: r.location, end: r.location + r.length, minor: iv * scale + fv, currency: c,
          explicit: explicit || labelCurrency != nil, grouped: grouped, decimals: frac.count, badScale: bad))
    }
    return out
  }

  static func labelCurrency(_ s: String) -> String? {
    let ns = s as NSString
    for m in code3.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
      let c = ns.substring(with: m.range(at: 1))
      if c == c.uppercased(), codes[c] != nil { return c }
    }
    let low = s.lowercased()
    for (w, c) in words where w.count > 1 && low.contains(w) {
      if w.first!.isASCII { continue }
      return c
    }
    return nil
  }
}

extension String {
  func trimmingTrailing() -> String {
    var s = Substring(self)
    while let l = s.last, l == " " || l == "\t" { s = s.dropLast() }
    return String(s)
  }

  func trimmingLeading() -> String {
    var s = Substring(self)
    while let f = s.first, f == " " || f == "\t" { s = s.dropFirst() }
    return String(s)
  }
}
