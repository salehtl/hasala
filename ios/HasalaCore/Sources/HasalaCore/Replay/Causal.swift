// Versioned entities: causality, fork resolution, ingest-id supersede and the
// txn edit paths (replay.ts `applyCausal` and below, ported; 03c §2 adds the
// `project` and `goal` kinds, 03b §2 the `bill` kind).
import CoreJSON
import CoreTime
import CoreWire
import HasalaText
import OrderedCollections

/// A decoded payload of a versioned op.
enum CausalPayload {
  case txn(TxnPayload)
  case categorize(category: String?, needsReview: Bool, source: CategorySource?)
  case split(parts: [Split], v4: Bool)
  case edit(EditPayload)
  case disposition(other: String, disposition: String?)
  case rule(Rule)
  case project(Project)
  case goal(Goal)
  case bill(Bill)
  case copyResolution(other: String, decision: String?)
}

struct TxnPayload {
  var amountMinor: Int64
  var currency: String
  var direction: String
  var postedAt: String
  var merchantRaw: String
  var last4: String
  var category: String?
  var needsReview: Bool
  var unparsed: Bool
  var tier: String
  var parseError: String?
  var verifiedOriginDomain: String?
  var mailboxMessageID: String?
  // v4
  var categorySource: CategorySource?
  var entryMethod: String?
  var location: String?
  var postedPrecision: String?
  var bank: String?
  var gates: TxnGates?
  var sourceMailbox: String?
  var sourceProvider: String?
  var dedupe: TxnDedupe?
}

struct EditPayload {
  var merchantRaw: String?
  var last4: String?
  var postedAt: String?
  var category: String??
  var needsReview: Bool?
  var amountHomeMinor: Int64??
  var possibleDuplicateOf: String??
  var amountMinor: Int64?
  var currency: String?
  var direction: String?
  /// Parse-only fields named by the edit (refused, `unsupported_edit_field`).
  var rejected: [String] = []

  var namedMoney: [String] {
    var out: [String] = []
    if amountMinor != nil { out.append("amount_minor") }
    if currency != nil { out.append("currency") }
    if direction != nil { out.append("direction") }
    return out
  }
}

extension State {
  // MARK: - Causality (§3.3:66)

  mutating func applyCausal(_ e: LogEntry) throws(PayloadError) {
    let op = e.op
    let seq = e.seq
    let ref = op.entity!  // validateOp guarantees it
    let wantKind = op.type.entityKind!
    guard utf8Equal(ref.kind, wantKind) else {
      anomaly(seq, "entity_kind_mismatch", "\(op.type.rawValue) \(op.opID) names a \(ref.kind), but it can only address a \(wantKind)")
      return
    }
    let key = State.entityKey(ref.kind, ref.id)
    let parent = op.parentVersion

    // Read BEFORE any causal decision: an unreadable payload never advances a
    // version or resolves a fork.
    let payload = try decodeCausalPayload(e)
    let authoredMs = (try? parseInstantMs(op.authoredAt)) ?? 0

    guard let parent else {
      guard Self.creates.contains(op.type) else {
        anomaly(seq, "invalid_parent", "\(op.type.rawValue) \(op.opID) names no parent, but only a create may")
        return
      }
      if let head = heads[key] {
        anomaly(seq, "duplicate_create", "\(op.opID) re-creates \(ref.kind) \(ref.id), already at version \(head.version)")
        return
      }
      guard create(e, payload) else { return }
      heads[key] = EntityHead(kind: ref.kind, id: ref.id, version: 1, opID: op.opID, writerID: e.writerID, authoredAtMs: authoredMs)
      return
    }

    guard Self.edits.contains(op.type) else {
      anomaly(seq, "invalid_parent", "\(op.type.rawValue) \(op.opID) names parent \(parent), but it can only create")
      return
    }
    if parent == 0 {
      anomaly(seq, "nonexistent_parent", "\(op.opID) names parent version 0 of \(ref.kind) \(ref.id), which never existed")
      return
    }
    guard var head = heads[key] else {
      anomaly(seq, "unknown_entity", "\(op.opID) edits \(ref.kind) \(ref.id), which no create introduced")
      return
    }
    if parent > head.version {
      anomaly(seq, "future_parent", "\(op.opID) names parent \(parent) of \(ref.kind) \(ref.id), whose head is \(head.version)")
      return
    }
    // A payload-level refusal consumes no version.
    guard precheck(e, payload) else { return }

    if parent == head.version {
      head.version += 1
      head.opID = op.opID
      head.writerID = e.writerID
      head.authoredAtMs = authoredMs
      heads[key] = head
      edit(e, payload, version: head.version)
      return
    }

    // parent < head.version: a true concurrent fork. Strict comparison: a full
    // tie keeps the incumbent.
    let challengerWins =
      authoredMs > head.authoredAtMs || (authoredMs == head.authoredAtMs && compareUTF8(e.writerID, head.writerID) > 0)
    head.version += 1
    forks.append(
      ForkNotice(
        entityKind: ref.kind, entityID: ref.id, winnerOp: challengerWins ? op.opID : head.opID,
        loserOp: challengerWins ? head.opID : op.opID, atSeq: seq))
    if challengerWins {
      head.opID = op.opID
      head.writerID = e.writerID
      head.authoredAtMs = authoredMs
      heads[key] = head
      edit(e, payload, version: head.version)
      return
    }
    heads[key] = head
    setVersion(ref.kind, ref.id, head.version)
  }

