// The replay engine (replay/replay.ts, ported; spec 04 §2.2 CoreReplay, 03c §2
// and §10 for the v4 dispatch).
//
// Four rules make every replica folding the same log reach the same state:
//   1. `seq` is the order; the fold refuses to go backwards.
//   2. `authored_at` decides entity forks and nothing else.
//   3. A version is a function of the total order (a fork advances it whichever
//      side wins).
//   4. Nothing is silently dropped: every refusal lands in `anomalies` or
//      `forks` with its seq. Neither stops a sync.
//
// The exit contract: `apply` returns, or throws `ReplayStop.order` (a position
// the fold cannot use: a caller bug) or `ReplayStop.newerVersion` (a log this
// build must not interpret). Everything wrong with an OP becomes an anomaly.
// Swift arithmetic in here never traps: money goes through `Int128` or
// reporting-overflow operations (spec 04 §2.4 R9).
import CoreJSON
import CoreTime
import CoreWire
import HasalaText
import OrderedCollections

/// The two conditions that stop a fold.
public enum ReplayStop: Error, Sendable, Equatable {
  /// A seq that does not move forward, or an op with no writer.
  case order(String)
  /// An op or blob newer than this build reads: "Update Hasala".
  case newerVersion(String)
}

/// One opened (plaintext) blob body at its log position.
public struct PositionedBlob: Sendable {
  public var writerID: String
  public var stream: String
  public var writerCounter: Int64
  public var seq: Int64
  public var body: [UInt8]

  public init(writerID: String, stream: String = "hot", writerCounter: Int64, seq: Int64, body: [UInt8]) {
    self.writerID = writerID
    self.stream = stream
    self.writerCounter = writerCounter
    self.seq = seq
    self.body = body
  }
}

/// One op at its position. `writerID` is the blob's writer (AAD-bound), never a payload field.
public struct LogEntry: Sendable {
  public var op: Op
  public var position: OpPosition
  public var writerID: String

  public init(op: Op, position: OpPosition, writerID: String) {
    self.op = op
    self.position = position
    self.writerID = writerID
  }

  public var seq: Int64 { position.seq }
}

public enum Replay {
  /// Folds a fresh state from `blobs`.
  public static func fold(_ blobs: [PositionedBlob]) throws(ReplayStop) -> State {
    var s = State()
    for b in blobs { try foldBlob(b, into: &s) }
    return s
  }

  /// Decodes and folds one opened blob (replay.ts `foldBlobs`, one item). The
  /// cursor advances BEFORE the decode, so a blob that will not decode still
  /// consumes its seq; an unknown newer version stops the fold.
  public static func foldBlob(_ b: PositionedBlob, into s: inout State) throws(ReplayStop) {
    try advance(to: b.seq, &s)
    switch OpCodec.decodeR10(b.body) {
    case .ops(let ops):
      try applyBlobOps(ops, seq: b.seq, writerID: b.writerID, into: &s)
    case .setAside(_, let message):
      s.unreadable.append(
        Unreadable(writerID: b.writerID, stream: b.stream, writerCounter: b.writerCounter, seq: b.seq, reason: message))
    case .hardStop(let stop):
      switch stop {
      case .updateRequired: throw .newerVersion("blob at seq \(b.seq) is newer than this build")
      case .tampered: throw .order("blob at seq \(b.seq) was refused by the reader")
      }
    }
  }

  /// Folds the already-decoded ops of one blob at `seq` (the blob position rules
  /// of ``foldBlob`` apply).
  public static func foldOps(_ ops: [Op], seq: Int64, writerID: String, into s: inout State) throws(ReplayStop) {
    try advance(to: seq, &s)
    try applyBlobOps(ops, seq: seq, writerID: writerID, into: &s)
  }

  static func advance(to seq: Int64, _ s: inout State) throws(ReplayStop) {
    // Strictly increasing, checked against the STATE: one blob is one row.
    guard seq > s.cursors.hot else {
      throw .order("blob at seq \(seq) does not follow \(s.cursors.hot): one blob is one row, one seq")
    }
    s.cursors.hot = seq
    s.appliedAtCursor.removeAll()
  }

  private static func applyBlobOps(_ ops: [Op], seq: Int64, writerID: String, into s: inout State) throws(ReplayStop) {
    for (i, op) in ops.enumerated() {
      try apply(LogEntry(op: op, position: OpPosition(seq: seq, index: i), writerID: writerID), to: &s)
    }
  }

