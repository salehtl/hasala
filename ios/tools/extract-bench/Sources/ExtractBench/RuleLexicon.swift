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
      case 0x00A0, 0x2007, 0x202F, 0x2009, 0x200A: out.append(" ")
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
      parts.append("(?<![a-z0-9])(?:" + en.map { $0.replacingOccurrences(of: " ", with: "\\s+") }.joined(separator: "|") + ")(?![a-z0-9])")
    }
    if !ar.isEmpty { parts.append("(?:" + ar.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|") + ")") }
    return re(parts.joined(separator: "|"))
  }

  static func has(_ r: NSRegularExpression, _ s: String) -> Bool {
    r.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
  }

  static func count(_ r: NSRegularExpression, _ s: String) -> Int {
    r.numberOfMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length))
  }
}

enum RuleLexicon {
  static let amountLabel = RuleText.words(
    ["amount", "amt", "value of", "transaction of", "sum of", "total amount", "txn amount", "transaction value", "for an amount of"],
    ["المبلغ", "مبلغ", "بمبلغ", "بقيمه", "قيمه العمليه", "قيمه المعامله", "قيمه الشراء"])

  static let balance = RuleText.words(
    [
      "balance", "bal", "available", "avl", "avail", "avlbl", "limit", "outstanding", "due", "minimum", "min", "statement",
      "remaining", "previous", "closing", "opening", "ledger",
    ],
    ["رصيد", "الرصيد", "المتاح", "متاح", "الحد", "المستحق", "مستحق", "المتبقي", "الحد الادني"])

  static let fee = RuleText.words(
    ["fee", "fees", "charge", "charges", "commission", "vat", "tax", "markup", "surcharge"],
    ["رسوم", "عموله", "ضريبه", "الرسوم"])

  static let rate = RuleText.words(["rate", "exchange rate", "conversion rate", "fx rate"], ["سعر الصرف", "سعر التحويل"])

  static let txnVerb = RuleText.words(
    [
      "debited", "credited", "withdrawn", "withdrawal", "deducted", "deposited", "deposit", "spent", "paid", "purchase",
      "purchased", "transaction", "transferred", "transfer", "received", "refunded", "refund", "reversed", "reversal", "charged",
      "used", "payment", "sent", "cash", "remittance", "settled", "posted",
    ],
    [
      "خصم", "ايداع", "سحب", "شراء", "مشتريات", "تحويل", "ارجاع", "استرداد", "دفع", "اضافه", "عمليه", "معامله", "المعامله",
      "استخدام", "استلام", "حواله", "سداد", "قيد",
    ])

  static let hardNegative = RuleText.words(
    [
      "otp", "one time password", "one-time password", "verification code", "passcode", "password", "pin", "declined",
      "unsuccessful", "failed", "rejected", "could not be processed", "not been processed", "insufficient", "activation",
      "activate", "will be debited", "will be deducted", "will be charged", "will be credited", "payment due", "due date",
      "is due", "reminder", "authentication code", "security code", "cvv",
    ],
    [
      "رمز التحقق", "رمز التفعيل", "كلمه المرور", "كلمه السر", "الرقم السري", "مرفوضه", "مرفوض", "رفض", "لم تتم", "غير ناجحه",
      "فشل", "تفعيل", "سيتم", "تذكير", "رمز", "الرمز السري",
    ])

  static let softNegative = RuleText.words(
    [
      "offer", "offers", "win", "promo", "promotion", "apply now", "exclusive", "discount", "congratulations", "pre-approved",
      "eligible", "terms and conditions apply", "t&c", "limited time", "unsubscribe", "e-statement", "statement is ready",
      "declined", "unsuccessful", "failed", "otp",
    ],
    ["عرض", "عروض", "خصم خاص", "اربح", "مؤهل", "كشف الحساب", "كشف حساب"])

  static let debit = RuleText.words(
    [
      "debited", "debit", "withdrawn", "withdrawal", "deducted", "purchase", "purchased", "spent", "paid", "payment", "sent",
      "transferred", "transfer", "outgoing", "outward", "charged", "used", "pos", "atm", "bill payment",
    ],
    ["خصم", "سحب", "شراء", "مشتريات", "دفع", "مدين", "تحويل", "صادر", "صادره", "استخدام", "سداد"])

