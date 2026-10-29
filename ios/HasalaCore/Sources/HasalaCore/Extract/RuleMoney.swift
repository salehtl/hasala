import Foundation

enum Exponent {
  static let threeDecimals: Set<String> = ["BHD", "IQD", "JOD", "KWD", "LYD", "OMR", "TND"]
  static let noDecimals: Set<String> = [
    "BIF", "CLP", "DJF", "GNF", "ISK", "JPY", "KMF", "KRW", "PYG", "RWF", "UGX", "UYI", "VND", "VUV", "XAF", "XOF", "XPF",
  ]

  static func of(_ c: String) -> Int {
    if threeDecimals.contains(c) { return 3 }
    if noDecimals.contains(c) { return 0 }
    return 2
  }
}

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
  static let codes: Set<String> = [
    "AED", "USD", "EUR", "GBP", "SAR", "QAR", "KWD", "BHD", "OMR", "JOD", "IQD", "LYD", "TND", "JPY", "KRW", "VND",
    "CLP", "ISK", "UGX", "XOF", "XAF", "INR", "PKR", "LKR", "NPR", "BDT", "EGP", "LBP", "MAD", "TRY", "CHF", "CAD",
    "AUD", "NZD", "SGD", "HKD", "CNY", "THB", "PHP", "MYR", "IDR", "ZAR", "SEK", "NOK", "DKK", "PLN", "CZK", "HUF",
    "RUB", "BRL", "MXN", "KES", "NGN", "GEL", "AZN", "KZT", "UZS", "TWD", "MVR", "SCR", "MUR", "ILS", "RON", "BGN",
    "UAH", "ARS", "COP", "PEN", "ETB", "TZS", "GHS", "SYP", "YER", "SDG", "AFN", "IRR", "AMD", "CNH",
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

  static func currencyBefore(_ s: String) -> String? {
    let t = s.extractTrimmingTrailing()
    if s.count - t.count > 2 { return nil }
    let ns = s as NSString
    if let m = codeBefore.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) {
      let c = ns.substring(with: m.range(at: 1)).uppercased()
      if codes.contains(c) { return c }
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
      if codes.contains(c) { return c }
    }
    let low = s.extractTrimmingLeading().lowercased()
    guard s.count - low.count <= 2 else { return nil }
    for (w, c) in words where low.hasPrefix(w) {
      let tail = low.dropFirst(w.count)
      if w.first!.isASCII && w.first!.isLetter, let n = tail.first, n.isLetter { continue }
      return c
    }
    return nil
  }

  static let window = 64

  static func scan(_ text: String, line: Int, labelCurrency: String?) -> [RuleMoney] {
    let ns = text as NSString
    var out: [RuleMoney] = []
    for m in number.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
      let r = m.range(at: 1)
      let back = min(r.location, window)
      let before = ns.substring(with: NSRange(location: r.location - back, length: back))
      let end = r.location + r.length
      let after = ns.substring(with: NSRange(location: end, length: min(ns.length - end, window)))
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
      let e = Exponent.of(c)
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
      if c == c.uppercased(), codes.contains(c) { return c }
    }
    let low = s.lowercased()
    for (w, c) in words where w.count > 1 && low.contains(w) {
      if w.first!.isASCII { continue }
      return c
    }
    return nil
  }
}

