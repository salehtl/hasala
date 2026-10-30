import Foundation

enum StatusLexicon {
  static let statusLabels: Set<String> = [
    "status", "transaction status", "transfer status", "payment status", "request status", "remittance status",
    "الحاله", "حاله المعامله", "حاله التحويل", "حاله الطلب", "حاله الدفع", "حاله الحواله",
  ]

  static let pendingValue = RuleText.words(
    [
      "pending", "in process", "in progress", "processing", "under process", "under processing", "being processed",
      "initiated", "awaiting", "on hold", "queued", "submitted", "scheduled", "not completed", "not yet completed",
    ],
    [
      "قيد التنفيذ", "قيد المعالجه", "قيد الانتظار", "قيد الاجراء", "قيد المراجعه", "جاري التنفيذ", "جاري المعالجه",
      "تحت المعالجه", "تحت الاجراء", "تحت التنفيذ", "معلقه", "معلق", "بانتظار", "في الانتظار", "لم تكتمل",
    ])

  static let pendingPhrase = RuleText.words(
    [
      "is pending", "are pending", "is in process", "is in progress", "is being processed", "is under process",
      "is under processing", "has been initiated", "was initiated", "have initiated", "has been submitted",
      "has been scheduled", "has been received and will be processed", "will be processed",
    ],
    ["قيد التنفيذ", "قيد المعالجه", "جاري تنفيذ", "جاري معالجه", "تحت المعالجه", "تحت الاجراء"])

  static let completedPhrase = RuleText.words(
    [
      "credited to beneficiary", "credited to the beneficiary", "has been credited", "have been credited", "has been debited",
      "have been debited", "has been transferred", "has been sent", "has been completed", "was successful",
      "is successful",
    ],
    ["تمت بنجاح", "تم تحويل", "تم خصم", "تم ايداع", "تم التحويل", "تم تنفيذ"])
}

enum KindLexicon {
  static let accountDebit = RuleText.words(
    [
      "debit advice", "debit alert", "debit notification", "debit notice", "account debited", "debited from your account",
      "debited from your a/c", "withdrawal from your account", "account debit",
    ],
    ["اشعار خصم", "خصم من الحساب", "خصم من حسابك", "اشعار مدين"])

  static let accountCredit = RuleText.words(
    [
      "credit advice", "credit alert", "credit notification", "credit notice", "account credited", "credited to your account",
      "credited to your a/c", "deposit to your account", "deposit alert", "account credit",
    ],
    ["اشعار ايداع", "ايداع في الحساب", "ايداع فى الحساب", "ايداع في حسابك", "ايداع فى حسابك", "اشعار دائن"])

  static let refund = RuleText.words(
    ["refund", "refunded", "reversed", "reversal", "returned", "chargeback", "charge back"],
    ["ارجاع", "استرداد", "استرجاع", "عكس", "مرتجع", "ارجع"])

  static let card = RuleText.words(
    ["card", "credit card", "debit card", "prepaid card", "apple pay", "google pay", "pos"],
    ["بطاقه", "بطاقتك", "البطاقه"])

  static let transfer = RuleText.words(
    [
      "transfer", "transferred", "remittance", "remitted", "telegraphic", "fund transfer", "funds transfer", "money transfer",
      "swift transfer",
    ],
    ["تحويل", "حواله", "التحويل", "الحواله", "تحويلات"])

  static let purchase = RuleText.words(
    ["purchase", "purchased", "spent", "used", "transaction", "paid", "payment", "charged", "pos", "e-commerce", "online"],
    ["مشتريات", "شراء", "معامله", "استخدام", "عمليه", "دفع"])

  static let account = RuleText.words(["account", "a/c", "acct"], ["حساب", "حسابك", "الحساب"])
}

enum MailRules {
  static let maskedLast4 = RuleText.re(
    "(?:(?<!x)x{2,}+|(?<!\\*)\\*{2,}+|ending(?:\\s+with|\\s+in)?\\s++(?:x++|\\*++)?|المنتهيه\\s++(?:ب|في)?\\s*+(?:x++|\\*++)?|منتهيه\\s+ب\\s*+(?:x++|\\*++)?)\\s?-?\\s?(\\d{4})(?!\\d)")

  static func foldedLines(_ text: String) -> [String] {
    RuleText.cleanLines(text).map(RuleText.fold)
  }

  static func statusValues(_ lines: [String]) -> [String] {
    var out: [String] = []
    for (i, line) in lines.enumerated() where !line.isEmpty {
      if let colon = line.firstIndex(where: { $0 == ":" || $0 == "：" }) {
        let key = RuleReader.labelKey(String(line[..<colon]))
        let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        if StatusLexicon.statusLabels.contains(key) {
          if !value.isEmpty {
            out.append(value)
          } else if let next = lines[(i + 1)...].first(where: { !$0.isEmpty }) {
            out.append(next)
          }
        }
        continue
      }
      if StatusLexicon.statusLabels.contains(RuleReader.labelKey(line)),
        let next = lines[(i + 1)...].first(where: { !$0.isEmpty })
      {
        out.append(next)
      }
    }
    return out
  }

  static let reflectedLabels: Set<String> = [
    "remark", "remarks", "narration", "description", "details", "purpose", "message", "note", "notes", "beneficiary",
    "beneficiary name", "merchant", "payee", "sender", "from", "to", "reference", "الوصف", "البيان", "ملاحظات", "ملاحظه", "المعامله",
    "المستفيد", "الي", "من",
  ]

