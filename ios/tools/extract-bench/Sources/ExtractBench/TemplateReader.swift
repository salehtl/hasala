import CoreTemplate

final class TemplateReader: Reader {
  let name = "templates"
  let templates: [CompiledTemplate]

  init() {
    templates = BundledTemplates.load().templates
  }

  func read(_ m: Mail) -> Reading {
    for t in templates where t.definition.match.senderDomain.contains(where: { m.sender == $0 || m.sender.hasSuffix("." + $0) }) {
      guard let x = try? t.execute(subject: m.subject, normalizedBody: m.text), x.matched, !x.currency.isEmpty else { continue }
      return Reading(
        isTransaction: true, amountMinor: x.amountMinor, currency: x.currency, merchant: x.merchant.isEmpty ? nil : x.merchant,
        direction: x.direction.isEmpty ? nil : x.direction, confidence: 1, note: "\(t.definition.id)@\(t.definition.version)")
    }
    return .none
  }
}
