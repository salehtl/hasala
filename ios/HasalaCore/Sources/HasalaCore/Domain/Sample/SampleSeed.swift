// The sample-data loader (spec 04 §4.6; 06 §13.5; owner decision 5 of the
// TestFlight plan): "Use sample data" on a review account authors the Maya
// scenario as ordinary ops, through `OpAuthor`, so it uploads, folds, projects
// and syncs to a second iPhone exactly like data read from Gmail.
//
// The seed (`CoreResources/sample/maya-v1.json`, digest in `SampleManifest`) is
// a `Document`: op drafts (type, entity, ingest id, payload) with the wall time
// of the moment each describes. It is generated from HasalaMocks' MayaLedger by
// `Tools/SampleSeedExport` and never edited by hand.
//
// `batches` turns it into blobs for the outbox:
//   - ids: every `@<kind>:<name>` placeholder becomes a fresh id of its kind
//     (ULIDs for txn/rule/project/goal, `c_` + ULID for a category, `ac_` / `ck_`
//     + 128 random bits, a manual-style ingest id), one per name, so two loads
//     never collide; literal ids (`ac_cash`, card-derived `ac_…`, `bd_…`) stay;
//   - dates: every date, month and instant shifts by whole months so the
//     document's anchor (Saturday 10 October 2026, 13:40 in Dubai) lands on the
//     latest 10th at 13:40 at or before `now`; a day past the target month's
//     end clamps to its last day;
//   - rows whose shifted moment is after that target are dropped;
//   - `@message:<name>` becomes `sample-<n>` (n = order of first use): the
//     transaction sheet shows "This is sample data" for those ids;
//   - at most `maxOpsPerBatch` ops per blob.
//
// The seed carries no `home_currency_set` and no rate: the account's open
// authors those (04 §6.2), and a second home currency is an anomaly.
//
// The gate (04 §6.13; 06 R-REV-3, AT-34): the server cannot refuse sealed ops,
// so the app's check is the only one. `batches` takes a `Permit`, and the only
// way to get one is `permit(...)` with the three facts: a live `GET /account`
// that says `review_account: true`, no transaction in the projection (outbox
// included), and no sample row. CoreSync's `LedgerPageObserver.sampleBatches`
// gathers the facts itself; that is the app's way in.
import CoreJSON
import CorePrimitives
import CoreResources
import CoreTime
import CoreWire
import Foundation
import HasalaText

public enum SampleSeedError: Error, Sendable, Equatable {
  /// The bundled file is missing or its digest is not `SampleManifest.sha256`.
  case unavailable
  /// The document is not this format (detail is content-free).
  case malformed(String)
  case author(AuthorError)
  /// The gate refused; nothing was authored.
  case refused(SampleSeedRefusal)
}

/// Why "Use sample data" is refused (04 §6.13; 06 AT-34).
public enum SampleSeedRefusal: String, Error, Sendable, Equatable, CaseIterable {
  /// `GET /account` did not say `review_account: true` for this account.
  case notReviewAccount = "not_review_account"
  /// A sample row is already in the ledger (or the outbox): the load is one-shot.
  case alreadyLoaded = "already_loaded"
  /// The ledger holds a transaction, folded or still in the outbox.
  case hasTransactions = "has_transactions"
}

public enum SampleSeed {
  /// Ops per blob (one `Outbox.enqueue` each).
  public static let maxOpsPerBatch = 200

  /// One op of the document.
  public struct Draft: Sendable, Equatable {
    public var type: OpType
    /// `(kind, id)`; nil for a parent-free op.
    public var entity: EntityRefDraft?
    public var ingestID: String?
    public var payload: JSONObject
    /// The instant the op describes (canonical UTC), shifted with the dates and
    /// compared with the target to drop rows from the future.
    public var at: String

    public init(type: OpType, entity: EntityRefDraft? = nil, ingestID: String? = nil, payload: JSONObject, at: String) {
      self.type = type
      self.entity = entity
      self.ingestID = ingestID
      self.payload = payload
      self.at = at
    }
  }

  public struct EntityRefDraft: Sendable, Equatable {
    public var kind: String
    public var id: String
    public init(kind: String, id: String) {
      self.kind = kind
      self.id = id
    }
  }

  /// The seed file: `{"format","format_version","name","anchor","ops":[…]}`,
  /// written one op per line so a regenerated seed diffs by row.
  public struct Document: Sendable, Equatable {
    public static let format = "hasala.sample"
    public static let formatVersion: Int64 = 1

    public var name: String
    /// The scenario clock (canonical UTC instant).
    public var anchor: String
    public var ops: [Draft]

