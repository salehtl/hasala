// `OpAuthor` (spec 04 §2.4 R5, §5.4; 03c §10; 03a §9): the only constructor of
// ops reachable from outside HasalaCore. Every op it returns:
//   - carries `v = SchemaVersion.author` (4) and a ULID `op_id`;
//   - is stamped by the 03c §1.8.2 author rule:
//       authored_ms = max(now, min(own_last, now + 24 h) + 1, seen + 1), then +1 per op in the blob,
//     where `seen` ignores writers more than 24 h ahead;
//   - has passed `validateOp` and the fold's payload decoder (`Replay.payloadProblem`);
//   - is at most 8 KiB of canonical JSON (04 §5.4 S7, `opTooLarge`), so an
//     email body can never slip in.
// An op failing a check is an author bug: the call throws and nothing is
// enqueued (03c §2, AT-30). The result is one blob's worth of ops, in order.
//
// User text (every `Label` and `Note`) is NFC-normalized and trimmed here
// (03c §1.6) before it reaches the payload; text that is still outside its
// grammar after that (empty, too long, a forbidden scalar) is a `refused`
// that `build()` reports, never an `invalidOp`.
//
// The authors are pure: the caller passes what the projection shows (versions,
// rows), the outbox's pending parent versions folded into `parentVersion`, and
// an `AuthorContext` (clock, ids, writer, own last stamp, `maxAuthored`).
import CoreCategorize
import CoreJSON
import CorePrimitives
import CoreReplay
import CoreTime
import CoreWire
import Foundation
import HasalaText

public struct AuthorContext: Sendable {
  public var writerID: String
  public var nowMs: Int64
  /// The largest `authored_at` this writer has authored, outbox included.
  public var ownLastMs: Int64?
  /// The fold's per-writer `maxAuthored` (03c §1.8.2).
  public var maxAuthored: [String: Int64]
  public var random: any RandomSource

  public init(writerID: String, nowMs: Int64, ownLastMs: Int64?, maxAuthored: [String: Int64], random: any RandomSource) {
    self.writerID = writerID
    self.nowMs = nowMs
    self.ownLastMs = ownLastMs
    self.maxAuthored = maxAuthored
    self.random = random
  }

  static let dayMs: Int64 = 86_400_000

  /// The first stamp of the next blob (03c §1.8.2).
  public var baseMs: Int64 {
    let cap = nowMs + Self.dayMs
    var t = nowMs
    if let own = ownLastMs { t = max(t, min(own, cap) + 1) }
    let seen = maxAuthored.values.filter { $0 <= cap }.max()
    if let seen { t = max(t, seen + 1) }
    return t
  }

  /// `clock_ahead_writers`: distinct writers, this one included, whose newest stamp is > 24 h ahead.
  public var clockAheadWriters: Int {
    let cap = nowMs + Self.dayMs
    var ahead = Set(maxAuthored.filter { $0.value > cap }.map(\.key))
    if let own = ownLastMs, own > cap { ahead.insert(writerID) }
    return ahead.count
  }
}

public enum AuthorError: Error, Sendable, Equatable {
  /// An op failed `validateOp` or the payload decoder: an author bug.
  case invalidOp(String)
  /// 04 §5.4 (S7) `OpTooLarge`: the op's canonical JSON is over `OpAuthor.maxOpBytes`.
  case opTooLarge(type: String, bytes: Int)
  /// A refusal the UI shows inline; nothing was authored.
  case refused(String)
  case random
}

/// One blob's worth of authored ops and the last stamp used (persist as `own_last_ms`).
public struct AuthoredBlob: Sendable {
  public let ops: [Op]
  public let lastAuthoredMs: Int64
}

/// Builds the ops of one user action.
public struct OpAuthor: Sendable {
  public let context: AuthorContext
  private var drafts: [(OpType, EntityRef?, Int64?, String?, JSONObject)] = []
  /// The first user-text refusal of this action; `build()` throws it.
  private var refusal: String?

  /// 04 §5.4 (S7): the largest canonical JSON of one op, in bytes.
  public static let maxOpBytes = 8 * 1024

  public init(_ context: AuthorContext) { self.context = context }

  // MARK: Assembly

  mutating func add(_ type: OpType, entity: (String, String)? = nil, parent: Int64? = nil, ingestID: String? = nil, _ payload: [(String, JSONValue)]) {
    drafts.append((type, entity.map { EntityRef(kind: $0.0, id: $0.1) }, parent, ingestID, JSONObject(payload)))
  }

  /// The number of ops drafted so far.
  public var count: Int { drafts.count }

