// Payload decoders of the versioned ops. Decoders switch on `op.v`: `v ≤ 3`
// decodes exactly as the v3 oracle (replay.ts `decodePayload`); `v == 4` adds
// 03c §3's deltas (Replay/V4/TxnV4.swift), 03c §5.1's rule shape and §6's
// projects and goals, and 03b §3.2's bills.
import CoreJSON
import CoreTime
import CoreWire
import HasalaText

extension State {
  func decodeCausalPayload(_ e: LogEntry) throws(PayloadError) -> CausalPayload {
    let op = e.op
    let p = try P.object(op)
    switch op.type {
    case .txnIngested, .txnSuperseded:
      return .txn(try State.decodeTxnPayload(p, v: op.v))
    case .txnCategorized:
      if op.v >= 4 {
        let (category, needsReview, source) = try State.decodeCategorizeV4(p)
        return .categorize(category: category, needsReview: needsReview, source: source)
      }
      return .categorize(category: try P.optionalCategory(p["category"]), needsReview: try P.bool(p["needs_review"], false), source: nil)
    case .txnSplit:
      return .split(parts: try State.decodeParts(p["parts"], v: op.v), v4: op.v >= 4)
    case .txnEdited:
      return .edit(try State.decodeEditPayload(p, v: op.v))
    case .txnDuplicateDisposition:
      let d = p["disposition"]
      guard let d, d.isNull || d.stringValue == "same" || d.stringValue == "different" else {
        throw PayloadError("disposition must be same, different, or null")
      }
      return .disposition(other: try P.requiredString(p["other_txn_id"], "other_txn_id"), disposition: d.stringValue)
    case .ruleAdded:
      if op.v >= 4 { return .rule(try State.decodeRuleV4(p, authoredAt: op.authoredAt)) }
      let pattern = try P.requiredString(p["pattern"], "pattern")
      guard let match = p["match"]?.stringValue, ["contains", "exact", "regex"].contains(match) else {
        throw PayloadError("match must be contains|exact|regex, got \(showValue(p["match"]))")
      }
      let category = try P.requiredString(p["category"], "category")
      let priority = try P.intFieldV3(p["priority"], "priority")
      return .rule(
        Rule(
          shape: 3, patterns: [pattern], match: match, category: category, priority: priority, enabled: true,
          removed: false, origin: "legacy", createdAt: nil, version: 0))
    case .projectDefined:
      return .project(try State.decodeProject(p))
    case .goalDefined:
      return .goal(try State.decodeGoal(p))
    case .billSet:
      return .bill(try State.decodeBill(p))
    default:
      throw PayloadError("no payload decoder for \(op.type.rawValue)")
    }
  }

  /// replay.ts `decodeTxnPayload`: a transaction, or a message no tier could read.
  static func decodeTxnPayload(_ p: JSONObject, v: Int) throws(PayloadError) -> TxnPayload {
    if v < 2 && p["verified_origin_domain"] != nil {
      throw PayloadError("verified_origin_domain requires schema v2")
    }
    if v >= 4 && p["verified_origin_domain"] != nil {
      throw PayloadError("verified_origin_domain is refused at v4")
    }
    let category = v >= 4 ? try P.optionalCategoryV4(p["category"], "category") : try P.optionalCategory(p["category"])
    let tier = try tierOf(p["tier"])
    let unparsed = try P.bool(p["unparsed"], false)
    let parseError = try parseErrorOf(p["parse_error"])
    let verifiedOrigin = try P.optionalString(p["verified_origin_domain"], "verified_origin_domain")
    let mailbox = mailboxMessageIDOf(p)
    let postedAt = try P.instant(p["posted_at"], "posted_at")
    let merchant = try P.optionalString(p["merchant_raw"], "merchant_raw") ?? ""
    let last4 = try P.optionalString(p["last4"], "last4") ?? ""

    var out = TxnPayload(
      amountMinor: 0, currency: "", direction: "", postedAt: postedAt, merchantRaw: merchant, last4: last4,
      category: category, needsReview: true, unparsed: unparsed, tier: tier, parseError: parseError,
      verifiedOriginDomain: verifiedOrigin, mailboxMessageID: mailbox)

    if unparsed {
      if tier != "none" {
        throw PayloadError("unparsed is true but tier is \(tier): nothing was extracted, so no tier produced it")
      }
      let rawAmount = p["amount_minor"]
      let amount = try P.money(rawAmount == nil || rawAmount!.isNull ? .string("0") : rawAmount, "amount_minor")
      if amount != 0 { throw PayloadError("unparsed is true but amount_minor is \(amount): an unparsed message carries no amount") }
      if let c = p["currency"], c.stringValue != "" {
        throw PayloadError("unparsed is true but currency is \(showValue(c)): an unparsed message carries no currency")
      }
      if let d = p["direction"], d.stringValue != "" {
        throw PayloadError("unparsed is true but direction is \(showValue(d)): an unparsed message carries no direction")
      }
      if try P.bool(p["needs_review"], true) != true {
        throw PayloadError("unparsed is true but needs_review is false: an unparsed message is a review item")
      }
    } else {
      if let pe = parseError { throw PayloadError("parse_error is \(pe) on a row that is not unparsed") }
      out.amountMinor = try P.positiveMoney(p["amount_minor"], "amount_minor")
      out.currency = try P.currency(p, "currency", v: v)
      out.direction = try P.direction(p["direction"])
      out.needsReview = try P.bool(p["needs_review"], category == nil)
    }
    if v >= 4 {
      try decodeTxnV4Deltas(p, into: &out)
      if let source = mailboxSourceOf(p) {
        out.sourceProvider = source.provider
        out.sourceMailbox = source.grant
      }
    }
    return out
  }