  static let creates: [OpType] = [.txnIngested, .txnSuperseded, .ruleAdded, .projectDefined, .goalDefined, .billSet]
  static let edits: [OpType] = [
    .txnCategorized, .txnSplit, .txnEdited, .txnDuplicateDisposition, .ruleAdded, .projectDefined, .goalDefined, .billSet,
    .txnCopyResolved,
  ]

  /// Mirrors the head version onto the materialized entity (the fork-loser
  /// branch). Exhaustive over the kinds (03b §2: no fall-through to rules).
  private mutating func setVersion(_ kind: String, _ id: String, _ version: Int64) {
    switch kind {
    case "txn": txns[id]?.version = version
    case "rule": rules[id]?.version = version
    case "project": projects[id]?.version = version
    case "goal": goals[id]?.version = version
    case "bill": bills[id]?.version = version
    default: break
    }
  }

  // MARK: - Creates

  /// Returns false when the create was refused, so no head is registered.
  private mutating func create(_ e: LogEntry, _ payload: CausalPayload) -> Bool {
    let id = e.op.entity!.id
    switch payload {
    case .rule(var r):
      r.version = 1
      rules[id] = r
      return true
    case .project(var p):
      p.version = 1
      p.createdAt = e.op.authoredAt
      projects[id] = p
      return true
    case .goal(var g):
      g.version = 1
      g.createdAt = e.op.authoredAt
      goals[id] = g
      return true
    case .bill(var b):
      b.version = 1
      b.firstSeq = e.seq
      b.createdAt = e.op.authoredAt
      bills[id] = b
      return true
    case .txn(let p):
      return createTxn(e, p, superseding: e.op.type == .txnSuperseded)
    default:
      return false
    }
  }

