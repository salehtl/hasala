// conformance/op/manifest.json (Go-encoded, internal/oplog
// TestWriteConformanceFixtures): the canonical JSON writer and the wire
// timestamp rules, against the bytes and answers both executors already agree on.
import CoreJSON
import CorePrimitives
import CoreTime
import Foundation
import Testing

@Suite("conformance/op")
struct OpManifestTests {
  static let manifest = Result { try Fixtures.json("op/manifest.json") }

  /// Every body the manifest pins as bytes.
  static let bodies = [
    "config_ops_base64", "golden_ops_base64", "golden_raw_body_base64", "golden_checkpoint_base64",
    "duplicate_disposition_base64", "verified_origin_base64", "parent_version_overflow_base64",
  ]

  // Re-encoding a parsed body reproduces it byte for byte. These bodies hold no
  // character Go and JSON.stringify escape differently (`<`, `>`, `&`, U+2028,
  // U+2029), so Go's bytes are also JSON.stringify's bytes: one claim covers
  // both executors.
  @Test("parse then write is byte-identical, in both number styles", arguments: bodies)
  func writerIsByteIdentical(_ key: String) throws {
    let bytes = [UInt8](try Self.manifest.get().base64(key))
    let value = try JSONParser.parse(bytes)
    #expect(JSONWriter(numbers: .literal).bytes(value) == bytes)
    #expect(JSONWriter(numbers: .literal, keyOrder: .insertion).bytes(value) == bytes)
    if key == "parent_version_overflow_base64" {
      // The one body JSON.stringify cannot reproduce: 2^53+1 is not a double.
      // This is exactly why wire/op.ts refuses it; the literal style keeps it.
      let js = JSONWriter().string(value)
      #expect(js.contains(#""parent_version":9007199254740992,"#))
      #expect(Array(js.replacingOccurrences(of: "9007199254740992", with: "9007199254740993").utf8) == bytes)
    } else {
      #expect(JSONWriter().bytes(value) == bytes)
    }
  }

  @Test("parent_version past 2^53 keeps its exact literal")
  func overflowLiteral() throws {
    let m = try Self.manifest.get()
    let body = try JSONParser.parse([UInt8](try m.base64("parent_version_overflow_base64")))
    let pv = body["ops"]?.arrayValue?.first?["parent_version"]?.numberValue
    #expect(pv?.literal == (try m.string("parent_version_overflow")))
    #expect(pv?.int64Value == 9_007_199_254_740_993)
    #expect(pv?.v4Int == nil)
  }

  @Test("expect_ops: op ids, instants, entities, parent versions and ingest ids read back")
  func expectOps() throws {
    let m = try Self.manifest.get()
    let ops = try JSONParser.parse([UInt8](try m.base64("golden_ops_base64"))).array("ops")
    let expected = try m.array("expect_ops")
    #expect(ops.count == expected.count)
    for (op, want) in zip(ops, expected) {
      #expect(try op.string("type") == want.string("type"))
      #expect(try op.string("op_id") == want.string("op_id"))
      #expect(String(try parseInstantMs(try op.string("authored_at"))) == (try want.string("authored_at_unix_ms")))
      #expect((op["entity"] != nil) == (want["has_entity"]?.boolValue == true))
      #expect(op["parent_version"]?.numberValue?.literal == want["parent_version"]?.stringValue)
      #expect((op["ingest_id"]?.stringValue ?? "") == (try want.string("ingest_id")))
    }
  }

  @Test("authored_at_cases: every accepted timestamp reads to Go's instant")
  func authoredAtCases() throws {
    let cases = try Self.manifest.get().array("authored_at_cases")
    #expect(cases.count == 15)
    var divergent = 0
    for c in cases {
      let wire = try c.string("wire")
      let ms = try parseInstantMs(wire)
      #expect(String(ms) == (try c.string("expect_unix_ms")), "\(wire)")
      // Canonical form: four year digits, UTC, .sss; idempotent; the same
      // string toISOString writes.
      let canonical = try canonicalTime(wire)
      #expect(Array(canonical.utf8)[4] == 0x2d, "\(wire)")
      #expect(try parseInstantMs(canonical) == ms)
      #expect(try canonicalTime(canonical) == canonical)
      #expect(Instant.iso(ms) == canonical)
      // Go writes its own spelling (`.5Z`, no `.000`); this executor reads it
      // to the same instant and the same canonical form.
      let goWire = try c.string("expect_canonical_wire")
      #expect(try parseInstantMs(goWire) == ms, "\(goWire)")
      #expect(try canonicalTime(goWire) == canonical)
      if goWire != canonical { divergent += 1 }
    }
    // The spelling divergence is real, or the read-back above proves nothing.
    #expect(divergent > 0)
  }

  @Test("authored_at_rejects: every refused timestamp is refused")
  func authoredAtRejects() throws {
    let rejects = try Self.manifest.get().array("authored_at_rejects")
    #expect(rejects.count == 23)
    for r in rejects {
      let wire = r.stringValue ?? ""
      #expect(throws: InstantError.self, "\(wire)") { try canonicalTime(wire) }
    }
  }
}
