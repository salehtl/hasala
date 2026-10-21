import Foundation
import Testing

@testable import CoreMail

private struct SenderDoc: Decodable {
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
    let inInbox: Bool
    let headers: String?
    let headersParts: [Part]?
    let expect: Expect
    enum CodingKeys: String, CodingKey {
      case name, headers, expect
      case inInbox = "in_inbox"
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
  let knownSenders: [String]
  let rejectDomains: [String]
  let limits: Limits
  let reasons: [String]
  let vectors: [Vector]
  enum CodingKeys: String, CodingKey {
    case limits, reasons, vectors
    case schemaVersion = "schema_version"
    case knownSenders = "known_senders"
    case rejectDomains = "reject_domains"
  }
}

private let senderDoc: SenderDoc = {
  var root: URL
  if let dir = ProcessInfo.processInfo.environment["HASALA_CONFORMANCE_DIR"], !dir.isEmpty {
    root = URL(fileURLWithPath: dir, isDirectory: true)
  } else {
    root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while root.path != "/",
      !FileManager.default.fileExists(atPath: root.appendingPathComponent("conformance/outlook-sender").path)
    {
      root.deleteLastPathComponent()
    }
    root.appendPathComponent("conformance", isDirectory: true)
  }
  let data = try! Data(contentsOf: root.appendingPathComponent("outlook-sender/vectors.json"))
  return try! JSONDecoder().decode(SenderDoc.self, from: data)
}()

@Suite("conformance/outlook-sender")
struct OutlookSenderConformanceTests {
  @Test func theDocumentsConstantsAreThePorts() {
    #expect(senderDoc.schemaVersion == 1)
    #expect(senderDoc.limits.maxRawUTF16Units == AuthResults.maxRawUnits)
    #expect(senderDoc.limits.maxContinuationLines == AuthResults.maxFieldLines)
    #expect(
      senderDoc.reasons
        == [AuthResults.Reason.pass, .parseError, .notInbox, .unknownSender, .noDMARCReject].map(\.rawValue))
    #expect(Set(senderDoc.vectors.map(\.expect.reason)) == Set(senderDoc.reasons))
  }

  @Test("every vector", arguments: senderDoc.vectors.map(\.name))
  func vector(_ name: String) throws {
    let v = try #require(senderDoc.vectors.first { $0.name == name })
    let raw = v.headers ?? (v.headersParts ?? []).map { String(repeating: $0.text, count: $0.repeatCount) }.joined()
    let a = AuthResults.analyzeOutlookSender(
      raw, inInbox: v.inInbox, knownSenders: senderDoc.knownSenders, rejectDomains: senderDoc.rejectDomains)
    #expect(a.verdict.trusted == v.expect.trusted)
    #expect(a.verdict.reason.rawValue == v.expect.reason)
    #expect(a.domain == v.expect.domain)
  }
}
