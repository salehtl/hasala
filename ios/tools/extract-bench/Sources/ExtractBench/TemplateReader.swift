import CoreTemplate
import CoreTime

final class TemplateReader: Reader {
  let name = "templates"
  let templates: [(CompiledTemplate, [String])]
  static let maxAmountMinor: Int64 = 9_999_999_999_999

  init() {
    templates = BundledTemplates.load().templates.map { t in (t, t.definition.match.senderDomain.map(Self.asciiLower)) }
  }

  static func asciiLower(_ s: String) -> String {
    String(decoding: s.utf8.map { $0 >= 0x41 && $0 <= 0x5a ? $0 + 0x20 : $0 }, as: UTF8.self)
  }

  static func usable(_ x: Extraction) -> Bool {
    x.matched && usable(amountMinor: x.amountMinor, currency: x.currency, direction: x.direction, postedAt: x.postedAt)
  }

  static func usable(amountMinor: Int64, currency: String, direction: String, postedAt: String) -> Bool {
    guard amountMinor > 0, amountMinor <= maxAmountMinor, currency.utf8.count == 3,
      currency.utf8.allSatisfy({ $0 >= 0x41 && $0 <= 0x5a }), direction == "debit" || direction == "credit"
    else { return false }
    if postedAt.isEmpty { return true }
    return (try? parseInstantMs(postedAt)) != nil
  }

  func read(_ m: Mail) -> Reading {
    let sender = Self.asciiLower(m.sender)
    for (t, domains) in templates where domains.contains(where: { sender == $0 || sender.hasSuffix("." + $0) }) {
      guard let x = try? t.execute(subject: m.subject, normalizedBody: m.text), Self.usable(x) else { continue }
      return Reading(
        isTransaction: true, amountMinor: x.amountMinor, currency: x.currency, merchant: x.merchant.isEmpty ? nil : x.merchant,
        direction: x.direction, confidence: 1, note: "\(t.definition.id)@\(t.definition.version)")
    }
    return .none
  }
}
