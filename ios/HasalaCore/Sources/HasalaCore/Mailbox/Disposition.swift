// What one downloaded bank message becomes (spec 04 §7.5 steps 7d-7e, §7.6; port of fetch.ts
// `disposeMessage`, re-cut into two halves so the first-connect scan can stage between them):
//
//   parse(...)    raw bytes -> set aside | ParsedMail   (trust analysis, normalizer, templates,
//                                                       posted_at conversion; no fold state)
//   finalize(...) ParsedMail + known cards + decide() -> MailboxIngestDraft (the txn_ingested
//                                                       payload and its review flag)
//
// This is op-authoring code. Its two disciplines, from fetch.ts:
//   1. Nothing is silently dropped. A message is set aside (not a bank: no op, recorded and
//      shown), or becomes an op: filed, prefilled-for-review, or the EMPTY review shape.
//   2. Filing without review needs every gate: Gmail's A-R verdict `pass`, the VERIFIED domain in
//      the trusted set T, a template hit with a usable amount, a card not marked "not mine", and
//      not forwarded. Anything less is `needs_review: true`. A card the ledger doesn't know
//      (`unknown`) files like a known one: setup has no cards step, and what an alert says about
//      the card is up to each bank, so filing never depends on it. The gate still records it.
import CoreJSON
import CoreMail
import CoreNorm
import CorePrimitives
import CoreTemplate
import CoreTime
import Foundation

/// The per-message size cap (fetch.ts MAILBOX_MAX_MESSAGE_BYTES): at or over it, unreadable.
public enum MailboxLimits {
  public static let maxMessageBytes = 1_000_000
}

/// The trust and parse facts a row records in its `gates` object (03c §3.1), display only.
public struct MailGates: Sendable, Equatable, Codable {
  /// AuthResults.Reason raw value: pass | no_ar | multiple_ar | not_topmost | fail | parse_error |
  /// no_eop (Outlook).
  public var ar: String
  /// The verified domain is in the trusted set T.
  public var senderTrusted: Bool
  /// `<id>@<version>` of the template that read the message, nil when none did.
  public var template: String?
  public var forwarded: Bool
}

public struct ParsedFields: Sendable, Equatable, Codable {
  public var amountMinor: Int64
  public var currency: String
  public var direction: String
  public var merchant: String
  public var last4: String
  /// Canonical UTC instant.
  public var postedAt: String
  /// "time" or "day".
  public var precision: String
  public var isTransfer: Bool
}

/// A downloaded bank message, read as far as the device can, before the fold-dependent gates
/// (known cards) and categorization. This is what the first-connect scan stages.
public struct ParsedMail: Sendable, Equatable, Codable {
  public var messageID: String
  /// hex(SHA-256(raw)), lower case.
  public var ingestID: String
  public var internalDateMs: Int64
  /// The template's bank id ("" when no template read it).
  public var bank: String
  /// "" when the template has no card field or none was extracted.
  public var last4: String
  public var templateHasCardField: Bool
  public var gates: MailGates
  /// nil: the empty review shape (no template hit with a usable amount).
  public var fields: ParsedFields?
  /// The empty shape's day (canonical instant of local midnight), always set.
  public var dayPostedAt: String
  public var headerIDHash: String? = nil
}

public struct CardKey: Sendable, Hashable, Codable, Comparable {
  public var bank: String
  public var last4: String
  public init(bank: String, last4: String) {
    self.bank = bank
    self.last4 = last4
  }
  public static func < (a: CardKey, b: CardKey) -> Bool {
    let (x, y) = (Array(a.bank.utf8), Array(b.bank.utf8))
    if x != y { return x.lexicographicallyPrecedes(y) }
    return Array(a.last4.utf8).lexicographicallyPrecedes(Array(b.last4.utf8))
  }
}

public enum CardState: String, Sendable, Codable { case mine, notMine = "not_mine" }

