import CoreInvariants
import CoreJSON
import CoreReplay
import HasalaText
import Testing

@Suite("conformance/fx")
struct FXConformanceTests {
  static let files: [String] = {
    guard let m = try? Fixtures.json("fx/manifest.json"), let cases = m["cases"]?.arrayValue else { return [] }
    return cases.compactMap { $0["file"]?.stringValue }
  }()

  static func fold(_ c: JSONValue) throws -> State {
    var blobs: [(seq: String, writer: String, ops: [JSONValue])] = []
    for e in try c.array("entries") {
      let seq = try e.string("seq")
      if let last = blobs.last, last.seq == seq {
        blobs[blobs.count - 1].ops.append(e["op"]!)
      } else {
        blobs.append((seq, try e.string("writer_id"), [e["op"]!]))
      }
    }
    var s = State()
    for b in blobs {
      let body = try ReplayConformanceTests.body(obj([("ops", .array(b.ops))]))
      try Replay.foldBlob(PositionedBlob(writerID: b.writer, stream: "hot", writerCounter: 0, seq: Int64(b.seq)!, body: body), into: &s)
    }
    return s
  }

  static func expected(_ s: State) -> JSONValue {
    func minor(_ v: Int64?) -> JSONValue { v.map { .string(String($0)) } ?? .null }
    let pending = s.pendingByCurrency.filter { !$0.value.isEmpty }.map { ccy, ids in
      (ccy, JSONValue.array(ids.sorted { compareUTF8($0, $1) < 0 }.map { .string($0) }))
    }
    return obj([
      ("home_currency", s.homeCurrency.map { .string($0) } ?? .null),
      ("rates", obj(s.rates.map { ($0.key, minor($0.value)) })),
      ("snapshots", obj(s.txns.map { ($0.key, minor($0.value.amountHomeMinor)) })),
      ("pending", obj(pending)),
      ("anomalies", .array(s.anomalies.map { obj([("kind", .string($0.kind)), ("at_seq", .string(String($0.atSeq)))]) })),
    ])
  }

  @Test("the manifest lists every case file")
  func manifestComplete() {
    #expect(Self.files.count >= 22)
    let onDisk = Fixtures.jsonFiles(under: Fixtures.conformanceRoot.appendingPathComponent("fx")).filter { $0 != "manifest.json" }
    #expect(Set(onDisk) == Set(Self.files))
  }

  @Test("each case folds to its expect (HASALA_UPDATE_GOLDEN=1 rewrites it)", arguments: files)
  func golden(_ file: String) throws {
    let c = try Fixtures.json("fx/\(file)")
    let s = try Self.fold(c)
    #expect(s.unreadable.isEmpty, "\(file): a blob was set aside")
    let hard = Invariants.check(s).filter { $0.severity == .hardStop }
    #expect(hard.isEmpty, "\(file): \(hard)")
    try Golden.check("fx/\(file)", c.setting("expect", Self.expected(s)), ascii: false)
  }
}