  static func isField(_ line: String, _ field: String) -> Bool {
    guard !field.isEmpty else { return false }
    if line == field { return true }
    guard let colon = line.firstIndex(where: { $0 == ":" || $0 == "：" }) else { return false }
    return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces) == field
  }

  static func statesSettled(_ lines: [String]) -> Bool {
    let body = lines.joined(separator: "\n")
    return RuleText.has(StatusLexicon.completedPhrase, body) || RuleText.has(TextGate.Markers.transactionClause, body)
  }

  static func foldedField(_ captured: String?) -> String {
    captured.map { RuleText.fold(RuleText.clean(RuleText.asciiDigits($0))).trimmingCharacters(in: .whitespaces) } ?? ""
  }

  static func setsAside(_ input: ExtractInput, direction: String?, captured: String? = nil) -> Bool {
    guard kind(input, direction: direction) == .transferNotice else { return false }
    let lines = foldedLines(input.text)
    let field = foldedField(captured)
    var bank: [String] = []
    var previous = ""
    for line in lines where !line.isEmpty {
      if !isField(line, field) && !reflectedLabels.contains(RuleReader.labelKey(previous)) { bank.append(line) }
      previous = line
    }
    let statuses = statusValues(bank)
    return !statuses.isEmpty && statuses.allSatisfy { RuleText.has(StatusLexicon.pendingValue, $0) } && !statesSettled(lines)
  }

  static let statementBreak = try! NSRegularExpression(pattern: "[.!?;؛](?=\\s|$)")
  static let ownTransfer = RuleText.re(
    "^\\s*(?:dear\\s+(?:valued\\s+)?customer[,:]?\\s+)?your\\s+(?:\\S+\\s+){0,3}?(?:transfer|remittance)(?![a-z])"
      + "|^\\s*(?:تحويلك|حوالتك|طلب\\s+التحويل|طلب\\s+الحواله)")

  static func statesPendingTransfer(_ input: ExtractInput, direction: String?, amountMinor: Int64?, captured: String? = nil) -> Bool {
    guard let amountMinor, kind(input, direction: direction) == .transferNotice else { return false }
    let lines = foldedLines(input.text)
    guard !statesSettled(lines) else { return false }
    let field = foldedField(captured)
    for line in lines.filter({ !$0.isEmpty }).prefix(3) {
      if isField(line, field) || reflectedLabels.contains(RuleReader.labelKey(line)) { return false }
      if let colon = line.firstIndex(where: { $0 == ":" || $0 == "：" }), !line[..<colon].contains(where: { $0.isNumber }) { return false }
      let ns = line as NSString
      var start = 0
      let breaks = statementBreak.matches(in: line, range: NSRange(location: 0, length: ns.length)).map(\.range)
      for r in breaks + [NSRange(location: ns.length, length: 0)] {
        let sentence = ns.substring(with: NSRange(location: start, length: r.location - start))
        start = r.location + r.length
        if RuleText.has(StatusLexicon.pendingPhrase, sentence), RuleText.has(ownTransfer, sentence),
          RuleMoneyParser.scan(sentence, line: 0, labelCurrency: nil).contains(where: { $0.minor == amountMinor })
        {
          return true
        }
      }
    }
    return false
  }

  static func pendingSignal(_ input: ExtractInput) -> ExtractPending {
    let lines = foldedLines(input.text)
    let statuses = statusValues(lines)
    if !statuses.isEmpty {
      return statuses.contains { RuleText.has(StatusLexicon.pendingValue, $0) } ? .status : .none
    }
    let body = ([RuleText.fold(input.subject)] + lines).joined(separator: "\n")
    return RuleText.has(StatusLexicon.pendingPhrase, body) && !RuleText.has(StatusLexicon.completedPhrase, body)
      ? .phrase : .none
  }

  static func kind(_ input: ExtractInput, direction: String?) -> ExtractMailKind {
    let lines = foldedLines(input.text)
    let heading = ([RuleText.fold(RuleText.clean(input.subject))] + lines.filter { !$0.isEmpty }.prefix(3)).joined(separator: "\n")
    if let k = kind(of: heading) { return k }
    let body = lines.joined(separator: "\n")
    if let k = kind(of: body, transferFirst: true) { return k }
    let card = RuleText.has(KindLexicon.card, body)
    let account = RuleText.has(KindLexicon.account, body)
    switch direction {
    case "debit"?:
      if card { return .cardPurchase }
      if account { return .accountDebitAlert }
    case "credit"?:
      if card { return .cardRefund }
      if account { return .accountCreditAlert }
    default: break
    }
    return .other
  }

  static func kind(of text: String, transferFirst: Bool = false) -> ExtractMailKind? {
    if transferFirst && RuleText.has(KindLexicon.transfer, text) && !RuleText.has(KindLexicon.accountCredit, text) {
      return .transferNotice
    }
    if RuleText.has(KindLexicon.accountDebit, text) { return .accountDebitAlert }
    if RuleText.has(KindLexicon.accountCredit, text) { return .accountCreditAlert }
    let card = RuleText.has(KindLexicon.card, text)
    if card && RuleText.has(KindLexicon.refund, text) { return .cardRefund }
    if RuleText.has(KindLexicon.transfer, text) { return .transferNotice }
    if card && RuleText.has(KindLexicon.purchase, text) { return .cardPurchase }
    return nil
  }

  static func last4(_ input: ExtractInput) -> String? {
    for text in [input.text, input.subject].map({ RuleText.fold(RuleText.asciiDigits($0)) }) {
      let ns = text as NSString
      if let m = maskedLast4.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
        return ns.substring(with: m.range(at: 1))
      }
    }
    return nil
  }
}