/// The at-ingest categorization decision (03c §8.2, `decide`), supplied by CoreCategorize's
/// owner. `source` is the `CategorySource` JSON (03c §3.2.1).
public struct IngestDecision: Sendable, Equatable {
  public var category: String?
  public var source: JSONValue
  public init(category: String?, source: JSONValue) {
    self.category = category
    self.source = source
  }
  public static let none = IngestDecision(category: nil, source: .object(JSONObject([("kind", .string("none"))])))
}

public protocol IngestCategorizer: Sendable {
  func decide(merchantRaw: String, direction: String) -> IngestDecision
}

/// No rules, no dictionary: everything files uncategorized (until CoreCategorize lands).
public struct NoCategorizer: IngestCategorizer {
  public init() {}
  public func decide(merchantRaw: String, direction: String) -> IngestDecision { .none }
}

/// One `txn_ingested` to author: its ingest id (the envelope's), the payload, and whether it is a
/// review item. The op itself (ULID entity id, op id, authored_at, envelope) is built by
/// CoreDomain's OpAuthor behind `MailboxPersistence` (spec 04 §2.4 R5).
public struct MailboxIngestDraft: Sendable, Equatable {
  public let messageID: String
  public let ingestID: String
  public let internalDateMs: Int64
  public let payload: JSONObject
  public let needsReview: Bool
}

public enum MessageDisposer {
  public enum Parse: Sendable, Equatable {
    /// Neither the claimed nor the verified domain is a bank domain (a sender-query false
    /// positive, spec 04 §7.5 step 7b): no op; domain + date only.
    case setAside(domain: String)
    case mail(ParsedMail)
  }

  /// Reads one raw message. `topLevelFrom` is the message's own From (from the metadata
  /// fetch, or the raw headers); `bankDomains` is the listing set, `trusted` the trust set T;
  /// `analyze` is the provider's Authentication-Results rule (`MailProvider.analyzeAuthResults`).
  public static func parse(
    raw: [UInt8], messageID: String, internalDateMs: Int64, topLevelFrom: String,
    templates: [CompiledTemplate], bankDomains: [String], trusted: [String],
    analyze: (String) -> AuthResults.Analysis
  ) -> Parse {
    let headers = MailHeaders.headerBlock(rawMessage: raw)
    let analysis = analyze(headers)
    let verified = analysis.verdict.trusted ? analysis.domain : nil
    let norm = try? Normalizer.normalize(version: Normalizer.currentVersion, raw: raw, receivedAtMs: internalDateMs)

    var domains: [String] = []
    for d in [verified ?? "", BankDomains.domainOf(norm?.from ?? ""), BankDomains.domainOf(topLevelFrom)]
    where !d.isEmpty && !domains.contains(d) {
      domains.append(d)
    }
    guard domains.contains(where: { BankDomains.isMember($0, of: bankDomains) }) else {
      return .setAside(domain: domains.first ?? "")
    }

    let senderTrusted = verified.map { BankDomains.isMember($0, of: trusted) } ?? false
    let forwarded = norm?.forwarded ?? false
    let day = dayInstant(internalDateMs)
    var mail = ParsedMail(
      messageID: messageID, ingestID: "", internalDateMs: internalDateMs, bank: "", last4: "",
      templateHasCardField: false,
      gates: MailGates(ar: analysis.verdict.reason.rawValue, senderTrusted: senderTrusted, template: nil, forwarded: forwarded),
      fields: nil, dayPostedAt: day)
    mail.ingestID = ingestID(raw)
    mail.headerIDHash = MessageIDEvidence.hash(headers: headers)

    guard let norm else { return .mail(mail) }
    for t in templates where t.definition.match.senderDomain.contains(where: { want in
      domains.contains { BankDomains.isMember($0, of: [asciiLowerString(want)]) }
    }) {
      guard let x = try? t.execute(subject: norm.subject, normalizedBody: norm.text), x.matched else { continue }
      guard let posted = postedAt(x, template: t, internalDateMs: internalDateMs),
        let f = usableFields(x, posted: posted)
      else { continue }
      mail.bank = t.definition.bank
      mail.templateHasCardField = t.definition.extract.contains { $0.field == "last4" }
      mail.last4 = x.last4
      mail.gates.template = "\(t.definition.id)@\(t.definition.version)"
      mail.fields = f
      return .mail(mail)
    }
    return .mail(mail)
  }

