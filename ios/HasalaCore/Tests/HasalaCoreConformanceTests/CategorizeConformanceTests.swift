// conformance/categorize (the TypeScript v3 matcher oracle) and
// conformance/dict/matching.json (Go's canonicalization and match answers),
// read by the v4 matcher as the categorize README says: every rule is one
// enabled alternative, every category active, no direction gate. Cases that
// need a regex executor (`requires: ["regex"]`) are skipped: the v4 matcher has
// no regex (spec 04 §2.2).
import CoreCategorize
import CoreJSON
import CorePrimitives
import Foundation
import HasalaText
import Testing

@Suite("conformance/categorize")
struct CategorizeConformanceTests {
  @Test("canon.json: canonical, fold_case, rune_length and subject")
  func canon() throws {
    let doc = try Fixtures.json("categorize/canon.json")
    #expect(try doc.int("max_subject_runes") == Canon.maxSubjectRunes)
    let vectors = try doc.array("vectors")
    #expect(vectors.count > 20)
    for v in vectors {
      let input = try v.string("input")
      let e = v["expect"]!
      let name = try v.string("name")
      let (c, f, n, s) = (try e.string("canonical"), try e.string("fold_case"), try e.int("rune_length"), try e.string("subject"))
      #expect(utf8Equal(Canon.canonical(input), c), "\(name)")
      #expect(utf8Equal(Canon.foldCase(input), f), "\(name)")
      #expect(Canon.runeLength(input) == n, "\(name)")
      #expect(utf8Equal(Canon.subject(input), s), "\(name)")
    }
  }

  static func ruleInputs(_ list: [JSONValue]) throws -> [RuleInput] {
    try list.map { r in
      RuleInput(
        id: try r.string("id"), patterns: [try r.string("pattern")], match: try r.string("match"),
        category: try r.string("category"), priority: r["priority"]!.numberValue!.int64Value!)
    }
  }

  static func entries(_ list: [JSONValue]) throws -> [DictEntry] {
    try list.map { DictEntry(pattern: try $0.string("pattern"), match: try $0.string("match"), category: try $0.string("category")) }
  }

  static func prepared(_ list: [PreparedPattern]) -> [[String]] {
    list.map { [$0.id, $0.pattern, $0.match.rawValue, $0.category, String($0.priority)] }
  }

  static func expectedPrepared(_ list: [JSONValue]) throws -> [[String]] {
    try list.map {
      [try $0.string("id"), try $0.string("pattern"), try $0.string("match"), try $0.string("category"),
       String($0["priority"]!.numberValue!.int64Value!)]
    }
  }

  static func decision(_ merchant: String, _ p: PreparedRules) -> JSONValue {
    guard let hit = Matcher.firstHit(merchant, p) else {
      return .object(JSONObject([("category", .null), ("source", .string("none"))]))
    }
    var o: [(String, JSONValue)] = [("category", .string(hit.category)), ("source", .string(hit.source.rawValue))]
    if hit.source == .rule { o.append(("id", .string(hit.id))) }
    o += [("pattern", .string(hit.pattern)), ("match", .string(hit.match.rawValue))]
    return .object(JSONObject(o)).sortingKeysByUTF8()
  }

  @Test("order.json: survivors in match order, defects, decisions")
  func order() throws {
    let cases = try Fixtures.json("categorize/order.json").array("cases")
    var ran = 0
    for c in cases {
      if c["requires"] != nil { continue }
      ran += 1
      let name = try c.string("name")
      let p = Matcher.prepare(rules: try Self.ruleInputs(try c.array("rules")), entries: try Self.entries(try c.array("entries")))
      let e = c["expect"]!
      #expect(Self.prepared(p.rules) == (try Self.expectedPrepared(try e.array("rules"))), "\(name)")
      #expect(Self.prepared(p.entries) == (try Self.expectedPrepared(try e.array("entries"))), "\(name)")
      let defects = try (try e.array("defects")).map { [try $0.string("id"), try $0.string("code")] }
      #expect(p.defects.map { [$0.id, $0.code] } == defects, "\(name)")
      for d in try e.array("decisions") {
        let merchant = try d.string("merchant")
        let got = Self.decision(merchant, p)
        #expect(got == d["decision"]!.sortingKeysByUTF8(), "\(name): \(merchant)")
      }
    }
    #expect(ran >= 14)
  }

  @Test("dictionary.json: entry gates and lookups")
  func dictionary() throws {
    let doc = try Fixtures.json("categorize/dictionary.json")
    for v in try doc.array("entries") {
      let name = try v.string("name")
      let raw = v["entry"]!
      let got = Matcher.validateDictEntry(
        DictEntry(pattern: try raw.string("pattern"), match: try raw.string("match"), category: try raw.string("category")))
      let e = v["expect"]!
      if e["ok"]?.boolValue == true {
        let want = e["entry"]!
        guard case .entry(let x) = got else {
          Issue.record("\(name): refused \(got)")
          continue
        }
        let (wp, wm, wc) = (try want.string("pattern"), try want.string("match"), try want.string("category"))
        #expect(utf8Equal(x.pattern, wp) && x.match == wm && x.category == wc, "\(name)")
      } else {
        let want = e["defect"]!
        let d = Defect(id: try want.string("id"), code: try want.string("code"))
        #expect(got == .defect(d), "\(name)")
      }
    }
    let lookups = doc["lookups"]!
    let p = Matcher.prepare(rules: [], entries: try Self.entries(try lookups.array("dictionary")))
    let e = lookups["expect"]!
    #expect(Self.prepared(p.entries) == (try Self.expectedPrepared(try e.array("entries"))))
    let defects = try (try e.array("defects")).map { [try $0.string("id"), try $0.string("code")] }
    #expect(p.defects.map { [$0.id, $0.code] } == defects)
    for d in try e.array("decisions") {
      let merchant = try d.string("merchant")
      #expect(Self.decision(merchant, p) == d["decision"]!.sortingKeysByUTF8(), "\(merchant)")
    }
  }

  @Test("conformance/dict/matching.json: Go's space set, lower-casing and match answers")
  func goMatching() throws {
    let doc = try Fixtures.json("dict/matching.json")
    for v in try doc.array("space") {
      let cp = UInt32(try v.int("cp"))
      let name = try v.string("name")
      #expect(Canon.isGoSpace(Unicode.Scalar(cp)!) == v["is_space"]!.boolValue!, "\(name)")
    }
    for v in try doc.array("lower") {
      let input = String(decoding: try v.base64("input_base64"), as: UTF8.self)
      let want = String(decoding: try v.base64("lower_base64"), as: UTF8.self)
      let name = try v.string("name")
      #expect(utf8Equal(Canon.foldCase(input), want), "\(name)")
    }
    for v in try doc.array("match") {
      let pattern = String(decoding: try v.base64("pattern_base64"), as: UTF8.self)
      let subject = String(decoding: try v.base64("subject_base64"), as: UTF8.self)
      let kind = MatchKind(rawValue: try v.string("match"))!
      let p = Matcher.prepare(rules: [], entries: [DictEntry(pattern: pattern, match: kind.rawValue, category: "groceries")])
      guard let entry = p.entries.first else { continue }
      let name = try v.string("name")
      #expect(Matcher.hits(entry, merchantRaw: subject) == v["matched"]!.boolValue!, "\(name)")
    }
  }
}