    public init(name: String, anchor: String, ops: [Draft]) {
      self.name = name
      self.anchor = anchor
      self.ops = ops
    }

    public init(json data: Data) throws(SampleSeedError) {
      let doc: JSONValue
      do { doc = try JSONParser.parse([UInt8](data)) } catch { throw .malformed("not JSON") }
      guard let o = doc.objectValue, o["format"]?.stringValue == Self.format,
        o["format_version"]?.numberValue?.v4Int == Self.formatVersion
      else { throw .malformed("unknown format") }
      guard let name = o["name"]?.stringValue, let anchor = o["anchor"]?.stringValue, (try? parseInstantMs(anchor)) != nil,
        let list = o["ops"]?.arrayValue
      else { throw .malformed("header") }
      var ops: [Draft] = []
      for (i, item) in list.enumerated() {
        guard let d = item.objectValue, let t = d["type"]?.stringValue.flatMap(OpType.init(rawValue:)),
          let payload = d["payload"]?.objectValue, let at = d["at"]?.stringValue, (try? parseInstantMs(at)) != nil
        else { throw .malformed("op \(i)") }
        var entity: EntityRefDraft?
        if let e = d["entity"]?.objectValue {
          guard let k = e["kind"]?.stringValue, let id = e["id"]?.stringValue else { throw .malformed("op \(i) entity") }
          entity = EntityRefDraft(kind: k, id: id)
        }
        for key in d.keys where !["at", "type", "entity", "ingest_id", "payload"].contains(key) {
          throw .malformed("op \(i) has an unknown member")
        }
        ops.append(Draft(type: t, entity: entity, ingestID: d["ingest_id"]?.stringValue, payload: payload, at: at))
      }
      self.init(name: name, anchor: anchor, ops: ops)
    }

    /// The canonical bytes: a header line, one line per op, a closing line.
    public func encoded() -> Data {
      let w = JSONWriter()
      var out = "{\"format\":\"\(Self.format)\",\"format_version\":\(Self.formatVersion),"
      out += "\"name\":" + w.string(.string(name)) + ",\"anchor\":" + w.string(.string(anchor)) + ",\"ops\":[\n"
      for (i, d) in ops.enumerated() {
        var o = JSONObject([("at", .string(d.at)), ("type", .string(d.type.rawValue))])
        if let e = d.entity { o["entity"] = .object(JSONObject([("kind", .string(e.kind)), ("id", .string(e.id))])) }
        if let ingest = d.ingestID { o["ingest_id"] = .string(ingest) }
        o["payload"] = .object(d.payload)
        out += w.string(.object(o)) + (i == ops.count - 1 ? "\n" : ",\n")
      }
      out += "]}\n"
      return Data(out.utf8)
    }
  }

  // MARK: The bundled seed

  /// `sample/maya-v1.json` from CoreResources, refused unless its SHA-256 is the manifest's.
  public static func bundled() throws(SampleSeedError) -> Data {
    guard
      let url = CoreResources.bundle.url(forResource: SampleManifest.name, withExtension: "json", subdirectory: "sample"),
      let data = try? Data(contentsOf: url), Hex.encode(sha256(data)) == SampleManifest.sha256
    else { throw .unavailable }
    return data
  }

  // MARK: The gate

  /// Proof that the gate passed; minted only by `permit(...)`.
  public struct Permit: Sendable {
    fileprivate init() {}
  }

  /// The gate (04 §6.13): `reviewAccount` is `review_account` from a live
  /// `GET /account` of this account's session (nil, the field missing, refuses);
  /// `holdsTransactions` and `sampleLoaded` are read from the projected ledger
  /// with the outbox overlaid. The refusal order is the one the screens show.
  public static func permit(reviewAccount: Bool?, holdsTransactions: Bool, sampleLoaded: Bool) throws(SampleSeedError)
    -> Permit
  {
    guard reviewAccount == true else { throw .refused(.notReviewAccount) }
    if sampleLoaded { throw .refused(.alreadyLoaded) }
    if holdsTransactions { throw .refused(.hasTransactions) }
    return Permit()
  }

  /// Whether `messageID` marks a sample row (it starts with `sample-`, as
  /// every `sample-<n>` does; Gmail ids are hex, so no real row matches).
  public static func isSampleMessageID(_ messageID: String?) -> Bool {
    messageID?.hasPrefix("sample-") == true
  }

  // MARK: Loading

