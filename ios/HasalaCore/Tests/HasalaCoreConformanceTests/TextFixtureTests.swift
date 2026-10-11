// conformance/dict/matching.json (Go's own answers, internal/dict
// TestWriteDictConformanceFixtures): the HasalaText building blocks the
// categorization canon is made of, against Go's verdicts.
import CorePrimitives
import HasalaText
import Foundation
import Testing

@Suite("conformance/dict text building blocks")
struct TextFixtureTests {
  static let matching = Result { try Fixtures.json("dict/matching.json") }

  @Test("space: Go's unicode.IsSpace verdict for every probed scalar")
  func space() throws {
    let probes = try Self.matching.get().array("space")
    #expect(probes.count >= 19)
    for p in probes {
      let cp = UInt32(try p.int("cp"))
      let isSpace = p["is_space"]?.boolValue == true
      let name = try p.string("name")
      #expect(ScalarSet.goSpace.contains(cp) == isSpace, "\(name)")
    }
  }

  @Test("lower: Go's strings.ToLower, byte for byte")
  func lower() throws {
    let cases = try Self.matching.get().array("lower")
    #expect(cases.count >= 13)
    for c in cases {
      let input = UTF8Text.decode(try c.base64("input_base64"))
      let want = [UInt8](try c.base64("lower_base64"))
      let name = try c.string("name")
      #expect(Array(GoCase.lower(input).utf8) == want, "\(name)")
    }
  }

  // Go's canonical form is strings.ToLower(strings.Join(strings.Fields(s), " ")).
  // For every entry Go accepted, collapse-then-lower reproduces its bytes.
  // (Which entries Go refuses, and why, is the dictionary validator's contract
  // in CoreCategorize, not these building blocks'.)
  @Test("canonical: collapse then lower reproduces every accepted pattern")
  func canonical() throws {
    let cases = try Self.matching.get().array("canonical").filter { $0["ok"]?.boolValue == true }
    #expect(!cases.isEmpty)
    for c in cases {
      let pattern = UTF8Text.decode(try c.base64("pattern_base64"))
      let want = [UInt8](try c.base64("canonical_pattern_base64"))
      let name = try c.string("name")
      #expect(Array(GoCase.lower(pattern.collapsingGoSpace).utf8) == want, "\(name)")
    }
  }
}