  static let credit = RuleText.words(
    [
      "credited", "credit", "deposited", "deposit", "refund", "refunded", "reversed", "reversal", "received", "returned",
      "cashback", "incoming", "inward", "salary", "added",
    ],
    ["ايداع", "استرداد", "ارجاع", "اضافه", "دائن", "وارد", "وارده", "استلام", "راتب", "عكس", "استرجاع", "اعاده"])

  static let directionNoise = RuleText.re(
    "(?<![a-z])(?:credit|debit)\\s+cards?(?![a-z])|(?<![a-z])(?:credit|debit)\\s+card\\s+(?:number|ending)|available\\s+credit|credit\\s+limit|(?:credited|transferred|paid)\\s+to\\s+(?:the\\s+)?beneficiary|بطاقه\\s+الائتمان|بطاقه\\s+الخصم|بطاقتك\\s+الائتمانيه|بطاقه\\s+ائتمان")

  static let incomingTransfer = RuleText.words(
    ["transfer received", "received a transfer", "received your payment", "payment received", "payment has been received", "payment of .{1,20} received", "incoming transfer", "inward transfer", "inward remittance", "transfer in"],
    ["تحويل وارد", "حواله وارده", "تحويل الي حسابك"])

  static let maskedRef = RuleText.re(
    "(?:x{2,}|\\*{1,})[\\s-]?\\d{2,4}(?!\\d)|ending\\s+(?:with\\s+|in\\s+)?\\d{3,4}|\\d{3,4}\\s*(?:x{2,}|\\*{2,})|المنتهيه|منتهيه\\s+ب|a/c|acct|account|card|بطاقه|بطاقتك|حساب|حسابك")

  static let strongMerchantLabels: Set<String> = [
    "merchant", "merchant name", "merchant details", "merchant location", "at", "payee", "payee name", "beneficiary",
    "beneficiary name", "beneficiary details", "paid to", "pay to", "sender", "sender name", "remitter", "remitter name",
    "received from", "transferred to", "sent to", "التاجر", "اسم التاجر", "لدي", "الدفع الي",
    "الدفع الى", "المستفيد", "اسم المستفيد", "المرسل", "اسم المرسل", "مكان العمليه", "مكان المعامله", "اسم المحول", "المحول",
    "الجهه", "التاجر/الموقع",
  ]

  static let weakMerchantLabels: Set<String> = [
    "description", "transaction description", "details", "transaction details", "narration", "remarks", "transaction",
    "transaction type", "beneficiary bank", "to", "from", "biller", "biller name", "service provider", "المعامله", "الوصف",
    "التفاصيل", "البيان", "تفاصيل المعامله", "البنك المستفيد", "نوع المعامله", "الي", "من", "الجهه المستفيده", "مزود الخدمه",
  ]

  static let otherLabels: Set<String> = [
    "amount", "transaction amount", "debit amount", "credit amount", "date", "transaction date", "time", "date and time",
    "date & time", "card", "card number", "card no", "card no.", "account", "account number", "account no", "account no.",
    "from account", "to account", "status", "reference", "reference number", "reference no", "ref", "ref no", "available balance",
    "balance", "available limit", "المبلغ", "التاريخ", "بتاريخ", "الوقت", "رقم البطاقه", "البطاقه", "رقم الحساب", "الحساب",
    "من حساب", "الي حساب", "الحاله", "الرقم المرجعي", "المرجع", "الرصيد", "الرصيد المتاح", "الحد المتاح",
  ]

  static let closing = RuleText.words(
    ["regards", "sincerely", "thank you for banking with", "thanks for banking with", "yours truly", "best wishes"],
    ["مع اطيب التحيات", "مع تحيات", "مع خالص التحيات", "شكرا لتعاملكم"])

  static let greeting = RuleText.words(
    ["dear", "customer", "valued", "hello", "hi", "client", "cardholder", "card holder", "card member", "sir", "madam"],
    ["عزيزي", "عزيزتي", "المتعامل", "العميل", "السيد", "السيده"])

  static let statusValue = RuleText.words(
    ["success", "successful", "successfully", "completed", "approved", "pending", "processed", "credited to beneficiary"],
    ["تمت بنجاح", "ناجحه", "مكتمله", "قيد التنفيذ"])
}