  /// Stamps, mints ids, validates and returns the blob.
  public func build() throws(AuthorError) -> AuthoredBlob {
    if let refusal { throw .refused(refusal) }
    var ops: [Op] = []
    let base = context.baseMs
    for (i, d) in drafts.enumerated() {
      let ms = base + Int64(i)
      guard let at = Instant.iso(ms) else { throw .invalidOp("authored_at out of range") }
      let opID = try Ulid.mint(ms: ms, random: context.random)
      guard SchemaVersion.author >= d.0.minVersion else { throw .invalidOp("type_not_yet_authored") }
      let op = Op(
        v: SchemaVersion.author, type: d.0, opID: opID, authoredAt: at, entity: d.1, parentVersion: d.2, ingestID: d.3,
        payload: .object(d.4))
      do { try OpCodec.validateOp(op) } catch { throw .invalidOp("\(d.0.rawValue): \(error)") }
      if let problem = Replay.payloadProblem(op) { throw .invalidOp("\(d.0.rawValue): \(problem)") }
      let size = Self.canonicalSize(op)
      if size > Self.maxOpBytes { throw .opTooLarge(type: d.0.rawValue, bytes: size) }
      ops.append(op)
    }
    return AuthoredBlob(ops: ops, lastAuthoredMs: base + Int64(max(drafts.count - 1, 0)))
  }

  /// The byte length of `op`'s canonical JSON: the object `OpCodec.encodeBlobOps`
  /// writes for it (key order and number form of `JSONWriter`'s defaults).
  static func canonicalSize(_ op: Op) -> Int {
    var o = JSONObject()
    o["v"] = .number(JSONNumber(Int64(op.v)))
    o["type"] = .string(op.type.rawValue)
    o["op_id"] = .string(op.opID)
    o["authored_at"] = .string(op.authoredAt)
    if let e = op.entity { o["entity"] = .object(JSONObject([("kind", .string(e.kind)), ("id", .string(e.id))])) }
    o["parent_version"] = op.parentVersion.map { .number(JSONNumber($0)) } ?? .null
    if let ingest = op.ingestID, !ingest.isEmpty { o["ingest_id"] = .string(ingest) }
    o["payload"] = op.payload
    return JSONWriter().bytes(.object(o)).count
  }

  /// A fresh entity id (ULID) at this context's clock.
  public func newEntityID() throws(AuthorError) -> String { try Ulid.mint(ms: context.nowMs, random: context.random) }

  // MARK: User text (03c §1.6)

  /// A `Label` as typed: NFC, trimmed; a value still outside the grammar is
  /// recorded as this action's refusal.
  mutating func label(_ typed: String, _ what: String) -> String {
    let s = UserText.normalize(typed)
    if let v = TextRules.checkLabel(s) { refuse("\(what): \(v)") }
    return s
  }

  /// A `Note` as typed: NFC, trimmed (`""` clears).
  mutating func note(_ typed: String, _ what: String) -> String {
    let s = UserText.normalize(typed)
    if let v = TextRules.checkNote(s) { refuse("\(what): \(v)") }
    return s
  }

  private mutating func refuse(_ why: String) {
    if refusal == nil { refusal = why }
  }

  // MARK: Transactions (03c §3.8)

  /// `txn_categorized {category, needs_review, source}` (03c §3.2).
  public mutating func categorize(txnID: String, parentVersion: Int64, category: String?, needsReview: Bool = false, source: CategorySource = .user) {
    add(
      .txnCategorized, entity: ("txn", txnID), parent: parentVersion,
      [("category", category.map(JSONValue.string) ?? .null), ("needs_review", .bool(needsReview)), ("source", Self.sourceJSON(source))])
  }

  /// `txn_split {parts}`; `[]` un-splits (03c §3.3).
  public mutating func split(txnID: String, parentVersion: Int64, parts: [(category: String, amountMinor: Int64, note: String?)]) {
    var list: [JSONValue] = []
    for p in parts {
      var o: [(String, JSONValue)] = [("category", .string(p.category)), ("amount_minor", .string(String(p.amountMinor)))]
      if let typed = p.note {
        let n = note(typed, "note")
        if !n.isEmpty { o.append(("note", .string(n))) }
      }
      list.append(.object(JSONObject(o)))
    }
    add(.txnSplit, entity: ("txn", txnID), parent: parentVersion, [("parts", .array(list))])
  }

  /// 03c §3.3 "Split evenly": `q, …, q, q + r`.
  public static func evenAmounts(_ total: Int64, _ n: Int) -> [Int64] {
    guard n > 0 else { return [] }
    let q = total / Int64(n)
    let r = total - q * Int64(n)
    return Array(repeating: q, count: n - 1) + [q + r]
  }

