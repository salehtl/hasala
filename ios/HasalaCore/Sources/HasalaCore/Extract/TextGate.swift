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

  package struct Prepared: Sendable {
    package let folded: String

    package init(_ normalized: String) {
      folded = TextGate.trimEnd(RuleText.fold(RuleText.asciiDigits(normalized)))
    }

    func has(_ r: NSRegularExpression) -> Bool { RuleText.has(r, folded) }
  }

  public static func isSetUpTest(_ normalized: String) -> Bool { isSetUpTest(Prepared(normalized)) }

  package static func isSetUpTest(_ t: Prepared) -> Bool { t.folded == setUpPhrase }

  public static func neverAPayment(_ normalized: String) -> TextGateStep { neverAPayment(Prepared(normalized)) }

  package static func neverAPayment(_ t: Prepared) -> TextGateStep {
    for w in wholeBody where w.kind == .oneTimeCode || w.kind == .declined {
      if w.matches(t) { return .drop(w.kind) }
    }
    let code = t.has(Markers.oneTimeCode)
    let declined = t.has(Markers.declined)
    guard code || declined else { return .pass(marked: false) }
    if t.has(Markers.transactionClause) { return .pass(marked: true) }
    return .drop(code ? .oneTimeCode : .declined)
  }

  public static func notice(_ normalized: String) -> TextDropKind? { notice(Prepared(normalized)) }

  package static func notice(_ t: Prepared) -> TextDropKind? {
    for w in wholeBody where w.kind == .notice || w.kind == .promotion {
      if w.matches(t) { return w.kind }
    }
    let notice = t.has(Markers.notice)
    let promotion = t.has(Markers.promotion)
    guard notice || promotion, !t.has(Markers.transactionClause), !t.has(Markers.paymentStatement) else { return nil }
    return notice ? .notice : .promotion
  }

  public static func hasPaymentShape(_ normalized: String, lenient: Bool) -> Bool {
    hasPaymentShape(Prepared(normalized), lenient: lenient)
  }

  package static func hasPaymentShape(_ t: Prepared, lenient: Bool) -> Bool {
    guard t.has(Shape.paymentWord) else { return false }
    if lenient { return t.folded.unicodeScalars.contains { $0.value >= 0x30 && $0.value <= 0x39 } }
    return t.has(Shape.amount) || t.has(Shape.maskedCard)
  }

  public static func maskedLast4(_ normalized: String) -> String? { maskedLast4(Prepared(normalized)) }

  package static func maskedLast4(_ t: Prepared) -> String? {
    let ns = t.folded as NSString
    guard let m = Shape.maskedCard.firstMatch(in: t.folded, range: NSRange(location: 0, length: ns.length)) else { return nil }
    let digits = ns.substring(with: m.range).unicodeScalars.filter { $0.value >= 0x30 && $0.value <= 0x39 }
    guard digits.count >= 4 else { return nil }
    return String(String.UnicodeScalarView(digits.suffix(4)))
  }

  public static func hasTransactionClause(_ normalized: String) -> Bool { Prepared(normalized).has(Markers.transactionClause) }

  static func hasPaymentStatement(_ normalized: String) -> Bool { Prepared(normalized).has(Markers.paymentStatement) }

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
      "amount": "[.,]*+[0-9][0-9.,]*+",
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
      "(?<![a-z])(?<!(?:auth|authori[sz]ation|approval|appr|ref|reference|transaction|txn|trx|promo|promotion|promotional|voucher|coupon|discount|referral|gift)[\\s.:#-]{1,3})(?:otp|one[- ]time password|passcode|password|verification code|security code|code|pin)(?![a-z])\\s{0,2}(?:is|:|-|=|هو|هي)?\\s{0,2}[\"']?[0-9]{4,8}(?![0-9])"
        + "|(?<![0-9.,])[0-9]{4,8}[\"']?\\s{0,2}(?:is\\s+(?:your\\s+)?|هو\\s+|هي\\s+)?(?:otp|one[- ]time password|passcode|verification code)(?![a-z])"
        + "|(?<![0-9.,])[0-9]{4,8}[\"']?\\s{0,2}is\\s+(?:your\\s+)?(?:code|password|pin)(?![a-z])"
        + "|(?<![a-z])(?:otp|one[- ]time password|passcode|verification code)(?![a-z])\\s{0,2}(?:\\([a-z ]{2,30}\\)\\s{0,2})?(?:for|to)\\s(?:[^\\n.!?]|\\.(?=\\S)){1,80}?(?:\\sis|:)\\s{0,2}[\"']?[0-9]{4,8}(?![0-9]|[.,][0-9])"
        + "|(?:رمز|كلمه المرور|كلمه السر)(?:\\s+(?:التحقق|التفعيل|الدخول|المرور))?\\s{0,2}(?:هو|هي|:)?\\s{0,2}[0-9]{4,8}(?![0-9])"
        + "|(?:رمز|كلمه\\s+المرور|كلمه\\s+السر)(?:\\s+[^\\s0-9]+){1,5}?\\s+(?:هو|هي|:)\\s{0,2}[0-9]{4,8}(?![0-9]|[.,][0-9])"
        + "|(?<![0-9.,])[0-9]{4,8}\\s{0,2}(?:هو|هي)\\s+(?:رمز|كلمه المرور|كلمه السر)"
        + "|(?<![0-9.,])[0-9]{4,8}\\s{0,2}(?:كلمه\\s+(?:المرور|السر)|رمز\\s+(?:التحقق|التفعيل|الدخول|المرور))")

    static let declined = RuleText.words(
      [
        "declined", "was not approved", "not approved", "unsuccessful", "could not be processed", "was not processed",
        "insufficient funds", "insufficient balance", "incorrect pin", "wrong pin", "invalid pin", "incorrect cvv", "wrong cvv",
        "invalid cvv",
      ],
      [
        "تم رفض", "مرفوضه", "لم تتم", "غير ناجحه", "رصيد غير كاف", "رقم سري خاطئ", "الرقم السري خاطئ", "رقم سري غير صحيح",
        "الرقم السري غير صحيح", "رمز تحقق غير صحيح", "رمز التحقق غير صحيح", "رمز تحقق خاطئ", "رمز التحقق خاطئ",
      ])

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

    static let number = "[0-9](?:[0-9,]|\\.(?=[0-9]))*+"

    static let statedAmount =
      "(?:(?:\(Shape.currencies))(?![a-z])\\s{0,2}\(number)|\(number)\\s{0,2}(?:\(Shape.currencies))(?![a-z])|[0-9][0-9,]*+\\.[0-9]{2}(?![0-9]))"

    static let lead =
      "(?:^|\\n|[.!?\u{061F}]\\s|[,:;\u{060C}])\\s{0,2}"
        + "(?:(?:dear\\s+(?:valued\\s+)?(?:customer|client|cardholder|member)|عزيزي\\s+(?:العميل|المتعامل)|عميلنا\\s+العزيز)[,:\u{060C}]?\\s{1,2})?"
        + "(?:(?:thank\\s+you|thanks)\\s+for\\s+)?(?:(?:your|the)\\s+)?"

    static let notMore = "(?!\\s+(?:or|and)\\s+(?:more|above|over))"

    static let paymentNoun = "(?:purchase|transfer|payment|withdrawal|refund|deposit|transaction|txn)"

    static let promoCue =
      "(?<![a-z])(?:above|over|more|minimum|min|least|upto|up\\s+to|spend|earn|earns|get|gets|win|wins|when|if|every|each|any|next"
      + "|cashback|back|save|enjoy|offer|qualify|qualifies|eligible|balance)(?![a-z])"

    static let notPromoted =
      "(?<!(?:make|makes|every|each|any|next|all|first|on|win|get|earn|minimum|min|per|be|can|to|balance)\\s)"
      + "(?<!(?:make|makes|every|each|any|next|all|first|on|for|with|per|win|get)\\s(?:an?|your|the)\\s)"

    static let notPromotedAfter =
      notMore + "(?!\\s+(?:minimum|min)(?![a-z]))(?!\\s{0,2}(?:%|\\+))"
      + "(?!\\s+(?:or|and|to|&)\\s+(?:above|over|more|get|earn|win|receive|enjoy|save)(?![a-z]))"
      + "(?!\\s+(?:earns?|gets?|wins?|qualif)(?![a-z]))"

    static let nearStatement =
      "(?<![a-z])" + notPromoted
      + "(?:\(paymentNoun)|purchased|paid|spent|charged|sent|received|withdrew|used|using|debit|credit)(?![a-z])"
      + "(?:(?!\(promoCue))(?:[^\\n.!?%;]|\\.(?=\\S))){0,60}?(?<![a-z])" + statedAmount + notPromotedAfter

    static let arabicCardUse =
      "(?:تم\\s+استخدام|استخدمت)\\s+(?:ال)?بطاق\\S*(?:\\s+\\S+){0,3}?\\s+(?:(?:ل|ب)?(?:شراء|مشتريات|سحب|دفع|سداد)\\s+)?"
      + "(?:بمبلغ|مبلغ|بقيمه|قيمه)\\s+(?:(?:aed|درهم)\\s{0,2})?[0-9][0-9.,]*+(?!\\s{0,2}(?:درهم|aed)?\\s{0,2}(?:او|و|ف)\\s{0,2}(?:اكثر|فوق|ما\\s+فوق))"

    static let paymentStatement = RuleText.re(
      nearStatement + "|" + arabicCardUse
        + "|" + lead
        + "(?:\(paymentNoun)\\s+of|paid|spent|charged|sent|received|purchased|withdrew)\\s+(?:an?\\s+amount\\s+of\\s+)?"
        + statedAmount + notMore
        + "|" + lead + "(?:\(paymentNoun)|debit|credit|amount|amt)\\s{0,2}(?::|-)\\s{0,2}" + statedAmount + notMore
        + "|" + lead + statedAmount + "\\s{1,2}(?:\(paymentNoun)|debit|credit)(?![a-z])" + notMore + "(?!\\s+(?:minimum|min)(?![a-z]))"
        + "|" + lead
        + "(?:عمليه\\s+)?(?:شراء|مشتريات|سحب(?:\\s+نقدي)?|ايداع(?:\\s+راتب)?|تحويل|سداد|دفع|خصم(?=\\s+(?:بمبلغ|مبلغ)))(?:\\s+[^\\s0-9]+){0,4}?\\s+"
        + "(?:(?:بمبلغ|مبلغ|بقيمه|قيمه)\\s+(?:(?:aed|درهم)\\s{0,2})?[0-9]|(?:aed|درهم)\\s{0,2}[0-9]|[0-9][0-9,]*+\\.[0-9]{2}(?![0-9])|\(number)\\s{0,2}(?:درهم|aed))")

    static let completed =
      "(?<![a-z])(?:purchase|transfer|payment|withdrawal|transaction|order)\\s+of\\s+" + statedAmount
      + "(?:(?!\\s(?:will|shall|once|pending|upon|after|until|unless|if|when|not|never|cannot)\\s|\\sto\\s+be\\s|n['\u{2019}]t\\s)(?:[^\\n.!?]|\\.(?=\\S))){0,100}?"
      + "(?<!\\sbe|\\snot|\\sbeing)\\s"
      + "(?:(?:(?:was|is|has\\s+been|have\\s+been)\\s+)?(?:completed|confirmed|successful|approved|processed)(?![a-z])"
      + "|(?:was|is|has\\s+been|have\\s+been|now)\\s+(?:complete|done)(?![a-z])"
      + "|(?<!\\sto\\s|\\sand\\s|\\sor\\s|\\sare\\s|\\syou\\s|\\splease\\s)(?:complete|done)(?![a-z]))"

    static let transactionClause = RuleText.re(
      completed
        + "|(?<![a-z])(?<!will be )(?<!to be )(?:debited|credited|deducted|deposited|withdrawn|transferred|refunded|reversed)(?![a-z])"
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
      "(?<![a-z])(?:\(currencies))(?![a-z])\\s{0,2}[.,]*+[0-9]|(?<![0-9.,])[.,]*+[0-9][0-9.,]*+\\s{0,2}(?:\(currencies))(?![a-z])"
        + "|(?<![0-9.,])[.,]*+[0-9][0-9.,]*+\\s{0,2}(?:درهم|دراهم|د\\.ا|ريال|دولار)|(?:درهم|دراهم|د\\.ا|ريال|دولار)\\s{0,2}[0-9]")

    static let maskedCard = RuleText.re(
      "(?:(?<!x)x{2,}+|(?<!\\*)\\*{2,}+|(?<!#)#{2,}+)[ -]?[0-9]{3,4}(?![0-9])|[0-9]{4}[ -]?(?:x{2,}|\\*{2,})|ending\\s++(?:with\\s+|in\\s+)?[0-9]{3,4}(?![0-9])"
        + "|المنتهيه\\s*(?:ب\\S*\\s*)?[0-9]{3,4}(?![0-9])")
  }
}
