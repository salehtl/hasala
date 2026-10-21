// CoreWire's op codec against the executors that already agree:
//
//   - conformance/op/manifest.json (Go): the v3 registry, every pinned body,
//     the refusals;
//   - conformance/ts (TypeScript-sealed blobs): `encodeBlobOps` of the decoded
//     ops reproduces the TypeScript encoder's plaintext BYTE FOR BYTE, which is
//     the byte-identity claim (wire/op.ts encodes and the frame stores those
//     bytes);
//   - conformance/blob and conformance/ts frames open through `FrameV1Reader`.
import CoreJSON
import CorePrimitives
import CoreTime
import CoreWire
import Foundation
import Testing

@Suite("conformance/op, conformance/ts: the op codec")
struct OpCodecConformanceTests {
  static let manifest = Result { try Fixtures.json("op/manifest.json") }

  @Test("the v3 registry is the first 14 types of the v4 one, with the same rules")
  func registry() throws {
    let m = try Self.manifest.get()
    let v3 = try m.array("types").map { $0.stringValue ?? "" }
    #expect(Array(OpType.allCases.prefix(14).map(\.rawValue)) == v3)
    let parentFree = Set(try m.array("parent_free").map { $0.stringValue ?? "" })
    for t in OpType.allCases.prefix(14) {
      #expect(t.isParentFree == parentFree.contains(t.rawValue), "\(t)")
      #expect(Int64(t.minVersion) == m["min_versions"]?[t.rawValue]?.numberValue?.int64Value, "\(t)")
    }
    #expect(m["schema_version"]?.numberValue?.int64Value == 3)
  }

  @Test(
    "every pinned op body decodes, and re-encodes stably",
    arguments: ["config_ops_base64", "golden_ops_base64", "duplicate_disposition_base64", "verified_origin_base64"])
  func pinnedBodies(_ key: String) throws {
    let bytes = [UInt8](try Self.manifest.get().base64(key))
    let ops = try OpCodec.decodeBlobOps(bytes)
    #expect(!ops.isEmpty)
    let once = try OpCodec.encodeBlobOps(ops)
    let again = try OpCodec.encodeBlobOps(try OpCodec.decodeBlobOps(once))
    #expect(once == again)
    #expect(try OpCodec.decodeBlobOps(once) == ops)
    // Go writes `…:00Z`; the TypeScript encoder (and this one) `…:00.000Z`: the
    // same instant, different bytes, which is the documented divergence.
    #expect(String(decoding: once, as: UTF8.self).contains("2026-06-05T10:00:00.000Z"))
  }

  @Test("expect_ops: the decoded envelopes")
  func expectOps() throws {
    let m = try Self.manifest.get()
    let ops = try OpCodec.decodeBlobOps([UInt8](try m.base64("golden_ops_base64")))
    let want = try m.array("expect_ops")
    #expect(ops.count == want.count)
    for (op, w) in zip(ops, want) {
      #expect(op.type.rawValue == (try w.string("type")))
      #expect(op.opID == (try w.string("op_id")))
      #expect(String(try parseInstantMs(op.authoredAt)) == (try w.string("authored_at_unix_ms")))
      #expect((op.entity != nil) == (w["has_entity"]?.boolValue == true))
      #expect(op.parentVersion.map(String.init) == w["parent_version"]?.stringValue)
      #expect((op.ingestID ?? "") == (try w.string("ingest_id")))
    }
  }