  /// `txn_annotated {txn_id, set}` (03c §3.5); a nil value clears the field.
  /// The `note` is user text (NFC, trimmed); the other fields are ids and tokens.
  public mutating func annotate(txnID: String, set: [(String, String?)]) {
    var o: [(String, JSONValue)] = []
    for (k, v) in set {
      guard let v else {
        o.append((k, .null))
        continue
      }
      o.append((k, .string(k == "note" ? note(v, "note") : v)))
    }
    add(.txnAnnotated, [("txn_id", .string(txnID)), ("set", .object(JSONObject(o)))])
  }

  /// `txn_edited` money/date edit (03c §3.4; user rows only, unsplit, parsed).
  public mutating func editTxn(
    txnID: String, parentVersion: Int64, amountMinor: Int64? = nil, currency: String? = nil, direction: String? = nil, postedAt: String? = nil
  ) {
    var o: [(String, JSONValue)] = []
    if let a = amountMinor { o.append(("amount_minor", .string(String(a)))) }
    if let c = currency { o.append(("currency", .string(c))) }
    if let d = direction { o.append(("direction", .string(d))) }
    if let p = postedAt { o.append(("posted_at", .string(p))) }
    add(.txnEdited, entity: ("txn", txnID), parent: parentVersion, o)
  }

  /// `merchant_named` (03c §3.6): the key is computed from the raw merchant.
  /// The name is NFC-normalized and trimmed; a name that trims to nothing (or
  /// nil) clears the rename, back to the prettified merchant.
  public mutating func renameMerchant(raw: String, to name: String?) {
    var display: JSONValue = .null
    if let name, !UserText.normalize(name).isEmpty { display = .string(label(name, "display_name")) }
    add(.merchantNamed, [("merchant_key", .string(Canon.merchantKey(raw))), ("display_name", display)])
  }

  /// A manual entry (03c §3.1): `txn_ingested` with a fresh manual ingest id, then
  /// the annotations of "Paid with" / a transfer. `localWallMs` is the chosen wall
  /// time at +04:00 expressed as if UTC; the stored instant is 4 h earlier.
  public mutating func manualEntry(
    amountMinor: Int64, currency: String, direction: String, localWallMs: Int64, merchant: String, category: String?,
    accountID: String? = nil, counterAccountID: String? = nil, location: String? = nil
  ) throws(AuthorError) -> String {
    let id = try newEntityID()
    let ingest = try Self.manualIngestID(context.random)
    guard let posted = Instant.iso(localWallMs - LocalClock.offsetMs) else { throw .refused("date out of range") }
    let merchant = UserText.normalize(merchant)
    if merchant.isEmpty { refuse("merchant: \(TextViolation.empty)") }
    var place: String?
    if let typed = location, !UserText.normalize(typed).isEmpty { place = label(typed, "location") }
    var p: [(String, JSONValue)] = [
      ("amount_minor", .string(String(amountMinor))), ("currency", .string(currency)), ("direction", .string(direction)),
      ("posted_at", .string(posted)), ("merchant_raw", .string(merchant)), ("last4", .string("")),
      ("category", category.map(JSONValue.string) ?? .null),
      ("category_source", Self.sourceJSON(category == nil ? .none : .user)), ("needs_review", .bool(false)),
      ("tier", .string("none")), ("unparsed", .bool(false)), ("entry_method", .string("manual")),
    ]
    if let l = place { p.append(("location", .string(l))) }
    add(.txnIngested, entity: ("txn", id), ingestID: ingest, p)
    var set: [(String, String?)] = []
    if let a = accountID { set.append(("account_id", a)) }
    if let c = counterAccountID { set.append(("counter_account_id", c)) }
    if !set.isEmpty { annotate(txnID: id, set: set) }
    return id
  }

  /// A `txn_ingested` (or `txn_superseded`) whose payload the caller built
  /// whole, as the Gmail lane does (04 §7.5 step 7e). Returns the entity id
  /// (minted when not given). The payload is checked like every other op.
  ///
  /// `predecessor` is the live row a supersede replaces (its category and
  /// source as the projection shows them). When its source is `user` or
  /// `held`, the payload's `category` and `category_source` are replaced by
  /// the predecessor's (03c §3.1 "Mailbox supersede"): a template fix that
  /// re-reads the email never wipes a person's choice.
  @discardableResult
  public mutating func ingest(
    payload: JSONObject, ingestID: String, superseding: Bool = false, entityID: String? = nil, predecessor: CategoryState? = nil
  ) throws(AuthorError) -> String {
    let id: String
    if let entityID { id = entityID } else { id = try newEntityID() }
    var payload = payload
    if superseding, let predecessor {
      for (k, v) in Self.supersedeFields(predecessor: predecessor, decision: nil) ?? [] { payload[k] = v }
    }
    drafts.append((superseding ? .txnSuperseded : .txnIngested, EntityRef(kind: "txn", id: id), nil, ingestID, payload))
    return id
  }

