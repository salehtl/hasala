import Foundation

struct TextMutation: Mutation {
  let kind: String
  let body: (Mail, Truth) -> String?

  func apply(_ m: Mail, _ t: Truth) -> Variant? {
    guard let text = body(m, t), text != m.text else { return nil }
    var out = m
    out.id = m.id + "~" + kind
    out.text = text
    return Variant(kind: kind, mail: out, truth: t)
  }
}

enum MU {
  static func hash(_ s: String) -> Int {
    var h: UInt64 = 14_695_981_039_346_656_037
    for b in s.utf8 { h = (h ^ UInt64(b)) &* 1_099_511_628_211 }
    return Int(h % 1_000_000_007)
  }

  static func lines(_ s: String) -> [String] { s.components(separatedBy: "\n") }
  static func join(_ l: [String]) -> String { l.joined(separator: "\n") }

  static func isArabicScalar(_ u: Unicode.Scalar) -> Bool { (0x0600...0x06FF).contains(u.value) }

  static func arabicCount(_ s: String) -> Int { s.unicodeScalars.filter(isArabicScalar).count }
  static func latinCount(_ s: String) -> Int {
    s.unicodeScalars.filter { ($0.value >= 65 && $0.value <= 90) || ($0.value >= 97 && $0.value <= 122) }.count
  }

  static func mainIsArabic(_ text: String) -> Bool {
    let ls = lines(text).filter { $0.count > 3 }
    var ar = 0
    var en = 0
    for l in ls {
      let a = arabicCount(l)
      let e = latinCount(l)
      if a > e { ar += 1 } else if e > a { en += 1 }
    }
    return ar > en
  }

  static func normDigits(_ s: String) -> String {
    var out = String.UnicodeScalarView()
    for u in s.unicodeScalars {
      switch u.value {
      case 0x660...0x669: out.append(Unicode.Scalar(u.value - 0x660 + 48)!)
      case 0x6F0...0x6F9: out.append(Unicode.Scalar(u.value - 0x6F0 + 48)!)
      case 0x66B: out.append(".")
      case 0x66C: out.append(",")
      default: out.append(u)
      }
    }
    return String(out)
  }

  static func toArabicIndic(_ s: String) -> String {
    var out = String.UnicodeScalarView()
    for u in s.unicodeScalars {
      if u.value >= 48 && u.value <= 57 { out.append(Unicode.Scalar(u.value - 48 + 0x660)!) } else { out.append(u) }
    }
    return String(out)
  }

  struct Found {
    var range: NSRange
    var number: String
    var intPart: String
    var frac: String
    var hasComma: Bool
  }

  static let numRe = try! NSRegularExpression(pattern: "(?<![0-9.,])([0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)(?:\\.([0-9]+))?(?![0-9])")

  static func findAmount(_ text: String, minor: Int64, currency: String?) -> Found? {
    let norm = normDigits(text) as NSString
    let exp = Hundredths.exponent
    let target = Decimal(minor)
    for r in numRe.matches(in: norm as String, range: NSRange(location: 0, length: norm.length)) {
      let ip = norm.substring(with: r.range(at: 1)).replacingOccurrences(of: ",", with: "")
      let fr = r.range(at: 2).location == NSNotFound ? "" : norm.substring(with: r.range(at: 2))
      guard let v = Decimal(string: fr.isEmpty ? ip : ip + "." + fr) else { continue }
      var scaled = v
      for _ in 0..<exp { scaled *= 10 }
      if scaled == target {
        return Found(
          range: r.range, number: norm.substring(with: r.range), intPart: ip, frac: fr,
          hasComma: norm.substring(with: r.range(at: 1)).contains(","))
      }
    }
    return nil
  }

  static func group(_ ip: String) -> String {
    var out = ""
    for (i, c) in ip.reversed().enumerated() {
      if i > 0 && i % 3 == 0 { out.append(",") }
      out.append(c)
    }
    return String(out.reversed())
  }

  static func amountPresent(_ text: String, minor: Int64, currency: String?) -> Bool {
    findAmount(text, minor: minor, currency: currency) != nil
  }

  static func protect(_ text: String, _ t: Truth, _ f: (String) -> String) -> String {
    guard let mer = t.merchant, !mer.isEmpty, text.contains(mer) else { return f(text) }
    let tok = "\u{1}M\u{1}"
    return f(text.replacingOccurrences(of: mer, with: tok)).replacingOccurrences(of: tok, with: mer)
  }

  static func replacePhrases(_ s: String, _ pairs: [(String, String)]) -> String {
    var cur = s
    for (a, b) in pairs.sorted(by: { $0.0.count > $1.0.count }) {
      guard !a.isEmpty else { continue }
      var r = cur.range(of: a, options: .caseInsensitive)
      var out = ""
      var rest = Substring(cur)
      var base = cur.startIndex
      while let rr = r {
        let before = rr.lowerBound > cur.startIndex ? cur[cur.index(before: rr.lowerBound)] : " "
        let after = rr.upperBound < cur.endIndex ? cur[rr.upperBound] : " "
        let ascii = a.unicodeScalars.allSatisfy { $0.value < 128 }
        let ok = !ascii || (!(before.isLetter || before.isNumber) && !(after.isLetter || after.isNumber))
        out += cur[base..<rr.lowerBound]
        out += ok ? b : String(cur[rr])
        base = rr.upperBound
        rest = cur[base...]
        r = cur.range(of: a, options: .caseInsensitive, range: base..<cur.endIndex)
      }
      out += rest
      cur = out.isEmpty && base == cur.startIndex ? cur : out
    }
    return cur
  }

  static func key(_ l: String) -> String {
    var k = l.trimmingCharacters(in: .whitespaces).lowercased()
    while k.hasSuffix(":") || k.hasSuffix("：") { k.removeLast() }
    return k.trimmingCharacters(in: .whitespaces)
  }

  static func isLabel(_ l: String) -> Bool {
    let k = key(l)
    if k.isEmpty { return false }
    if Lexicon.knownLabels.contains(k) { return true }
    return l.trimmingCharacters(in: .whitespaces).hasSuffix(":") && k.count < 40
  }

  static func pairs(_ ls: [String]) -> [Int] {
    var out: [Int] = []
    var i = 0
    while i + 1 < ls.count {
      let v = ls[i + 1].trimmingCharacters(in: .whitespaces)
      if isLabel(ls[i]) && !v.isEmpty && !isLabel(ls[i + 1]) && !v.hasPrefix("(") {
        out.append(i)
        i += 2
      } else {
        i += 1
      }
    }
    return out
  }
}