  private mutating func createTxn(_ e: LogEntry, _ p: TxnPayload, superseding: Bool) -> Bool {
    let op = e.op
    let seq = e.seq
    let id = op.entity!.id
    let ingestID = op.ingestID!  // validateOp requires it on both txn creates
    let previous = liveByIngestID[ingestID]

    if !superseding {
      if let previous {
        anomaly(seq, "duplicate_ingest", "\(op.opID) re-ingests \(ingestID.prefix(12))…, live as \(previous)")
        return false
      }
      if let merged = mergedIngest[ingestID] {
        anomaly(seq, "duplicate_ingest", "\(op.opID) re-ingests \(ingestID.prefix(12))…, merged as \(merged)")
        return false
      }
    } else if previous == nil {
      anomaly(seq, "supersede_without_origin", "\(op.opID) supersedes \(ingestID.prefix(12))…, which no ingest introduced")
    } else {
      retire(previous!, by: op.opID)
    }

    var t = Txn(
      id: id, ingestID: ingestID, amountMinor: p.amountMinor, currency: p.currency, direction: p.direction,
      postedAt: p.postedAt, merchantRaw: p.merchantRaw, last4: p.last4, category: p.category, needsReview: p.needsReview,
      unparsed: p.unparsed, tier: p.tier, parseError: p.parseError,
      provenance: utf8Equal(e.writerID, ingestWriterID) ? "ingest" : "user", amountHomeMinor: nil, splits: [],
      supersededBy: nil, possibleDuplicateOf: nil, verifiedOriginDomain: p.verifiedOriginDomain,
      mailboxMessageID: p.mailboxMessageID, duplicateDisposition: nil, version: 1)
    t.categorySource = p.categorySource
    t.entryMethod = p.entryMethod
    t.location = p.location
    t.postedPrecision = p.postedPrecision
    t.bank = p.bank
    t.gates = p.gates
    t.sourceMailbox = p.sourceMailbox
    t.sourceProvider = p.sourceProvider
    t.dedupe = p.dedupe

    // 03c §3.1: a v4 supersede links the predecessor and carries its
    // annotations forward (only note and archived onto an unparsed successor).
    if superseding, op.v >= 4, let previous, txns[previous] != nil {
      txns[previous]!.successorID = id
      let held = txns.filter { $0.value.isLive && $0.value.copyOf.map { utf8Equal($0, previous) } == true }.map(\.key)
      for h in held { txns[h]!.copyOf = id }
      if t.sourceMailbox == nil {
        t.sourceMailbox = txns[previous]!.sourceMailbox
        t.sourceProvider = txns[previous]!.sourceProvider
      }
      let carried = txns[previous]!.annotations
      let fields = carried.keys.sorted { compareUTF8($0, $1) < 0 }
      for f in fields {
        if t.unparsed && !Self.annotationAllowedOnUnparsed(f) {
          anomaly(seq, "unsupported_edit_field", "\(op.opID): \(f) not carried to unparsed successor \(id)")
          continue
        }
        t.annotations[f] = carried[f]
      }
    }

    txns[id] = t
    liveByIngestID[ingestID] = id
    freezeIfPossible(id, seq: seq)
    guard op.v >= 4 else {
      indexFingerprint(id, seq: seq)
      return true
    }
    detectCopy(id, e)
    if txns[id]!.copyOf != nil {
      indexFingerprintIfAbsent(id, seq: seq)
    } else if txns[id]!.mergedInto == nil {
      indexFingerprint(id, seq: seq)
    }
    return true
  }

  /// Takes a transaction out of the live indexes. It stays in `txns`, visible.
  private mutating func retire(_ id: String, by supersedeOp: String) {
    guard txns[id] != nil else { return }
    txns[id]!.supersededBy = supersedeOp
    let t = txns[id]!
    liveByIngestID[t.ingestID] = nil
    unindexFingerprint(fingerprint(t), t.id)
    clearPending(t)
  }

  // MARK: - Edits

  /// Payload-level validity decided before causality (a refusal consumes no version).
  private mutating func precheck(_ e: LogEntry, _ payload: CausalPayload) -> Bool {
    guard case .split(let parts, let v4) = payload else { return true }
    let id = e.op.entity!.id
    guard let t = txns[id] else {
      anomaly(e.seq, "unknown_entity", "\(e.op.opID) splits \(id), which is not a transaction")
      return false
    }
    if t.unparsed {
      anomaly(e.seq, "split_sum", "\(e.op.opID) splits \(t.id), which is unparsed and has no amount to split")
      return false
    }
    if v4 && parts.isEmpty { return true }  // 03c §3.3: un-split
    let sum = parts.reduce(Int128(0)) { $0 + Int128($1.amountMinor) }
    if sum != Int128(t.amountMinor) {
      anomaly(e.seq, "split_sum", "\(e.op.opID) splits \(t.id) into \(sum), but it is \(t.amountMinor)")
      return false
    }
    return true
  }