  /// A row's categorization as the projection shows it.
  public struct CategoryState: Sendable, Equatable {
    public var category: String?
    public var source: CategorySource
    public init(category: String?, source: CategorySource) {
      self.category = category
      self.source = source
    }
  }

  /// The `category` / `category_source` fields of a mailbox supersede (03c
  /// §3.1): the predecessor's when its source is `user` or `held`; otherwise
  /// the at-ingest decision's (§8.3), or nil (the payload keeps its own) when
  /// no decision is given.
  public static func supersedeFields(predecessor: CategoryState, decision: Decision?) -> [(String, JSONValue)]? {
    switch predecessor.source.kind {
    case .user, .held:
      return [("category", predecessor.category.map(JSONValue.string) ?? .null), ("category_source", sourceJSON(predecessor.source))]
    default:
      return decision.map(decisionFields)
    }
  }

  /// The payload fields `category` and `category_source` for a pipeline decision (03c §8.3).
  public static func decisionFields(_ d: Decision) -> [(String, JSONValue)] {
    guard let c = d.category else { return [("category", .null), ("category_source", sourceJSON(.none))] }
    return [("category", .string(c)), ("category_source", sourceJSON(source(d.source)))]
  }

  /// The writer checkpoint (spec 01 §3.3(c); the sync engine's push step 3):
  /// the canonical, sorted heads payload.
  public mutating func writerCheckpoint(_ heads: [CheckpointHead]) throws(AuthorError) {
    let payload: JSONValue
    do { payload = try Checkpoint.encodePayload(heads) } catch { throw .invalidOp("writer_checkpoint: \(error)") }
    guard let o = payload.objectValue else { throw .invalidOp("writer_checkpoint: payload") }
    drafts.append((.writerCheckpoint, nil, nil, nil, o))
  }

  /// `hex(SHA-256("hasala/v1/manual-ingest" ‖ 0x00 ‖ 16 random bytes))` (03c §1.10).
  public static func manualIngestID(_ random: any RandomSource) throws(AuthorError) -> String {
    let r: Data
    do { r = try random.bytes(16) } catch { throw .random }
    var bytes = Array("hasala/v1/manual-ingest".utf8)
    bytes.append(0)
    bytes += r
    return Hex.encode(sha256(bytes))
  }

  // MARK: Rules (03c §5)

  public struct RuleDraft: Sendable, Equatable {
    public var patterns: [String]
    public var match: MatchKind
    public var category: String
    public var priority: Int64
    public var enabled: Bool
    public var removed: Bool
    public var origin: String

    public init(patterns: [String], match: MatchKind, category: String, priority: Int64 = 10, enabled: Bool = true, removed: Bool = false, origin: String = "manual") {
      self.patterns = patterns
      self.match = match
      self.category = category
      self.priority = priority
      self.enabled = enabled
      self.removed = removed
      self.origin = origin
    }

    var payload: [(String, JSONValue)] {
      [
        ("patterns", .array(patterns.map(JSONValue.string))), ("match", .string(match.rawValue)), ("category", .string(category)),
        ("priority", .number(JSONNumber(priority))), ("enabled", .bool(enabled)), ("removed", .bool(removed)), ("origin", .string(origin)),
      ]
    }
  }

  /// `rule_added` create (`parentVersion` nil) or whole-record edit.
  @discardableResult
  public mutating func rule(id: String? = nil, parentVersion: Int64? = nil, _ draft: RuleDraft) throws(AuthorError) -> String {
    let rid: String
    if let id { rid = id } else { rid = try newEntityID() }
    // Patterns are not NFC-normalized: the matcher compares bytes (Canon
    // keeps NFC and NFD apart), so a pattern must keep the merchant's own form.
    add(.ruleAdded, entity: ("rule", rid), parent: parentVersion, draft.payload)
    return rid
  }

  /// A rule as the projection shows it, for dedup and pause.
  public struct RuleSnapshot: Sendable, Equatable {
    public var id: String
    public var version: Int64
    public var draft: RuleDraft
    public init(id: String, version: Int64, draft: RuleDraft) {
      self.id = id
      self.version = version
      self.draft = draft
    }
  }

