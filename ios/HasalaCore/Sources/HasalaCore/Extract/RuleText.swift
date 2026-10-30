import Foundation

enum RuleText {
  static func asciiDigits(_ s: String) -> String {
    var out = String.UnicodeScalarView()
    out.reserveCapacity(s.unicodeScalars.count)
    for u in s.unicodeScalars {
      switch u.value {
      case 0x0660...0x0669: out.append(UnicodeScalar(u.value - 0x0660 + 0x30)!)
      case 0x06F0...0x06F9: out.append(UnicodeScalar(u.value - 0x06F0 + 0x30)!)
      case 0x066B: out.append(".")
      case 0x066C: out.append(",")
      case 0x0085, 0x00A0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000: out.append(" ")
      case 0x200B, 0x200C, 0x200D, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069, 0xFEFF: continue
      default: out.append(u)
      }
    }
    return String(out)
  }

  static func fold(_ s: String) -> String {
    var out = String.UnicodeScalarView()
    for u in s.lowercased().unicodeScalars {
      switch u.value {
      case 0x0622, 0x0623, 0x0625, 0x0671: out.append("\u{0627}")
      case 0x0629: out.append("\u{0647}")
      case 0x0649: out.append("\u{064A}")
      case 0x064B...0x0652, 0x0640, 0x0670: continue
      default: out.append(u)
      }
    }
    return String(out)
  }

  static func re(_ p: String) -> NSRegularExpression {
    try! NSRegularExpression(pattern: p, options: [.caseInsensitive])
  }

  static func words(_ en: [String], _ ar: [String] = []) -> NSRegularExpression {
    var parts: [String] = []
    if !en.isEmpty {
      parts.append(
        "(?<![a-z0-9])(?:" + en.map { $0.replacingOccurrences(of: " ", with: "\\s+") }.joined(separator: "|")
          + ")(?![a-z0-9])")
    }
    if !ar.isEmpty { parts.append("(?:" + ar.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|") + ")") }
    return re(parts.joined(separator: "|"))
  }

  static func has(_ r: NSRegularExpression, _ s: String) -> Bool {
    r.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
  }

  static func replace(_ r: NSRegularExpression, _ s: String) -> String {
    r.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: " ")
  }

  static func count(_ r: NSRegularExpression, _ s: String) -> Int {
    r.numberOfMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length))
  }

  static func norm(_ s: String) -> String {
    let up = s.uppercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
    return String(up).split(separator: " ").joined(separator: " ")
  }

  static func clean(_ s: String) -> String {
    var out = ""
    out.reserveCapacity(s.count)
    var space = false
    for ch in s {
      if ch == "\r" || ch == "\t" || ch == " " || ch == "\u{000B}" || ch == "\u{000C}" {
        space = true
        continue
      }
      if space && !out.isEmpty { out.append(" ") }
      space = false
      out.append(ch)
    }
    return out
  }

  static let maxLineUTF16 = 4_096

  static func cleanLines(_ text: String) -> [String] {
    asciiDigits(text).replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
      .map { prefix(clean(String($0)), utf16: maxLineUTF16) }
  }

  static func prefix(_ s: String, utf16 limit: Int) -> String {
    guard s.utf16.count > limit else { return s }
    var out = String.UnicodeScalarView()
    var n = 0
    for u in s.unicodeScalars {
      n += UTF16.width(u)
      if n > limit { break }
      out.append(u)
    }
    return String(out)
  }
}

enum PromoFilter {
  static let promo = RuleText.re(
    "(?<![a-z0-9])(?:earn|earned|win|cashback|cash\\s+back|offers?|discounts?|rewards?|points|save\\s+up|up\\s+to|promo|promotion|exclusive|apply\\s+now|eligible|vouchers?|bonus|free)(?![a-z0-9])|%\\s*off(?![a-z])"
      + "|(?<!\\p{L})(?:وال|بال|فال|لل|ال|و|ب|ل|ف)?(?:اربح|استرداد\\s+نقدي|عرض|عروض|مكافاه|مكافات|نقاط|وفر|قسيمه|حصري|مجانا|احصل)(?!\\p{L})")
  static let posted = RuleText.words(
    [
      "has been", "have been", "was", "were", "debited", "credited", "spent", "paid", "purchased", "used", "transferred",
      "withdrawn", "deducted", "charged", "refunded", "reversed", "purchase of",
    ],
    ["تم ", "تمت", "تم خصم", "تم ايداع"])

  static func isPromo(_ folded: String) -> Bool {
    RuleText.has(promo, folded)
  }

  static func strip(_ text: String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false).filter { line in
      let l = RuleText.fold(String(line))
      guard l.unicodeScalars.contains(where: { CharacterSet.decimalDigits.contains($0) }) else { return true }
      guard isPromo(l) else { return true }
      return RuleText.has(posted, l)
    }.joined(separator: "\n")
  }
}

extension String {
  func extractTrimmingTrailing() -> String {
    var s = Substring(self)
    while let l = s.last, l == " " || l == "\t" { s = s.dropLast() }
    return String(s)
  }

  func extractTrimmingLeading() -> String {
    var s = Substring(self)
    while let f = s.first, f == " " || f == "\t" { s = s.dropFirst() }
    return String(s)
  }
}
