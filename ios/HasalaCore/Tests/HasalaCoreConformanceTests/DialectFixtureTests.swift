// conformance/dialect/patterns.json (Go's literal output, internal/tmpl
// TestWriteDialectConformanceFixtures): the Swift validator must give the same reason codes in
// the same order as Go and TypeScript, and the ICU engine (through the translation layer) must
// match and capture exactly what Go's RE2 did on every accepted pattern and every hostile
// probe input (CR, U+2028, U+2029, NBSP, VT, BOM, the Kelvin sign, long s, Arabic). A generated
// 9,324-pattern corpus pins the validator as a FUNCTION, through a SHA-256 of its verdicts.
import CoreJSON
import CorePrimitives
import Foundation
import Testing

@testable import CoreTemplate

struct AcceptedPattern: CustomTestStringConvertible, Sendable {
  let name: String
  let pattern: String
  let jsPattern: String
  let flags: [String]
  let groupNames: [String]
  let probes: [JSONValue]
  var testDescription: String { name }
}

enum DialectFixture {
  static let doc = Result { try Fixtures.json("dialect/patterns.json") }

  static func strings(_ v: JSONValue?) -> [String] { v?.arrayValue?.compactMap(\.stringValue) ?? [] }

  static func accepted() -> [AcceptedPattern] {
    guard let rows = try? doc.get().array("accepted") else { return [] }
    return rows.compactMap { r in
      guard let name = r["name"]?.stringValue, let p = r["pattern"]?.stringValue, let js = r["js_pattern"]?.stringValue
      else { return nil }
      return AcceptedPattern(
        name: name, pattern: p, jsPattern: js, flags: strings(r["flags"]), groupNames: strings(r["group_names"]),
        probes: r["probes"]?.arrayValue ?? [])
    }
  }

  static let inputs: [String: [UInt16]] = {
    var out: [String: [UInt16]] = [:]
    for p in (try? doc.get().array("probe_inputs")) ?? [] {
      if let n = p["name"]?.stringValue, let b = try? p.base64("input_base64") {
        out[n] = Array(String(decoding: b, as: UTF8.self).utf16)
      }
    }
    return out
  }()

  /// A transliteration of `dialectCorpus()` (internal/tmpl/conformance_test.go and
  /// tmpl/dialect.test.ts), edit for edit: the digest is over the SEQUENCE.
  static func corpus() -> [String] {
    let atoms = ["a", "[a-z]", "[^\\n]", "\\n", "م"]
    let quants = ["", "?", "*", "+", "{2}", "{1,4}", "{0,2}", "{2,}", "{1,32}"]
    var units: [String] = []
    for a in atoms { for q in quants { units.append(a + q) } }
    var inner = units
    for u in units.prefix(12) {
      for v in units.prefix(12) {
        inner.append(u + v)
        inner.append(u + "|" + v)
      }
    }
    var pats: [String] = []
    for i in inner {
      pats.append(i)
      for q in quants {
        pats.append("(?:" + i + ")" + q)
        pats.append("(?:(?:" + i + ")" + q + "){2}")
        pats.append("x(?:" + i + ")" + q + "y")
      }
    }
    return pats
  }
}

@Suite("conformance/dialect")
struct DialectFixtureTests {
  @Test("the Swift limits are Go's limits")
  func limits() throws {
    let l = try #require(try DialectFixture.doc.get()["limits"])
    #expect(try l.int("max_pattern_runes") == Dialect.maxPatternRunes)
    #expect(try l.int("max_capture_groups") == Dialect.maxCaptureGroups)
    #expect(try l.int("max_bound_product") == Dialect.maxBoundProduct)
    #expect(try l.int("max_unbounded_per_branch") == Dialect.maxUnboundedPerBranch)
    #expect(try l.int("max_repetition_width") == Dialect.maxRepetitionWidth)
  }

  @Test("rejected patterns: Go's reason codes, in Go's order")
  func rejected() throws {
    let rows = try DialectFixture.doc.get().array("rejected")
    #expect(rows.count > 25)
    for r in rows {
      let pattern = try r.string("pattern")
      let code = try r.string("code")
      let js = try r.string("js_pattern")
      let want = DialectFixture.strings(r["codes"])
      let got = Dialect.validatePattern(pattern, flags: DialectFixture.strings(r["flags"]))
      #expect(got == want, "\(code): \(pattern.debugDescription)")
      #expect(got.contains(code))
      #expect(Dialect.toJS(pattern) == js)
    }
  }

