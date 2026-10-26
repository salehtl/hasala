import CoreJSON
import CoreReplay
import CoreTemplate
import CoreTime
import Foundation

public enum BankTextLink: String, Sendable, Equatable, CaseIterable {
  case notLinked = "not_linked"
  case linked
  case unknownUnanswered = "unknown_unanswered"
}

public enum BankTextOrigin: String, Sendable, Equatable {
  case automation
  case paste
}

public struct BankTextRow: Sendable, Equatable {
  public var id: String
  public var bank: String?
  public var amountMinor: Int64
  public var currency: String
  public var direction: String
  public var last4: String
  public var postedMs: Int64
  public var templateRef: String?
  public var unparsed: Bool

  public init(
    id: String, bank: String?, amountMinor: Int64, currency: String, direction: String, last4: String, postedMs: Int64,
    templateRef: String?, unparsed: Bool
  ) {
    self.id = id
    self.bank = bank
    self.amountMinor = amountMinor
    self.currency = currency
    self.direction = direction
    self.last4 = last4
    self.postedMs = postedMs
    self.templateRef = templateRef
    self.unparsed = unparsed
  }

  public var transferRole: TextTransferRole? { templateRef.flatMap { TextTransferRole.of(templateRef: $0) } }
}

public enum BankTextTransferPair {
  public static let windowMs = DuplicateRules.transferCopyWindowMs

  public static func partner(of row: BankTextRow, among rows: [BankTextRow]) -> BankTextRow? {
    guard !row.unparsed, row.direction == "debit", let bank = row.bank, let role = row.transferRole else { return nil }
    var best: (row: BankTextRow, gap: Int64)?
    for o in rows where o.id != row.id {
      guard !o.unparsed, o.transferRole == role.counterpart, o.bank == bank, o.direction == row.direction,
        o.amountMinor == row.amountMinor, o.currency == row.currency
      else { continue }
      let gap = abs(o.postedMs - row.postedMs)
      guard gap <= windowMs else { continue }
      if best.map({ gap < $0.gap || (gap == $0.gap && o.id < $0.row.id) }) ?? true { best = (o, gap) }
    }
    return best?.row
  }
}

public struct BankTextDraft: Sendable, Equatable {
  public let ingestID: String
  public let payload: JSONObject
  public let needsReview: Bool
}

enum BankTextPayload {
  static func card(_ k: BankTextKept, cards: [CardKey: CardState]) -> String {
    let last4 = k.fields?.last4 ?? k.last4
    guard !last4.isEmpty else { return "none" }
    switch cards[CardKey(bank: k.bank ?? "", last4: last4)] {
    case .mine?: return "known"
    case .notMine?: return "not_mine"
    case nil: return "unknown"
    }
  }

  static func filesItself(
    _ k: BankTextKept, card: String, link: BankTextLink, origin: BankTextOrigin, transferPartner: Bool
  ) -> Bool {
    origin == .automation && link == .notLinked && k.fields != nil && k.template?.senderMatches == true && card == "known"
      && !k.marked && !k.held && !transferPartner
  }

  static func gates(_ k: BankTextKept, card: String) -> JSONValue {
    .object(
      JSONObject([
        ("sender", .string(k.template?.senderMatches == true ? "trusted" : "untrusted")),
        ("template", .string(k.template?.ref ?? "none")), ("card", .string(card)), ("forwarded", .bool(false)),
      ]))
  }

  static func build(
    _ k: BankTextKept, ingestID: String, receivedMinuteMs: Int64, cards: [CardKey: CardState], link: BankTextLink,
    origin: BankTextOrigin, transferPartner: Bool, categorizer: any IngestCategorizer
  ) -> BankTextDraft {
    let card = card(k, cards: cards)
    let received = Instant.iso(receivedMinuteMs) ?? ""
    guard let f = k.fields else { return unparsed(k, ingestID: ingestID, received: received, card: card) }
    let files = filesItself(k, card: card, link: link, origin: origin, transferPartner: transferPartner)
    let decided = categorizer.decide(merchantRaw: f.merchant, direction: f.direction)
    let decision =
      decided.category == nil
      ? MessageDisposer.refundDecision(template: k.template?.ref, direction: f.direction) ?? decided : decided
    var p = JSONObject([
      ("amount_minor", .string(String(f.amountMinor))), ("currency", .string(f.currency)), ("direction", .string(f.direction)),
      ("posted_at", .string(f.postedAt)), ("posted_precision", .string(f.precision)), ("merchant_raw", .string(f.merchant)),
      ("last4", .string(f.last4)),
    ])
    if let c = decision.category {
      p["category"] = .string(c)
      p["category_source"] = decision.source
    }
    p["needs_review"] = .bool(!files)
    p["unparsed"] = .bool(false)
    p["tier"] = .string(k.tier)
    p["entry_method"] = .string("mailbox")
    if let b = k.bank, !b.isEmpty { p["bank"] = .string(b) }
    p["gates"] = gates(k, card: card)
    p["channel"] = .string(TxnChannel.sms)
    p["received_at"] = .string(received)
    return BankTextDraft(ingestID: ingestID, payload: p, needsReview: !files)
  }

  static func unparsed(_ k: BankTextKept, ingestID: String, received: String, card: String) -> BankTextDraft {
    var u = k
    u.fields = nil
    u.template = nil
    var p = JSONObject([
      ("unparsed", .bool(true)), ("needs_review", .bool(true)), ("tier", .string("none")), ("posted_at", .string(k.postedAt)),
      ("posted_precision", .string("time")), ("merchant_raw", .string(k.merchant)), ("last4", .string(k.last4)),
      ("category", .null), ("entry_method", .string("mailbox")),
    ])
    if let b = k.bank, !b.isEmpty { p["bank"] = .string(b) }
    p["gates"] = gates(u, card: card)
    p["channel"] = .string(TxnChannel.sms)
    p["received_at"] = .string(received)
    return BankTextDraft(ingestID: ingestID, payload: p, needsReview: true)
  }

  static func fallbacks(_ d: BankTextDraft, _ k: BankTextKept, card: String, receivedMinuteMs: Int64) -> [BankTextDraft] {
    let received = Instant.iso(receivedMinuteMs) ?? ""
    var bare = k
    bare.merchant = ""
    if (try? parseInstantMs(bare.postedAt)) == nil { bare.postedAt = received }
    var plain = bare
    plain.last4 = ""
    plain.bank = nil
    plain.postedAt = received
    return [
      unparsed(k, ingestID: d.ingestID, received: received, card: card),
      unparsed(bare, ingestID: d.ingestID, received: received, card: card),
      unparsed(plain, ingestID: d.ingestID, received: received, card: "none"),
    ]
  }
}