  /// "Always use X for M" (03c §5.4): a learned rule, or an edit of an
  /// existing one with the same match and pattern, or nothing when it already
  /// files there. `userRows` feed the overreach guard.
  public mutating func learnRule(
    merchantRaw: String, category: String, existing: [RuleSnapshot], userRows: [(merchantRaw: String, category: String)]
  ) throws(AuthorError) {
    guard let (match, pattern) = LearnedPattern.propose(merchantRaw: merchantRaw, category: category, userRows: userRows) else { return }
    if let same = existing.first(where: { !$0.draft.removed && $0.draft.match == match && $0.draft.patterns.contains(pattern) }) {
      if same.draft.category == category && same.draft.enabled { return }
      var d = same.draft
      d.category = category
      d.enabled = true
      try rule(id: same.id, parentVersion: same.version, d)
      return
    }
    try rule(RuleDraft(patterns: [pattern], match: match, category: category, priority: 100, origin: "learned"))
  }

  /// Pause/resume or remove (03c §5.5): the rule edit, then, when pausing or
  /// removing, a `held` re-categorization of every row the rule files with
  /// needs_review = 0 (`heldRows`: id, version, category). Chunked at
  /// `Sweep.maxOpsPerBlob` ops per blob, the rule edit first; enqueue the
  /// blobs in order, in one transaction.
  public static func setRule(
    _ r: RuleSnapshot, enabled: Bool? = nil, removed: Bool? = nil, heldRows: [(id: String, version: Int64, category: String)],
    context: AuthorContext
  ) throws(AuthorError) -> [AuthoredBlob] {
    var d = r.draft
    if let e = enabled { d.enabled = e }
    if let x = removed { d.removed = x }
    var out: [AuthoredBlob] = []
    var ctx = context
    var a = OpAuthor(ctx)
    try a.rule(id: r.id, parentVersion: r.version, d)
    if !d.enabled || d.removed {
      for row in heldRows {
        if a.count >= Sweep.maxOpsPerBlob {
          let blob = try a.build()
          out.append(blob)
          ctx.ownLastMs = blob.lastAuthoredMs
          a = OpAuthor(ctx)
        }
        a.categorize(txnID: row.id, parentVersion: row.version, category: row.category, needsReview: true, source: CategorySource(kind: .held, ruleID: r.id))
      }
    }
    out.append(try a.build())
    return out
  }

  // MARK: Categories (03c §4.2)

  public mutating func defineCategory(id: String, name: String, kind: CategoryKind, bucket: Bucket?, icon: String?, active: Bool) {
    let name = label(name, "name")
    add(
      .categoryDefined,
      [
        ("id", .string(id)), ("name", .string(name)), ("kind", .string(kind.rawValue)), ("bucket", bucket.map { .string($0.rawValue) } ?? .null),
        ("icon", icon.map(JSONValue.string) ?? .null), ("active", .bool(active)),
      ])
  }

  /// A new user category id: `c_` + lower-case ULID.
  public func newCategoryID() throws(AuthorError) -> String { "c_" + ASCII.lowercased(try newEntityID()) }

  // MARK: Plan (03a §3, §9)

  public mutating func setBudget(category: String, month: CivilMonth, amountMinor: Int64, scope: String = "onward") {
    add(
      .budgetSet,
      [("category_id", .string(category)), ("month", .string(month.wire)), ("amount_minor", .string(String(amountMinor))), ("scope", .string(scope))])
  }

  /// `budget_moved`; nil legs are Ready to assign. Returns the op's index in this blob.
  public mutating func moveMoney(month: CivilMonth, from: String?, to: String?, amountMinor: Int64, reason: String = "move", batchID: String? = nil, undoes: String? = nil) {
    add(
      .budgetMoved,
      [
        ("month", .string(month.wire)), ("from_category_id", from.map(JSONValue.string) ?? .null),
        ("to_category_id", to.map(JSONValue.string) ?? .null), ("amount_minor", .string(String(amountMinor))), ("reason", .string(reason)),
        ("batch_id", batchID.map(JSONValue.string) ?? .null), ("undoes", undoes.map(JSONValue.string) ?? .null),
      ])
  }

  /// Auto-assign's allocations as one blob of moves from Ready to assign (03a §6.11, §3.3).
  public mutating func autoAssign(month: CivilMonth, _ allocations: [(category: String, amount: Int64)], batchID: String) {
    for (c, v) in allocations where v > 0 {
      moveMoney(month: month, from: nil, to: c, amountMinor: v, reason: "auto_assign", batchID: batchID)
    }
  }

