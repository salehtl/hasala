import Foundation

enum PromoFilter {
  static let strong = RuleText.words(
    [
      "earn", "earns", "earned", "earning", "win", "wins", "won", "cashback", "cash back", "offer", "offers", "discount",
      "discounts", "reward", "rewards", "points", "save up to", "promo", "promotion", "voucher", "vouchers", "bonus",
    ],
    [])
  static let weak = RuleText.words(["free", "up to", "exclusive", "apply now", "eligible"], [])
  static let percentOff = RuleText.re("%\\s*off(?![a-z])")
  static let arabicPromo = RuleText.re(
    "(?<![\\p{L}])(?:و|ف|ب|ل|ال|وال|بال|فال|لل)?(?:"
      + ["اربح", "استرداد نقدي", "عرض", "عروض", "مكافأة", "مكافاة", "مكافأت", "مكافات", "نقاط", "وفر", "قسيمة", "قسيمه", "حصري", "مجانا", "مجاناً", "احصل"]
      .map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|") + ")")
  static let posted = RuleText.re("(?<![a-z])(?:has been|was|debited|credited)(?![a-z])|(?<![\\p{L}])(?:تم|تمت)(?![\\p{L}])")

  static func isPromo(_ line: String) -> Bool {
    let l = line.lowercased()
    guard l.unicodeScalars.contains(where: { CharacterSet.decimalDigits.contains($0) }) else { return false }
    if RuleText.has(posted, l) { return false }
    if RuleText.has(strong, l) || RuleText.has(percentOff, l) || RuleText.has(arabicPromo, l) { return true }
    guard RuleText.has(weak, l) else { return false }
    let f = RuleText.fold(l)
    return !RuleText.has(RuleLexicon.amountLabel, f) && !RuleText.has(RuleLexicon.txnVerb, f)
  }

  static func strip(_ text: String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false).filter { !isPromo(String($0)) }.joined(separator: "\n")
  }
}

final class Filtered: Reader {
  let inner: Reader
  let name: String

  init(_ inner: Reader) {
    self.inner = inner
    name = inner.name + "+promo"
  }

  func reset() { inner.reset() }

  func read(_ m: Mail) -> Reading {
    var c = m
    c.text = PromoFilter.strip(m.text)
    return inner.read(c)
  }
}

enum Gate {
  static let fileWithoutReview = 0.8
  static let held = 0.5

  static func agree(_ l: Reading, _ r: Reading) -> Bool {
    l.isTransaction && r.isTransaction && l.amountMinor != nil && l.amountMinor == r.amountMinor && l.currency != nil
      && l.currency == r.currency
  }

  static func combine(learned l: Reading, rules r: Reading) -> Reading {
    var out = combined(learned: l, rules: r)
    if let c = out.currency, Hundredths.refused.contains(c) {
      out.confidence = min(out.confidence, held)
      out.note += "; currency not in hundredths"
    }
    return out
  }

  static func combined(learned l: Reading, rules r: Reading) -> Reading {
    switch (l.isTransaction, r.isTransaction) {
    case (true, true) where agree(l, r):
      let lead = l.confidence >= r.confidence
      var out = lead ? l : r
      out.merchant = out.merchant ?? (lead ? r.merchant : l.merchant)
      out.confidence = min(0.95, min(l.confidence, r.confidence))
      out.note = "agree: " + out.note
      if l.direction != r.direction {
        out.confidence = min(out.confidence, held)
        out.note += "; direction differs"
      }
      return out
    case (true, true):
      var out = l.confidence >= r.confidence ? l : r
      out.confidence = min(out.confidence, held)
      out.note = "disagree: " + out.note
      return out
    case (true, false):
      var out = l
      out.confidence = min(out.confidence, 0.6)
      return out
    case (false, true):
      var out = r
      out.confidence = min(out.confidence, 0.6)
      return out
    default:
      return .none
    }
  }

  static func contradicts(_ x: Reading, _ t: Reading) -> Bool {
    x.isTransaction && x.amountMinor != nil && x.currency != nil
      && (x.amountMinor != t.amountMinor || x.currency != t.currency)
  }

  static func checkTemplate(_ t: Reading, learned l: Reading, rules r: Reading) -> Reading {
    var out = t
    if let c = t.currency, !RuleMoneyParser.codes.contains(c) {
      out.confidence = min(out.confidence, held)
      out.note += "; currency not ISO"
    } else if let d = [l, r].first(where: { contradicts($0, t) }) {
      out.confidence = min(out.confidence, held)
      out.note += "; a reader reads \(d.amountMinor ?? -1) \(d.currency ?? "")"
    }
    return out
  }
}

final class ChainReader: Reader {
  let name = "chain"
  let templates = TemplateReader()
  let learned = Filtered(InductionReader())
  let rules = Filtered(RuleReader())

  func reset() {
    learned.reset()
    rules.reset()
  }

  func read(_ m: Mail) -> Reading {
    let l = learned.read(m)
    let r = rules.read(m)
    let t = templates.read(m)
    if t.isTransaction { return Gate.checkTemplate(t, learned: l, rules: r) }
    return Gate.combine(learned: l, rules: r)
  }
}
