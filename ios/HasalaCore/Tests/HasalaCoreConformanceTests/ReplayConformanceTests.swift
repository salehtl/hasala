// conformance/replay (the TypeScript v3 fold oracle): every log folds to the
// oracle's state, byte for byte, with diagnostic text blanked (A-21), through
// the Swift fold at schema 4 (spec 03c acceptance test 2: v4 additions leave
// every v3 case byte-identical).
import CoreInvariants
import CoreJSON
import CorePrimitives
import CoreReplay
import CoreWire
import Foundation
import Testing

@Suite("conformance/replay")
struct ReplayConformanceTests {
  static let files: [String] = {
    guard let m = try? Fixtures.json("replay/manifest.json"), let cases = m["cases"]?.arrayValue else { return [] }
    return cases.compactMap { $0["file"]?.stringValue }
  }()

  enum Outcome {
    case state(State)
    case stopped(kind: String, at: Int)
  }

  /// The body a log item stands for: its exact bytes, or its ops wrapped in an ops blob.
  static func body(_ item: JSONValue) throws -> [UInt8] {
    if let ops = item["ops"]?.arrayValue {
      let v = ops.compactMap { $0["v"]?.numberValue?.int64Value }.max() ?? 1
      let blob = JSONValue.object(JSONObject([("v", .number(JSONNumber(max(v, 1)))), ("kind", .string("ops")), ("ops", .array(ops))]))
      return JSONWriter().bytes(blob)
    }
    if let text = item["body"]?.stringValue { return Array(text.utf8) }
    return [UInt8](try item.base64("body_base64"))
  }

  static func fold(_ c: JSONValue) throws -> Outcome {
    var s = State()
    for (i, item) in try c.array("log").enumerated() {
      let isOps = item["ops"] != nil
      let blob = PositionedBlob(
        writerID: try item.string("writer_id"), stream: isOps ? "hot" : try item.string("stream"),
        writerCounter: isOps ? 0 : Int64(try item.string("writer_counter"))!, seq: Int64(try item.string("seq"))!,
        body: try body(item))
      do {
        try Replay.foldBlob(blob, into: &s)
      } catch {
        switch error {
        case .order: return .stopped(kind: "replay_order", at: i)
        case .newerVersion: return .stopped(kind: "newer_version", at: i)
        }
      }
    }
    return .state(s)
  }

  @Test("the manifest lists every case file")
  func manifestComplete() throws {
    #expect(Self.files.count >= 100)
    let onDisk = Fixtures.jsonFiles(under: Fixtures.conformanceRoot.appendingPathComponent("replay")).filter { $0 != "manifest.json" }
    #expect(Set(onDisk) == Set(Self.files))
  }

  static let disagreements: [String: Comment] = [:]

  @Test("fold matches the oracle", arguments: files)
  func foldMatches(_ file: String) throws {
    if let why = Self.disagreements[file] {
      withKnownIssue(why) { try Self.compare(file) }
      return
    }
    try Self.compare(file)
  }

  static func compare(_ file: String) throws {
    let c = try Fixtures.json("replay/\(file)")
    let expect = c["expect"]!
    let got = try Self.fold(c)
    if let err = expect["error"], !err.isNull {
      guard case .stopped(let kind, let at) = got else {
        Issue.record("\(file): expected a stop, folded to the end")
        return
      }
      #expect(kind == (try err.string("kind")))
      #expect(at == (try err.int("at_entry")))
      return
    }
    guard case .state(let s) = got else {
      Issue.record("\(file): stopped early: \(got)")
      return
    }
    let bytes = s.serialized(blankingDiagnostics: true)
    let want = try expect.string("state_sha256")
    let have = Hex.encode(sha256(bytes))
    if have != want {
      let ours = try JSONParser.parse(bytes)
      let theirs = expect["state"]!.sortingKeysByUTF8()
      Issue.record("\(file): state differs\n ours: \(JSONWriter().string(ours).prefix(4000))\n want: \(JSONWriter().string(theirs).prefix(4000))")
    }
    // The order serializeState sorts away: first declaration of banks and categories.
    if let order = expect["order"] {
      #expect(s.banks.keys.map(\.value) == (try order.array("banks")).compactMap(\.stringValue))
      #expect(s.categories.keys.map(\.value) == (try order.array("categories")).compactMap(\.stringValue))
    }
  }