  /// The sweep's re-filings and the model's suggestions as blobs of at most 500
  /// `txn_categorized` ops (03c §8.4, §8.6.6). `version` is the row's projected
  /// version (with the outbox's pending parents folded in by the caller).
  public static func categorizations(
    _ items: [(txnID: String, version: Int64, category: String, needsReview: Bool, source: CategorySource)], context: AuthorContext
  ) throws(AuthorError) -> [AuthoredBlob] {
    var out: [AuthoredBlob] = []
    var ctx = context
    var i = 0
    while i < items.count {
      var a = OpAuthor(ctx)
      for it in items[i..<min(i + Sweep.maxOpsPerBlob, items.count)] {
        a.categorize(txnID: it.txnID, parentVersion: it.version, category: it.category, needsReview: it.needsReview, source: it.source)
      }
      let blob = try a.build()
      out.append(blob)
      ctx.ownLastMs = blob.lastAuthoredMs
      i += Sweep.maxOpsPerBlob
    }
    return out
  }

  public mutating func setIncomeSource(id: String, name: String, category: String = "salary", amountMinor: Int64, payday: Int64, active: Bool = true) {
    let name = label(name, "name")
    add(
      .incomeSourceSet,
      [
        ("id", .string(id)), ("name", .string(name)), ("category_id", .string(category)), ("amount_minor", .string(String(amountMinor))),
        ("payday", .number(JSONNumber(payday))), ("active", .bool(active)),
      ])
  }

  public mutating func setPlanRole(category: String, role: String) {
    add(.categoryPlanRoleSet, [("category_id", .string(category)), ("role", .string(role))])
  }

  /// The 50/30/20 template (v4 authors omit `monthly_total_minor`, 03a §3.1).
  public mutating func setBudgetTemplate(need: Int64, want: Int64, saving: Int64) throws(AuthorError) {
    guard need + want + saving == 100, [need, want, saving].allSatisfy({ (0...100).contains($0) }) else {
      throw .refused("the split must add up to 100")
    }
    add(.budgetSplitSet, [("need", .number(JSONNumber(need))), ("want", .number(JSONNumber(want))), ("saving", .number(JSONNumber(saving)))])
  }

  /// Setup 2 "Use this plan": one onward `budget_set` per seeded category (03a §6.12, §9).
  public mutating func seedPlan(income: Int64, split: BudgetSplit?, month: CivilMonth) {
    for (c, amount) in PlanEngine.seed(income: income, split: split).categories {
      setBudget(category: c, month: month, amountMinor: amount)
    }
  }

  // MARK: Projects and goals (03c §6; 03a §9 `defineProject` / `defineGoal`)

  public enum Status: String, Sendable, Equatable { case active, completed, removed }

  /// A project as the editor holds it (03c §6.1). `completedOn` is required
  /// when `status` is `.completed` and dropped otherwise.
  public struct ProjectDraft: Sendable, Equatable {
    public var name: String
    public var startsOn: CivilDate?
    public var endsOn: CivilDate?
    public var budgetMinor: Int64?
    public var countInPlan: Bool
    public var status: Status
    public var completedOn: CivilDate?
    public var icon: String?

    public init(
      name: String, startsOn: CivilDate? = nil, endsOn: CivilDate? = nil, budgetMinor: Int64? = nil, countInPlan: Bool = false,
      status: Status = .active, completedOn: CivilDate? = nil, icon: String? = "flag"
    ) {
      self.name = name
      self.startsOn = startsOn
      self.endsOn = endsOn
      self.budgetMinor = budgetMinor
      self.countInPlan = countInPlan
      self.status = status
      self.completedOn = completedOn
      self.icon = icon
    }
  }

  /// `project_defined`: create (`id` and `parentVersion` nil) or whole-record
  /// edit (toggle, Mark complete, remove). Returns the project id.
  @discardableResult
  public mutating func defineProject(id: String? = nil, parentVersion: Int64? = nil, _ d: ProjectDraft) throws(AuthorError) -> String {
    if let s = d.startsOn, let e = d.endsOn, e < s { throw .refused("the end date is before the start date") }
    if let b = d.budgetMinor, b <= 0 { throw .refused("the budget must be more than 0") }
    let completed = try Self.completedOn(d.status, d.completedOn)
    let pid: String
    if let id { pid = id } else { pid = try newEntityID() }
    var p: [(String, JSONValue)] = [
      ("name", .string(label(d.name, "name"))), ("starts_on", d.startsOn.map { .string($0.wire) } ?? .null),
      ("ends_on", d.endsOn.map { .string($0.wire) } ?? .null), ("budget_minor", d.budgetMinor.map { .string(String($0)) } ?? .null),
      ("count_in_plan", .bool(d.countInPlan)), ("status", .string(d.status.rawValue)),
    ]
    if let completed { p.append(("completed_on", .string(completed.wire))) }
    p.append(("icon", d.icon.map(JSONValue.string) ?? .null))
    add(.projectDefined, entity: ("project", pid), parent: parentVersion, p)
    return pid
  }