  /// The payload for a parsed message, with the card gate and the categorization applied.
  /// `provider` is `provenance.provider` (the mailbox the message came from).
  public static func finalize(
    _ m: ParsedMail, provider: MailProviderID, grantID: String, cards: [CardKey: CardState],
    categorizer: any IngestCategorizer
  ) -> MailboxIngestDraft {
    let provenance = JSONValue.object(
      JSONObject([
        ("provider", .string(provider.rawValue)), ("grant_id", .string(grantID)), ("message_id", .string(m.messageID)),
      ]))
    guard let f = m.fields else {
      // The empty needs-review shape (spec 04 §7.6 row 2): no amount, no currency, no direction,
      // no body text; dated at local midnight of the email's local day.
      let gates = gatesJSON(m.gates, template: "none", card: "none")
      var p = JSONObject([
        ("unparsed", .bool(true)), ("needs_review", .bool(true)), ("posted_at", .string(m.dayPostedAt)),
        ("posted_precision", .string("day")), ("merchant_raw", .string("")), ("last4", .string("")),
        ("category", .null), ("entry_method", .string("mailbox")), ("provenance", provenance), ("gates", gates),
      ])
      if let h = m.headerIDHash { p["dedupe"] = .object(JSONObject([("message_id", .string(h))])) }
      return MailboxIngestDraft(
        messageID: m.messageID, ingestID: m.ingestID, internalDateMs: m.internalDateMs, payload: p, needsReview: true)
    }

    let card: String
    if !m.templateHasCardField {
      card = "none"
    } else {
      switch cards[CardKey(bank: m.bank, last4: m.last4)] {
      case .mine?: card = "known"
      case .notMine?: card = "not_mine"
      case nil: card = "unknown"
      }
    }
    let filesItself =
      m.gates.ar == AuthResults.Reason.pass.rawValue && m.gates.senderTrusted && !m.gates.forwarded
      && card != "not_mine"
    let decision = categorizer.decide(merchantRaw: f.merchant, direction: f.direction)

    var p = JSONObject([
      ("amount_minor", .string(String(f.amountMinor))), ("currency", .string(f.currency)),
      ("direction", .string(f.direction)), ("posted_at", .string(f.postedAt)),
      ("posted_precision", .string(f.precision)), ("merchant_raw", .string(f.merchant)), ("last4", .string(f.last4)),
    ])
    if let c = decision.category {
      p["category"] = .string(c)
      p["category_source"] = decision.source
    }
    p["needs_review"] = .bool(!filesItself)
    p["unparsed"] = .bool(false)
    p["tier"] = .string("template")
    p["entry_method"] = .string("mailbox")
    p["provenance"] = provenance
    p["bank"] = .string(m.bank)
    p["gates"] = gatesJSON(m.gates, template: m.gates.template ?? "none", card: card)
    if let h = m.headerIDHash { p["dedupe"] = .object(JSONObject([("message_id", .string(h))])) }
    return MailboxIngestDraft(
      messageID: m.messageID, ingestID: m.ingestID, internalDateMs: m.internalDateMs, payload: p,
      needsReview: !filesItself)
  }