  private static func tierOf(_ v: JSONValue?) throws(PayloadError) -> String {
    guard let v else { return "none" }
    guard let s = v.stringValue, s == "template" || s == "heuristic" || s == "none" else {
      throw PayloadError("tier must be template|heuristic|none, got \(showValue(v))")
    }
    return s
  }

  /// A short lower-snake token, never message text: `^[a-z][a-z0-9_]{0,63}$`.
  private static func parseErrorOf(_ v: JSONValue?) throws(PayloadError) -> String? {
    guard let v, !v.isNull, v.stringValue != "" else { return nil }
    guard let s = v.stringValue else { throw PayloadError("parse_error must be a string or null, got \(showValue(v))") }
    let u = Array(s.utf8)
    let ok =
      (1...64).contains(u.count) && ASCII.isLower(u[0])
      && u.allSatisfy { ASCII.isLower($0) || ASCII.isDigit($0) || $0 == 0x5f }
    guard ok else { throw PayloadError("parse_error \(showValue(v)) is not a lower-snake token") }
    return s
  }

  /// The re-fetch id of a well-formed mailbox provenance; never throws.
  private static func mailboxMessageIDOf(_ p: JSONObject) -> String? {
    guard let prov = p["provenance"]?.objectValue else { return nil }
    guard let provider = prov["provider"]?.stringValue, !provider.isEmpty else { return nil }
    guard let grant = prov["grant_id"]?.stringValue, !grant.isEmpty else { return nil }
    guard let message = prov["message_id"]?.stringValue, !message.isEmpty else { return nil }
    return message
  }

  static func mailboxSourceOf(_ p: JSONObject) -> (provider: String, grant: String)? {
    guard mailboxMessageIDOf(p) != nil, let prov = p["provenance"]?.objectValue,
      let provider = prov["provider"]?.stringValue, let grant = prov["grant_id"]?.stringValue
    else { return nil }
    return (provider, grant)
  }

  /// replay.ts `decodeEditPayload` (v4: the same fields; `category` is refused
  /// later, in the fold, so the rest of the op applies).
  static func decodeEditPayload(_ p: JSONObject, v: Int) throws(PayloadError) -> EditPayload {
    var out = EditPayload()
    out.rejected = ["unparsed", "tier", "parse_error"].filter { p[$0] != nil }
    if p["amount_minor"] != nil { out.amountMinor = try P.positiveMoney(p["amount_minor"], "amount_minor") }
    if p["currency"] != nil { out.currency = try P.currency(p, "currency", v: v) }
    if p["direction"] != nil { out.direction = try P.direction(p["direction"]) }
    if let m = try P.optionalString(p["merchant_raw"], "merchant_raw") { out.merchantRaw = m }
    if let l = try P.optionalString(p["last4"], "last4") { out.last4 = l }
    if p["posted_at"] != nil { out.postedAt = try P.instant(p["posted_at"], "posted_at") }
    if p["category"] != nil {
      out.category = .some(v >= 4 ? try P.optionalCategoryV4(p["category"], "category") : try P.optionalCategory(p["category"]))
    }
    if p["needs_review"] != nil { out.needsReview = try P.bool(p["needs_review"], false) }
    if let raw = p["amount_home_minor"] {
      out.amountHomeMinor = .some(raw.isNull ? nil : try P.positiveMoney(raw, "amount_home_minor"))
    }
    if let dup = p["possible_duplicate_of"] {
      if !dup.isNull && (dup.stringValue ?? "").isEmpty {
        throw PayloadError("possible_duplicate_of must be a non-empty string or null")
      }
      out.possibleDuplicateOf = .some(dup.stringValue)
    }
    return out
  }

  /// replay.ts `decodeParts`; at v4 (03c §3.3) `[]` or 2-16 parts, each with a
  /// `CategoryId` and an optional `Note`.
  static func decodeParts(_ raw: JSONValue?, v: Int) throws(PayloadError) -> [Split] {
    guard let list = raw?.arrayValue else { throw PayloadError("parts is not an array") }
    if v >= 4 {
      if list.count == 1 { throw PayloadError("parts: a split has 0 or 2-16 parts, got 1") }
      if list.count > 16 { throw PayloadError("parts: a split has at most 16 parts, got \(list.count)") }
    }
    var out: [Split] = []
    for (i, x) in list.enumerated() {
      guard let o = x.objectValue else { throw PayloadError("part \(i) is not an object") }
      let category =
        v >= 4 ? try P.categoryID(o["category"], "part \(i) category") : try P.requiredString(o["category"], "part \(i) category")
      let amount = try P.positiveMoney(o["amount_minor"], "part \(i) amount_minor")
      var note: String?
      if v >= 4, let n = o["note"], !n.isNull { note = try P.note(n, "part \(i) note") }
      out.append(Split(category: category, amountMinor: amount, note: note))
    }
    return out
  }
}
