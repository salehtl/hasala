// conformance/normalizer: the Go normalizer's literal output, which CoreNorm must reproduce
// byte for byte (spec 04 §2.2 CoreNorm, §19.1 T1). Two families:
//
//   - edge-cases.json (public, synthetic): the input classes real mail never exercises
//     (quoted-printable leniency, malformed base64, unknown charsets and encodings, broken
//     MIME trees, header recovery, forward dates).
//   - <name>.json (private, real mail, via HASALA_PRIVATE_FIXTURES): the operator's own bank
//     mail, including windows-1256 and Arabic DIB alerts and Apple/Gmail forwards. Those tests
//     are named "[real-corpus] ..." and are disabled, by name, without the variable.
//
// Expectations are compared as BYTES (`Array(s.utf8)`), never as `String`, which would hide
// NFC/NFD differences. Failure messages name the case and the field and the first differing
// byte offset only; they never print fixture content (the private files hold real mail).
import CoreJSON
import CoreNorm
import CorePrimitives
import CoreTime
import Foundation
import Testing

struct NormalizerCase: CustomTestStringConvertible, Sendable {
  let name: String
  let version: Int
  let receivedAt: String
  let raw: [UInt8]
  let expectError: String
  let text: [UInt8]
  let part: String
  let charset: String
  let subject: [UInt8]
  let from: [UInt8]
  let forwarded: Bool
  let emailDate: String
  let dateSource: String

  var testDescription: String { name }

  init(_ c: JSONValue, version: Int, receivedAt: String) throws {
    name = try c.string("name")
    self.version = version
    self.receivedAt = receivedAt
    raw = [UInt8](try c.base64("raw_base64"))
    expectError = c["expect_error"]?.stringValue ?? ""
    text = [UInt8](try c.base64("expect_text_base64"))
    part = try c.string("expect_part")
    charset = try c.string("expect_charset")
    subject = [UInt8](try c.base64("expect_subject_base64"))
    from = [UInt8](try c.base64("expect_from_base64"))
    forwarded = c["expect_forwarded"]?.boolValue == true
    emailDate = try c.string("expect_email_date")
    dateSource = try c.string("expect_date_source")
  }

  /// Runs the case; returns the mismatching fields (empty when the case passes).
  func mismatches() throws -> [String] {
    let receivedMs = try Instant.parseMs(receivedAt)
    let got: NormalizeResult
    do throws(NormalizeError) {
      got = try Normalizer.normalize(version: version, raw: raw, receivedAtMs: receivedMs)
    } catch .noTextPart {
      return expectError == "no_text_part" ? [] : ["threw no_text_part, expected a result"]
    } catch {
      return ["threw \(error)"]
    }
    if !expectError.isEmpty { return ["expected error \(expectError), got a result"] }
    var out: [String] = []
    func bytes(_ field: String, _ g: String, _ w: [UInt8]) {
      let gb = Array(g.utf8)
      guard gb != w else { return }
      let i = (0..<min(gb.count, w.count)).first { gb[$0] != w[$0] } ?? min(gb.count, w.count)
      out.append("\(field): first byte difference at \(i) (got \(gb.count) bytes, want \(w.count))")
    }
    bytes("text", got.text, text)
    bytes("subject", got.subject, subject)
    bytes("from", got.from, from)
    if got.partUsed.rawValue != part { out.append("part: got \(got.partUsed.rawValue), want \(part)") }
    if !got.charset.utf8.elementsEqual(charset.utf8) { out.append("charset differs") }
    if got.forwarded != forwarded { out.append("forwarded: got \(got.forwarded)") }
    if got.dateSource.rawValue != dateSource { out.append("date_source: got \(got.dateSource.rawValue)") }
    if got.emailDate != emailDate { out.append("email_date differs") }
    return out
  }
}

enum NormalizerFixtures {
  static let edgeDoc = Result { try Fixtures.json("normalizer/edge-cases.json") }

  static func edgeCases() -> [NormalizerCase] {
    guard let doc = try? edgeDoc.get(), let cases = doc["cases"]?.arrayValue,
      let version = try? doc.int("normalizer_version"), let received = try? doc.string("received_at")
    else { return [] }
    return cases.compactMap { try? NormalizerCase($0, version: version, receivedAt: received) }
  }

  static var privateDir: URL? { Fixtures.privateConformanceRoot?.appendingPathComponent("normalizer") }

  /// The real-mail case files present in the private checkout, sorted.
  static func corpusFiles() -> [String] {
    guard let dir = privateDir,
      let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
    else { return [] }
    return names.filter { $0.hasSuffix(".json") && $0 != "manifest.json" && $0 != "edge-cases.json" }.sorted()
  }

