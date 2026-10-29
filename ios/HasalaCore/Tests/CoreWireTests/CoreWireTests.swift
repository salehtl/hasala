// Unit tests for CoreWire: the schema-4 registry and the blob rule, the op
// codec's messages, the checkpoint codec, the v3 layout and envelope, the chain
// and R0.
import CoreJSON
import CorePrimitives
import Foundation
import Testing

@testable import CoreWire

let user = UserID("6f1c2b9e-4d3a-4f5b-8c7d-0e1f2a3b4c5d")!
let writer = WriterID("ios-0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d")!
let ingest = String(repeating: "a", count: 64)

func blob(_ v: Int, _ ops: [String]) -> [UInt8] {
  Array(#"{"v":\#(v),"kind":"ops","ops":[\#(ops.joined(separator: ","))]}"#.utf8)
}

func decodeError(_ bytes: [UInt8]) -> WireDecodeError? {
  do {
    _ = try OpCodec.decodeBlobOps(bytes)
    return nil
  } catch { return error }
}

let rateSet = #"{"v":4,"type":"rate_set","op_id":"01J0000000000000000000000R","authored_at":"2026-06-05T10:00:00Z","parent_version":null,"payload":{"currency":"USD"}}"#

@Suite("CoreWire: registry")
struct RegistryTests {
  @Test("31 types in 00 §3's wire order, then mailbox_retired, txn_copy_resolved and merchant_category_rejected; profile_set is reserved")
  func order() {
    #expect(OpType.allCases.count == 31)
    #expect(
      OpType.allCases.dropFirst(14).map(\.rawValue) == [
        "budget_set", "budget_moved", "income_source_set", "category_plan_role_set", "bill_set",
        "bill_occurrence_set", "account_set", "card_linked", "account_checkin", "txn_annotated", "merchant_named",
        "sender_trust_set", "project_defined", "goal_defined", "mailbox_retired", "txn_copy_resolved",
        "merchant_category_rejected",
      ])
    #expect(OpType.allCases.filter(\.travelsAlone) == [.merchantCategoryRejected])
    #expect(OpType.merchantCategoryRejected.isParentFree && OpType.merchantCategoryRejected.minVersion == 4)
    #expect(OpType(rawValue: "profile_set") == nil)
    #expect(OpType.reserved == ["profile_set"])
    #expect(SchemaVersion.current == 4 && SchemaVersion.author == 4)
  }

  @Test("every new type is MIN_VERSION 4 = SCHEMA_VERSION; parent-free rows 8-18 and 20-26")
  func rules() {
    for t in OpType.allCases.dropFirst(14) { #expect(t.minVersion == 4, "\(t)") }
    let versioned = OpType.allCases.filter { !$0.isParentFree }.map(\.rawValue)
    #expect(
      versioned == [
        "txn_ingested", "txn_superseded", "txn_categorized", "txn_split", "txn_edited", "txn_duplicate_disposition",
        "rule_added", "bill_set", "project_defined", "goal_defined", "txn_copy_resolved",
      ])
    #expect(OpType.billSet.entityKind == "bill" && OpType.goalDefined.entityKind == "goal")
  }
}