  private mutating func edit(_ e: LogEntry, _ payload: CausalPayload, version: Int64) {
    let op = e.op
    let seq = e.seq
    let id = op.entity!.id

    switch payload {
    case .rule(var r):
      guard let old = rules[id] else {
        anomaly(seq, "unknown_entity", "\(op.opID) edits rule \(id), which is not materialized")
        return
      }
      if r.shape == 4 { r.createdAt = old.shape == 4 ? old.createdAt : nil }
      r.version = version
      rules[id] = r
      return
    case .project(var p):
      guard let old = projects[id] else {
        anomaly(seq, "unknown_entity", "\(op.opID) edits project \(id), which is not materialized")
        return
      }
      p.createdAt = old.createdAt
      p.version = version
      projects[id] = p
      return
    case .goal(var g):
      guard let old = goals[id] else {
        anomaly(seq, "unknown_entity", "\(op.opID) edits goal \(id), which is not materialized")
        return
      }
      g.createdAt = old.createdAt
      g.version = version
      goals[id] = g
      return
    case .bill(var b):
      guard let old = bills[id] else {
        anomaly(seq, "unknown_entity", "\(op.opID) edits bill \(id), which is not materialized")
        return
      }
      b.firstSeq = old.firstSeq
      b.createdAt = old.createdAt
      b.version = version
      bills[id] = b
      return
    default:
      break
    }

    guard let t = txns[id] else {
      anomaly(seq, "unknown_entity", "\(op.opID) edits \(id), which is not a transaction")
      return
    }
    if let by = t.supersededBy {
      anomaly(seq, "edit_of_superseded", "\(op.opID) edits \(id), superseded by \(by)")
    }
    txns[id]!.version = version

    switch payload {
    case .categorize(let category, let needsReview, let source):
      txns[id]!.category = category
      if let source {
        txns[id]!.categorySource = source
      } else if txns[id]!.categorySource != nil {
        txns[id]!.categorySource = category == nil ? CategorySource.none : .user
      }
      setNeedsReview(id, needsReview, seq: seq)
      forwardCategory(id, seq: seq)
    case .split(let parts, _):
      txns[id]!.splits = parts
      forwardSplit(id, seq: seq)
    case .edit(let p):
      applyTxnEdit(id, p, e)
      flagEditOfMergedCopy(id, seq: seq)
    case .disposition(let other, let disposition):
      guard let notice = txns[id]!.possibleDuplicateOf, utf8Equal(notice, other) else {
        anomaly(
          seq, "duplicate_disposition_mismatch",
          "\(id): disposition names \(other), notice names \(txns[id]!.possibleDuplicateOf ?? "null")")
        return
      }
      txns[id]!.duplicateDisposition = disposition
    case .copyResolution(let other, let decision):
      resolveCopy(id, other: other, decision: decision, e)
    default:
      anomaly(seq, "unhandled_op", "\(op.type.rawValue) \(op.opID) reached the edit path with no handler")
    }
  }

  /// The one place `needs_review` is written after create: it may not be
  /// cleared on an unparsed row (the review queue is its only surface).
  private mutating func setNeedsReview(_ id: String, _ want: Bool, seq: Int64) {
    if txns[id]!.unparsed && !want {
      anomaly(seq, "unsupported_edit_field", "\(id): needs_review cannot be cleared on an unparsed transaction")
      return
    }
    txns[id]!.needsReview = want
  }

  /// The money half of an edit: applied on a user-authored row, refused on an
  /// ingest row, a split row (amount) or an unparsed row.
  private mutating func applyMoneyEdit(_ id: String, _ p: EditPayload, seq: Int64) {
    let named = p.namedMoney
    if named.isEmpty { return }
    let t = txns[id]!
    if t.provenance != "user" {
      anomaly(seq, "unsupported_edit_field", "\(id): \(named.joined(separator: ", ")) may only change via txn_superseded on a transaction the mailbox produced")
      return
    }
    if t.unparsed {
      anomaly(seq, "unsupported_edit_field", "\(id): \(named.joined(separator: ", ")) cannot be set on an unparsed transaction")
      return
    }
    if p.amountMinor != nil && !t.splits.isEmpty {
      anomaly(seq, "unsupported_edit_field", "\(id): amount_minor cannot change while the transaction is split into \(t.splits.count) parts")
      return
    }
    let live = t.isLive
    if live { clearPending(t) }
    if let a = p.amountMinor { txns[id]!.amountMinor = a }
    if let c = p.currency { txns[id]!.currency = c }
    if let d = p.direction { txns[id]!.direction = d }
    if live && p.amountHomeMinor == nil { freezeIfPossible(id, seq: seq) }
  }

