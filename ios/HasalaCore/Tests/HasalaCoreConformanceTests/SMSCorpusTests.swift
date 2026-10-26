import CoreJSON
import CoreNorm
import CorePrimitives
import Foundation
import Testing

@testable import CoreTemplate

enum SMSCorpus {
  static let other = "other"
  static let families = ["purchase", "debit", "credit", "salary", "refund", "reversal", "own-transfer", "card-payment", other]
  static var dir: URL? {
    Fixtures.privateConformanceRoot?.appendingPathComponent("templates").appendingPathComponent(TemplateFixtures.smsSubdir)
  }
  static func templateID(_ family: String) -> String { "dib.sms.\(family).v1" }
  static func fileName(_ family: String) -> String { family == other ? "dib-other.json" : "corpus-\(templateID(family)).json" }
}

@Suite("conformance/templates/sms")
struct SMSCorpusTests {
  @Test(
    "[real-corpus] the DIB texts normalize and read exactly as Go's executor read them",
    .enabled(if: Fixtures.hasPrivate, "HASALA_PRIVATE_FIXTURES is unset"))
  func corpus() throws {
    let dir = try #require(SMSCorpus.dir)
    #expect(TemplateFixtures.jsonNames(dir) == SMSCorpus.families.map(SMSCorpus.fileName).sorted())
    let texts = BundledTemplates.load().templates.filter(\.definition.isSMS)
    #expect(texts.count == SMSCorpus.families.count - 1)
    var total = 0
    var matched = 0
    var failures: [String] = []
    for family in SMSCorpus.families {
      let doc = try JSONParser.parse([UInt8](try Data(contentsOf: dir.appendingPathComponent(SMSCorpus.fileName(family)))))
      #expect(doc["family"]?.stringValue == family)
      #expect(doc["kind"]?.stringValue == "corpus")
      let own: CompiledTemplate?
      if family == SMSCorpus.other {
        #expect(doc["template"] == nil)
        own = nil
      } else {
        #expect(doc["template"]?.stringValue == SMSCorpus.templateID(family))
        own = try #require(texts.first { $0.definition.id == SMSCorpus.templateID(family) })
      }
      let version = try doc.int("normalizer_version")
      for c in try doc.array("cases") {
        total += 1
        let name = try c.string("name")
        let sender = try c.string("sender")
        let text = String(decoding: try c.base64("text_base64"), as: UTF8.self)
        let normalized = try Normalizer.normalizeText(version: version, text: text)
        guard Array(normalized.utf8) == [UInt8](try c.base64("normalized_body_base64")), try c.base64("subject_base64").isEmpty else {
          failures.append("\(name): normalized text")
          continue
        }
        var readBy = ""
        var first = Extraction.zero(.noMatch)
        var gated: [String] = []
        for t in texts where t.definition.matchesSMSSender(sender) {
          let x = try t.execute(subject: "", normalizedBody: normalized)
          if x.matched {
            if readBy.isEmpty {
              readBy = t.definition.id
              first = x
            }
          } else if x.error == .missingField {
            gated.append(t.definition.id)
          }
        }
        if !readBy.isEmpty { matched += 1 }
        let got = try own.map { try $0.execute(subject: "", normalizedBody: normalized) } ?? first
        var diffs = try TemplateFixtures.diffs(got, try #require(c["expect"]))
        if readBy != (try c.string("read_by")) { diffs.append("read_by") }
        if gated != DialectFixture.strings(c["gated"]) { diffs.append("gated") }
        if !diffs.isEmpty { failures.append("\(name): \(diffs.joined(separator: ", "))") }
      }
    }
    #expect(failures.isEmpty, "\(failures.count) failing cases, e.g. \(failures.prefix(10).joined(separator: "; "))")
    #expect(total > 4000)
    #expect(matched > 4000)
  }
}
