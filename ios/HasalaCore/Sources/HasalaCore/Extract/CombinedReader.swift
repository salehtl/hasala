public enum CombinedReader {
  public static func read(_ input: ExtractInput, _ memory: LearnedLayouts) -> (ExtractReading, LearnedLayouts) {
    let stripped = strip(input)
    let (l, next) = LearnedReader.read(stripped, memory)
    let r = RuleReader.read(stripped)
    let lo = aedOverride(l, stripped)
    let ro = aedOverride(r, stripped)
    let (out, agreed) = combine(learned: lo, rules: ro)
    var result = reading(out, input, agreed: agreed, negative: l.negative || r.negative)
    if out.isTransaction {
      result.rulesConfidencePercent = ro.isTransaction ? ro.confidence : 0
      result.learnedConfidencePercent = lo.isTransaction ? lo.confidence : 0
      result.readersAgree = readersAgree(lo, ro)
    }
    return (result, result.outcome == .notTransaction ? memory : next)
  }

  public static func readRules(_ input: ExtractInput) -> ExtractReading {
    let stripped = strip(input)
    let r = aedOverride(RuleReader.read(stripped), stripped)
    return reading(r, input, agreed: false, negative: r.negative)
  }

  public static func readLearned(_ input: ExtractInput, _ memory: LearnedLayouts) -> (ExtractReading, LearnedLayouts) {
    let stripped = strip(input)
    let (l, next) = LearnedReader.read(stripped, memory)
    let result = reading(aedOverride(l, stripped), input, agreed: false, negative: l.negative)
    return (result, result.outcome == .notTransaction ? memory : next)
  }

  public static func aedAmount(_ input: ExtractInput, foreign: Int64, currency: String) -> Int64? {
    guard currency != "AED", foreign > 0 else { return nil }
    return RuleReader.aedAmount(strip(input), foreign: foreign, currency: currency)
  }

  public static func pending(_ input: ExtractInput, direction: ExtractDirection?) -> ExtractPending {
    let kind = MailRules.kind(input, direction: direction?.rawValue)
    if kind == .cardPurchase || kind == .cardRefund { return .none }
    return MailRules.pendingSignal(input)
  }

  public static func templateVerdict(
    _ input: ExtractInput, amountMinor: Int64, currency: String, direction: ExtractDirection?,
    read: () -> ExtractReading?
  ) -> ExtractTemplateVerdict? {
    let signal = pending(input, direction: direction)
    if signal == .status { return nil }
    let reading = read()
    var out = ExtractTemplateVerdict(amountMinor: amountMinor, currency: currency)
    guard let iso = ExtractCurrency.iso(currency) else {
      out.holds.append(.currencyNotISO)
      if signal == .phrase { out.holds.append(.pendingPhrase) }
      return out
    }
    out.currency = iso
    let currency = iso
    if let aed = aedAmount(input, foreign: amountMinor, currency: currency), aed <= ExtractReading.maxAmountMinor {
      out.amountMinor = aed
      out.currency = "AED"
      out.aedOver = currency
      let confirmed =
        reading.map { $0.outcome == .transaction && $0.agreed && $0.amountMinor == aed && $0.currency == "AED" } ?? false
      if !confirmed { out.holds.append(.aedNotConfirmed) }
    }
    if let reading, reading.readersConfirm,
      reading.amountMinor != out.amountMinor || reading.currency != out.currency
    {
      out.holds.append(.readersDisagree)
    }
    if signal == .phrase { out.holds.append(.pendingPhrase) }
    return out
  }

  static func readersAgree(_ l: Reading, _ r: Reading) -> Bool {
    l.isTransaction && r.isTransaction && l.amountMinor != nil && l.amountMinor == r.amountMinor
      && l.currency != nil && l.currency == r.currency && l.direction != nil && l.direction == r.direction
      && !l.directionGuessed && !r.directionGuessed
  }

  public static func statedDate(_ input: ExtractInput) -> ExtractStatedDate? {
    RuleDate.stated(strip(input))
  }

  static func strip(_ input: ExtractInput) -> ExtractInput {
    var stripped = input
    stripped.text = PromoFilter.strip(input.text)
    return stripped
  }

  static func aedOverride(_ r: Reading, _ input: ExtractInput) -> Reading {
    guard r.isTransaction, let cur = r.currency, cur != "AED", r.currencyExplicit, let foreign = r.amountMinor,
      let aed = RuleReader.aedAmount(input, foreign: foreign, currency: cur)
    else { return r }
    var out = r
    out.amountMinor = aed
    out.currency = "AED"
    out.note += "; aed over \(cur)"
    return out
  }

  static func combine(learned l: Reading, rules r: Reading) -> (Reading, Bool) {
    switch (l.isTransaction, r.isTransaction) {
    case (true, true) where l.amountMinor == r.amountMinor && l.currency == r.currency:
      let directionsAgree = l.direction == r.direction || l.directionGuessed || r.directionGuessed
      let currencyStated = l.currencyExplicit || r.currencyExplicit
      guard directionsAgree, currencyStated, l.fromLayout else {
        var out = r
        out.merchant = r.merchant ?? l.merchant
        out.confidence = min(out.confidence, directionsAgree ? 60 : 50)
        let why = !directionsAgree ? "direction conflict" : !currencyStated ? "no currency stated" : "unlearned layout"
        out.note = "same amount, \(why): " + out.note
        return (out, false)
      }
      var out = l.confidence >= r.confidence ? l : r
      out.merchant = l.merchant ?? r.merchant
      if l.directionGuessed && !r.directionGuessed { out.direction = r.direction }
      if r.directionGuessed && !l.directionGuessed { out.direction = l.direction }
      out.currencyExplicit = true
      out.confidence = min(95, max(l.confidence, r.confidence) + 5)
      out.note = "agree: " + out.note
      return (out, true)
    case (true, true):
      var out = l.confidence >= r.confidence ? l : r
      out.confidence = min(out.confidence, 50)
      out.note = "disagree: " + out.note
      return (out, false)
    case (true, false):
      var out = l
      out.confidence = min(out.confidence, 60)
      out.note = "learned only: " + out.note
      return (out, false)
    case (false, true):
      var out = r
      out.confidence = min(out.confidence, 60)
      out.note = "rules only: " + out.note
      return (out, false)
    default:
      return (Reading(note: "learned: \(l.note) | rules: \(r.note)"), false)
    }
  }

  static func reading(_ r: Reading, _ input: ExtractInput, agreed: Bool, negative: Bool) -> ExtractReading {
    let direction = r.direction.flatMap(ExtractDirection.init(rawValue:))
    let kind = MailRules.kind(input, direction: r.isTransaction ? r.direction : nil)
    var notes = [r.note]
    let outcome: ExtractOutcome
    let card = kind == .cardPurchase || kind == .cardRefund
    if r.isTransaction {
      if !card && MailRules.isPending(input) {
        outcome = .pending
        notes.append("pending status")
      } else {
        outcome = .transaction
      }
    } else if negative {
      outcome = .notTransaction
    } else {
      let signal = card ? ExtractPending.none : MailRules.pendingSignal(input)
      if signal == .status || (signal == .phrase && kind == .transferNotice) {
        outcome = .pending
        notes.append("pending status, no amount")
      } else {
        outcome = .unknown
      }
    }
    guard r.isTransaction else {
      return ExtractReading(outcome: outcome, kind: kind, confidencePercent: 0, notes: notes)
    }
    var amountMinor = r.amountMinor
    if let c = r.currency, Exponent.of(c) != 2 {
      amountMinor = nil
      notes.append("\(c) is not a two-decimal currency: no amount in hundredths")
    }
    return ExtractReading(
      outcome: outcome, amountMinor: amountMinor, currency: r.currency, direction: direction, merchant: r.merchant,
      last4: MailRules.last4(input), kind: kind, confidencePercent: r.confidence, agreed: agreed, notes: notes)
  }
}
