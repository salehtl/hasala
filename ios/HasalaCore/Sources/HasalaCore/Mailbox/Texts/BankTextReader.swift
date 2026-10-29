import CoreExtract
import CoreNorm
import CoreTemplate
import CoreTime
import Foundation

public struct BankTextArrival: Sendable, Equatable {
  public var text: String
  public var sender: String?
  public var receivedAtMs: Int64
  public var testWindowOpen: Bool

  public init(text: String, sender: String?, receivedAtMs: Int64, testWindowOpen: Bool = false) {
    self.text = text
    self.sender = sender
    self.receivedAtMs = receivedAtMs
    self.testWindowOpen = testWindowOpen
  }

  public var arrivalMinuteMs: Int64 { Civil.floorDiv(receivedAtMs, 60_000) * 60_000 }
}

public struct BankTextTemplateHit: Sendable, Equatable {
  public let id: String
  public let version: Int
  public let senderMatches: Bool

  public var ref: String { "\(id)@\(version)" }
  public var transferRole: TextTransferRole? { TextTransferRole.of(templateRef: ref) }
}

public struct BankTextKept: Sendable, Equatable {
  public var sender: BankTextSenderKind
  public var bank: String?
  public var template: BankTextTemplateHit?
  public var fields: ParsedFields?
  public var merchant: String
  public var last4: String
  public var postedAt: String
  public var precision: String
  public var marked: Bool
  public var held: Bool
  public var countsAsPayment: Bool
  public var readerConfident = false

  public var tier: String { template != nil ? "template" : fields != nil ? "heuristic" : "none" }
  public var unparsed: Bool { fields == nil }

  public func timed(arrivalMinuteMs: Int64) -> BankTextKept {
    let precise = fields?.precision ?? precision
    guard precise == "day", let start = try? parseInstantMs(fields?.postedAt ?? postedAt) else { return self }
    let end = start + Civil.msPerDay
    let ms =
      arrivalMinuteMs < start ? start : arrivalMinuteMs < end ? arrivalMinuteMs : end - 60_000 - (arrivalMinuteMs - end) % Civil.msPerDay
    guard let at = Instant.iso(ms) else { return self }
    var k = self
    k.postedAt = at
    k.precision = "time"
    k.fields?.postedAt = at
    k.fields?.precision = "time"
    return k
  }
}

public enum BankTextReading: Sendable, Equatable {
  case setUpTest
  case dropped(TextDropKind, counted: Bool, bank: String?)
  case kept(BankTextKept)

  public var kept: BankTextKept? {
    if case .kept(let k) = self { return k }
    return nil
  }

  public var countsAsPayment: Bool { kept?.countsAsPayment ?? false }
}

public enum BankTextReader {
  public static let templates: [CompiledTemplate] = BundledTemplates.load(channel: .sms).templates
  static let bundledBanks = BankTextSenders.bankSenders(templates: templates)

  public static func normalized(_ text: String) -> String {
    (try? Normalizer.normalizeText(version: Normalizer.currentVersion, text: text)) ?? text
  }

  public static func sender(_ sender: String?) -> BankTextSender {
    BankTextSenders.classify(sender, banks: bundledBanks)
  }

  struct Read {
    var reading: BankTextReading
    var layouts: LearnedLayouts
    var sender: BankTextSender
    var text: String
  }

  public static func read(_ a: BankTextArrival, layouts: LearnedLayouts = LearnedLayouts()) -> (
    reading: BankTextReading, layouts: LearnedLayouts
  ) {
    let r = read(a, templates: templates, banks: bundledBanks, layouts: layouts)
    return (r.reading, r.layouts)
  }

  public static func read(_ a: BankTextArrival, templates: [CompiledTemplate], layouts: LearnedLayouts = LearnedLayouts()) -> (
    reading: BankTextReading, layouts: LearnedLayouts
  ) {
    let r = read(a, templates: templates, banks: BankTextSenders.bankSenders(templates: templates), layouts: layouts)
    return (r.reading, r.layouts)
  }

  static func read(_ a: BankTextArrival, templates: [CompiledTemplate], banks: [String: String], layouts: LearnedLayouts) -> Read {
    let sender = BankTextSenders.classify(a.sender, banks: banks)
    let text = normalized(a.text)
    let (r, next) = reading(a, sender: sender, text: text, templates: templates, layouts: layouts)
    return Read(reading: r, layouts: next, sender: sender, text: text)
  }