  /// Applies one op at its position (replay.ts `applyOp`).
  public static func apply(_ e: LogEntry, to s: inout State) throws(ReplayStop) {
    let op = e.op
    let seq = e.seq
    guard seq >= 1 else { throw .order("seq must be positive, got \(seq)") }
    guard seq >= s.cursors.hot else {
      throw .order("op \(op.opID) arrives at seq \(seq), behind the folded prefix at \(s.cursors.hot)")
    }
    guard !e.writerID.isEmpty else { throw .order("op \(op.opID) at seq \(seq) names no writer") }
    guard op.v <= SchemaVersion.current else {
      throw .newerVersion("op \(op.opID) is v\(op.v), this build supports v\(SchemaVersion.current)")
    }

    if seq > s.cursors.hot {
      s.cursors.hot = seq
      s.appliedAtCursor.removeAll()
    } else if s.appliedAtCursor.contains(op.opID) {
      s.anomaly(seq, "duplicate_delivery", "\(op.opID) was already applied at seq \(seq)")
      return
    }
    s.appliedAtCursor.append(op.opID)
    // 03c §1.8.2: every op visited, applied or refused.
    if let ms = try? parseInstantMs(op.authoredAt), ms > s.maxAuthored[e.writerID, default: Int64.min] {
      s.maxAuthored[e.writerID] = ms
    }

    do {
      try OpCodec.validateOp(op)
    } catch {
      switch error {
      case .unknownNewerVersion(let m): throw .newerVersion(m)
      case .invalid(let m):
        s.anomaly(seq, "invalid_op", "\(op.type.rawValue) \(op.opID): \(m)")
        return
      }
    }

    do {
      try s.dispatch(e)
    } catch {
      s.anomaly(seq, "invalid_payload", "\(op.type.rawValue) \(op.opID): \(error.message)")
    }
  }
}

extension State {
  mutating func anomaly(_ seq: Int64, _ kind: String, _ detail: String) {
    anomalies.append(Anomaly(kind: kind, detail: detail, atSeq: seq))
  }

  mutating func dispatch(_ e: LogEntry) throws(PayloadError) {
    switch e.op.type {
    case .rateSet: try applyRateSet(e)
    case .rateUnset: try applyRateUnset(e)
    case .homeCurrencySet: try applyHomeCurrencySet(e)
    case .bankDeclared: try applyBankDeclared(e)
    case .budgetSplitSet: try applyBudgetSplitSet(e)
    case .categoryDefined: try applyCategoryDefined(e)
    case .writerCheckpoint: try applyCheckpoint(e)
    // v4 parent-free families (Replay/V4/)
    case .txnAnnotated: try applyTxnAnnotated(e)
    case .merchantNamed: try applyMerchantNamed(e)
    case .senderTrustSet: try applySenderTrustSet(e)
    case .budgetSet: try applyBudgetSet(e)
    case .budgetMoved: try applyBudgetMoved(e)
    case .incomeSourceSet: try applyIncomeSourceSet(e)
    case .categoryPlanRoleSet: try applyCategoryPlanRoleSet(e)
    case .billOccurrenceSet: try applyBillOccurrenceSet(e)
    case .accountSet: try applyAccountSet(e)
    case .cardLinked: try applyCardLinked(e)
    case .accountCheckin: try applyAccountCheckin(e)
    // versioned entities
    case .txnIngested, .txnSuperseded, .txnCategorized, .txnSplit, .txnEdited, .txnDuplicateDisposition,
      .ruleAdded, .projectDefined, .goalDefined, .billSet:
      try applyCausal(e)
    }
  }

  // MARK: - Parent-free v3 ops (§3.7:126)

  private mutating func applyHomeCurrencySet(_ e: LogEntry) throws(PayloadError) {
    let ccy = try P.currency(try P.object(e.op), "currency", v: e.op.v)
    if let home = homeCurrency {
      anomaly(e.seq, "home_currency_reset", "home currency is already \(home); \(e.op.opID) says \(ccy)")
      return
    }
    if let head = rates[ccy] {
      anomaly(
        e.seq, "rate_set_before_home_currency",
        "\(ccy) already carries a rate head (\(head.map(String.init) ?? "unset")) where \(e.op.opID) adopts it as the home currency")
    }
    onHomeCurrencySet(ccy, seq: e.seq)
  }

  private mutating func applyRateSet(_ e: LogEntry) throws(PayloadError) {
    let p = try P.object(e.op)
    let ccy = try P.currency(p, "currency", v: e.op.v)
    let micro = try P.positiveMoney(p["rate_micro"], "rate_micro")
    if let home = homeCurrency, utf8Equal(home, ccy) {
      anomaly(e.seq, "rate_set_for_home_currency", "\(e.op.opID) sets a rate for the home currency \(ccy)")
      return
    }
    onRateSet(ccy, micro, seq: e.seq)
    rateUpdatedAt[ccy] = e.op.authoredAt
  }

  private mutating func applyRateUnset(_ e: LogEntry) throws(PayloadError) {
    let ccy = try P.currency(try P.object(e.op), "currency", v: e.op.v)
    if let home = homeCurrency, utf8Equal(home, ccy) {
      anomaly(e.seq, "rate_unset_for_home_currency", "\(e.op.opID) unsets the implicit identity rate of \(ccy)")
      return
    }
    onRateUnset(ccy)
    rateUpdatedAt[ccy] = e.op.authoredAt
  }

