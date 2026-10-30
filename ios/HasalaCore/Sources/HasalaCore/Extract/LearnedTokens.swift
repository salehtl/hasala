import Foundation

enum IClass: Int, Codable, Sendable {
  case word, punct, nl, money, num, cur
}

struct IToken {
  var raw: String
  var key: String
  var cls: IClass
  var line: Int
  var spaceBefore: Bool
  var code: Int32 = 0
}

struct IInterner {
  var map: [String: Int32] = [:]
  mutating func code(_ s: String) -> Int32 {
    if let c = map[s] { return c }
    let c = Int32(map.count + 1)
    map[s] = c
    return c
  }
}

enum ILex {
  static let moneyCode: Int32 = -1
  static let numCode: Int32 = -2
  static let curCode: Int32 = -3
  static let gapCode: Int32 = Int32.min
  static let nlKey = "\u{23CE}"
  static let subjKey = "\u{00A7}s"

  static func typedCode(_ cls: IClass) -> Int32 {
    switch cls {
    case .money: moneyCode
    case .num: numCode
    default: curCode
    }
  }

  static func code(_ cls: IClass, _ key: String, _ interner: inout IInterner) -> Int32 {
    switch cls {
    case .money, .num, .cur: typedCode(cls)
    default: interner.code(LayoutCodec.shapeKey(key, cls))
    }
  }

  static let iso: Set<String> = [
    "AED", "USD", "EUR", "GBP", "SAR", "QAR", "KWD", "BHD", "OMR", "JOD", "JPY", "INR", "PKR", "EGP", "CHF", "CAD", "AUD",
    "CNY", "SGD", "HKD", "TRY", "LKR", "PHP", "THB", "MYR", "IDR", "KRW", "NZD", "ZAR", "SEK", "NOK", "DKK", "RUB", "BDT",
    "NPR", "MAD", "TND", "LBP", "IQD", "LYD", "CNH", "MXN", "BRL", "PLN", "CZK", "HUF", "ILS", "KES", "NGN", "VND", "TWD",
  ]
  static let aedAliases: Set<String> = ["dhs", "dh", "dhs.", "درهم", "د.إ", "دراهم", "aed."]

  static func currency(_ raw: String) -> String? {
    let u = raw.uppercased()
    if iso.contains(u) { return u }
    if aedAliases.contains(raw.lowercased()) { return "AED" }
    return nil
  }

  static let debitWords: Set<String> = [
    "debited", "debit", "withdrawn", "withdrawal", "deducted", "purchase", "purchased", "spent", "paid", "payment", "charged",
    "sent", "transferred", "transfer", "atm", "withdraw", "خصم", "شراء", "مشتريات", "سحب", "تحويل", "دفع", "الدفع", "مدين",
    "الخصم", "الشراء", "السحب", "التحويل", "مدفوعات",
  ]
  static let creditWords: Set<String> = [
    "credited", "credit", "deposited", "deposit", "refund", "refunded", "reversed", "reversal", "received", "returned",
    "إيداع", "ايداع", "إرجاع", "ارجاع", "استرداد", "دائن", "مسترد", "الإيداع", "الايداع", "استرجاع", "إضافة", "اضافة",
  ]
  static let txWords: Set<String> = ["transaction", "amount", "المبلغ", "مبلغ", "معاملة", "المعاملة", "عملية"]
  static let excludeWords: Set<String> = [
    "otp", "password", "passcode", "verification", "declined", "unsuccessful", "failed", "rejected", "رفض", "مرفوضة", "رمز",
    "activation", "activate", "activated", "pin", "المرور", "التحقق", "رفضت", "تفعيل", "statement", "reminder", "كشف",
  ]
  static let balanceWords: Set<String> = [
    "balance", "bal", "available", "avl", "avail", "limit", "outstanding", "due", "minimum", "رصيد", "الرصيد", "المتاح",
    "متاح", "الحد", "المستحق", "total",
  ]
  static let amountWords: Set<String> = [
    "amount", "المبلغ", "مبلغ", "of", "value", "debited", "credited", "purchase", "spent", "sum", "withdrawn", "deducted",
    "deposited", "paid", "transferred",
  ]
  static let merchantLabels: Set<String> = [
    "at", "to", "merchant", "beneficiary", "payee", "الى", "إلى", "لدى", "التاجر", "المستفيد", "description", "المعاملة",
    "name", "towards", "@", "in", "بقيمة", "لصالح", "from",
  ]
  static let greetWords: Set<String> = ["dear", "عزيزي", "hello", "hi", "مرحبا", "عزيزتي", "السيد", "mr", "ms", "mrs"]
  static let functionWords: Set<String> = [
    "the", "a", "an", "of", "on", "in", "at", "to", "from", "your", "you", "with", "for", "has", "have", "been", "was", "is",
    "are", "and", "or", "by", "via", "using", "card", "account", "a/c", "ending", "no", "number", "made", "this", "that",
    "acct", "ac", "ref", "date", "time", "من", "على", "في", "الى", "إلى", "عن", "مع", "بطاقة", "حساب", "رقم", "تم", "بتاريخ",
    "dear", "customer", "it", "we", "our",
  ]

