// 03c's parent-free keyed families: `txn_annotated` (§3.5), `merchant_named`
// (§3.6), `sender_trust_set` (§7.1), and the v4 shapes of `category_defined`
// (§4.2) and `rule_added` (§5.1). Keyed values install by position (§1.8.1):
// the fold never compares `authored_at`, writers or op ids to decide one.
import CoreJSON
import CoreWire
import HasalaText
import OrderedCollections

extension State {
  /// The closed set of `txn_annotated.set` keys (03c §3.5).
  static let annotationFields = [
    "account_id", "archived", "counter_account_id", "note", "project_id", "refund_of", "transfer_peer",
  ]

  /// Fields §3.5 allows on an unparsed row.
  static func annotationAllowedOnUnparsed(_ field: String) -> Bool { field == "note" || field == "archived" }

  /// Validates one annotation value; returns the value to install (nil = a clear).
  private static func annotationValue(_ field: String, _ v: JSONValue) throws(PayloadError) -> String? {
    if v.isNull { return nil }
    switch field {
    case "note":
      let n = try P.note(v, "note")
      return n.isEmpty ? nil : n
    case "archived":
      return try P.oneOf(v, "archived", ["user", "not_a_transaction"])
    case "account_id", "counter_account_id":
      return try P.id03b(v, field)
    case "project_id", "refund_of", "transfer_peer":
      return try P.ulid(v, field)
    default:
      throw PayloadError("set.\(field) is not an annotation")
    }
  }

  mutating func applyTxnAnnotated(_ e: LogEntry) throws(PayloadError) {
    let p = try P.object(e.op)
    let txnID = try P.ulid(p["txn_id"], "txn_id")
    let set = try P.object(p["set"], "set")
    guard (1...7).contains(set.count) else { throw PayloadError("set holds \(set.count) keys, want 1-7") }
    // Validate everything first: an invalid op installs nothing.
    var values: [(String, String?)] = []
    for m in set.members.sorted(by: { compareUTF8($0.key, $1.key) < 0 }) {
      guard Self.annotationFields.contains(m.key) else { throw PayloadError("set.\(m.key) is not an annotation") }
      values.append((m.key, try Self.annotationValue(m.key, m.value)))
    }
    guard txns[txnID] != nil else {
      anomaly(e.seq, "unknown_entity", "\(e.op.opID): annotates \(txnID), which no create introduced")
      return
    }
    // Forward through the successor chain (bounded: a chain longer than the
    // txn count is a cycle, which the fold never builds).
    var id = txnID
    var steps = 0
    while let next = txns[id]?.successorID, txns[next] != nil, steps <= txns.count {
      id = next
      steps += 1
    }
    let unparsed = txns[id]!.unparsed
    for (field, value) in values {
      if unparsed && !Self.annotationAllowedOnUnparsed(field) {
        anomaly(e.seq, "unsupported_edit_field", "\(e.op.opID): \(field) cannot be set on an unparsed transaction")
        continue
      }
      txns[id]!.annotations[field] = Keyed(value, opID: e.op.opID)
    }
    forwardToMergeWinner(id)
  }

  mutating func applyMerchantNamed(_ e: LogEntry) throws(PayloadError) {
    let p = try P.object(e.op)
    guard let key = p["merchant_key"]?.stringValue, Grammar.isMerchantKey(key) else {
      throw PayloadError("merchant_key must be 1-256 scalars with no forbidden scalar, got \(showValue(p["merchant_key"]))")
    }
    var name: String?
    if let v = P.present(p["display_name"]) { name = try P.label(v, "display_name") }
    merchantNames[key] = Keyed(name, opID: e.op.opID)
  }

  mutating func applySenderTrustSet(_ e: LogEntry) throws(PayloadError) {
    let p = try P.object(e.op)
    guard let domain = p["domain"]?.stringValue, Grammar.isDomain(domain) else {
      throw PayloadError("domain must be a normalized domain, got \(showValue(p["domain"]))")
    }
    let trusted = try P.boolField(p["trusted"], "trusted")
    senderTrust[domain] = Keyed(trusted, opID: e.op.opID)
  }

  /// 03c §4.2: `category_defined` at v4 (`icon` instead of `color`; strict grammars).
  func decodeCategoryV4(_ p: JSONObject) throws(PayloadError) -> CategoryDef {
    let id = try P.categoryID(p["id"], "id")
    let name = try P.label(p["name"], "name")
    let kind = try P.oneOf(p["kind"], "kind", ["spending", "income", "excluded"])
    let bucket = try State.bucketFor(kind, p["bucket"])
    var icon: String?
    if let v = P.present(p["icon"]) {
      guard let s = v.stringValue, Grammar.isIconID(s) else { throw PayloadError("icon must be an IconId, got \(showValue(v))") }
      icon = s
    }
    let active = try P.boolField(p["active"], "active")
    return CategoryDef(shape: 4, id: id, name: name, kind: kind, bucket: bucket, color: nil, icon: icon, active: active)
  }

  /// 03c §5.1: `rule_added` at v4. `created_at` is filled from the create op.
  static func decodeRuleV4(_ p: JSONObject, authoredAt: String) throws(PayloadError) -> Rule {
    guard let list = p["patterns"]?.arrayValue, (1...8).contains(list.count) else {
      throw PayloadError("patterns must be an array of 1-8 strings")
    }
    var patterns: [String] = []
    for (i, x) in list.enumerated() {
      guard let s = x.stringValue, Grammar.isRulePattern(s) else { throw PayloadError("patterns[\(i)] is not a rule pattern") }
      if patterns.contains(where: { utf8Equal($0, s) }) { throw PayloadError("patterns[\(i)] repeats an earlier pattern") }
      patterns.append(s)
    }
    let match = try P.oneOf(p["match"], "match", ["exact", "starts_with", "contains"])
    let category = try P.categoryID(p["category"], "category")
    let priority = try P.intV4(p["priority"], "priority", 0...1000)
    let enabled = try P.boolField(p["enabled"], "enabled")
    let removed = P.present(p["removed"]) == nil ? false : try P.boolField(p["removed"], "removed")
    let origin = try P.oneOf(p["origin"], "origin", ["manual", "learned"])
    return Rule(
      shape: 4, patterns: patterns, match: match, category: category, priority: priority, enabled: enabled,
      removed: removed, origin: origin, createdAt: authoredAt, version: 0)
  }
}