  @Test("the raw-body record decodes (read only), and is not an op blob")
  func rawBody() throws {
    let bytes = [UInt8](try Self.manifest.get().base64("golden_raw_body_base64"))
    #expect(try OpCodec.kindOf(bytes) == .rawBody)
    let r = try FrameV1Reader.decodeRawBody(bytes)
    #expect(r.raw == Data("hi".utf8))
    #expect(throws: WireDecodeError.setAside(#"blob kind is "raw_body", not "ops""#)) {
      try OpCodec.decodeBlobOps(bytes)
    }
  }

  @Test("the checkpoint payload re-encodes byte for byte")
  func checkpoint() throws {
    let bytes = [UInt8](try Self.manifest.get().base64("golden_checkpoint_base64"))
    let heads = try Checkpoint.decodePayload(try JSONParser.parse(bytes))
    #expect(heads.count == 3)
    #expect(JSONWriter().bytes(try Checkpoint.encodePayload(heads.reversed())) == bytes)
  }

  @Test("every invalid duplicate-disposition payload sets its blob aside")
  func duplicateDispositionInvalid() throws {
    let m = try Self.manifest.get()
    let body = try JSONParser.parse([UInt8](try m.base64("duplicate_disposition_base64")))
    for payload in try m.array("duplicate_disposition_invalid_payloads") {
      let bad = Self.replacingFirstOp(body) { $0["payload"] = payload }
      #expect(throws: WireDecodeError.self) { try OpCodec.decodeBlobOps(JSONWriter().bytes(bad)) }
      if case .setAside? = Self.error(JSONWriter().bytes(bad)) {} else { Issue.record("not set aside: \(payload)") }
    }
  }

  @Test("parent_version past 2^53 is refused, by the oracle's message")
  func parentVersionOverflow() throws {
    let bytes = [UInt8](try Self.manifest.get().base64("parent_version_overflow_base64"))
    #expect(
      Self.error(bytes)
        == .setAside(
          "op 0: parent_version is 9007199254740993, outside the range a JSON number carries exactly — "
            + "Go's int64 can hold it and this executor cannot"))
  }

  @Test("authored_at_rejects: each one sets its blob aside")
  func authoredAtRejects() throws {
    let m = try Self.manifest.get()
    let body = try JSONParser.parse([UInt8](try m.base64("duplicate_disposition_base64")))
    for r in try m.array("authored_at_rejects") {
      let bad = Self.replacingFirstOp(body) { $0["authored_at"] = r }
      guard case .setAside(let msg)? = Self.error(JSONWriter().bytes(bad)) else {
        Issue.record("accepted \(r)")
        continue
      }
      #expect(msg.hasPrefix("want an RFC3339") || msg.hasPrefix("timestamp "), "\(msg)")
    }
  }

  @Test("set_aside_blobs: each shared body is set aside, never a hard stop")
  func setAsideBlobs() throws {
    let cases = try Self.manifest.get().array("set_aside_blobs")
    #expect(!cases.isEmpty)
    for c in cases {
      let name = try c.string("name")
      let bytes = [UInt8](try c.base64("body_base64"))
      do {
        if try c.string("kind") == "raw_body" {
          _ = try FrameV1Reader.decodeRawBody(bytes)
        } else {
          _ = try OpCodec.decodeBlobOps(bytes)
        }
        Issue.record("accepted \(name)")
      } catch let e as WireDecodeError {
        if case .setAside = e {} else { Issue.record("\(name): \(e)") }
      }
    }
  }

  @Test("accepted_variants: case-variant keys are ignored and a surrogate pair is read")
  func acceptedVariants() throws {
    let cases = try Self.manifest.get().array("accepted_variants")
    #expect(!cases.isEmpty)
    for c in cases {
      let name = try c.string("name")
      let ops = try OpCodec.decodeBlobOps([UInt8](try c.base64("body_base64")))
      let want = try c.array("expect_ops")
      #expect(ops.count == want.count, "\(name)")
      for (op, w) in zip(ops, want) {
        #expect(op.type.rawValue == (try w.string("type")), "\(name)")
        #expect(op.opID == (try w.string("op_id")), "\(name)")
        #expect(String(try parseInstantMs(op.authoredAt)) == (try w.string("authored_at_unix_ms")), "\(name)")
        #expect((op.entity != nil) == (w["has_entity"]?.boolValue == true), "\(name)")
        #expect(op.parentVersion.map(String.init) == w["parent_version"]?.stringValue, "\(name)")
        #expect((op.ingestID ?? "") == (try w.string("ingest_id")), "\(name)")
      }
    }
  }

  // MARK: TypeScript byte identity

  static func tsOpCases() -> [String] {
    guard let m = try? Fixtures.json("ts/manifest.json"), let f = m["fixtures"]?.arrayValue else { return [] }
    return f.filter { $0["kind"]?.stringValue == "ops" }.compactMap { $0["file"]?.stringValue }
  }

  @Test("encodeBlobOps reproduces the TypeScript encoder's bytes", arguments: tsOpCases())
  func typeScriptBytes(_ file: String) throws {
    let m = try Fixtures.json("ts/manifest.json")
    let fixture = try #require(m["fixtures"]?.arrayValue?.first { $0["file"]?.stringValue == file })
    let plaintext = [UInt8](try fixture.base64("expect_plaintext_base64"))
    let ops = try OpCodec.decodeBlobOps(plaintext)
    #expect(try OpCodec.encodeBlobOps(ops) == plaintext)
  }

  @Test("the TypeScript cases are the ones expected")
  func typeScriptCaseCount() { #expect(Self.tsOpCases().count == 2) }

  // MARK: v1 frames

  static func frameCases() -> [String] {
    ["ts", "blob"].flatMap { dir -> [String] in
      guard let m = try? Fixtures.json("\(dir)/manifest.json"), let f = m["fixtures"]?.arrayValue else { return [] }
      return f.compactMap { $0["file"]?.stringValue.map { "\(dir)/\($0)" } }
    }
  }

  @Test("v1 frames open at their envelope, and nowhere else", arguments: frameCases())
  func v1Frames(_ path: String) throws {
    let dir = String(path.split(separator: "/")[0])
    let file = String(path.split(separator: "/")[1])
    let m = try Fixtures.json("\(dir)/manifest.json")
    let fixture = try #require(m["fixtures"]?.arrayValue?.first { $0["file"]?.stringValue == file })
    let env = try #require(fixture["envelope"])
    let counter = try #require(Int64(try env.string("writer_counter")))
    let envelope = FrameV1Reader.Envelope(
      userID: try env.string("user_id"), stream: try env.string("stream"), writerID: try env.string("writer_id"),
      counter: counter)
    let frame = try Fixtures.data(path)
    #expect(String(decoding: try envelope.aad(), as: UTF8.self) == (try fixture.string("expect_aad")))
    let plaintext = try FrameV1Reader.open(frame, envelope: envelope)
    #expect(plaintext == (try fixture.base64("expect_plaintext_base64")))
    let moved = FrameV1Reader.Envelope(
      userID: envelope.userID, stream: envelope.stream, writerID: envelope.writerID, counter: counter + 1)
    #expect(throws: WireDecodeError.setAside("associated data mismatch: sealed at a different position")) {
      try FrameV1Reader.open(frame, envelope: moved)
    }
    switch fixture["kind"]?.stringValue {
    case "ops": #expect(try !OpCodec.decodeBlobOps(plaintext).isEmpty)
    case "raw_body": #expect(try FrameV1Reader.decodeRawBody(plaintext).ingestID.count == 64)
    default: break
    }
  }

  @Test("conformance/blob chain_steps")
  func chainSteps() throws {
    let steps = try Fixtures.json("blob/manifest.json").array("chain_steps")
    var prev = Hash32.zero
    for s in steps {
      let fill = try Hex.decode(try s.string("fill_byte"))[0]
      let next = Chain.hash(prev: prev, frame: Data(repeating: fill, count: try s.int("length")))
      #expect(next.hex == (try s.string("expect_hash")))
      prev = next
    }
  }

  // MARK: Helpers

  static func error(_ bytes: [UInt8]) -> WireDecodeError? {
    do {
      _ = try OpCodec.decodeBlobOps(bytes)
      return nil
    } catch { return error }
  }

  static func replacingFirstOp(_ body: JSONValue, _ edit: (inout JSONObject) -> Void) -> JSONValue {
    guard var doc = body.objectValue, var ops = doc["ops"]?.arrayValue, var first = ops.first?.objectValue else {
      return body
    }
    edit(&first)
    ops[0] = .object(first)
    doc["ops"] = .array(ops)
    return .object(doc)
  }
}
