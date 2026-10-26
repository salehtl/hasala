import Foundation

public enum TextDropKind: String, Sendable, Codable, CaseIterable {
  case oneTimeCode = "one_time_code"
  case declined
  case notice
  case promotion
  case noPaymentShape = "no_payment_shape"
}

public enum TextGateStep: Sendable, Equatable {
  case drop(TextDropKind)
  case pass(marked: Bool)
}

public enum TextGate {
  public static let maxTextBytes = 16_384
  public static let setUpPhrase = "hasala test"
  public static let merchantWordLimit = 4
  public static let merchantByteLimit = 40

  struct Prepared {
    let folded: String

    init(_ normalized: String) {
      folded = TextGate.trimEnd(RuleText.fold(RuleText.asciiDigits(normalized)))
    }

    func has(_ r: NSRegularExpression) -> Bool { RuleText.has(r, folded) }
  }

  public static func isSetUpTest(_ normalized: String) -> Bool {
    Prepared(normalized).folded == setUpPhrase
  }

  public static func neverAPayment(_ normalized: String) -> TextGateStep {
    let t = Prepared(normalized)
    for w in wholeBody where w.kind == .oneTimeCode || w.kind == .declined {
      if w.matches(t) { return .drop(w.kind) }
    }
    let code = t.has(Markers.oneTimeCode)
    let declined = t.has(Markers.declined)
    guard code || declined else { return .pass(marked: false) }
    if t.has(Markers.transactionClause) { return .pass(marked: true) }
    return .drop(code ? .oneTimeCode : .declined)
  }

  public static func notice(_ normalized: String) -> TextDropKind? {
    let t = Prepared(normalized)
    for w in wholeBody where w.kind == .notice || w.kind == .promotion {
      if w.matches(t) { return w.kind }
    }
    let notice = t.has(Markers.notice)
    let promotion = t.has(Markers.promotion)
    guard notice || promotion, !t.has(Markers.transactionClause) else { return nil }
    return notice ? .notice : .promotion
  }

  public static func hasPaymentShape(_ normalized: String, lenient: Bool) -> Bool {
    let t = Prepared(normalized)
    guard t.has(Shape.paymentWord) else { return false }
    if lenient { return t.folded.unicodeScalars.contains { $0.value >= 0x30 && $0.value <= 0x39 } }
    return t.has(Shape.amount) || t.has(Shape.maskedCard)
  }

  public static func maskedLast4(_ normalized: String) -> String? {
    let t = Prepared(normalized)
    let ns = t.folded as NSString
    guard let m = Shape.maskedCard.firstMatch(in: t.folded, range: NSRange(location: 0, length: ns.length)) else { return nil }
    let digits = ns.substring(with: m.range).unicodeScalars.filter { $0.value >= 0x30 && $0.value <= 0x39 }
    guard digits.count >= 4 else { return nil }
    return String(String.UnicodeScalarView(digits.suffix(4)))
  }

  public static func hasTransactionClause(_ normalized: String) -> Bool { Prepared(normalized).has(Markers.transactionClause) }

  public static func cardPurchaseMerchant(_ normalized: String, merchant: String?) -> String {
    guard let m = merchant?.trimmingCharacters(in: .whitespaces), !m.isEmpty else { return "" }
    let text = RuleText.asciiDigits(normalized)
    var searchFrom = text.startIndex
    while let r = text.range(of: m, options: [.caseInsensitive], range: searchFrom..<text.endIndex) {
      let before = RuleText.fold(String(text[text.startIndex..<r.lowerBound]))
      var head = Substring(before)
      while let last = head.last, last == " " || last == ":" || last == "-" { head = head.dropLast() }
      if cardPurchaseLabels.contains(where: { endsWithWord(head, $0) }) { return limited(m) }
      searchFrom = r.upperBound
    }
    return ""
  }

  static let cardPurchaseLabels = ["at", "merchant", "merchant name", "لدي", "التاجر", "اسم التاجر"]

  static func endsWithWord(_ s: Substring, _ word: String) -> Bool {
    guard s.hasSuffix(word) else { return false }
    let rest = s.dropLast(word.count)
    guard let c = rest.last else { return true }
    return !(c.isLetter || c.isNumber)
  }