  /// Where a goal's progress comes from (03c §6.2).
  public enum GoalSourceDraft: Sendable, Equatable {
    /// A saving-bucket spending category, counted from `since`.
    case category(id: String, since: CivilDate)
    /// A 03b account's balance (`starting_minor` must be 0).
    case account(id: String)
  }

  public struct GoalDraft: Sendable, Equatable {
    public var name: String
    public var targetMinor: Int64
    public var targetMonth: CivilMonth?
    public var source: GoalSourceDraft
    public var startingMinor: Int64
    public var status: Status
    public var completedOn: CivilDate?
    public var icon: String?

    public init(
      name: String, targetMinor: Int64, targetMonth: CivilMonth? = nil, source: GoalSourceDraft, startingMinor: Int64 = 0,
      status: Status = .active, completedOn: CivilDate? = nil, icon: String? = nil
    ) {
      self.name = name
      self.targetMinor = targetMinor
      self.targetMonth = targetMonth
      self.source = source
      self.startingMinor = startingMinor
      self.status = status
      self.completedOn = completedOn
      self.icon = icon
    }
  }

  /// `goal_defined`: create or whole-record edit. A goal funded by a new
  /// dedicated category is `defineCategory` then `defineGoal` on one author
  /// (one blob, 03c §6.2). Returns the goal id.
  @discardableResult
  public mutating func defineGoal(id: String? = nil, parentVersion: Int64? = nil, _ d: GoalDraft) throws(AuthorError) -> String {
    guard d.targetMinor > 0 else { throw .refused("the target must be more than 0") }
    guard d.startingMinor >= 0 else { throw .refused("the amount already saved cannot be negative") }
    let completed = try Self.completedOn(d.status, d.completedOn)
    let source: JSONValue
    switch d.source {
    case .category(let c, let since):
      source = .object(JSONObject([("kind", .string("category")), ("category_id", .string(c)), ("since", .string(since.wire))]))
    case .account(let a):
      guard d.startingMinor == 0 else { throw .refused("an account goal starts from the account's balance") }
      source = .object(JSONObject([("kind", .string("account")), ("account_id", .string(a))]))
    }
    let gid: String
    if let id { gid = id } else { gid = try newEntityID() }
    var p: [(String, JSONValue)] = [
      ("name", .string(label(d.name, "name"))), ("target_minor", .string(String(d.targetMinor))),
      ("target_month", d.targetMonth.map { .string($0.wire) } ?? .null), ("source", source),
      ("starting_minor", .string(String(d.startingMinor))), ("status", .string(d.status.rawValue)),
    ]
    if let completed { p.append(("completed_on", .string(completed.wire))) }
    p.append(("icon", d.icon.map(JSONValue.string) ?? .null))
    add(.goalDefined, entity: ("goal", gid), parent: parentVersion, p)
    return gid
  }

  private static func completedOn(_ status: Status, _ on: CivilDate?) throws(AuthorError) -> CivilDate? {
    guard status == .completed else { return nil }
    guard let on else { throw .refused("a completed record needs its completion date") }
    return on
  }

  // MARK: Duplicates (03c §3.7 lane `duplicate`; v3 `txn_duplicate_disposition`)

  public enum DuplicateDisposition: String, Sendable, Equatable { case same, different }

  /// Resolves a possible-duplicate notice: `same` (not counted again),
  /// `different` (counted), nil (undo). `otherTxnID` is the row the notice
  /// names (`possible_duplicate_of`); the fold refuses a mismatch.
  public mutating func resolveDuplicate(txnID: String, parentVersion: Int64, otherTxnID: String, disposition: DuplicateDisposition?) {
    add(
      .txnDuplicateDisposition, entity: ("txn", txnID), parent: parentVersion,
      [("other_txn_id", .string(otherTxnID)), ("disposition", disposition.map { .string($0.rawValue) } ?? .null)])
  }

  public mutating func retireMailbox(grantID: String, provider: String, legacy: Bool) {
    add(.mailboxRetired, [("grant_id", .string(grantID)), ("provider", .string(provider)), ("legacy", .bool(legacy))])
  }

  // MARK: Configuration

  public mutating func setHomeCurrency(_ code: String) { add(.homeCurrencySet, [("currency", .string(code))]) }

