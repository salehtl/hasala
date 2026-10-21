// conformance/authres: every vector the ledgerd TypeScript oracle (src/mail/authres.ts) wrote,
// Gmail and Outlook.com, reproduced by `AuthResults` as the README says. The
// file is read in place from the repository (never bundled); HASALA_CONFORMANCE_DIR overrides.
import CoreJSON
import Foundation
import Testing

@testable import CoreMail

private struct Doc: Decodable {
  struct Part: Decodable {
    let text: String
    let repeatCount: Int
    enum CodingKeys: String, CodingKey {
      case text
      case repeatCount = "repeat"
    }
  }
  struct Expect: Decodable {
    let trusted: Bool
    let reason: String
    let domain: String?
  }
  struct Vector: Decodable {
    let name: String
    let group: String
    let provider: String?
    let headers: String?
    let headersParts: [Part]?
    let expect: Expect
    enum CodingKeys: String, CodingKey {
      case name, group, provider, headers, expect
      case headersParts = "headers_parts"
    }
  }
  struct Limits: Decodable {
    let maxRawUTF16Units: Int
    let maxContinuationLines: Int
    enum CodingKeys: String, CodingKey {
      case maxRawUTF16Units = "max_raw_utf16_units"
      case maxContinuationLines = "max_continuation_lines"
    }
  }
  let schemaVersion: Int
  let authservID: String
  let limits: Limits
  let providers: [String]
  let reasons: [String]
  let vectors: [Vector]
  enum CodingKeys: String, CodingKey {
    case limits, providers, reasons, vectors
    case schemaVersion = "schema_version"
    case authservID = "authserv_id"
  }
}

private let doc: Doc = {
  var root: URL
  if let dir = ProcessInfo.processInfo.environment["HASALA_CONFORMANCE_DIR"], !dir.isEmpty {
    root = URL(fileURLWithPath: dir, isDirectory: true)
  } else {
    root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while root.path != "/", !FileManager.default.fileExists(atPath: root.appendingPathComponent("conformance/authres").path) {
      root.deleteLastPathComponent()
    }
    root.appendPathComponent("conformance", isDirectory: true)
  }
  let data = try! Data(contentsOf: root.appendingPathComponent("authres/vectors.json"))
  return try! JSONDecoder().decode(Doc.self, from: data)
}()

@Suite("conformance/authres")
struct AuthResultsConformanceTests {
  @Test("the document's constants are the port's")
  func constants() {
    #expect(doc.schemaVersion == 2)
    #expect(doc.authservID == AuthResults.gmailAuthservID)
    #expect(doc.limits.maxRawUTF16Units == AuthResults.maxRawUnits)
    #expect(doc.limits.maxContinuationLines == AuthResults.maxFieldLines)
    #expect(doc.providers == AuthResults.Provider.allCases.map(\.rawValue))
    #expect(
      doc.reasons
        == [
          AuthResults.Reason.pass, .noAR, .multipleAR, .notTopmost, .fail, .parseError, .noEOP, .notInbox, .unknownSender,
          .noDMARCReject,
        ].map(\.rawValue))
    #expect(doc.vectors.filter { $0.provider == "outlook" }.count > 40)
  }

  @Test("vectors.json is what Swift computes (HASALA_UPDATE_GOLDEN=1 rewrites it)")
  func golden() throws {
    let file = try Fixtures.json("authres/vectors.json")
    let vectors = try Golden.mapping(file["vectors"]) { v in
      let parts = try (v["headers_parts"]?.arrayValue ?? []).map { String(repeating: try $0.string("text"), count: try $0.int("repeat")) }
      let raw = v["headers"]?.stringValue ?? parts.joined()
      let provider = try #require(AuthResults.Provider(rawValue: v["provider"]?.stringValue ?? "gmail"))
      let a = AuthResults.analyze(raw, provider: provider)
      return v.setting(
        "expect",
        obj([
          ("trusted", .bool(a.verdict.trusted)), ("reason", .string(a.verdict.reason.rawValue)),
          ("domain", a.domain.map { .string($0) } ?? .null),
        ]))
    }
    try Golden.check("authres/vectors.json", file.setting("vectors", vectors))
  }

  @Test("every vector", arguments: doc.vectors.map(\.name))
  func vector(_ name: String) throws {
    let v = try #require(doc.vectors.first { $0.name == name })
    let raw = v.headers ?? (v.headersParts ?? []).map { String(repeating: $0.text, count: $0.repeatCount) }.joined()
    let provider = try #require(AuthResults.Provider(rawValue: v.provider ?? "gmail"))
    let a = AuthResults.analyze(raw, provider: provider)
    #expect(a.verdict.trusted == v.expect.trusted)
    #expect(a.verdict.reason.rawValue == v.expect.reason)
    #expect(a.domain == v.expect.domain)
    // The public entry points agree with the one reading.
    switch provider {
    case .gmail:
      #expect(AuthResults.gmailVerdict(raw) == a.verdict)
      #expect(AuthResults.verifiedDomain(raw) == a.domain)
    case .outlook:
      #expect(AuthResults.outlookVerdict(raw) == a.verdict)
      #expect(AuthResults.verifiedDomain(raw, provider: .outlook) == a.domain)
    }
  }
}
