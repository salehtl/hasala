// conformance/ts (frames sealed by the TypeScript executor) and conformance/blob
// (frames sealed by Go): the gzip payloads open with CorePrimitives' capped
// gunzip to the manifests' plaintexts, and those plaintexts re-encode through
// CoreJSON's writer.
//
// # Why gzip is compared by its DECOMPRESSED payload
//
// A gzip member is a 10-byte header, a DEFLATE stream and a trailer, and two
// conforming compressors may emit different bytes for the same input:
//
//   - the header's OS byte is the compressing zlib build's OS_CODE: 3 in the
//     Linux builds that sealed conformance/ts, 19 in Apple's system zlib, 255
//     (unknown) in Go's compress/gzip;
//   - the DEFLATE stream depends on the implementation: Go's compress/flate is
//     not zlib, so conformance/blob's streams differ from any zlib's at level 9.
//
// So the contract checked here is the payload, never the compressed bytes. The
// frame (and its chain hash) is whatever its author wrote: each blob is encoded
// once, by its author, and stored as written (wire/op.ts header comment), and
// the sealed v3 frame is persisted before upload for the same reason (client-
// core-a §0 finding 2). One stronger fact is measured and pinned below,
// because it is useful and true today: Apple's zlib and the zlib that sealed
// conformance/ts write the SAME DEFLATE stream at level 9; only the OS byte
// differs. If an OS update changes the system zlib, that test, and only that
// test, fails.
import CoreJSON
import CorePrimitives
import Foundation
import Testing

@Suite("conformance/ts and conformance/blob frames")
struct FrameFixtureTests {
  static let maxPlaintext = 2 << 20  // wire/blob.ts MAX_PLAINTEXT

  struct Case: CustomTestStringConvertible, Sendable {
    let dir: String
    let fixture: JSONValue
    var file: String { fixture["file"]?.stringValue ?? "?" }
    var testDescription: String { "\(dir)/\(file)" }
  }

  static func cases(_ dir: String) -> [Case] {
    guard let m = try? Fixtures.json("\(dir)/manifest.json"), let f = m["fixtures"]?.arrayValue else { return [] }
    return f.map { Case(dir: dir, fixture: $0) }
  }

  static let all = cases("ts") + cases("blob")

  /// The fixtures whose plaintext is a JSON body (`kind` ops or raw_body); the
  /// bucket-edge fixtures carry incompressible filler instead.
  static func jsonCases(_ dir: String) -> [Case] {
    cases(dir).filter { ($0.fixture["kind"]?.stringValue ?? "") != "" }
  }

  @Test("the manifests list the fixtures this suite expects")
  func counts() {
    #expect(Self.cases("ts").count == 5)
    #expect(Self.cases("blob").count == 5)
    #expect(Self.jsonCases("ts").count == 3 && Self.jsonCases("blob").count == 3)
  }

  @Test("frame layout: version, AAD, bucket, pre-pad length, zero nonce and tag", arguments: all)
  func layout(_ c: Case) throws {
    let bytes = try Fixtures.data("\(c.dir)/\(c.file)")
    let frame = try FrameV1(bytes)
    #expect(frame.version == 1)
    #expect(String(decoding: frame.aad, as: UTF8.self) == (try c.fixture.string("expect_aad")))
    #expect(bytes.count == (try c.fixture.int("expect_bucket")))
    #expect(frame.prePadLength == (try c.fixture.int("expect_pre_pad_length")))
    // v1 frames are the Phase-1 plaintext frame: nonce and tag slots are zero.
    #expect(frame.nonce.allSatisfy { $0 == 0 } && frame.tag.allSatisfy { $0 == 0 })
  }

