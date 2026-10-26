import CoreJSON
import CoreNorm
import CorePrimitives
import Foundation
import Testing

@testable import CoreTemplate

enum SMSCorpus {
  static let families = ["purchase", "debit", "credit", "salary", "refund", "reversal", "own-transfer", "card-payment", "other"]
  static var dir: URL? { Fixtures.privateConformanceRoot?.appendingPathComponent("sms") }
}

@Suite("conformance/sms")
struct SMSCorpusTests {
  @Test(
    "[real-corpus] the DIB texts normalize and read exactly as Go's executor read them",
    .enabled(if: Fixtures.hasPrivate, "HASALA_PRIVATE_FIXTURES is unset"))
  func corpus() throws {
    let dir = try #require(SMSCorpus.dir)
    let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".json") }.sorted()
    #expect(names == SMSCorpus.families.map { "dib-\($0).json" }.sorted())
    let texts = BundledTemplates.load().templates.filter(\.definition.isSMS)
    #expect(texts.count == SMSCorpus.families.count - 1)
    var total = 0
    var matched = 0
    var failures: [String] = []
    for family in SMSCorpus.families {
      let doc = try JSONParser.parse([UInt8](try Data(contentsOf: dir.appendingPathComponent("dib-\(family).json"))))
      #expect(doc["family"]?.stringValue == family)
      #expect(doc["kind"]?.stringValue == "corpus")
      let version = try doc.int("normalizer_version")
      for c in try doc.array("cases") {
        total += 1
        let name = try c.string("name")
        let sender = try c.string("sender")
        let text = String(decoding: try c.base64("text_base64"), as: UTF8.self)
        let normalized = try Normalizer.normalizeText(version: version, text: text)
        guard Array(normalized.utf8) == [UInt8](try c.base64("normalized_base64")) else {
          failures.append("\(name): normalized text")
          continue
        }
        var template = ""
        var expect = Extraction.zero(.noMatch)
        var gated: [String] = []
        for t in texts where t.definition.matchesSMSSender(sender) {
          let x = try t.execute(subject: "", normalizedBody: normalized)
          if x.matched {
            if template.isEmpty {
              template = t.definition.id
              expect = x
            }
          } else if x.error == .missingField {
            gated.append(t.definition.id)
          }
        }
        if !template.isEmpty { matched += 1 }
        let e = try #require(c["expect"])
        var diffs: [String] = []
        func check(_ field: String, _ ok: Bool) { if !ok { diffs.append(field) } }
        check("template", template == (try c.string("template")))
        check("gated", gated == DialectFixture.strings(c["gated"]))
        check("matched", expect.matched == (e["matched"]?.boolValue == true))
        check("error", expect.error.rawValue == (try e.string("error")))
        check("amount_minor", String(expect.amountMinor) == (try e.string("amount_minor")))
        check("currency", same(expect.currency, try e.string("currency")))
        check("direction", same(expect.direction, try e.string("direction")))
        check("posted_at", same(expect.postedAt, try e.string("posted_at")))
        check("merchant", Array(expect.merchant.utf8) == Array((try e.string("merchant")).utf8))
        check("last4", same(expect.last4, try e.string("last4")))
        check("is_transfer", expect.isTransfer == (e["is_transfer"]?.boolValue == true))
        check("empty_groups", expect.emptyGroups == DialectFixture.strings(e["empty_groups"]))
        if !diffs.isEmpty { failures.append("\(name): \(diffs.joined(separator: ", "))") }
      }
    }
    #expect(failures.isEmpty, "\(failures.count) failing cases, e.g. \(failures.prefix(10).joined(separator: "; "))")
    #expect(total > 4000)
    #expect(matched > 4000)
  }
}