  static func expected(_ c: JSONValue) throws -> JSONValue {
    switch try fold(c) {
    case .stopped(let kind, let at):
      return obj([("error", obj([("kind", .string(kind)), ("at_entry", .number(JSONNumber(Int64(at))))]))])
    case .state(let s):
      let bytes = s.serialized(blankingDiagnostics: true)
      let sha = Hex.encode(sha256(bytes))
      var e: [(String, JSONValue)] = [
        ("error", .null), ("state", try JSONParser.parse(bytes)), ("state_sha256", .string(sha)),
        ("order", obj([("banks", .array(s.banks.keys.map { .string($0.value) })), ("categories", .array(s.categories.keys.map { .string($0.value) }))])),
      ]
      if let old = c["expect"], old["state_sha256"]?.stringValue == sha, let d = old["diagnostics"] { e.append(("diagnostics", d)) }
      return obj(e)
    }
  }

  @Test("each case's expect is what Swift computes (HASALA_UPDATE_GOLDEN=1 rewrites it)", arguments: files)
  func golden(_ file: String) throws {
    guard Self.disagreements[file] == nil else { return }
    let c = try Fixtures.json("replay/\(file)")
    try Golden.check("replay/\(file)", c.setting("expect", try Self.expected(c)))
  }

  @Test("folding decoded ops directly equals folding the blob bodies", arguments: files)
  func directEqualsDecoded(_ file: String) throws {
    let c = try Fixtures.json("replay/\(file)")
    guard let err = c["expect"]?["error"], err.isNull else { return }
    var direct = State()
    for item in try c.array("log") {
      let seq = Int64(try item.string("seq"))!
      let writer = try item.string("writer_id")
      guard item["ops"] != nil else {
        try Replay.foldBlob(
          PositionedBlob(
            writerID: writer, stream: try item.string("stream"), writerCounter: Int64(try item.string("writer_counter"))!,
            seq: seq, body: try Self.body(item)), into: &direct)
        continue
      }
      let ops = try OpCodec.decodeBlobOps(try Self.body(item))
      try Replay.foldOps(ops, seq: seq, writerID: writer, into: &direct)
    }
    guard case .state(let viaBlobs) = try Self.fold(c) else { return }
    #expect(direct.serialized() == viaBlobs.serialized())
  }

  @Test("FoldCanary's v3 half is the canary-canary-v3 log, and folds to its state")
  func canaryCopyIsFaithful() throws {
    let c = try Fixtures.json("replay/canary-canary-v3.json")
    let log = try c.array("log")
    let ours = FoldCanary.log()
    #expect(ours.count > log.count)
    var s = State()
    for (i, item) in log.enumerated() {
      let wantOps = try OpCodec.decodeBlobOps(try Self.body(item))
      #expect(ours[i].seq == Int64(try item.string("seq"))!)
      #expect(ours[i].writerID == (try item.string("writer_id")))
      #expect(ours[i].ops == wantOps)
      try Replay.foldOps(ours[i].ops, seq: ours[i].seq, writerID: ours[i].writerID, into: &s)
    }
    #expect(s.serializedSHA256(blankingDiagnostics: true) == (try c["expect"]!.string("state_sha256")))
  }

  @Test("every oracle state passes the state-level invariants", arguments: files)
  func invariants(_ file: String) throws {
    guard case .state(let s) = try Self.fold(try Fixtures.json("replay/\(file)")) else { return }
    let hard = Invariants.check(s).filter { $0.severity == .hardStop }
    #expect(hard.isEmpty, "\(file): \(hard)")
  }
}