  @Test("the gzip payload opens (capped) to the manifest's plaintext", arguments: all)
  func payloadOpens(_ c: Case) throws {
    let frame = try FrameV1(try Fixtures.data("\(c.dir)/\(c.file)"))
    let plaintext = try Gzip.decompress(frame.gzip, maxOutputBytes: Self.maxPlaintext)
    #expect(plaintext == (try c.fixture.base64("expect_plaintext_base64")))
    // The cap is exact against real frames too.
    #expect(throws: GzipError.overCap(plaintext.count - 1)) {
      try Gzip.decompress(frame.gzip, maxOutputBytes: plaintext.count - 1)
    }
  }

  @Test("our gzip of each plaintext opens back to it", arguments: all)
  func ourGzipRoundTrips(_ c: Case) throws {
    let plaintext = try c.fixture.base64("expect_plaintext_base64")
    let ours = try Gzip.compress(plaintext)
    #expect(try Gzip.decompress(ours, maxOutputBytes: Self.maxPlaintext) == plaintext)
  }

  @Test("measured: Apple's zlib writes the TypeScript fixtures' DEFLATE stream; only the OS byte differs",
    arguments: cases("ts"))
  func zlibMatchesTypeScript(_ c: Case) throws {
    let theirs = try FrameV1(try Fixtures.data("\(c.dir)/\(c.file)")).gzip
    let ours = try Gzip.compress(try c.fixture.base64("expect_plaintext_base64"))
    #expect(ours.count == theirs.count)
    #expect(ours.prefix(9) == theirs.prefix(9))  // magic, method, flags, mtime 0, XFL 2
    #expect(theirs[9] == 3)  // OS = Unix (the Linux zlib that sealed them)
    #expect(ours.dropFirst(10) == theirs.dropFirst(10))  // DEFLATE stream and trailer
  }

  // conformance/ts plaintexts were written by JSON.stringify, so the canonical
  // writer reproduces them byte for byte, the escapes fixture (U+2028, U+2029,
  // `<`, `>`, `&` written literally) included.
  @Test("TypeScript plaintexts re-encode byte for byte", arguments: jsonCases("ts"))
  func typeScriptPlaintextsAreCanonical(_ c: Case) throws {
    let plaintext = [UInt8](try c.fixture.base64("expect_plaintext_base64"))
    let value = try JSONParser.parse(plaintext)
    #expect(JSONWriter().bytes(value) == plaintext)
    #expect(JSONWriter(numbers: .literal, keyOrder: .insertion).bytes(value) == plaintext)
  }

  // conformance/blob plaintexts were written by Go's encoding/json, which
  // escapes `<`, `>`, `&`, U+2028 and U+2029 where JSON.stringify does not. The
  // writer reproduces every Go body without those characters byte for byte,
  // and the escapes body value for value, with the characters literal.
  @Test("Go plaintexts re-encode byte for byte, except Go's HTML escapes", arguments: jsonCases("blob"))
  func goPlaintexts(_ c: Case) throws {
    let plaintext = [UInt8](try c.fixture.base64("expect_plaintext_base64"))
    let value = try JSONParser.parse(plaintext)
    let ours = JSONWriter().bytes(value)
    let goEscapes = ["\\u003c", "\\u003e", "\\u0026", "\\u2028", "\\u2029"]
    let text = String(decoding: plaintext, as: UTF8.self)
    if goEscapes.contains(where: { text.contains($0) }) {
      #expect(ours != plaintext)
      #expect(try JSONParser.parse(ours) == value)
      let oursText = String(decoding: ours, as: UTF8.self)
      #expect(!goEscapes.contains(where: { oursText.contains($0) }))
    } else {
      #expect(ours == plaintext)
    }
  }

  @Test("the Go escapes fixture is the one that exercises the difference")
  func escapesFixtureExists() throws {
    let escapes = Self.cases("blob").filter { $0.file.contains("escapes") }
    #expect(escapes.count == 1)
    let text = String(decoding: try escapes[0].fixture.base64("expect_plaintext_base64"), as: UTF8.self)
    #expect(text.contains("\\u2028") && text.contains("\\u003c") && text.contains("\\u0026"))
  }
}
