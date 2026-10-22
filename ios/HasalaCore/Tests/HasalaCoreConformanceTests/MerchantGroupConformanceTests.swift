import CoreCategorize
import CoreJSON
import Foundation
import Testing

@Suite("conformance/merchant-group")
struct MerchantGroupConformanceTests {
  static let file = "merchant-group/vectors.json"

  static func groups() throws -> MerchantGroup { MerchantGroup(dictionary: try MerchantDictionary.bundled().get()) }

  @Test("vectors.json is what Swift computes (HASALA_UPDATE_GOLDEN=1 rewrites it)")
  func golden() throws {
    let doc = try Fixtures.json(Self.file)
    let groups = try Self.groups()
    let header = obj([
      ("bundle", .string(DictionaryManifest.bundle)), ("sha256", .string(DictionaryManifest.sha256)),
      ("entries", .number(JSONNumber(Int64(DictionaryManifest.entries)))),
    ])
    let cases = try Golden.mapping(doc["cases"]) { c in
      c.setting("expect", obj([("key", .string(groups.key(raw: try c.string("raw"))))]))
    }
    try Golden.check(Self.file, doc.setting("dictionary", header).setting("cases", cases))
  }

  @Test func theHeaderNamesTheBundledDictionary() throws {
    let doc = try Fixtures.json(Self.file)
    #expect(try doc.int("schema_version") == 1)
    let d = try #require(doc["dictionary"])
    #expect(try d.string("sha256") == DictionaryManifest.sha256)
    #expect(try d.string("bundle") == DictionaryManifest.bundle)
    #expect(try d.int("entries") == DictionaryManifest.entries)
    #expect(try Self.groups().bundle == DictionaryManifest.bundle)
  }

  @Test("the near-miss pairs, asserted by hand")
  func pairs() throws {
    let groups = try Self.groups()
    let pairs = try #require(try Fixtures.json(Self.file)["pairs"]?.arrayValue)
    #expect(pairs.count >= 12)
    for p in pairs {
      let a = groups.key(raw: try p.string("a"))
      let b = groups.key(raw: try p.string("b"))
      let same = try #require(p["same"]?.boolValue)
      let name = try p.string("name")
      #expect((a == b) == same, "\(name): \(a) vs \(b)")
    }
  }

  @Test func casesHaveUniqueNamesAndInputs() throws {
    let cases = try #require(try Fixtures.json(Self.file)["cases"]?.arrayValue)
    let names = try cases.map { try $0.string("name") }
    #expect(Set(names).count == names.count)
    let raws = try cases.map { try $0.string("raw") }
    #expect(Set(raws).count == raws.count)
  }
}
