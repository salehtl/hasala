public enum CombinedReader {
  public static func read(_ input: ExtractInput, _ memory: LearnedLayouts) -> (ExtractReading, LearnedLayouts) {
    var stripped = input
    stripped.text = PromoFilter.strip(input.text)
    let (l, next) = LearnedReader.read(stripped, memory)
    let r = RuleReader.read(stripped)
    let (out, agreed) = combine(learned: l, rules: r)
    return (reading(out, input, agreed: agreed, negative: l.negative || r.negative), next)
  }

  public static func readRules(_ input: ExtractInput) -> ExtractReading {
    var stripped = input
    stripped.text = PromoFilter.strip(input.text)
    let r = RuleReader.read(stripped)
    return reading(r, input, agreed: false, negative: r.negative)
  }

  public static func readLearned(_ input: ExtractInput, _ memory: LearnedLayouts) -> (ExtractReading, LearnedLayouts) {
    var stripped = input
    stripped.text = PromoFilter.strip(input.text)
    let (l, next) = LearnedReader.read(stripped, memory)
    return (reading(l, input, agreed: false, negative: l.negative), next)
  }

  static func combine(learned l: Reading, rules r: Reading) -> (Reading, Bool) {
    switch (l.isTransaction, r.isTransaction) {
    case (true, true) where l.amountMinor == r.amountMinor && l.currency == r.currency:
      var out = l.confidence >= r.confidence ? l : r
      out.merchant = l.merchant ?? r.merchant
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
    if r.isTransaction {
      if kind != .cardPurchase && kind != .cardRefund && MailRules.isPending(input) {
        outcome = .pending
        notes.append("pending status")
      } else {
        outcome = .transaction
      }
    } else {
      outcome = negative ? .notTransaction : .unknown
    }
    guard r.isTransaction else {
      return ExtractReading(outcome: outcome, kind: kind, confidencePercent: 0, notes: notes)
    }
    return ExtractReading(
      outcome: outcome, amountMinor: r.amountMinor, currency: r.currency, direction: direction, merchant: r.merchant,
      last4: MailRules.last4(input), kind: kind, confidencePercent: r.confidence, agreed: agreed, notes: notes)
  }
}