  static let fieldNames: Set<String> = [
    "reference", "ref", "status", "number", "no", "date", "time", "balance", "amount", "account", "card", "details", "type",
    "المرجعي", "الرقم", "الحالة", "التاريخ", "المبلغ", "الحساب", "البطاقة", "رقم",
  ]

  static func isLabelish(_ k: String) -> Bool {
    debitWords.contains(k) || creditWords.contains(k) || txWords.contains(k) || balanceWords.contains(k)
      || merchantLabels.contains(k) || functionWords.contains(k) || greetWords.contains(k)
  }

  static let layoutWords: Set<String> = debitWords.union(creditWords).union(txWords).union(balanceWords).union(amountWords)
    .union(merchantLabels).union(greetWords).union(functionWords).union(fieldNames).union(IAlign.strongLabels)

  static func direction(_ k: String) -> String? {
    if debitWords.contains(k) { return "debit" }
    if creditWords.contains(k) { return "credit" }
    return nil
  }
}

enum ITokenizer {
  static let leadPunct: Set<Character> = ["(", "[", "{", "\"", "'", "<", "\u{201C}", "\u{2018}"]
  static let trailPunct: Set<Character> = [
    ".", ",", ":", ";", ")", "]", "}", "!", "?", "\"", "'", ">", "\u{060C}", "\u{061B}", "\u{201D}", "\u{2019}", "-",
  ]

  static func digitsNormalized(_ s: String) -> String {
    var out = ""
    out.reserveCapacity(s.count)
    for u in s.unicodeScalars {
      switch u.value {
      case 0x0660...0x0669: out.unicodeScalars.append(Unicode.Scalar(u.value - 0x0660 + 48)!)
      case 0x06F0...0x06F9: out.unicodeScalars.append(Unicode.Scalar(u.value - 0x06F0 + 48)!)
      case 0x066B: out.append(".")
      case 0x066C: out.append(",")
      case 0x0D, 0x09, 0xA0, 0x200F, 0x200E: out.append(" ")
      default: out.unicodeScalars.append(u)
      }
    }
    return out
  }

  static func isMoneyShape(_ s: String) -> Bool {
    let c = Array(s.utf8)
    if c.isEmpty { return false }
    var i = 0
    var intDigits = 0
    var groups = 0
    var groupLen = 0
    while i < c.count, c[i] >= 48 && c[i] <= 57 || c[i] == 44 {
      if c[i] == 44 {
        if intDigits == 0 { return false }
        if groups > 0 && groupLen != 3 { return false }
        if groups == 0 && groupLen > 3 { return false }
        groups += 1
        groupLen = 0
      } else {
        intDigits += 1
        groupLen += 1
      }
      i += 1
    }
    if intDigits == 0 { return false }
    if groups > 0 && groupLen != 3 { return false }
    if i == c.count { return false }
    guard c[i] == 46 else { return false }
    i += 1
    let fracStart = i
    while i < c.count, c[i] >= 48 && c[i] <= 57 { i += 1 }
    let frac = i - fracStart
    return i == c.count && frac >= 1 && frac <= 3
  }

  static func isPlainInt(_ s: String) -> Bool {
    let c = Array(s.utf8)
    if c.isEmpty || c.count > 12 { return false }
    var groups = 0
    var groupLen = 0
    var digits = 0
    for b in c {
      if b == 44 {
        if digits == 0 || (groups > 0 && groupLen != 3) || (groups == 0 && groupLen > 3) { return false }
        groups += 1
        groupLen = 0
      } else if b >= 48 && b <= 57 {
        digits += 1
        groupLen += 1
      } else {
        return false
      }
    }
    return !(groups > 0 && groupLen != 3)
  }

  static func splitGlued(_ w: String) -> [String] {
    let chars = Array(w)
    guard chars.count >= 4 else { return [w] }
    if let firstDigit = chars.firstIndex(where: { $0.isASCII && $0.isNumber }), firstDigit == 3 {
      let pre = String(chars[0..<3])
      let rest = String(chars[3...])
      if ILex.currency(pre) != nil, isMoneyShape(rest) || isPlainInt(rest) { return [pre, rest] }
    }
    if chars.count > 3 {
      let suf = String(chars[(chars.count - 3)...])
      let rest = String(chars[0..<(chars.count - 3)])
      if ILex.currency(suf) != nil, isMoneyShape(rest) || isPlainInt(rest) { return [rest, suf] }
    }
    return [w]
  }