  public static func refusedShape(_ d: MailboxIngestDraft, keepGates: Bool) -> MailboxIngestDraft {
    var p = JSONObject([
      ("unparsed", .bool(true)), ("needs_review", .bool(true)), ("parse_error", .string("payload_refused")),
      ("posted_at", .string(dayInstant(d.internalDateMs))), ("posted_precision", .string("day")),
      ("merchant_raw", .string("")), ("last4", .string("")), ("category", .null), ("entry_method", .string("mailbox")),
    ])
    if let prov = d.payload["provenance"] { p["provenance"] = prov }
    if keepGates, let g = d.payload["gates"] { p["gates"] = g }
    return MailboxIngestDraft(
      messageID: d.messageID, ingestID: d.ingestID, internalDateMs: d.internalDateMs, payload: p, needsReview: true)
  }

  static func gatesJSON(_ g: MailGates, template: String, card: String) -> JSONValue {
    .object(
      JSONObject([
        ("ar", .string(g.ar)), ("sender", .string(g.senderTrusted ? "trusted" : "untrusted")),
        ("template", .string(template)), ("card", .string(card)), ("forwarded", .bool(g.forwarded)),
      ]))
  }

  /// hex(SHA-256(raw)), lower case.
  public static func ingestID(_ raw: [UInt8]) -> String {
    Hex.encode(sha256(Data(raw)))
  }

  /// Canonical instant of local midnight (+04:00) of the instant's local day.
  public static func dayInstant(_ epochMs: Int64) -> String {
    guard let d = LocalClock.localDate(epochMs), let s = Instant.iso(LocalClock.startOfDay(d)) else {
      return "1970-01-01T00:00:00.000Z"
    }
    return s
  }

  /// 03c §1.5: the template renders the bank's zoneless UAE wall clock with a `Z`. With a time:
  /// `wall − 4 h`, precision "time". A bare date D: local midnight, `(D−1)T20:00:00.000Z`,
  /// precision "day". No body date (`date_from: "email"`): Gmail's internalDate, already UTC.
  static func postedAt(_ x: Extraction, template t: CompiledTemplate, internalDateMs: Int64) -> (String, String)? {
    if x.postedAt.isEmpty {
      guard let s = Instant.iso(internalDateMs) else { return nil }
      return (s, "time")
    }
    guard let wallMs = try? parseInstantMs(x.postedAt) else { return nil }
    let layouts = t.definition.extract.filter { $0.field == "date" }.flatMap(\.layouts)
    let timed = layouts.map { $0.contains("hh") || $0.contains("HH") }
    let isMidnight = Civil.floorDiv(wallMs, Civil.msPerDay) * Civil.msPerDay == wallMs
    // A bare-date layout renders midnight. When the template has both kinds of layout, a
    // midnight value is read as a bare date (a printed 12:00 AM loses its time; it keeps its day).
    let dayOnly = !timed.contains(true) || (isMidnight && timed.contains(false))
    if dayOnly {
      // The wall value's own civil date D (it is a zoneless wall clock, so no offset applies).
      guard let d = CivilDate(daysSinceEpoch: Civil.floorDiv(wallMs, Civil.msPerDay)),
        let s = Instant.iso(LocalClock.startOfDay(d))
      else { return nil }
      return (s, "day")
    }
    guard let s = Instant.iso(wallMs - LocalClock.offsetMs) else { return nil }
    return (s, "time")
  }

  /// A template hit is usable when the amount is positive, the currency is three upper-case
  /// letters and the direction is debit or credit; otherwise it is a miss (the safe direction:
  /// the message becomes the empty review shape).
  static func usableFields(_ x: Extraction, posted: (String, String)) -> ParsedFields? {
    guard x.amountMinor > 0, x.currency.utf8.count == 3, x.currency.utf8.allSatisfy({ $0 >= 0x41 && $0 <= 0x5a }),
      x.direction == "debit" || x.direction == "credit"
    else { return nil }
    return ParsedFields(
      amountMinor: x.amountMinor, currency: x.currency, direction: x.direction, merchant: x.merchant, last4: x.last4,
      postedAt: posted.0, precision: posted.1, isTransfer: x.isTransfer)
  }

  static func asciiLowerString(_ s: String) -> String { String(decoding: s.utf8.map(asciiLower), as: UTF8.self) }
}
