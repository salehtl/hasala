// conformance/templates: the Go executor's literal output, which CoreTemplate must reproduce
// field by field (all ten `expect` fields, on every case, matched or not: a partial extraction
// and its reason are what the diagnostics store). Two families:
//
//   - synthetic-*.json (public): the classes real mail never exercises (malformed amounts,
//     every date layout edge, empty groups, fall-through, currency forms).
//   - corpus-*.json (private, HASALA_PRIVATE_FIXTURES): the operator's real bank mail, already
//     normalized, for the four shipping templates. "[real-corpus] ..." tests, disabled by name
//     without the variable; their failure messages name the case, never its content.
import CoreJSON
import CorePrimitives
import CoreResources
import Foundation
import Testing

@testable import CoreTemplate

struct TemplateFixtureFile: CustomTestStringConvertible, Sendable {
  let file: String
  let root: URL
  var testDescription: String { file }

  func load() throws -> JSONValue {
    try JSONParser.parse([UInt8](try Data(contentsOf: root.appendingPathComponent(file))))
  }
}

enum TemplateFixtures {
  static var publicDir: URL { Fixtures.conformanceRoot.appendingPathComponent("templates") }
  static var privateDir: URL? { Fixtures.privateConformanceRoot?.appendingPathComponent("templates") }

  static func files(_ dir: URL?, prefix: String) -> [TemplateFixtureFile] {
    guard let dir, let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
    return names.filter { $0.hasPrefix(prefix) && $0.hasSuffix(".json") }.sorted().map {
      TemplateFixtureFile(file: $0, root: dir)
    }
  }

  static func synthetic() -> [TemplateFixtureFile] { files(publicDir, prefix: "synthetic-") }
  static func corpus() -> [TemplateFixtureFile] { files(privateDir, prefix: "corpus-") }

  /// Runs every case of one fixture file; returns (cases, matched, failures).
  static func run(_ f: TemplateFixtureFile) throws -> (Int, Int, [String]) {
    let doc = try f.load()
    let def = try TemplateDefinition(json: try #require(doc["definition"]))
    let compiled = try CompiledTemplate(def)
    var failures: [String] = []
    var matched = 0
    let cases = try doc.array("cases")
    for c in cases {
      let name = try c.string("name")
      let subject = String(decoding: try c.base64("subject_base64"), as: UTF8.self)
      let body = String(decoding: try c.base64("normalized_body_base64"), as: UTF8.self)
      let e = try #require(c["expect"])
      let got = try compiled.execute(subject: subject, normalizedBody: body)
      if got.matched { matched += 1 }
      var diffs: [String] = []
      func check(_ field: String, _ ok: Bool) { if !ok { diffs.append(field) } }
      check("matched", got.matched == (e["matched"]?.boolValue == true))
      check("error", got.error.rawValue == (try e.string("error")))
      check("amount_minor", String(got.amountMinor) == (try e.string("amount_minor")))
      check("currency", same(got.currency, try e.string("currency")))
      check("direction", same(got.direction, try e.string("direction")))
      check("posted_at", same(got.postedAt, try e.string("posted_at")))
      check("merchant", Array(got.merchant.utf8) == Array((try e.string("merchant")).utf8))
      check("last4", same(got.last4, try e.string("last4")))
      check("is_transfer", got.isTransfer == (e["is_transfer"]?.boolValue == true))
      check("empty_groups", got.emptyGroups == DialectFixture.strings(e["empty_groups"]))
      if !diffs.isEmpty { failures.append("\(name): \(diffs.joined(separator: ", "))") }
    }
    return (cases.count, matched, failures)
  }
}

@Suite("conformance/templates")
struct TemplateFixtureTests {
  @Test("only synthetic fixtures are committed here; the real ones are private")
  func publicTreeIsSynthetic() throws {
    let names = try FileManager.default.contentsOfDirectory(atPath: TemplateFixtures.publicDir.path)
      .filter { $0.hasSuffix(".json") }
    #expect(names.count > 5)
    #expect(names.allSatisfy { $0.hasPrefix("synthetic-") })
    for f in TemplateFixtures.synthetic() {
      #expect(try f.load()["kind"]?.stringValue == "synthetic", "\(f.file)")
    }
  }

  @Test("every fixture definition passes the dialect check")
  func definitionsPassDialect() throws {
    for f in TemplateFixtures.synthetic() + TemplateFixtures.corpus() {
      let def = try TemplateDefinition(json: try #require(try f.load()["definition"]))
      for (i, x) in def.extract.enumerated() {
        for (j, p) in x.patterns.enumerated() {
          #expect(Dialect.validatePattern(p, flags: x.flags) == [], "\(f.file) extract[\(i)].patterns[\(j)]")
        }
      }
    }
  }

  @Test("template conformance (synthetic)", arguments: TemplateFixtures.synthetic())
  func synthetic(_ f: TemplateFixtureFile) throws {
    let (n, _, failures) = try TemplateFixtures.run(f)
    #expect(n > 0)
    #expect(failures.isEmpty, "\(failures.prefix(20).joined(separator: "\n"))")
  }

  @Test(
    "[real-corpus] template conformance on the operator's real mail",
    .enabled(if: Fixtures.hasPrivate, "HASALA_PRIVATE_FIXTURES is unset"))
  func corpus() throws {
    let files = TemplateFixtures.corpus()
    #expect(files.count == BundledTemplates.load().templates.filter { !$0.definition.isSMS }.count)
    var total = 0
    var matched = 0
    for f in files {
      #expect(try f.load()["kind"]?.stringValue == "corpus", "\(f.file)")
      let (n, m, failures) = try TemplateFixtures.run(f)
      total += n
      matched += m
      #expect(failures.isEmpty, "\(f.file): \(failures.count) failing cases, e.g. \(failures.prefix(10).joined(separator: "; "))")
    }
    #expect(total > 1000)
    #expect(matched > 100)  // a set that matched nothing would agree perfectly and prove nothing
  }
}