  // MARK: - Configuration (schema v3)

  private mutating func applyBankDeclared(_ e: LogEntry) throws(PayloadError) {
    let p = try P.object(e.op)
    let bank = try P.nonEmptyString(p["bank"], "bank")
    let active = try P.boolField(p["active"], "active")
    banks[bank] = active
  }

  private mutating func applyBudgetSplitSet(_ e: LogEntry) throws(PayloadError) {
    let p = try P.object(e.op)
    let need = try percent(p["need"], "need")
    let want = try percent(p["want"], "want")
    let saving = try percent(p["saving"], "saving")
    let sum = need + want + saving
    if sum != 100 { throw PayloadError("need + want + saving must be 100, got \(sum) (\(need)/\(want)/\(saving))") }
    let raw = p["monthly_total_minor"]
    let total: Int64? = (raw == nil || raw!.isNull) ? nil : try P.money(raw, "monthly_total_minor")
    budgetSplit = BudgetSplit(need: need, want: want, saving: saving)
    budgetMonthlyTotal = total
  }

  private func percent(_ v: JSONValue?, _ what: String) throws(PayloadError) -> Int64 {
    let n = try P.intFieldV3(v, what)
    if n < 0 || n > 100 { throw PayloadError("\(what) is \(n), and a percentage is between 0 and 100") }
    return n
  }

  private mutating func applyCategoryDefined(_ e: LogEntry) throws(PayloadError) {
    let p = try P.object(e.op)
    if e.op.v >= 4 {
      let def = try decodeCategoryV4(p)
      categories[def.id] = def
      return
    }
    let id = try P.nonEmptyString(p["id"], "id")
    guard let kind = p["kind"]?.stringValue, kind == "spending" || kind == "income" || kind == "excluded" else {
      throw PayloadError("kind must be spending, income or excluded, got \(showValue(p["kind"]))")
    }
    let name = try P.nonEmptyString(p["name"], "name")
    let bucket = try State.bucketFor(kind, p["bucket"])
    let colorRaw = p["color"]
    let color: String? = (colorRaw == nil || colorRaw!.isNull) ? nil : try P.nonEmptyString(colorRaw, "color")
    let active = try P.boolField(p["active"], "active")
    categories[id] = CategoryDef(shape: 3, id: id, name: name, kind: kind, bucket: bucket, color: color, icon: nil, active: active)
  }

  /// replay.ts `bucketFor`: a spending category carries a bucket; the others none.
  static func bucketFor(_ kind: String, _ v: JSONValue?) throws(PayloadError) -> String? {
    if kind != "spending" {
      if let v, !v.isNull { throw PayloadError("a \(kind) category must not carry a bucket, got \(showValue(v))") }
      return nil
    }
    guard let b = v?.stringValue, b == "need" || b == "want" || b == "saving" else {
      throw PayloadError("a spending category needs a bucket of need, want or saving, got \(showValue(v))")
    }
    return b
  }

  private mutating func applyCheckpoint(_ e: LogEntry) throws(PayloadError) {
    let heads: [CheckpointHead]
    do {
      heads = try Checkpoint.decodePayload(e.op.payload)
    } catch {
      throw PayloadError(error.message)
    }
    var out: [CheckpointEntry] = []
    for h in heads {
      guard let counter = Int64(h.counter) else { throw PayloadError("checkpoint counter exceeds int64") }
      out.append(CheckpointEntry(writerID: h.writerID, stream: h.stream, counter: counter, hash: h.hash))
    }
    checkpoints = out
  }
}

extension Replay {
  /// The payload problem the fold would record as `invalid_payload` for `op`, or
  /// nil. Authors run it on every op before it enters the outbox (03c §2,
  /// AT-30): one bad op would cost its whole blob on every device. Causal
  /// refusals (which depend on what other devices did) are not predicted here.
  public static func payloadProblem(_ op: Op) -> String? {
    var scratch = State()
    let e = LogEntry(op: op, position: OpPosition(seq: 1, index: 0), writerID: "author-check")
    do {
      if op.type.isParentFree {
        try scratch.dispatch(e)
      } else {
        _ = try scratch.decodeCausalPayload(e)
      }
    } catch {
      return error.message
    }
    return nil
  }
}

extension Replay {
  /// A blob the reader set aside (spec 01 §6.6 R7-R10): it still consumes its
  /// seq, and is listed in `unreadable` with a content-free reason.
  public static func foldSetAside(
    seq: Int64, writerID: String, stream: String = "hot", writerCounter: Int64, reason: String, into s: inout State
  ) throws(ReplayStop) {
    try advance(to: seq, &s)
    s.unreadable.append(Unreadable(writerID: writerID, stream: stream, writerCounter: writerCounter, seq: seq, reason: reason))
  }
}