  public static func limited(_ merchant: String) -> String {
    let words = merchant.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).prefix(merchantWordLimit)
    var out = ""
    for w in words {
      let next = out.isEmpty ? String(w) : out + " " + w
      if next.utf8.count <= merchantByteLimit {
        out = next
        continue
      }
      if out.isEmpty {
        for ch in w {
          if (out + String(ch)).utf8.count > merchantByteLimit { break }
          out.append(ch)
        }
      }
      break
    }
    return out
  }

  static func trimEnd(_ s: String) -> String {
    var sub = Substring(s)
    while let last = sub.last, last == " " || last == "." || last == "!" || last == "\n" { sub = sub.dropLast() }
    while let first = sub.first, first == " " || first == "\n" { sub = sub.dropFirst() }
    return String(sub)
  }

  struct WholeBody {
    let kind: TextDropKind
    let pattern: String
    let regex: NSRegularExpression

    init(_ kind: TextDropKind, _ wording: String) {
      self.kind = kind
      pattern = wording
      regex = try! NSRegularExpression(pattern: Self.compile(wording), options: [.caseInsensitive])
    }

    func matches(_ t: Prepared) -> Bool { RuleText.has(regex, t.folded) }

    static let wildcards: [String: String] = [
      "n": "[0-9]+",
      "amount": "[0-9.,]*[0-9][0-9.,]*",
      "ccy": "[a-z]{3}",
      "card": "[x*]{0,6}[0-9]{2,6}",
      "any": "[^\\n]+?",
      "date": "[0-9]{1,4}[-./][0-9]{1,2}[-./][0-9]{1,4}",
    ]

    static func compile(_ wording: String) -> String {
      var out = "^"
      var literal = ""
      var i = wording.startIndex
      func flush() {
        guard !literal.isEmpty else { return }
        out += NSRegularExpression.escapedPattern(for: RuleText.fold(RuleText.asciiDigits(literal)))
        literal = ""
      }
      let body = TextGate.trimEnd(wording)
      i = body.startIndex
      while i < body.endIndex {
        if body[i] == "{", let close = body[i...].firstIndex(of: "}"), let w = wildcards[String(body[body.index(after: i)..<close])] {
          flush()
          out += w
          i = body.index(after: close)
          continue
        }
        literal.append(body[i])
        i = body.index(after: i)
      }
      flush()
      return out + "$"
    }
  }

  static let wholeBody: [WholeBody] = DIBTexts.wholeBody.map { WholeBody($0.kind, $0.wording) }

  enum Markers {
    static let oneTimeCode = RuleText.re(
      "(?<![a-z])(?<!(?:auth|authori[sz]ation|approval|appr|ref|reference|transaction|txn|trx)[\\s.:#-]{1,3})(?:otp|one[- ]time password|passcode|password|verification code|security code|code|pin)(?![a-z])\\s{0,2}(?:is|:|-|=|هو|هي)?\\s{0,2}[\"']?[0-9]{4,8}(?![0-9])"
        + "|(?<![0-9.,])[0-9]{4,8}[\"']?\\s{0,2}(?:is\\s+(?:your\\s+)?|هو\\s+|هي\\s+)?(?:otp|one[- ]time password|passcode|verification code)(?![a-z])"
        + "|(?<![0-9.,])[0-9]{4,8}[\"']?\\s{0,2}is\\s+(?:your\\s+)?(?:code|password|pin)(?![a-z])"
        + "|(?:رمز|كلمه المرور|كلمه السر)(?:\\s+(?:التحقق|التفعيل|الدخول|المرور))?\\s{0,2}(?:هو|هي|:)?\\s{0,2}[0-9]{4,8}(?![0-9])"
        + "|(?<![0-9.,])[0-9]{4,8}\\s{0,2}(?:هو|هي)\\s+(?:رمز|كلمه المرور|كلمه السر)")

    static let declined = RuleText.words(
      [
        "declined", "was not approved", "not approved", "unsuccessful", "could not be processed", "was not processed",
        "insufficient funds", "insufficient balance",
      ],
      ["تم رفض", "مرفوضه", "لم تتم", "غير ناجحه", "رصيد غير كاف"])

    static let notice = RuleText.re(
      RuleText.words(
        [
          "has been blocked", "is blocked", "temporarily blocked", "has been suspended", "has been activated", "has been deactivated",
          "is now active", "is now activated", "successfully activated", "activated successfully", "successfully deactivated",
          "has been registered", "have been registered", "is now registered", "are now registered", "successfully registered",
          "registered successfully", "registration request", "registration is successful", "registration was successful",
          "registration successful", "registration is complete", "registration completed", "service request", "ticket number",
          "has been reset",
        ],
        ["تم ايقاف", "الايقاف المؤقت", "ايقاف مؤقت", "تم تفعيل", "الغاء تفعيل", "اعاده تفعيل", "تسجيلك", "مسجل لاستخدام", "رقم تذكره", "تذكره الخدمه"]
      ).pattern + "|(?<![a-z])request\\s?#")

    static let promotion = RuleText.re(
      "(?<![a-z])(?:t\\s?&\\s?c'?s?|terms\\s+(?:and|&)\\s+conditions)\\s+apply|(?<![a-z])sms\\s+stop\\s+to|(?<![a-z])send\\s+stop\\s+to|(?<![a-z])unsubscribe|offer\\s+valid\\s+(?:till|until|up\\s+to)"
        + "|تطبق\\s+الشروط|الشروط\\s+والاحكام|(?<!\\p{L})(?:وال|بال|فال|لل|ال|و|ب|ل|ف)?(?:عرض|عروض)(?!\\p{L})")

    static let transactionClause = RuleText.re(
      "(?<![a-z])(?<!will be )(?<!to be )(?:debited|credited|deducted|deposited|withdrawn|transferred|refunded|reversed)(?![a-z])"
        + "|(?<![a-z])(?:has been|have been|was|were) (?:charged|used|paid|spent|sent)(?![a-z])"
        + "|(?<![a-z])(?:you|you've|you have) (?:paid|spent|sent)(?![a-z])"
        + "|(?<![a-z])purchase of [^\\n]{1,80}? (?:was|is|has been) (?:successful|approved|completed)(?![a-z])"
        + "|(?<![a-z])successful purchase(?![a-z])"
        + "|(?:(?<![a-z])(?:\(Shape.currencies))(?![a-z])\\s{0,2}[0-9][0-9.,]*|(?<![0-9.,])[0-9][0-9.,]*\\s{0,2}(?:\(Shape.currencies))(?![a-z]))"
        + "\\s{1,2}(?:(?:was|has been|have been|is) )?(?:spent|charged|paid|used|sent|received)(?![a-z])"
        + "|تم (?:خصم|ايداع|تحويل|سداد|ارجاع|سحب|دفع|شراء|اضافه|استرداد)|تمت عمليه|تمت (?:عمليه )?(?:الشراء|شراء)")
  }

  enum Shape {
    static let paymentWord = RuleText.re(
      "(?<![a-z])(?:purchase|purchased|purchases|debited|credited|refund|refunded|refunds|reversal|reversed|transfer|transferred|transfers|withdrawal|withdrawn|withdrew|deposit|deposited|payment|paid|spent|charged|sent|received|used|transaction|txn)(?![a-z])"
        + "|شراء|مشتريات|بمبلغ|خصم|ايداع|تحويل|سحب|سداد|ارجاع|استرداد|دفع|راتب|حواله")

    static let currencies =
      "aed|usd|eur|gbp|sar|qar|omr|kwd|bhd|egp|jod|inr|pkr|lkr|npr|bdt|php|idr|thb|myr|sgd|hkd|cny|jpy|krw|chf|cad|aud|nzd|try|zar|rub|sek|nok|dkk|dhs|dh|dirham|dirhams"

    static let amount = RuleText.re(
      "(?<![a-z])(?:\(currencies))(?![a-z])\\s{0,2}[0-9.,]*[0-9]|[0-9][0-9.,]*\\s{0,2}(?:\(currencies))(?![a-z])"
        + "|[0-9][0-9.,]*\\s{0,2}(?:درهم|دراهم|د\\.ا|ريال|دولار)|(?:درهم|دراهم|د\\.ا|ريال|دولار)\\s{0,2}[0-9]")

    static let maskedCard = RuleText.re(
      "(?:x{2,}|\\*{2,}|#{2,})[ -]?[0-9]{3,4}(?![0-9])|[0-9]{4}[ -]?(?:x{2,}|\\*{2,})|ending\\s+(?:with\\s+|in\\s+)?[0-9]{3,4}(?![0-9])"
        + "|المنتهيه\\s*(?:ب\\S*\\s*)?[0-9]{3,4}(?![0-9])")
  }
}
