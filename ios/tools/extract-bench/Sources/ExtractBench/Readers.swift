import CoreExtract
import Foundation

enum Adapt {
  static let held = 0.5

  static func input(_ m: Mail) -> ExtractInput {
    ExtractInput(sender: m.sender, subject: m.subject, text: m.text, receivedAtMs: m.receivedAtMs, listUnsubscribe: m.listUnsubscribe)
  }

  static func reading(_ x: ExtractReading) -> Reading {
    guard x.outcome == .transaction else { return Reading(note: "\(x.outcome.rawValue): " + x.notes.joined(separator: "; ")) }
    return Reading(
      isTransaction: true, amountMinor: x.amountMinor, currency: x.currency, merchant: x.merchant, direction: x.direction?.rawValue,
      confidence: Double(x.confidencePercent) / 100, note: x.notes.joined(separator: "; "))
  }

  static func usable(_ x: ExtractReading) -> Bool {
    guard let a = x.amountMinor, let c = x.currency, x.direction != nil else { return false }
    return a > 0 && a <= TemplateReader.maxAmountMinor && c.utf8.count == 3 && c.utf8.allSatisfy { $0 >= 0x41 && $0 <= 0x5a }
  }

  static func held(_ r: Reading, _ why: String) -> Reading {
    var out = r
    out.confidence = min(out.confidence, held)
    out.note += "; " + why
    return out
  }
}

final class RulesReader: Reader {
  let name = "rules"

  func read(_ m: Mail) -> Reading { Adapt.reading(CombinedReader.readRules(Adapt.input(m))) }
}

final class LearnedOnlyReader: Reader {
  let name = "learned"
  var memory = LearnedLayouts()

  func reset() { memory = LearnedLayouts() }

  func read(_ m: Mail) -> Reading {
    let (x, next) = CombinedReader.readLearned(Adapt.input(m), memory)
    memory = next
    return Adapt.reading(x)
  }
}

final class CombinedOnlyReader: Reader {
  let name = "combined"
  var memory = LearnedLayouts()

  func reset() { memory = LearnedLayouts() }

  func read(_ m: Mail) -> Reading {
    let (x, next) = CombinedReader.read(Adapt.input(m), memory)
    memory = next
    return ChainReader.filed(x)
  }
}

final class ChainReader: Reader {
  let name = "chain"
  let templates = TemplateReader()
  var memory = LearnedLayouts()

  func reset() { memory = LearnedLayouts() }

  static func filed(_ x: ExtractReading) -> Reading {
    guard x.outcome == .transaction, Adapt.usable(x) else { return Adapt.reading(ExtractReading(outcome: .unknown, notes: x.notes)) }
    let r = Adapt.reading(x)
    return x.meetsAgreementBar ? r : Adapt.held(r, "below the agreement bar")
  }

  func read(_ m: Mail) -> Reading {
    let input = Adapt.input(m)
    let t = templates.read(m)
    let (x, next) = CombinedReader.read(input, memory)
    memory = next
    guard t.isTransaction, let amount = t.amountMinor, let currency = t.currency else { return Self.filed(x) }
    let pending = CombinedReader.pending(input, direction: t.direction.flatMap(ExtractDirection.init(rawValue:)))
    if pending == .status { return Reading(note: "pending status: " + t.note) }
    var out = t
    if let aed = CombinedReader.aedAmount(input, foreign: amount, currency: currency), aed <= TemplateReader.maxAmountMinor {
      out.amountMinor = aed
      out.currency = "AED"
      out.note += "; aed over \(currency)"
      let confirmed = x.outcome == .transaction && x.agreed && x.amountMinor == aed && x.currency == "AED"
      if !confirmed { out = Adapt.held(out, "aed not confirmed by the readers") }
    }
    if pending == .phrase { out = Adapt.held(out, "pending phrase") }
    return out
  }
}