  static func corpusCase(_ file: String) throws -> NormalizerCase {
    let dir = try #require(privateDir)
    let c = try JSONParser.parse([UInt8](try Data(contentsOf: dir.appendingPathComponent(file))))
    return try NormalizerCase(c, version: try c.int("normalizer_version"), receivedAt: try c.string("received_at"))
  }
}

@Suite("conformance/normalizer")
struct NormalizerFixtureTests {
  @Test("no real-mail case is committed beside the synthetic family")
  func publicTreeIsSynthetic() throws {
    let names = try FileManager.default.contentsOfDirectory(
      atPath: Fixtures.conformanceRoot.appendingPathComponent("normalizer").path)
    #expect(names.filter { $0.hasSuffix(".json") }.sorted() == ["edge-cases.json"])
  }

  @Test("every input class the corpus lacks is covered, and the mutation guards are present")
  func edgeClasses() throws {
    let doc = try NormalizerFixtures.edgeDoc.get()
    let cases = try doc.array("cases")
    #expect(cases.count >= 100)
    let classes = Set(cases.compactMap { $0["class"]?.stringValue })
    for required in ["quoted-printable", "base64", "transfer-encoding", "charset", "structure", "headers", "stages", "forward"] {
      #expect(classes.contains(required), "\(required)")
    }
    #expect(cases.contains { $0["expect_part"]?.stringValue == "raw" })
    #expect(cases.contains { $0["expect_error"]?.stringValue == "no_text_part" })
    let names = Set(cases.compactMap { $0["name"]?.stringValue })
    for guardName in [
      "fwd-date-zone-token-is-stripped", "fwd-date-iso8601-is-not-a-layout",
      "fwd-date-no-at-keyword-is-not-a-layout", "html-block-tag-pass-precedes-generic-rule",
    ] {
      #expect(names.contains(guardName), "\(guardName)")
    }
    #expect(NormalizerFixtures.edgeCases().count == cases.count, "a case failed to load")
  }

  @Test("the text cases are what Go's NormalizeText produced, byte for byte")
  func textCases() throws {
    let doc = try NormalizerFixtures.edgeDoc.get()
    let cases = try doc.array("text_cases")
    #expect(cases.count >= 10)
    for c in cases {
      let name = try c.string("name")
      let text = String(decoding: try c.base64("text_base64"), as: UTF8.self)
      let want = [UInt8](try c.base64("expect_text_base64"))
      let got = try Normalizer.normalizeText(version: try doc.int("normalizer_version"), text: text)
      #expect(Array(got.utf8) == want, "\(name)")
    }
    #expect(throws: NormalizeError.unknownVersion(2)) { try Normalizer.normalizeText(version: 2, text: "x") }
  }

  @Test("normalizer edge case", arguments: NormalizerFixtures.edgeCases())
  func edgeCase(_ c: NormalizerCase) throws {
    let m = try c.mismatches()
    #expect(m.isEmpty, "\(c.name): \(m.joined(separator: "; "))")
  }

  @Test(
    "[real-corpus] the corpus case files are exactly the ones manifest.json lists",
    .enabled(if: Fixtures.hasPrivate, "HASALA_PRIVATE_FIXTURES is unset"))
  func corpusManifest() throws {
    let dir = try #require(NormalizerFixtures.privateDir)
    let manifest = try JSONParser.parse([UInt8](try Data(contentsOf: dir.appendingPathComponent("manifest.json"))))
    let listed = try manifest.array("cases").map { try $0.string("file") }.sorted()
    let files = NormalizerFixtures.corpusFiles()
    #expect(files.count >= 30)
    #expect(files == listed)
  }

  @Test(
    "[real-corpus] normalizer conformance on the operator's real mail",
    .enabled(if: Fixtures.hasPrivate, "HASALA_PRIVATE_FIXTURES is unset"))
  func corpus() throws {
    let files = NormalizerFixtures.corpusFiles()
    #expect(!files.isEmpty)
    for f in files {
      let c = try NormalizerFixtures.corpusCase(f)
      let m = try c.mismatches()
      #expect(m.isEmpty, "\(f): \(m.joined(separator: "; "))")
    }
  }

  @Test("an unknown version is an error, and the version list is [1]")
  func versions() {
    #expect(Normalizer.versions() == [1])
    #expect(Normalizer.currentVersion == 1)
    #expect(throws: NormalizeError.unknownVersion(2)) { try Normalizer.normalize(version: 2, raw: [], receivedAtMs: 0) }
    #expect(throws: NormalizeError.unknownVersion(0)) { try Normalizer.normalize(version: 0, raw: [], receivedAtMs: 0) }
  }
}
