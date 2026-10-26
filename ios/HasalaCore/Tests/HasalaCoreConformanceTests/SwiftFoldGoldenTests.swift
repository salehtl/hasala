import CoreDomain
import CoreInvariants
import CoreJSON
import CorePrimitives
import CoreReplay
import CoreTime
import CoreWire
import Foundation
import Testing

struct FoldGoldenCase {
  var name: String
  var note: String
  var blobs: [(seq: Int, writer: String, ops: [String])]
}

struct FoldGoldenSet {
  var file: String
  var note: String
  var cases: [FoldGoldenCase]
}

enum FoldGoldens {
  static let w1 = "ios-0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"
  static let w2 = "ios-1b2c3d4e-5f60-4b7c-8d9e-0f1a2b3c4d5e"

  static func ulid(_ n: Int) -> String { "01JC" + String(repeating: "0", count: 22 - String(n).count) + String(n) }
  static func ingestID(_ n: Int) -> String { String(repeating: "0", count: 62) + (n < 10 ? "0\(n)" : "\(n)") }

  static func op(
    _ type: String, _ payload: String, id: String, entity: (String, String)? = nil, parent: Int? = nil,
    ingest: String? = nil, at: String = "2026-10-01T08:00:00.000Z"
  ) -> String {
    var s = #"{"v":4,"type":"\#(type)","op_id":"\#(id)","authored_at":"\#(at)""#
    if let e = entity { s += #","entity":{"kind":"\#(e.0)","id":"\#(e.1)"}"# }
    s += #","parent_version":\#(parent.map(String.init) ?? "null")"#
    if let i = ingest { s += #","ingest_id":"\#(i)""# }
    return s + #","payload":\#(payload)}"#
  }

  static let sets: [FoldGoldenSet] = [MailboxRetireGoldens.set, DuplicateGoldens.set, EdgeGoldens.set, SMSFoldGoldens.set]

  static func file(_ set: FoldGoldenSet) throws -> JSONValue {
    var cases: [JSONValue] = []
    for c in set.cases {
      var log: [JSONValue] = []
      var s = State()
      for b in c.blobs {
        let ops = try b.ops.map { try JSONParser.parse(Array($0.utf8)) }
        let body = JSONWriter().bytes(obj([("v", .number(JSONNumber(4))), ("kind", .string("ops")), ("ops", .array(ops))]))
        let decoded = try OpCodec.decodeBlobOps(body)
        try Replay.foldOps(decoded, seq: Int64(b.seq), writerID: b.writer, into: &s)
        let canonical = try JSONParser.parse(OpCodec.encodeBlobOps(decoded))["ops"] ?? .array([])
        log.append(obj([("seq", .string(String(b.seq))), ("writer_id", .string(b.writer)), ("ops", canonical)]))
      }
      let bytes = s.serialized(blankingDiagnostics: true)
      let state = try JSONParser.parse(bytes)
      cases.append(
        obj([
          ("name", .string(c.name)), ("group", .string("fold_v4")), ("note", .string(c.note)),
          ("schema_version", .number(JSONNumber(4))), ("log", .array(log)),
          (
            "expect",
            obj([
              ("error", .null), ("state", state), ("state_sha256", .string(Hex.encode(sha256(bytes)))),
              ("anomaly_kinds", .array(s.anomalies.map { .string($0.kind) })),
            ])
          ),
        ]))
    }
    return obj([
      ("note", .string(set.note)),
      ("regenerate", .string("HASALA_WRITE_SWIFT_GOLDENS=1 swift test --filter SwiftFoldGoldenTests (in ios/HasalaCore)")),
      ("format", .string("Each case is a conformance/replay case (log items of ops, expect.state blanked as there, expect.state_sha256 the pass condition), folded by the v4 fold.")),
      ("cases", .array(cases)),
    ])
  }
}

@Suite("conformance/swift fold goldens", .serialized)
struct SwiftFoldGoldenTests {
  static let root = Fixtures.conformanceRoot.appendingPathComponent("swift", isDirectory: true)

  @Test("write the fold goldens (only with HASALA_WRITE_SWIFT_GOLDENS=1)", .enabled(if: SwiftGoldenTests.writing))
  func write() throws {
    for set in FoldGoldens.sets {
      try Data(Pretty.text(try FoldGoldens.file(set)).utf8).write(to: Self.root.appendingPathComponent(set.file))
    }
  }

  @Test("the committed fold goldens are what the fold writes now", arguments: FoldGoldens.sets.map(\.file))
  func fresh(_ file: String) throws {
    let set = try #require(FoldGoldens.sets.first { $0.file == file })
    let committed = try String(contentsOf: Self.root.appendingPathComponent(file), encoding: .utf8)
    let now = Pretty.text(try FoldGoldens.file(set))
    #expect(committed == now, "\(file) is stale: regenerate it")
  }

  @Test("SamePurchase.pairs over the folded edge cases skips archived rows and held copies")
  func pairs() throws {
    let doc = try Fixtures.json("swift/\(EdgeGoldens.set.file)")
    var seen = 0
    for c in try doc.array("cases") {
      let name = try c.string("name")
      guard let want = EdgeGoldens.pairs[name] else { continue }
      seen += 1
      guard case .state(let s) = try ReplayConformanceTests.fold(c) else {
        Issue.record("\(name) stopped")
        continue
      }
      let rows = try s.txns.values.map { t in
        SamePurchase.Row(
          id: t.id, live: t.isLive, unparsed: t.unparsed, archived: t.annotation("archived") != nil,
          manual: t.entryMethod == "manual", amountMinor: t.amountMinor, currency: t.currency, amountHomeMinor: t.amountHomeMinor,
          direction: t.direction, bank: t.bank, last4: t.last4, postedMs: try parseInstantMs(t.postedAt),
          merchantKey: DuplicateRules.merchantKey(t.merchantRaw), possibleDuplicateOf: t.possibleDuplicateOf,
          duplicateDisposition: t.duplicateDisposition, heldCopy: t.isHeldCopy)
      }
      #expect(SamePurchase.pairs(rows, home: "AED").map { $0.foreign + ">" + $0.home } == want, "\(name)")
    }
    #expect(seen == EdgeGoldens.pairs.count)
  }

  @Test("every committed case folds through the replay reader to its hash, and passes the invariants", arguments: FoldGoldens.sets.map(\.file))
  func readBack(_ file: String) throws {
    let doc = try Fixtures.json("swift/\(file)")
    for c in try doc.array("cases") {
      let name = try c.string("name")
      let want = try c["expect"]!.string("state_sha256")
      guard case .state(let s) = try ReplayConformanceTests.fold(c) else {
        Issue.record("\(file): \(name) stopped")
        continue
      }
      #expect(Hex.encode(sha256(s.serialized(blankingDiagnostics: true))) == want, "\(name)")
      let hard = Invariants.check(s).filter { $0.severity == .hardStop }
      #expect(hard.isEmpty, "\(name): \(hard)")
    }
  }
}