  /// Where the document lands: whole months to shift, and the target instant
  /// (the latest local wall time at or before `nowMs` with the anchor's day of
  /// month, clamped, and time of day).
  public static func target(anchorMs: Int64, nowMs: Int64) -> (months: Int, targetMs: Int64)? {
    guard let anchor = LocalWall(utcMs: anchorMs), let now = LocalWall(utcMs: nowMs) else { return nil }
    for back in 0...1 {
      guard let month = now.date.yearMonth.adding(months: -back) else { return nil }
      let day = min(anchor.date.day, month.daysInMonth)
      guard let date = CivilDate(year: month.year, month: month.month, day: day) else { return nil }
      let candidate = LocalWall(date: date, msOfDay: anchor.msOfDay)
      if candidate.utcMs <= nowMs { return (monthsBetween(anchor.date.yearMonth, month), candidate.utcMs) }
    }
    return nil
  }

  /// The document as blobs of authored ops, ready for `Outbox.enqueue` in order.
  public static func batches(_ data: Data, nowMs: Int64, context: AuthorContext, permit: Permit) throws(SampleSeedError)
    -> [AuthoredBlob]
  {
    let doc = try Document(json: data)
    guard let anchorMs = try? parseInstantMs(doc.anchor), let (months, targetMs) = target(anchorMs: anchorMs, nowMs: nowMs)
    else { throw .malformed("anchor") }
    var ids = IDMinter(random: context.random, nowMs: context.nowMs)
    var drafts: [Draft] = []
    for var d in doc.ops {
      guard let at = try? parseInstantMs(d.at), let shiftedAt = Shift.instant(at, months: months) else {
        throw .malformed("at")
      }
      if shiftedAt > targetMs { continue }
      d.at = Instant.iso(shiftedAt) ?? d.at
      d.payload = try Shift.payload(d.payload, type: d.type, months: months)
      if d.type == .billSet { d.payload["created_at"] = .string(d.at) }
      d.payload = try ids.remap(d.payload)
      if let e = d.entity { d.entity = EntityRefDraft(kind: e.kind, id: try ids.remap(e.id)) }
      if let ingest = d.ingestID { d.ingestID = try ids.remap(ingest) }
      drafts.append(d)
    }
    var out: [AuthoredBlob] = []
    var ctx = context
    var i = 0
    while i < drafts.count {
      var a = OpAuthor(ctx)
      for d in drafts[i..<min(i + maxOpsPerBatch, drafts.count)] {
        a.add(d.type, entity: d.entity.map { ($0.kind, $0.id) }, ingestID: d.ingestID, d.payload)
      }
      let blob: AuthoredBlob
      do { blob = try a.build() } catch { throw .author(error) }
      out.append(blob)
      ctx.ownLastMs = blob.lastAuthoredMs
      i += maxOpsPerBatch
    }
    return out
  }

  // MARK: Ids

  /// Mints one id per placeholder name, of the placeholder's kind.
  struct IDMinter {
    let random: any RandomSource
    let nowMs: Int64
    var minted: [String: String] = [:]
    var messages = 0

    init(random: any RandomSource, nowMs: Int64) {
      self.random = random
      self.nowMs = nowMs
    }

    static let kinds: Set<String> = ["txn", "rule", "project", "goal", "category", "account", "checkin", "ingest", "message"]

    /// `@<kind>:<name>` → its id; any other string is returned as it is. A
    /// string shaped like a placeholder (`@`, lower-case letters, `:`) whose
    /// kind is unknown, or whose name is empty, is a malformed document.
    mutating func remap(_ s: String) throws(SampleSeedError) -> String {
      guard s.utf8.first == 0x40 else { return s }  // "@"
      if let done = minted[s] { return done }
      let body = s.dropFirst()
      guard let colon = body.firstIndex(of: ":"), body.startIndex < colon,
        body[..<colon].utf8.allSatisfy({ (0x61...0x7a).contains($0) })
      else { return s }
      let kind = String(body[..<colon])
      guard Self.kinds.contains(kind), !body[body.index(after: colon)...].isEmpty else {
        throw .malformed("placeholder")
      }
      let id: String
      do {
        switch kind {
        case "txn", "rule", "project", "goal": id = try Ulid.mint(ms: nowMs, random: random)
        case "category": id = "c_" + ASCII.lowercased(try Ulid.mint(ms: nowMs, random: random))
        case "account": id = "ac_" + Hex.encode(try random.bytes(16))
        case "checkin": id = "ck_" + Hex.encode(try random.bytes(16))
        case "ingest": id = try OpAuthor.manualIngestID(random)
        default:
          messages += 1
          id = "sample-\(messages)"
        }
      } catch {
        throw .author(.random)
      }
      minted[s] = id
      return id
    }