  /// `rate_set {currency, rate_micro}`: home-currency units per unit of
  /// `currency`, times 10^6 (Settings › Currency; bootstrap's USD 3.6725).
  public mutating func setRate(currency: String, rateMicro: Int64) throws(AuthorError) {
    guard rateMicro > 0 else { throw .refused("the rate must be more than 0") }
    add(.rateSet, [("currency", .string(currency)), ("rate_micro", .string(String(rateMicro)))])
  }

  /// `rate_unset {currency}`: that currency's rows stop counting until a rate is set again.
  public mutating func unsetRate(currency: String) { add(.rateUnset, [("currency", .string(currency))]) }

  public mutating func declareBank(_ bank: String, active: Bool) { add(.bankDeclared, [("bank", .string(bank)), ("active", .bool(active))]) }

  /// `sender_trust_set` from typed input (03c §7.2 author rules).
  public mutating func setSenderTrust(typed: String, trusted: Bool, currentTrusted: [String]) throws(AuthorError) {
    let domain: String
    switch SenderTrust.normalize(typed) {
    case .success(let d): domain = d
    case .failure(let r): throw .refused(r.rawValue)
    }
    if trusted {
      if SenderTrust.isForwarder(domain) { throw .refused(SenderTrust.Refusal.forwarderDomain.rawValue) }
      if SenderTrust.isSharedSuffix(domain) { throw .refused(SenderTrust.Refusal.sharedSuffix.rawValue) }
      if !currentTrusted.contains(domain) && currentTrusted.count >= 100 { throw .refused(SenderTrust.Refusal.tooManySenders.rawValue) }
    }
    add(.senderTrustSet, [("domain", .string(domain)), ("trusted", .bool(trusted))])
  }

  // MARK: Helpers

  static func source(_ d: DecisionSource) -> CategorySource {
    switch d {
    case .none: .none
    case .rule(let id): CategorySource(kind: .rule, ruleID: id)
    case .dictionary(let b, let e): CategorySource(kind: .dictionary, bundle: b, entry: e)
    }
  }

  public static func sourceJSON(_ s: CategorySource) -> JSONValue {
    var o: [(String, JSONValue)] = [("kind", .string(s.kind.rawValue))]
    if let v = s.ruleID { o.append(("rule_id", .string(v))) }
    if let v = s.bundle { o.append(("bundle", .string(v))) }
    if let v = s.entry { o.append(("entry", .string(v))) }
    if let v = s.model { o.append(("model", .string(v))) }
    return .object(JSONObject(o))
  }

  /// The `CategorySource` of a sweep decision.
  public static func categorySource(_ d: DecisionSource) -> CategorySource { source(d) }
}

/// The author's text rule (03c §1.6): NFC, then the edges trimmed of
/// `EDGE_SPACE` and white space (line breaks included). Author-only: the fold
/// never normalizes (03c §1.11).
public enum UserText {
  public static func normalize(_ typed: String) -> String {
    let scalars = Array(typed.precomposedStringWithCanonicalMapping.unicodeScalars)
    func edge(_ s: Unicode.Scalar) -> Bool { ScalarSet.edgeSpace.contains(s) || s.properties.isWhitespace }
    guard let first = scalars.firstIndex(where: { !edge($0) }), let last = scalars.lastIndex(where: { !edge($0) }) else { return "" }
    var out = String.UnicodeScalarView()
    out.append(contentsOf: scalars[first...last])
    return String(out)
  }
}

/// ULIDs (03c §1.7): 48-bit millisecond time, 80 random bits, Crockford base32.
public enum Ulid {
  static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ".utf8)

  public static func mint(ms: Int64, random: any RandomSource) throws(AuthorError) -> String {
    let r: Data
    do { r = try random.bytes(10) } catch { throw .random }
    var value = [UInt8](repeating: 0, count: 16)
    let t = UInt64(max(0, ms)) & 0xFFFF_FFFF_FFFF
    for i in 0..<6 { value[i] = UInt8((t >> (8 * (5 - i))) & 0xFF) }
    for (i, b) in r.enumerated() { value[6 + i] = b }
    // 128 bits → 26 base32 digits (the first carries 3 bits).
    var out: [UInt8] = []
    var acc: UInt32 = 0
    var bits = 2  // pad to 130 bits
    for b in value {
      acc = (acc << 8) | UInt32(b)
      bits += 8
      while bits >= 5 {
        bits -= 5
        out.append(alphabet[Int((acc >> UInt32(bits)) & 31)])
      }
    }
    return String(decoding: out, as: UTF8.self)
  }
}