  static func tokenize(subject: String, text: String, interner: inout IInterner, cap: Int = LearnedLayouts.tokenLimitPerMail) -> [IToken] {
    var out: [IToken] = []
    var lineNo = 0
    func emitLine(_ line: String, subject: Bool) {
      let norm = digitsNormalized(line)
      let words = norm.split(whereSeparator: { $0 == " " || $0 == "\u{2003}" || $0 == "\u{2002}" || $0 == "\u{3000}" })
      if words.isEmpty && !subject { return }
      var lineToks: [IToken] = []
      if subject { lineToks.append(IToken(raw: ILex.subjKey, key: ILex.subjKey, cls: .word, line: lineNo, spaceBefore: false)) }
      for w0 in words {
        var w = Substring(w0)
        var lead: [String] = []
        while let f = w.first, leadPunct.contains(f), w.index(after: w.startIndex) < w.endIndex {
          lead.append(String(f))
          w = w[w.index(after: w.startIndex)...]
        }
        var trail: [String] = []
        while let l = w.last, trailPunct.contains(l), w.index(after: w.startIndex) < w.endIndex {
          trail.append(String(l))
          w = w[..<w.index(before: w.endIndex)]
        }
        trail.reverse()
        var first = true
        for p in lead {
          lineToks.append(IToken(raw: p, key: p, cls: .punct, line: lineNo, spaceBefore: first))
          first = false
        }
        for piece in splitGlued(String(w)) {
          let cls: IClass
          if piece.allSatisfy({ trailPunct.contains($0) || leadPunct.contains($0) }) {
            cls = .punct
          } else if piece.contains(where: { $0.isASCII && $0.isNumber }) {
            cls = isMoneyShape(piece) ? .money : .num
          } else {
            cls = .word
          }
          lineToks.append(IToken(raw: piece, key: piece.lowercased(), cls: cls, line: lineNo, spaceBefore: first))
          first = false
        }
        for p in trail {
          lineToks.append(IToken(raw: p, key: p, cls: .punct, line: lineNo, spaceBefore: false))
        }
      }
      for i in lineToks.indices where lineToks[i].cls == .word && ILex.currency(lineToks[i].raw) != nil {
        let prevNum = i > 0 && (lineToks[i - 1].cls == .money || lineToks[i - 1].cls == .num)
        let nextNum = i + 1 < lineToks.count && (lineToks[i + 1].cls == .money || lineToks[i + 1].cls == .num)
        let upper = lineToks[i].raw == lineToks[i].raw.uppercased() || ILex.aedAliases.contains(lineToks[i].key)
        if prevNum || nextNum || (upper && lineToks[i].raw.count == 3 && ILex.iso.contains(lineToks[i].raw)) {
          lineToks[i].cls = .cur
        }
      }
      for i in lineToks.indices where lineToks[i].cls == .num && isPlainInt(lineToks[i].raw) {
        let prevCur = i > 0 && lineToks[i - 1].cls == .cur
        let nextCur = i + 1 < lineToks.count && lineToks[i + 1].cls == .cur
        if prevCur || nextCur { lineToks[i].cls = .money }
      }
      out.append(contentsOf: lineToks)
      out.append(IToken(raw: "\n", key: ILex.nlKey, cls: .nl, line: lineNo, spaceBefore: false))
      lineNo += 1
    }
    emitLine(subject, subject: true)
    for l in text.split(separator: "\n", omittingEmptySubsequences: false) {
      emitLine(String(l), subject: false)
      if out.count >= cap { break }
    }
    if out.count > cap { out = Array(out[0..<cap]) }
    for i in out.indices { out[i].code = ILex.code(out[i].cls, out[i].key, &interner) }
    return out
  }

  static func join(_ toks: ArraySlice<IToken>) -> String {
    var s = ""
    for t in toks where t.cls != .nl {
      if t.key == ILex.subjKey { continue }
      if !s.isEmpty && t.spaceBefore { s += " " }
      s += t.raw
    }
    return s
  }

  static func minor(_ raw: String, currency: String) -> Int64? {
    let clean = raw.replacingOccurrences(of: ",", with: "")
    let parts = clean.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count <= 2, let whole = Int64(parts[0].isEmpty ? "0" : String(parts[0])) else { return nil }
    let exp = Exponent.of(currency)
    var frac = parts.count == 2 ? String(parts[1]) : ""
    guard frac.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
    if frac.count > exp {
      let extra = frac.dropFirst(exp)
      if extra.contains(where: { $0 != "0" }) { return nil }
      frac = String(frac.prefix(exp))
    }
    while frac.count < exp { frac += "0" }
    var mult: Int64 = 1
    for _ in 0..<exp { mult *= 10 }
    let (m, o) = whole.multipliedReportingOverflow(by: mult)
    if o { return nil }
    let (total, overflow) = m.addingReportingOverflow(Int64(frac.isEmpty ? "0" : frac) ?? 0)
    return overflow ? nil : total
  }
}
