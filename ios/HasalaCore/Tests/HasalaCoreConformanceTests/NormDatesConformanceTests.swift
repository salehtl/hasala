import CoreJSON
@testable import CoreNorm
import CorePrimitives
import CoreTime
import Foundation
import Testing

enum NormDatesFixtures {
  static let doc = Result { try Fixtures.json("norm-dates/dates.json") }

  static func cases(_ key: String) -> [JSONValue] {
    (try? doc.get())?[key]?.arrayValue ?? []
  }
}

@Suite("conformance/norm-dates")
struct NormDatesConformanceTests {
  @Test("the fixture loads with every family populated")
  func loads() throws {
    let doc = try NormDatesFixtures.doc.get()
    #expect(try doc.int("schema_version") == 1)
    for key in ["forward_dates", "email_dates", "instants"] {
      #expect(!NormDatesFixtures.cases(key).isEmpty, "\(key)")
    }
  }

  static func expected(_ family: String, _ c: JSONValue) throws -> JSONValue {
    switch family {
    case "forward_dates":
      return Unwrap.parseForwardDate(try c.string("input")).map { .string(Normalizer.format($0)) } ?? .null
    case "email_dates":
      let receivedMs = try Instant.parseMs(try c.string("received_at"))
      let (date, source) = Normalizer.emailDateOf(forwardDate: try c.string("forward_date"), receivedAtMs: receivedMs)
      return obj([("email_date", .string(date)), ("date_source", .string(source.rawValue))])
    default:
      let input = try c.string("input")
      guard let canonical = try? canonicalTime(input), let ms = try? parseInstantMs(input) else { return obj([("ok", .bool(false))]) }
      return obj([("ok", .bool(true)), ("epoch_ms", .string(String(ms))), ("canonical", .string(canonical)), ("utc_day", .string(utcDay(ms)))])
    }
  }

  @Test("dates.json is what Swift computes (HASALA_UPDATE_GOLDEN=1 rewrites it)")
  func golden() throws {
    var doc = try NormDatesFixtures.doc.get()
    for family in ["forward_dates", "email_dates", "instants"] {
      doc = doc.setting(family, try Golden.mapping(doc[family]) { $0.setting("expect", try Self.expected(family, $0)) })
    }
    try Golden.check("norm-dates/dates.json", doc)
  }

  @Test("forward_dates: parseForwardDate", arguments: NormDatesFixtures.cases("forward_dates"))
  func forwardDate(_ c: JSONValue) throws {
    let name = try c.string("name")
    let got = Unwrap.parseForwardDate(try c.string("input")).map(Normalizer.format)
    let want = c["expect"]?.stringValue
    if want == nil { #expect(c["expect"]?.isNull == true, "\(name)") }
    #expect(got == want, "\(name)")
  }

  @Test("email_dates: the forwarded date or the arrival time", arguments: NormDatesFixtures.cases("email_dates"))
  func emailDate(_ c: JSONValue) throws {
    let name = try c.string("name")
    let receivedMs = try Instant.parseMs(try c.string("received_at"))
    let (date, source) = Normalizer.emailDateOf(forwardDate: try c.string("forward_date"), receivedAtMs: receivedMs)
    let expect = try #require(c["expect"])
    #expect(date == (try expect.string("email_date")), "\(name)")
    #expect(source.rawValue == (try expect.string("date_source")), "\(name)")
  }

  @Test("instants: the wire timestamp grammar", arguments: NormDatesFixtures.cases("instants"))
  func instant(_ c: JSONValue) throws {
    let name = try c.string("name")
    let input = try c.string("input")
    let expect = try #require(c["expect"])
    guard expect["ok"]?.boolValue == true else {
      #expect(throws: InstantError.self, "\(name)") { try canonicalTime(input) }
      return
    }
    let ms = try parseInstantMs(input)
    #expect(String(ms) == (try expect.string("epoch_ms")), "\(name)")
    #expect(try canonicalTime(input) == (try expect.string("canonical")), "\(name)")
    #expect(utcDay(ms) == (try expect.string("utc_day")), "\(name)")
  }
}
