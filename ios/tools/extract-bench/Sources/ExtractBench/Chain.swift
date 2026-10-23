import Foundation

enum PromoFilter {
  static let promo = [
    "earn", "win ", "cashback", "cash back", "offer", "discount", "reward", "points", "save up", "up to", "promo", "exclusive",
    "apply now", "eligible", "voucher", "bonus", "free ", "% off",
    "اربح", "استرداد نقدي", "عرض", "عروض", "مكافأة", "مكافاة", "نقاط", "وفر", "قسيمة", "حصري", "مجانا", "مجاناً", "احصل",
  ]
  static let posted = ["has been", "was ", "debited", "credited", "تم ", "تمت"]

  static func strip(_ text: String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false).filter { line in
      let l = line.lowercased()
      guard l.unicodeScalars.contains(where: { CharacterSet.decimalDigits.contains($0) }) else { return true }
      guard promo.contains(where: { l.contains($0) }) else { return true }
      return posted.contains(where: { l.contains($0) })
    }.joined(separator: "\n")
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
    if t.isTransaction { return t }
    switch (l.isTransaction, r.isTransaction) {
    case (true, true) where l.amountMinor == r.amountMinor && l.currency == r.currency:
      var out = l.confidence >= r.confidence ? l : r
      out.merchant = l.merchant ?? r.merchant
      out.confidence = min(0.95, max(l.confidence, r.confidence) + 0.05)
      out.note = "agree: " + out.note
      return out
    case (true, true):
      var out = l.confidence >= r.confidence ? l : r
      out.confidence = min(out.confidence, 0.5)
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
}