@Suite("CoreWire: op codec")
struct OpCodecTests {
  @Test("a v4 blob round-trips; the encoder writes Go's field order and .sssZ")
  func roundTrip() throws {
    let ops = try OpCodec.decodeBlobOps(blob(4, [rateSet]))
    #expect(ops.count == 1 && ops[0].type == .rateSet && ops[0].authoredAt == "2026-06-05T10:00:00.000Z")
    let out = String(decoding: try OpCodec.encodeBlobOps(ops), as: UTF8.self)
    #expect(
      out
        == #"{"v":4,"kind":"ops","ops":[{"v":4,"type":"rate_set","op_id":"01J0000000000000000000000R","authored_at":"2026-06-05T10:00:00.000Z","parent_version":null,"payload":{"currency":"USD"}}]}"#
    )
  }

  @Test("versioned create: entity before parent_version, ingest_id after it")
  func fieldOrder() throws {
    let op = Op(
      v: 4, type: .txnIngested, opID: "01J000000000000000000000I1", authoredAt: "2026-06-05T14:00:00+04:00",
      entity: EntityRef(kind: "txn", id: "T1"), parentVersion: nil, ingestID: ingest,
      payload: .object(JSONObject([("b", .number(JSONNumber(1))), ("1", .string("x"))])))
    let out = String(decoding: try OpCodec.encodeBlobOps([op]), as: UTF8.self)
    #expect(
      out
        == #"{"v":4,"kind":"ops","ops":[{"v":4,"type":"txn_ingested","op_id":"01J000000000000000000000I1","authored_at":"2026-06-05T10:00:00.000Z","entity":{"kind":"txn","id":"T1"},"parent_version":null,"ingest_id":"\#(ingest)","payload":{"1":"x","b":1}}]}"#
    )
  }

  @Test("the blob v is the highest op v")
  func blobVersion() throws {
    let a = Op(v: 2, type: .rateSet, opID: "a", authoredAt: "2026-06-05T10:00:00Z", payload: .null)
    let b = Op(v: 3, type: .bankDeclared, opID: "b", authoredAt: "2026-06-05T10:00:00Z", payload: .null)
    #expect(String(decoding: try OpCodec.encodeBlobOps([a, b]), as: UTF8.self).hasPrefix(#"{"v":3,"#))
    #expect(String(decoding: try OpCodec.encodeBlobOps([]), as: UTF8.self) == #"{"v":1,"kind":"ops","ops":[]}"#)
  }

  @Test("a v above the schema is the hard stop, at the blob or at any op")
  func newer() {
    #expect(decodeError(blob(5, [])) == .unknownNewerVersion("op blob is v5, this build supports v4"))
    let v5op = rateSet.replacingOccurrences(of: #"{"v":4"#, with: #"{"v":5"#)
    #expect(decodeError(blob(4, [rateSet, v5op])) == .unknownNewerVersion("op 1 is v5, this build supports v4"))
  }

  @Test("only the next schema version is the hard stop: a larger v sets the blob aside")
  func implausibleVersion() {
    #expect(decodeError(blob(6, [])) == .setAside("op blob: version 6 is not valid"))
    #expect(
      OpCodec.decodeR10(Array(#"{"v":9007199254740991,"kind":"ops","ops":[]}"#.utf8))
        == .setAside(.opsUndecodable, message: "op blob: version 9007199254740991 is not valid"))
    let huge = rateSet.replacingOccurrences(of: #"{"v":4"#, with: #"{"v":9007199254740991"#)
    #expect(decodeError(blob(4, [rateSet, huge])) == .setAside("op 1: version 9007199254740991 is not valid"))
    #expect(OpCodec.decodeR10(blob(4, [huge])) == .setAside(.opsUndecodable, message: "op 0: version 9007199254740991 is not valid"))
    let v5op = rateSet.replacingOccurrences(of: #"{"v":4"#, with: #"{"v":5"#)
    #expect(OpCodec.decodeR10(blob(5, [v5op])) == .hardStop(.updateRequired))
    #expect(OpCodec.decodeR10(blob(4, [v5op])) == .hardStop(.updateRequired))
  }

  @Test("the blob is the unit: a reserved profile_set beside a valid op sets the whole blob aside (T36)")
  func reserved() {
    let profile = rateSet.replacingOccurrences(of: "rate_set", with: "profile_set")
    #expect(decodeError(blob(4, [rateSet, profile])) == .setAside(#"op 1: unknown type "profile_set""#))
    #expect(OpCodec.decodeR10(blob(4, [rateSet, profile])) == .setAside(.opsUndecodable, message: #"op 1: unknown type "profile_set""#))
    #expect(OpCodec.decodeR10(blob(5, [])) == .hardStop(.updateRequired))
  }

  @Test("a v4 type in a v3 op is an envelope failure")
  func minVersion() {
    let early = #"{"v":3,"type":"merchant_named","op_id":"m","authored_at":"2026-06-05T10:00:00Z","payload":{}}"#
    #expect(decodeError(blob(3, [early])) == .setAside("op 0: type merchant_named requires schema v4"))
  }

  @Test("the oracle's messages for each envelope rule", arguments: [
    (#"{"v":1.0,"kind":"ops"}"#, "op blob: v is written as 1.0, which Go refuses as a non-integer literal"),
    (#"{"v":"1","kind":"ops"}"#, #"op blob: version is "1""#),
    (#"{"v":0,"kind":"ops"}"#, "op blob: version 0 is not valid"),
    (#"{"v":1,"kind":"raw"}"#, #"blob kind is "raw", not "ops""#),
    (#"{"v":1}"#, #"blob kind is undefined, not "ops""#),
    (#"{"v":1,"kind":"ops","ops":{}}"#, "ops is not an array"),
    (#"[1]"#, "op blob: body is not a JSON object"),
    (#"{"v":1,"#, "op blob: body is not valid JSON (7 bytes)"),
    (#"{"v":1,"kind":"ops","ops":[7]}"#, "op 0: not a JSON object"),
    (
      #"{"v":1,"kind":"ops","ops":[{"v":1,"type":"rate_set","op_id":"r","authored_at":"2026-06-05T24:00:00Z","payload":{}}]}"#,
      #"timestamp "2026-06-05T24:00:00Z" has hour 24"#
    ),
    (
      #"{"v":1,"kind":"ops","ops":[{"v":1,"type":"rate_set","op_id":"r","authored_at":"2026-02-30T10:00:00+24:00","payload":{}}]}"#,
      #"timestamp "2026-02-30T10:00:00+24:00" has day 30"#
    ),
    (
      #"{"v":1,"kind":"ops","ops":[{"v":1,"type":"rate_set","op_id":"r","authored_at":"9999-12-31T23:59:59-23:59","payload":{}}]}"#,
      #"timestamp "9999-12-31T23:59:59-23:59" canonicalises to "+010000-01-01T23:58:59.000Z", which is outside the four-digit-year range this wire format carries"#
    ),
    (
      #"{"v":1,"kind":"ops","ops":[{"v":1,"type":"rate_set","op_id":"r","authored_at":5,"payload":{}}]}"#,
      "op 0: want an RFC3339 timestamp, got 5"
    ),
    (
      #"{"v":1,"kind":"ops","ops":[{"v":1,"type":"rate_set","op_id":"","authored_at":"2026-06-05T10:00:00Z","payload":{}}]}"#,
      "op 0: op_id is empty"
    ),
    (
      #"{"v":1,"kind":"ops","ops":[{"v":1,"type":"rate_set","op_id":"r","authored_at":"2026-06-05T10:00:00Z","entity":{},"payload":{}}]}"#,
      "op 0: rate_set is parent-free and must not name an entity"
    ),
    (
      #"{"v":1,"kind":"ops","ops":[{"v":1,"type":"rate_set","op_id":"r","authored_at":"2026-06-05T10:00:00Z","parent_version":1,"payload":{}}]}"#,
      "op 0: rate_set is parent-free and must not carry a parent_version"
    ),
    (
      #"{"v":1,"kind":"ops","ops":[{"v":1,"type":"txn_edited","op_id":"e","authored_at":"2026-06-05T10:00:00Z","payload":{}}]}"#,
      "op 0: txn_edited must name an entity"
    ),
    (
      #"{"v":1,"kind":"ops","ops":[{"v":1,"type":"txn_edited","op_id":"e","authored_at":"2026-06-05T10:00:00Z","entity":{"kind":"txn"},"payload":{}}]}"#,
      "op 0: entity needs both a kind and an id"
    ),
    (
      #"{"v":1,"kind":"ops","ops":[{"v":1,"type":"txn_edited","op_id":"e","authored_at":"2026-06-05T10:00:00Z","entity":{"kind":"txn","id":"T"},"parent_version":-1,"payload":{}}]}"#,
      "op 0: parent_version -1 is negative"
    ),
    (
      #"{"v":1,"kind":"ops","ops":[{"v":1,"type":"txn_edited","op_id":"e","authored_at":"2026-06-05T10:00:00Z","entity":{"kind":"txn","id":"T"},"parent_version":"1","payload":{}}]}"#,
      #"op 0: parent_version is "1""#
    ),
    (
      #"{"v":1,"kind":"ops","ops":[{"v":1,"type":"txn_ingested","op_id":"i","authored_at":"2026-06-05T10:00:00Z","entity":{"kind":"txn","id":"T"},"ingest_id":"","payload":{}}]}"#,
      "op 0: txn_ingested needs a 64-hex-char ingest_id, got undefined"
    ),
    (
      #"{"v":1,"kind":"ops","ops":[{"v":1,"type":"rate_set","op_id":"r","authored_at":"2026-06-05T10:00:00Z","ingest_id":null,"payload":{}}]}"#,
      "op 0: rate_set must not carry an ingest_id, got null"
    ),
    (
      #"{"v":1,"kind":"ops","ops":[{"v":1,"type":"rate_set","op_id":"r","authored_at":"2026-06-05T10:00:00Z"}]}"#,
      "op 0: payload is empty"
    ),
  ])
  func messages(_ body: String, _ message: String) {
    #expect(decodeError(Array(body.utf8)) == .setAside(message))
  }

  @Test("absent or null ops is zero ops; a null payload is a payload")
  func lenient() throws {
    #expect(try OpCodec.decodeBlobOps(Array(#"{"v":1,"kind":"ops"}"#.utf8)).isEmpty)
    #expect(try OpCodec.decodeBlobOps(Array(#"{"v":1,"kind":"ops","ops":null}"#.utf8)).isEmpty)
    let nullPayload = #"{"v":1,"type":"rate_set","op_id":"r","authored_at":"2026-06-05T10:00:00Z","payload":null}"#
    #expect(try OpCodec.decodeBlobOps(blob(1, [nullPayload]))[0].payload == .null)
  }

  @Test("an op built in code is validated before it is encoded, with its index")
  func validateBeforeEncode() {
    let bad = Op(v: 4, type: .rateSet, opID: "r", authoredAt: "2026-06-05T10:00:00Z", entity: EntityRef(kind: "txn", id: "T"), payload: .null)
    #expect(throws: OpValidationError.invalid("op 0: rate_set is parent-free and must not name an entity")) {
      try OpCodec.encodeBlobOps([bad])
    }
    let early = Op(v: 3, type: .goalDefined, opID: "g", authoredAt: "2026-06-05T10:00:00Z", entity: EntityRef(kind: "goal", id: "G"), payload: .null)
    #expect(throws: OpValidationError.invalid("type goal_defined requires schema v4")) { try OpCodec.validateOp(early) }
  }

  @Test("showValue: undefined, truncation at 512 UTF-16 units, deep nesting")
  func show() {
    #expect(showValue(nil) == "undefined")
    #expect(showValue(.string("a")) == #""a""#)
    let long = showValue(.string(String(repeating: "x", count: 600)))
    #expect(long.utf16.count == 513 && long.hasSuffix("…"))
    var deep = JSONValue.null
    for _ in 0..<25 { deep = .array([deep]) }
    #expect(showValue(deep) == "[deeply nested object]")
    var shallow = JSONValue.null
    for _ in 0..<24 { shallow = .array([shallow]) }
    #expect(showValue(shallow).hasPrefix("[[["))
  }
}

@Suite("CoreWire: checkpoint")
struct CheckpointTests {
  let h = String(repeating: "b", count: 64)

  @Test("encode sorts by UTF-8 bytes and refuses duplicates; decode refuses unsorted")
  func ordering() throws {
    let heads = [
      CheckpointHead(writerID: "z", stream: "hot", counter: "1", hash: h),
      CheckpointHead(writerID: "a", stream: "hot", counter: "2", hash: h),
    ]
    let payload = try Checkpoint.encodePayload(heads)
    #expect(try Checkpoint.decodePayload(payload).map(\.writerID) == ["a", "z"])
    #expect(throws: OpValidationError.invalid("duplicate checkpoint head for (a, hot)")) {
      try Checkpoint.encodePayload(heads + [heads[1]])
    }
    let unsorted = JSONValue.object(
      JSONObject([("heads", .array(try Checkpoint.encodePayload(heads)["heads"]!.arrayValue!.reversed()))]))
    #expect(throws: WireDecodeError.setAside("checkpoint heads are not sorted by (writer_id, stream)")) {
      try Checkpoint.decodePayload(unsorted)
    }
    #expect(throws: WireDecodeError.setAside("want a decimal-integer string, got 1")) {
      try Checkpoint.decodePayload(
        .object(JSONObject([("heads", .array([.object(JSONObject([("writer_id", .string("a")), ("stream", .string("hot")), ("counter", .number(JSONNumber(1))), ("hash", .string(h))]))]))])))
    }
  }
}

@Suite("CoreWire: frame v3 layout, envelope, chain, R0")
struct FrameTests {
  @Test("the AAD is 82 + digits(counter) bytes", arguments: [(Int64(1), 83), (9, 83), (10, 84), (99999, 87), (Int64.max, 101)])
  func aadLength(_ counter: Int64, _ length: Int) throws {
    let e = try Envelope(userID: user, writerID: writer, counter: counter)
    #expect(e.aad.count == length)
    #expect(String(decoding: e.aad, as: UTF8.self) == "\(user.string)|hot|\(writer.string)|\(counter)")
  }

  @Test("counters are 1-based")
  func counterZero() {
    #expect(throws: EnvelopeError.self) { try Envelope(userID: user, writerID: writer, counter: 0) }
  }

  @Test("layout offsets and the header")
  func layout() throws {
    let l = FrameV3.Layout(aadLength: 83, frameLength: 1024)
    #expect(l.header == 0..<90 && l.nonce == 90..<102 && l.region == 102..<1008 && l.tag == 1008..<1024)
    #expect(l.regionLength == 906)
    #expect(FrameV3.overhead(aadLength: 83) == 122)
    let h = FrameV3.header(epoch: 0x0102_0304, aad: Data([0xaa]))
    #expect([UInt8](h) == [3, 1, 2, 3, 4, 0, 1, 0xaa])
    #expect(FrameV3.parseHeader(h) == FrameV3.Header(version: 3, epoch: 0x0102_0304, aadLength: 1))
    #expect(FrameV3.bucket(for: 1025) == 4096 && FrameV3.bucket(for: 1_048_577) == nil)
  }

  @Test("identifiers: canonical lower-case only, the writer grammar")
  func identifiers() {
    #expect(UserID("6F1C2B9E-4D3A-4F5B-8C7D-0E1F2A3B4C5D") == nil)
    #expect(UserID("00000000-0000-0000-0000-000000000000") == nil)
    #expect(UserID(raw: user.raw) == user)
    #expect(WriterID("ios-0a1b2c3d-4e5f-3a6b-8c7d-9e0f1a2b3c4d") == nil)  // not v4
    #expect(WriterID("ios-0a1b2c3d-4e5f-4a6b-cc7d-9e0f1a2b3c4d") == nil)  // bad variant
    #expect(WriterID("dev-a") == nil)
  }

  @Test("chain verification: linkage, counters, writers")
  func chain() throws {
    let a = Data(repeating: 1, count: 1024)
    let b = Data(repeating: 2, count: 1024)
    let h1 = Chain.hash(prev: .zero, frame: a)
    let h2 = Chain.hash(prev: h1, frame: b)
    let rows = [
      Chain.Row(writerID: writer.string, stream: "hot", counter: 1, prevHash: .zero, blobHash: h1, blob: a),
      Chain.Row(writerID: writer.string, stream: "hot", counter: 2, prevHash: h1, blobHash: h2, blob: b),
    ]
    try Chain.verify(writerID: writer.string, stream: "hot", rows: rows, pinned: .genesis)
    #expect(Chain.headAfter(rows, pinned: .genesis) == Chain.Head(counter: 2, hash: h2))
    #expect(throws: Chain.Break.self) {
      try Chain.verify(writerID: writer.string, stream: "hot", rows: [rows[1]], pinned: .genesis)
    }
    let swapped = Chain.Row(writerID: writer.string, stream: "hot", counter: 2, prevHash: h1, blobHash: h2, blob: a)
    #expect(throws: Chain.Break.self) {
      try Chain.verify(writerID: writer.string, stream: "hot", rows: [rows[0], swapped], pinned: .genesis)
    }
    let list = rows.enumerated().map {
      Chain.HashRow(seq: Int64($0.offset + 10), writerID: $0.element.writerID, counter: $0.element.counter, prevHash: $0.element.prevHash, blobHash: $0.element.blobHash)
    }
    #expect(try Chain.verifyHashList(writerID: writer.string, stream: "hot", list: list, pinned: .genesis).hash == h2)
    try Chain.verifyFetchedRange(pinned: [1: h1, 2: h2], rows: rows)
  }

  @Test("R0 row shape")
  func rowShape() {
    let blob = Data(count: 1024)
    let h = Data(count: 32)
    #expect(RowShape.check(stream: "hot", writerID: writer.string, counter: "3", sizeBucket: 1024, blob: blob, prevHash: h, blobHash: h) != nil)
    #expect(RowShape.check(stream: "cold", writerID: writer.string, counter: "3", sizeBucket: 1024, blob: blob, prevHash: h, blobHash: h) == nil)
    #expect(RowShape.check(stream: "hot", writerID: "ingest", counter: "3", sizeBucket: 1024, blob: blob, prevHash: h, blobHash: h) == nil)
    #expect(RowShape.check(stream: "hot", writerID: writer.string, counter: "0", sizeBucket: 1024, blob: blob, prevHash: h, blobHash: h) == nil)
    #expect(RowShape.check(stream: "hot", writerID: writer.string, counter: "3", sizeBucket: 1024, blob: Data(count: 1023), prevHash: h, blobHash: h) == nil)
    #expect(RowShape.check(stream: "hot", writerID: writer.string, counter: "3", sizeBucket: 1024, blob: blob, prevHash: Data(count: 31), blobHash: h) == nil)
  }
}