    mutating func remap(_ o: JSONObject) throws(SampleSeedError) -> JSONObject {
      var out = JSONObject()
      for k in o.keys { out[k] = try remap(o[k]!) }
      return out
    }

    mutating func remap(_ v: JSONValue) throws(SampleSeedError) -> JSONValue {
      switch v {
      case .string(let s): return .string(try remap(s))
      case .array(let a):
        var out: [JSONValue] = []
        for x in a { out.append(try remap(x)) }
        return .array(out)
      case .object(let o): return .object(try remap(o))
      default: return v
      }
    }
  }

  // MARK: Dates

  /// A local (+04:00) wall time: a civil date and milliseconds into the day.
  struct LocalWall {
    let date: CivilDate
    let msOfDay: Int64

    init?(utcMs: Int64) {
      let local = utcMs + LocalClock.offsetMs
      guard let d = CivilDate(daysSinceEpoch: Civil.floorDiv(local, Civil.msPerDay)) else { return nil }
      date = d
      msOfDay = local - Civil.floorDiv(local, Civil.msPerDay) * Civil.msPerDay
    }

    init(date: CivilDate, msOfDay: Int64) {
      self.date = date
      self.msOfDay = msOfDay
    }

    var utcMs: Int64 { date.daysSinceEpoch * Civil.msPerDay + msOfDay - LocalClock.offsetMs }
  }

  /// The date-valued payload fields per op type, and how they shift.
  enum Shift {
    enum Kind { case instant, date, month }

    static let fields: [OpType: [([String], Kind)]] = [
      .txnIngested: [(["posted_at"], .instant)],
      .txnSuperseded: [(["posted_at"], .instant)],
      .accountCheckin: [(["as_of"], .instant)],
      .accountSet: [(["closed_on"], .date)],
      .billSet: [(["anchor"], .date), (["start"], .date), (["end"], .date)],
      .billOccurrenceSet: [(["due"], .date), (["until"], .date)],
      .budgetSet: [(["month"], .month)],
      .budgetMoved: [(["month"], .month)],
      .projectDefined: [(["starts_on"], .date), (["ends_on"], .date), (["completed_on"], .date)],
      .goalDefined: [(["target_month"], .month), (["source", "since"], .date)],
    ]

    static func date(_ d: CivilDate, months: Int) -> CivilDate? {
      guard let m = d.yearMonth.adding(months: months) else { return nil }
      return CivilDate(year: m.year, month: m.month, day: min(d.day, m.daysInMonth))
    }

    static func instant(_ ms: Int64, months: Int) -> Int64? {
      guard months != 0 else { return ms }
      guard let w = LocalWall(utcMs: ms), let d = date(w.date, months: months) else { return nil }
      return LocalWall(date: d, msOfDay: w.msOfDay).utcMs
    }

    static func value(_ s: String, _ kind: Kind, months: Int) -> String? {
      switch kind {
      case .instant:
        guard let ms = try? parseInstantMs(s), let shifted = instant(ms, months: months) else { return nil }
        return Instant.iso(shifted)
      case .date:
        // Re-read through the wire grammar: a shift out of 2000-2099 is refused.
        return CivilDate(wire: s).flatMap { date($0, months: months) }.flatMap { CivilDate(wire: $0.wire) }?.wire
      case .month:
        return CivilMonth(wire: s).flatMap { $0.adding(months: months) }.flatMap { CivilMonth(wire: $0.wire) }?.wire
      }
    }

    static func payload(_ p: JSONObject, type: OpType, months: Int) throws(SampleSeedError) -> JSONObject {
      guard months != 0, let list = fields[type] else { return p }
      var out = p
      for (path, kind) in list {
        try set(&out, path[...], kind, months)
      }
      return out
    }

    private static func set(_ o: inout JSONObject, _ path: ArraySlice<String>, _ kind: Kind, _ months: Int)
      throws(SampleSeedError)
    {
      guard let key = path.first, let v = o[key] else { return }
      if path.count > 1 {
        guard var inner = v.objectValue else { return }
        try set(&inner, path.dropFirst(), kind, months)
        o[key] = .object(inner)
        return
      }
      guard let s = v.stringValue else { return }  // null stays null
      guard let shifted = value(s, kind, months: months) else { throw .malformed("a date outside 2000-2099") }
      o[key] = .string(shifted)
    }
  }
}

extension OpAuthor {
  /// A draft whose payload the caller built whole (the sample loader; `build()` checks it).
  mutating func add(_ type: OpType, entity: (String, String)?, ingestID: String?, _ payload: JSONObject) {
    add(type, entity: entity, parent: nil, ingestID: ingestID, payload.keys.map { ($0, payload[$0]!) })
  }
}
