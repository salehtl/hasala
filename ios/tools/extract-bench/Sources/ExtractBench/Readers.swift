import CoreExtract
import Foundation

enum Adapt {
  static let heldConfidence = 0.5

  static func input(_ m: Mail) -> ExtractInput {
    ExtractInput(sender: m.sender, subject: m.subject, text: m.text, receivedAtMs: m.receivedAtMs, listUnsubscribe: m.listUnsubscribe)
  }

  static func reading(_ x: ExtractReading) -> Reading {
    guard x.outcome == .transaction else { return Reading(note: "\(x.outcome.rawValue): " + x.notes.joined(separator: "; ")) }
    return Reading(
      isTransaction: true, amountMinor: x.amountMinor, currency: x.currency, merchant: x.merchant, direction: x.direction?.rawValue,
      confidence: Double(x.confidencePercent) / 100, note: x.notes.joined(separator: "; "))
  }

  static func held(_ r: Reading, _ why: String) -> Reading {
    var out = r
    out.confidence = min(out.confidence, heldConfidence)
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
    guard x.outcome == .transaction, x.isUsable else { return Adapt.reading(ExtractReading(outcome: .unknown, notes: x.notes)) }
    let r = Adapt.reading(x)
    return x.meetsAgreementBar ? r : Adapt.held(r, "below the agreement bar")
  }

  func combined(_ input: ExtractInput) -> ExtractReading {
    let (x, next) = CombinedReader.read(input, memory)
    memory = next
    return x
  }

  func read(_ m: Mail) -> Reading {
    let input = Adapt.input(m)
    let t = templates.read(m)
    guard t.isTransaction, let amount = t.amountMinor, let currency = t.currency else { return Self.filed(combined(input)) }
    guard
      let v = CombinedReader.templateVerdict(
        input, amountMinor: amount, currency: currency, direction: t.direction.flatMap(ExtractDirection.init(rawValue:)),
        read: { combined(input) })
    else { return Reading(note: "pending status: " + t.note) }
    var out = t
    out.amountMinor = v.amountMinor
    out.currency = v.currency
    if let over = v.aedOver { out.note += "; aed over \(over)" }
    for hold in v.holds { out = Adapt.held(out, hold.rawValue) }
    return out
  }
}
