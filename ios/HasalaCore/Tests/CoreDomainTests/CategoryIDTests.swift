import CoreCategorize
import CoreReplay
import CoreWire
import HasalaText
import Testing

@testable import CoreDomain

@Suite("category ids are byte-exact")
struct CategoryIDTests {
  static let nfc = "caf\u{E9}"
  static let nfd = "cafe\u{301}"

  static func bytes(_ s: String?) -> [UInt8]? { s.map { Array($0.utf8) } }

  @Test("two look-alike ids from the log stay two categories, through a snapshot and the taxonomy")
  func lookAlikesStayTwo() throws {
    let ops = [Self.nfc, Self.nfd].enumerated().map { i, id in
      #"{"v":3,"type":"category_defined","op_id":"op-\#(i)","authored_at":"2026-10-01T08:00:00.000Z","parent_version":null,"payload":{"id":"\#(id)","name":"N\#(i)","kind":"spending","bucket":"want","active":true}}"#
    }
    let body = Array(#"{"v":3,"kind":"ops","ops":[\#(ops.joined(separator: ","))]}"#.utf8)
    var s = State()
    try Replay.foldOps(try OpCodec.decodeBlobOps(body), seq: 1, writerID: "dev-a", into: &s)
    #expect(s.categories.keys.map { Self.bytes($0.value)! } == [Self.bytes(Self.nfc)!, Self.bytes(Self.nfd)!])
    #expect(s.categories[ExactKey(Self.nfc)]?.name == "N0" && s.categories[ExactKey(Self.nfd)]?.name == "N1")

    let back = try SnapshotCodec.decode(try SnapshotCodec.encode(StateSnapshot(state: s))).state
    #expect(back.categories.keys.map { Self.bytes($0.value)! } == [Self.bytes(Self.nfc)!, Self.bytes(Self.nfd)!])

    let t = TaxonomyView(state: s)
    #expect(t.info(Self.nfc)?.name == "N0" && t.info(Self.nfd)?.name == "N1")
    #expect(Self.bytes(t.info(Self.nfd)?.id) == Self.bytes(Self.nfd))
  }

  @Test("a new id typed in NFD is normalized to NFC before the v4 CategoryId check, which refuses any non-ASCII id")
  func authoredNFC() throws {
    var a = OpAuthor(ctx())
    a.defineCategory(id: Self.nfd, name: "Caf\u{E9}", kind: .spending, bucket: .want, icon: nil, active: true)
    do {
      _ = try a.build()
      Issue.record("a non-ASCII category id was authored")
    } catch {
      let text = Array(String(describing: error).utf8)
      #expect(text.firstRange(of: Self.bytes(Self.nfc)!) != nil && text.firstRange(of: Self.bytes(Self.nfd)!) == nil, "\(error)")
    }
    var b = OpAuthor(ctx())
    b.defineCategory(id: "cafe", name: "Caf\u{E9}", kind: .spending, bucket: .want, icon: nil, active: true)
    let op = try #require(try b.build().ops.first)
    #expect(op.payload["id"]?.stringValue == "cafe")
  }
}
