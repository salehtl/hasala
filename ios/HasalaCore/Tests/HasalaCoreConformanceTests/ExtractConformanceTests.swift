import CoreExtract
import CoreJSON
import Foundation
import Testing

@Suite("conformance/extract")
struct ExtractConformanceTests {
  static func input(_ m: JSONValue) throws -> ExtractInput {
    ExtractInput(
      sender: try m.string("sender"), subject: try m.string("subject"), text: try m.string("text"),
      receivedAtMs: Int64(try m.int("received_at_ms")), listUnsubscribe: try #require(m["list_unsubscribe"]?.boolValue))
  }

  static func text(_ s: String?) -> JSONValue { s.map { .string($0) } ?? .null }

  static func expect(_ r: ExtractReading) -> JSONValue {
    obj([
      ("outcome", .string(r.outcome.rawValue)), ("kind", .string(r.kind.rawValue)),
      ("amount_minor", r.amountMinor.map { .number(JSONNumber($0)) } ?? .null), ("currency", text(r.currency)),
      ("direction", text(r.direction?.rawValue)), ("merchant", text(r.merchant)), ("last4", text(r.last4)),
      ("confidence_percent", .number(JSONNumber(Int64(r.confidencePercent)))), ("agreed", .bool(r.agreed)),
      ("meets_agreement_bar", .bool(r.meetsAgreementBar)),
      ("rules_confidence_percent", .number(JSONNumber(Int64(r.rulesConfidencePercent)))),
      ("learned_confidence_percent", .number(JSONNumber(Int64(r.learnedConfidencePercent)))),
      ("readers_agree", .bool(r.readersAgree)), ("meets_filing_bar", .bool(r.meetsFilingBar)),
    ])
  }

  @Test func theDocumentsConstantsAreThePorts() throws {
    let file = try Fixtures.json("extract/vectors.json")
    #expect(try file.int("schema_version") == 1)
    #expect(try file.int("agreement_bar_percent") == ExtractReading.agreementBarPercent)
    let limits = try #require(file["limits"])
    #expect(try limits.int("senders") == LearnedLayouts.senderLimit)
    #expect(try limits.int("layouts_per_sender") == LearnedLayouts.layoutLimitPerSender)
    #expect(try limits.int("examples_per_layout") == LearnedLayouts.exampleLimitPerLayout)
    #expect(try limits.int("tokens_per_mail") == LearnedLayouts.tokenLimitPerMail)
    #expect(try file.array("outcomes").compactMap(\.stringValue) == ExtractOutcome.allCases.map(\.rawValue))
    #expect(try file.array("kinds").compactMap(\.stringValue) == ExtractMailKind.allCases.map(\.rawValue))
  }

  @Test("vectors.json is what Swift computes (HASALA_UPDATE_GOLDEN=1 rewrites it)")
  func golden() throws {
    let file = try Fixtures.json("extract/vectors.json")
    let streams = try Golden.mapping(file["streams"]) { s in
      var memory = LearnedLayouts()
      var out: [JSONValue] = []
      for m in s["mails"]?.arrayValue ?? [] {
        let (r, next) = CombinedReader.read(try Self.input(m), memory)
        memory = next
        out.append(Self.expect(r))
      }
      return s.setting("expect", .array(out))
    }
    try Golden.check("extract/vectors.json", file.setting("streams", streams))
  }
}