  private mutating func applyTxnEdit(_ id: String, _ p: EditPayload, _ e: LogEntry) {
    let seq = e.seq
    if !p.rejected.isEmpty {
      anomaly(seq, "unsupported_edit_field", "\(id): \(p.rejected.joined(separator: ", ")) may only change via txn_superseded")
    }
    let before = fingerprint(txns[id]!)
    applyMoneyEdit(id, p, seq: seq)
    if let m = p.merchantRaw { txns[id]!.merchantRaw = m }
    if let l = p.last4 { txns[id]!.last4 = l }
    if let at = p.postedAt { txns[id]!.postedAt = at }
    if let c = p.category {
      if e.op.v >= 4 {
        // 03c §3.4: one path for categories keeps `category_source` truthful.
        anomaly(seq, "unsupported_edit_field", "\(e.op.opID): category use txn_categorized")
      } else {
        txns[id]!.category = c
      }
    }
    if let nr = p.needsReview { setNeedsReview(id, nr, seq: seq) }
    if let home = p.amountHomeMinor {
      if txns[id]!.unparsed {
        anomaly(seq, "unsupported_edit_field", "\(id): amount_home_minor cannot be set on an unparsed transaction")
      } else {
        txns[id]!.amountHomeMinor = home
        txns[id]!.homeSource = home == nil ? nil : .stated
        txns[id]!.homeRateMicro = nil
        if txns[id]!.isLive {
          if home == nil { markPending(txns[id]!) } else { clearPending(txns[id]!) }
        }
      }
    }
    if let dup = p.possibleDuplicateOf {
      txns[id]!.possibleDuplicateOf = dup
      txns[id]!.duplicateDisposition = nil
    }
    let t = txns[id]!
    let after = fingerprint(t)
    if !utf8Equal(after, before) && t.isLive {
      unindexFingerprint(before, id)
      txns[id]!.possibleDuplicateOf = nil
      txns[id]!.duplicateDisposition = nil
      indexFingerprint(id, seq: seq)
    }
  }

  // MARK: - Fingerprint index (§3.3:67): a notice, never a drop

  /// state.ts `fingerprint`: `last4|amount|direction|merchant|utcDay`, or
  /// `unparsed|ingest_id`.
  public func fingerprint(_ t: Txn) -> String {
    if t.unparsed { return "unparsed|" + t.ingestID }
    let day = (try? parseInstantMs(t.postedAt)).map(utcDay) ?? ""
    return "\(t.last4)|\(t.amountMinor)|\(t.direction)|\(t.merchantRaw)|\(day)"
  }

  private mutating func indexFingerprint(_ id: String, seq: Int64) {
    let fp = fingerprint(txns[id]!)
    let key = ExactKey(fp)
    guard var bucket = byFingerprint[key] else {
      byFingerprint[key] = [id]
      return
    }
    if let other = bucket.first, !utf8Equal(other, id) {
      txns[id]!.possibleDuplicateOf = other
      txns[id]!.duplicateDisposition = nil
      anomaly(seq, "possible_duplicate", "\(id) matches \(other) on \(fp)")
    }
    bucket.append(id)
    byFingerprint[key] = bucket
  }

  mutating func indexFingerprintIfAbsent(_ id: String, seq: Int64) {
    let key = ExactKey(fingerprint(txns[id]!))
    if byFingerprint[key]?.contains(where: { utf8Equal($0, id) }) == true { return }
    byFingerprint[key, default: []].append(id)
  }

  mutating func unindexFingerprint(_ fp: String, _ id: String) {
    let key = ExactKey(fp)
    guard var bucket = byFingerprint[key] else { return }
    if let i = bucket.firstIndex(where: { utf8Equal($0, id) }) { bucket.remove(at: i) }
    byFingerprint[key] = bucket.isEmpty ? nil : bucket
  }
}