  @Test("accepted patterns pass, compile, and name Go's groups", arguments: DialectFixture.accepted())
  func accepted(_ c: AcceptedPattern) throws {
    #expect(Dialect.validatePattern(c.pattern, flags: c.flags) == [])
    #expect(Dialect.groupNames(c.pattern) == c.groupNames)
    #expect(Dialect.toJS(c.pattern) == c.jsPattern)
  }

  /// The engine claim: ICU, through the translation, reproduces RE2's match, full match text
  /// and every named group (absent vs. empty kept apart) on every probe.
  @Test("engine agreement on every probe", arguments: DialectFixture.accepted())
  func engine(_ c: AcceptedPattern) throws {
    let re = try ICUPattern.compile(c.pattern, caseInsensitive: c.flags.contains("i"))
    #expect(re.groups.compactMap { $0 } == c.groupNames)
    #expect(!c.probes.isEmpty)
    for p in c.probes {
      let inputName = try p.string("input")
      let input = try #require(DialectFixture.inputs[inputName], "probe input \(inputName)")
      let m = try re.firstMatch(in: input)
      let wantMatch = p["match"]?.boolValue == true
      #expect((m != nil) == wantMatch, "\(c.name) / \(inputName): Go matched=\(wantMatch)")
      guard let m, wantMatch else { continue }
      let text = String(decoding: input[m.range], as: UTF16.self)
      let wantText = [UInt8](try p.base64("text"))
      #expect(Array(text.utf8) == wantText, "\(c.name) / \(inputName): full match")
      for member in p["groups"]?.objectValue?.members ?? [] {
        let k = try #require(re.groups.firstIndex { $0 == member.key }, "group \(member.key)")
        let got = m.groups[k].map { String(decoding: input[$0], as: UTF16.self) }
        if member.value.isNull {
          #expect(got == nil, "\(c.name) / \(inputName): group \(member.key) participated here but not in Go")
        } else {
          let want = [UInt8](try Base64.decode(try #require(member.value.stringValue)))
          #expect(got.map { Array($0.utf8) } == want, "\(c.name) / \(inputName): group \(member.key)")
        }
      }
    }
  }

  @Test("toJS reproduces Go's ToJS")
  func toJS() throws {
    for r in try DialectFixture.doc.get().array("to_js") {
      let (p, js) = (try r.string("pattern"), try r.string("js"))
      #expect(Dialect.toJS(p) == js)
    }
  }

  @Test("the validators agree on every pattern of the generated corpus (SHA-256 and checkpoints)")
  func corpus() throws {
    let spec = try #require(try DialectFixture.doc.get()["corpus"])
    let pats = DialectFixture.corpus()
    let size = try spec.int("size")
    let digest = try spec.string("sha256")
    #expect(pats.count == size)
    var checkpoints: [Int: JSONValue] = [:]
    for c in try spec.array("checkpoints") { checkpoints[try c.int("index")] = c }
    var digestInput: [UInt8] = []
    for (i, p) in pats.enumerated() {
      let codes = Dialect.validatePattern(p, flags: []).joined(separator: ",")
      digestInput.append(contentsOf: Array(p.utf8) + [0] + Array(codes.utf8) + [0x0a])
      if let c = checkpoints[i] {
        let want = try c.string("pattern")
        #expect(p == want, "checkpoint \(i): the generator drifted from Go's")
        #expect(codes == DialectFixture.strings(c["codes"]).joined(separator: ","), "checkpoint \(i): \(p)")
      }
    }
    #expect(Hex.encode(sha256(digestInput)) == digest)
  }

  @Test("the canonical definition bytes are Go's", arguments: ["canonical", "canonical_sms"])
  func canonical(_ key: String) throws {
    let c = try #require(try DialectFixture.doc.get()[key])
    let def = try TemplateDefinition(json: [UInt8](try c.base64("definition_base64")))
    let want = [UInt8](try c.base64("canonical_base64"))
    #expect(def.canonicalJSON() == want)
  }
}
