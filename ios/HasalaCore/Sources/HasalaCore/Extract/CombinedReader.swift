public enum CombinedReader {
  public static let maxTextUTF16 = 65_536
  public static let maxSubjectUTF16 = 1_024

  public static func read(_ input: ExtractInput, _ memory: LearnedLayouts) -> (ExtractReading, LearnedLayouts) {
    let input = bounded(input)
    let stripped = strip(input)
    let (l, next) = LearnedReader.read(stripped, memory)
    let r = RuleReader.read(stripped)
    let lo = aedOverride(dateless(l, stripped.text), stripped)
    let ro = aedOverride(dateless(r, stripped.text), stripped)
    let (out, agreed) = combine(learned: lo, rules: ro, text: stripped.text)
    var result = reading(out, input, agreed: agreed, negative: l.negative || r.negative)
    if out.isTransaction {
      result.rulesConfidencePercent = ro.isTransaction ? ro.confidence : 0
      result.learnedConfidencePercent = lo.isTransaction ? lo.confidence : 0
      result.readersAgree = readersAgree(lo, ro)
      result.directionAmbiguous = ro.directionAmbiguous && result.direction?.rawValue == ro.direction
      result.aedFromOverride = out.aedOverride && !readsItself(l, out) && !readsItself(r, out)
      result.aedOverrideUsed = lo.aedOverride || ro.aedOverride
    }
    return (result, result.outcome == .notTransaction ? memory : next)
  }

  public static func readRules(_ input: ExtractInput) -> ExtractReading {
    let input = bounded(input)
    let stripped = strip(input)
    let r = aedOverride(dateless(RuleReader.read(stripped), stripped.text), stripped)
    return reading(r, input, agreed: false, negative: r.negative)
  }

  public static func readLearned(_ input: ExtractInput, _ memory: LearnedLayouts) -> (ExtractReading, LearnedLayouts) {
    let input = bounded(input)
    let stripped = strip(input)
    let (l, next) = LearnedReader.read(stripped, memory)
    let result = reading(aedOverride(dateless(l, stripped.text), stripped), input, agreed: false, negative: l.negative)
    return (result, result.outcome == .notTransaction ? memory : next)
  }

  public static func aedAmount(_ input: ExtractInput, foreign: Int64, currency: String) -> Int64? {
    guard currency != "AED", foreign > 0 else { return nil }
    return RuleReader.aedAmount(strip(input), foreign: foreign, currency: currency)
  }

  public static func pending(_ input: ExtractInput, direction: ExtractDirection?) -> ExtractPending {
    let input = bounded(input)
    if MailRules.kind(input, direction: direction?.rawValue).isCard { return .none }
    return MailRules.pendingSignal(input)
  }

  public static func templateVerdict(
    _ input: ExtractInput, amountMinor: Int64, currency: String, direction: ExtractDirection?, captured: String? = nil,
    read: () -> ExtractReading?
  ) -> ExtractTemplateVerdict? {
    let signal = pending(input, direction: direction)
    if signal == .status && MailRules.setsAside(bounded(input), direction: direction?.rawValue, captured: captured) { return nil }
    let reading = read()
    var out = ExtractTemplateVerdict(amountMinor: amountMinor, currency: currency)
    if let iso = ExtractCurrency.iso(currency) {
      out.currency = iso
      if let aed = aedAmount(input, foreign: amountMinor, currency: iso), aed <= ExtractReading.maxAmountMinor {
        out.amountMinor = aed
        out.currency = "AED"
        out.aedOver = iso
        let confirmed =
          reading.map {
            $0.outcome == .transaction && $0.agreed && !$0.aedFromOverride && $0.amountMinor == aed && $0.currency == "AED"
          } ?? false
        if !confirmed { out.holds.append(.aedNotConfirmed) }
      }
      if let reading, reading.readersConfirm,
        reading.amountMinor != out.amountMinor || reading.currency != out.currency || reading.direction != direction
      {
        out.holds.append(.readersDisagree)
      }
    } else {
      out.holds.append(.currencyNotISO)
    }
    if signal == .phrase { out.holds.append(.pendingPhrase) }
    if signal == .status { out.holds.append(.pendingStatus) }
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

  static func readsItself(_ r: Reading, _ out: Reading) -> Bool {
    r.isTransaction && !r.aedOverride && r.currency == out.currency && r.amountMinor == out.amountMinor
  }

  static func bounded(_ input: ExtractInput) -> ExtractInput {
    var out = input
    out.text = RuleText.prefix(input.text, utf16: maxTextUTF16)
    out.subject = RuleText.prefix(input.subject, utf16: maxSubjectUTF16)
    return out
  }

  static func strip(_ input: ExtractInput) -> ExtractInput {
    var stripped = bounded(input)
    stripped.text = PromoFilter.strip(stripped.text)
    return stripped
  }

  static func aedOverride(_ r: Reading, _ input: ExtractInput) -> Reading {
    guard r.isTransaction, let cur = r.currency, cur != "AED", r.currencyExplicit, let foreign = r.amountMinor,
      let aed = RuleReader.aedAmount(input, foreign: foreign, currency: cur)
    else { return r }
    var out = r
    out.amountMinor = aed
    out.currency = "AED"
    out.aedOverride = true
    out.note += "; aed over \(cur)"
    return out
  }

  static func dateless(_ r: Reading, _ text: String) -> Reading {
    var out = r
    let raw = r.merchant?.trimmingCharacters(in: .whitespaces)
    var t = MerchantWhen.trimmed(r.merchant)
    if t == raw { t = MerchantWhen.reconcile(learned: t, rules: nil, text: text) }
    out.merchantTrimmed = t != raw
    out.merchant = t
    return out
  }

  static func combine(learned l: Reading, rules r: Reading, text: String = "") -> (Reading, Bool) {
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
      out.merchant = l.merchantTrimmed
        ? (l.merchant ?? r.merchant) : MerchantWhen.reconcile(learned: l.merchant, rules: r.merchant, text: text)
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
    let card = kind.isCard
    var held = false
    if r.isTransaction {
      let signal = card ? ExtractPending.none : MailRules.pendingSignal(input)
      let aside =
        signal == .phrase
        ? MailRules.statesPendingTransfer(input, direction: r.direction, amountMinor: r.amountMinor)
        : signal == .status && MailRules.setsAside(input, direction: r.direction, captured: r.merchant)
      if aside {
        outcome = .pending
        notes.append("pending status")
      } else {
        outcome = .transaction
        held = signal != .none
        if held { notes.append("pending wording held") }
      }
    } else if negative {
      outcome = .notTransaction
    } else {
      if !card && MailRules.setsAside(input, direction: nil) {
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
    var out = ExtractReading(
      outcome: outcome, amountMinor: amountMinor, currency: r.currency, direction: direction, merchant: r.merchant,
      last4: MailRules.last4(input), kind: kind, confidencePercent: r.confidence, agreed: agreed, notes: notes,
      aedFromOverride: r.aedOverride)
    out.pendingWordingHeld = held
    return out
  }
}
