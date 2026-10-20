// 03c §3.1-§3.2: the v4 deltas of the txn payloads, and `CategorySource`.
import CoreJSON
import CoreWire
import HasalaText

extension State {
  /// The v4-only fields of `txn_ingested` / `txn_superseded` (03c §3.1).
  static func decodeTxnV4Deltas(_ p: JSONObject, into out: inout TxnPayload) throws(PayloadError) {
    if let raw = p["category_source"], !raw.isNull {
      out.categorySource = try decodeCategorySource(raw, category: out.category)
    } else {
      out.categorySource = out.category == nil ? CategorySource.none : CategorySource.user
    }
    if let v = P.present(p["entry_method"]) { out.entryMethod = try P.oneOf(v, "entry_method", ["mailbox", "manual", "import"]) }
    if let v = P.present(p["location"]) { out.location = try P.label(v, "location") }
    if let v = P.present(p["posted_precision"]) { out.postedPrecision = try P.oneOf(v, "posted_precision", ["day", "time"]) }
    if let v = P.present(p["bank"]) {
      guard let s = v.stringValue, Grammar.isBank(s) else { throw PayloadError("bank must be a Bank, got \(showValue(v))") }
      out.bank = s
    }
    if let v = P.present(p["gates"]) { out.gates = try decodeGates(v) }
  }

  public static let gateARValues = [
    "pass", "no_ar", "multiple_ar", "not_topmost", "fail", "parse_error", "no_eop", "not_inbox", "unknown_sender",
    "no_dmarc_reject",
  ]

  /// 03c §3.1 `gates`: a closed enum per key; unknown keys ignored.
  static func decodeGates(_ v: JSONValue?) throws(PayloadError) -> TxnGates {
    let o = try P.object(v, "gates")
    var g = TxnGates()
    if let v = P.present(o["ar"]) {
      g.ar = try P.oneOf(v, "gates.ar", gateARValues)
    }
    if let v = P.present(o["sender"]) { g.sender = try P.oneOf(v, "gates.sender", ["trusted", "untrusted"]) }
    if let v = P.present(o["template"]) {
      guard let s = v.stringValue, isTemplateRef(s) else {
        throw PayloadError("gates.template must be <id>@<version> or none, got \(showValue(v))")
      }
      g.template = s
    }
    if let v = P.present(o["card"]) { g.card = try P.oneOf(v, "gates.card", ["known", "unknown", "not_mine", "none"]) }
    if let v = P.present(o["forwarded"]) { g.forwarded = try P.boolField(v, "gates.forwarded") }
    return g
  }

  /// `none`, or `<id>@<version>`: printable ASCII without spaces, at most 128 bytes,
  /// one `@` with something on both sides.
  private static func isTemplateRef(_ s: String) -> Bool {
    if s == "none" { return true }
    let u = Array(s.utf8)
    guard (3...128).contains(u.count), u.allSatisfy({ $0 > 0x20 && $0 < 0x7f }) else { return false }
    let at = u.filter { $0 == 0x40 }.count
    guard at == 1, let i = u.firstIndex(of: 0x40) else { return false }
    return i > 0 && i < u.count - 1
  }

  /// 03c §3.2.1: a `CategorySource` consistent with `category`.
  static func decodeCategorySource(_ v: JSONValue?, category: String?) throws(PayloadError) -> CategorySource {
    let o = try P.object(v, "source")
    let kindName = try P.oneOf(o["kind"], "source.kind", CategorySource.Kind.allCases.map(\.rawValue))
    let kind = CategorySource.Kind(rawValue: kindName)!
    var s = CategorySource(kind: kind)
    switch kind {
    case .none:
      if category != nil { throw PayloadError("source none requires a null category") }
    case .user:
      break
    case .held:
      if let v = P.present(o["rule_id"]) { s.ruleID = try P.ulid(v, "source.rule_id") }
    case .rule:
      s.ruleID = try P.ulid(o["rule_id"], "source.rule_id")
    case .dictionary:
      guard let b = o["bundle"]?.stringValue, Grammar.isDictBundle(b) else {
        throw PayloadError("source.bundle must be a DictBundle, got \(showValue(o["bundle"]))")
      }
      guard let entry = o["entry"]?.stringValue, !entry.isEmpty, entry.utf8.count <= 200 else {
        throw PayloadError("source.entry must be 1-200 bytes, got \(showValue(o["entry"]))")
      }
      s.bundle = b
      s.entry = entry
    case .model:
      guard let m = o["model"]?.stringValue, Grammar.isModelTag(m) else {
        throw PayloadError("source.model must be a ModelTag, got \(showValue(o["model"]))")
      }
      s.model = m
    }
    if kind != .none && kind != .user && category == nil {
      throw PayloadError("source \(kindName) requires a category")
    }
    return s
  }

  /// 03c §3.2: `category` (key present), `needs_review` and `source` all required.
  static func decodeCategorizeV4(_ p: JSONObject) throws(PayloadError) -> (String?, Bool, CategorySource) {
    guard p["category"] != nil else { throw PayloadError("category is required (null to uncategorize)") }
    let category = try P.optionalCategoryV4(p["category"], "category")
    let needsReview = try P.boolField(p["needs_review"], "needs_review")
    guard let raw = p["source"] else { throw PayloadError("source is required") }
    let source = try decodeCategorySource(raw, category: category)
    return (category, needsReview, source)
  }
}