  static func reading(
    _ a: BankTextArrival, sender: BankTextSender, text: String, templates: [CompiledTemplate], layouts: LearnedLayouts
  ) -> (BankTextReading, LearnedLayouts) {
    func drop(_ k: TextDropKind) -> (BankTextReading, LearnedLayouts) {
      let counted = sender.kind == .bank
      return (.dropped(k, counted: counted, bank: counted ? sender.bank : nil), layouts)
    }
    guard text.utf8.count <= TextGate.maxTextBytes else { return drop(.noPaymentShape) }
    let gate = TextGate.Prepared(text)
    if TextGate.isSetUpTest(gate) {
      return (a.testWindowOpen ? .setUpTest : .dropped(.noPaymentShape, counted: false, bank: nil), layouts)
    }

    let marked: Bool
    switch TextGate.neverAPayment(gate) {
    case .drop(let k): return drop(k)
    case .pass(let m): marked = m
    }

    let learn = sender.learns
    var memory = layouts
    let input = ExtractInput(sender: sender.layoutKey, subject: "", text: text, receivedAtMs: a.receivedAtMs, listUnsubscribe: false)
    for t in templates where t.definition.isSMS {
      guard let x = try? t.execute(subject: "", normalizedBody: text), x.matched,
        let posted = MessageDisposer.postedAt(x, template: t, internalDateMs: a.arrivalMinuteMs),
        var f = MessageDisposer.usableFields(x, posted: posted)
      else { continue }
      let verdict = CombinedReader.templateVerdict(
        input, amountMinor: f.amountMinor, currency: f.currency, direction: ExtractDirection(rawValue: f.direction)
      ) {
        let (r, next) = CombinedReader.read(input, memory)
        if learn { memory = next }
        return r
      }
      if let verdict {
        f.amountMinor = verdict.amountMinor
        f.currency = verdict.currency
      }
      let hit = BankTextTemplateHit(
        id: t.definition.id, version: t.definition.version, senderMatches: a.sender.map { t.definition.matchesSMSSender($0) } ?? false)
      let kept = BankTextKept(
        sender: sender.kind, bank: t.definition.bank, template: hit, fields: f, merchant: f.merchant, last4: f.last4,
        postedAt: f.postedAt, precision: f.precision, marked: marked, held: verdict?.held ?? true, countsAsPayment: true)
      return (.kept(kept), memory)
    }

    if let k = TextGate.notice(gate) { return drop(k) }

    let lenient = sender.kind == .bank || sender.kind == .none
    guard TextGate.hasPaymentShape(gate, lenient: lenient) else { return drop(.noPaymentShape) }
    let (r, next) = CombinedReader.read(input, memory)
    if learn { memory = next }
    let stated = CombinedReader.statedDate(input)
    let limit = { (m: String?) -> String in
      sender.kind == .bank
        ? String((m ?? "").prefix(MessageDisposer.readerMerchantLimit)) : TextGate.cardPurchaseMerchant(text, merchant: m)
    }
    var fields: ParsedFields?
    if r.outcome == .transaction, var f = MessageDisposer.readerFields(r, stated: stated, internalDateMs: a.arrivalMinuteMs) {
      f.merchant = limit(f.merchant)
      fields = f
    }
    let last4 =
      (r.last4 ?? TextGate.maskedLast4(gate)).flatMap { $0.utf8.count == 4 && $0.utf8.allSatisfy { $0 >= 0x30 && $0 <= 0x39 } ? $0 : nil }
      ?? ""
    let timed = MessageDisposer.readerPostedAt(stated, internalDateMs: a.arrivalMinuteMs).flatMap { $0.1 == "time" ? $0.0 : nil }
    let kept = BankTextKept(
      sender: sender.kind, bank: sender.bank, template: nil, fields: fields, merchant: fields?.merchant ?? limit(r.merchant),
      last4: fields?.last4 ?? last4, postedAt: fields?.postedAt ?? timed ?? Instant.iso(a.arrivalMinuteMs) ?? "",
      precision: fields?.precision ?? "time", marked: marked, held: false, countsAsPayment: lenient,
      readerConfident: fields != nil && r.meetsFilingBar && r.kind != .transferNotice)
    return (.kept(kept), memory)
  }
}
