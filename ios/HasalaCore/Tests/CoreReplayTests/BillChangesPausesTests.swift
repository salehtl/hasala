import CoreJSON
import CoreWire
import Foundation
import Testing

@testable import CoreReplay

@Suite("CoreReplay: bill changes and pauses")
struct BillChangesPausesTests {
  static func bill(_ extra: String = "", status: String = "active", end: String = "null") -> String {
    #"{"name":"Netflix","keys":["netflix"],"direction":"debit","currency":"AED","amount_mode":"fixed","amount_minor":"5600","tolerance_bp":200,"cadence":{"unit":"month","every":1},"anchor":"2026-01-06","start":"2026-01-06","end":\#(end),"category":"subscriptions","account":null,"source":"manual","status":"\#(status)"\#(extra)}"#
  }

  static func create(_ payload: String, at: String = "2026-10-01T08:00:00.000Z") -> String {
    op("bill_set", payload, id: 1, entity: ("bill", "bm_1"), at: at)
  }

  static func folded(_ payload: String) throws -> Log {
    var log = Log()
    try log.blob(create(payload))
    return log
  }

  @Test("absent, null and empty lists fold to the same record and the same witness as an old record")
  func emptyIsAbsent() throws {
    let old = try Self.folded(Self.bill())
    #expect(old.kinds.isEmpty)
    let b = try #require(old.state.bills["bm_1"])
    #expect(b.changes.isEmpty && b.pauses.isEmpty && b.createdAt == "2026-10-01T08:00:00.000Z")
    for extra in [#","changes":[],"pauses":[]"#, #","changes":null,"pauses":null"#, #","changes":[]"#] {
      let s = try Self.folded(Self.bill(extra))
      #expect(s.kinds.isEmpty, "\(extra)")
      #expect(s.state.serialized() == old.state.serialized(), "\(extra)")
    }
    let witness = String(decoding: old.state.serialized(), as: UTF8.self)
    #expect(!witness.contains("\"changes\"") && !witness.contains("\"pauses\""))
    #expect(witness.contains(#""created_at":"2026-10-01T08:00:00.000Z""#))
  }

  @Test("changes and pauses decode in order and reach the witness")
  func accepted() throws {
    let extra =
      #","changes":[{"from":"2026-06-06","amount_mode":"fixed","amount_minor":"6300","tolerance_bp":100},{"from":"2026-09-06","amount_mode":"variable","amount_minor":"7000","tolerance_bp":null}],"pauses":[{"from":"2026-02-01","until":"2026-03-01"},{"from":"2026-03-01","until":"2026-04-10"},{"from":"2026-08-01","until":null}]"#
    let log = try Self.folded(Self.bill(extra))
    #expect(log.kinds.isEmpty)
    let b = try #require(log.state.bills["bm_1"])
    #expect(
      b.changes == [
        BillChange(from: "2026-06-06", amountMode: "fixed", amountMinor: 6300, toleranceBp: 100),
        BillChange(from: "2026-09-06", amountMode: "variable", amountMinor: 7000, toleranceBp: nil),
      ])
    #expect(
      b.pauses == [
        BillPause(from: "2026-02-01", until: "2026-03-01"), BillPause(from: "2026-03-01", until: "2026-04-10"),
        BillPause(from: "2026-08-01", until: nil),
      ])
    let witness = String(decoding: log.state.serialized(), as: UTF8.self)
    #expect(witness.contains(#""changes":[{"amount_minor":"6300","amount_mode":"fixed","from":"2026-06-06","tolerance_bp":100}"#))
    #expect(witness.contains(#""pauses":[{"from":"2026-02-01","until":"2026-03-01"}"#))
  }

  @Test("a change may fall on start and on end")
  func boundaries() throws {
    let extra =
      #","changes":[{"from":"2026-01-06","amount_mode":"fixed","amount_minor":"6300","tolerance_bp":0},{"from":"2026-12-06","amount_mode":"fixed","amount_minor":"6400","tolerance_bp":5000}],"pauses":[{"from":"2026-01-06","until":null}]"#
    let log = try Self.folded(Self.bill(extra, status: "cancelled", end: #""2026-12-06""#))
    #expect(log.kinds.isEmpty)
    #expect(log.state.bills["bm_1"]?.changes.count == 2)
  }

  static func two(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }

  static func changes(_ n: Int) -> String {
    #","changes":["# + (1...n).map { i in #"{"from":"2026-02-\#(two(i))","amount_mode":"fixed","amount_minor":"6300","tolerance_bp":0}"# }
      .joined(separator: ",") + "]"
  }

  static func pauses(_ n: Int) -> String {
    #","pauses":["# + (1...n).map { i in #"{"from":"2026-02-\#(two(i))","until":"2026-02-\#(two(i + 1))"}"# }.joined(separator: ",") + "]"
  }

  @Test("24 changes and 24 pauses are the most a record holds")
  func limits() throws {
    #expect(try Self.folded(Self.bill(Self.changes(24) + Self.pauses(24))).kinds.isEmpty)
  }

  static let refusals: [(String, String)] = [
    ("changes not an array", #","changes":{}"#),
    ("change not an object", #","changes":["2026-06-06"]"#),
    ("bad from", #","changes":[{"from":"2026-6-6","amount_mode":"fixed","amount_minor":"6300","tolerance_bp":0}]"#),
    ("from before start", #","changes":[{"from":"2026-01-05","amount_mode":"fixed","amount_minor":"6300","tolerance_bp":0}]"#),
    ("zero amount", #","changes":[{"from":"2026-06-06","amount_mode":"fixed","amount_minor":"0","tolerance_bp":0}]"#),
    ("leading zero amount", #","changes":[{"from":"2026-06-06","amount_mode":"fixed","amount_minor":"06300","tolerance_bp":0}]"#),
    ("bad mode", #","changes":[{"from":"2026-06-06","amount_mode":"estimate","amount_minor":"6300","tolerance_bp":0}]"#),
    ("tolerance over 5000", #","changes":[{"from":"2026-06-06","amount_mode":"fixed","amount_minor":"6300","tolerance_bp":5001}]"#),
    ("negative tolerance", #","changes":[{"from":"2026-06-06","amount_mode":"fixed","amount_minor":"6300","tolerance_bp":-1}]"#),
    ("fixed without tolerance", #","changes":[{"from":"2026-06-06","amount_mode":"fixed","amount_minor":"6300","tolerance_bp":null}]"#),
    ("tolerance key missing", #","changes":[{"from":"2026-06-06","amount_mode":"variable","amount_minor":"6300"}]"#),
    ("variable with tolerance", #","changes":[{"from":"2026-06-06","amount_mode":"variable","amount_minor":"6300","tolerance_bp":0}]"#),
    (
      "duplicate from",
      #","changes":[{"from":"2026-06-06","amount_mode":"fixed","amount_minor":"6300","tolerance_bp":0},{"from":"2026-06-06","amount_mode":"fixed","amount_minor":"6400","tolerance_bp":0}]"#
    ),
    (
      "decreasing from",
      #","changes":[{"from":"2026-07-06","amount_mode":"fixed","amount_minor":"6300","tolerance_bp":0},{"from":"2026-06-06","amount_mode":"fixed","amount_minor":"6400","tolerance_bp":0}]"#
    ),
    ("25 changes", Self.changes(25)),
    ("pauses not an array", #","pauses":"2026-02-01""#),
    ("pause from before start", #","pauses":[{"from":"2026-01-05","until":null}]"#),
    ("pause until missing", #","pauses":[{"from":"2026-02-01"}]"#),
    ("pause until equals from", #","pauses":[{"from":"2026-02-01","until":"2026-02-01"}]"#),
    ("pause until before from", #","pauses":[{"from":"2026-02-01","until":"2026-01-20"}]"#),
    ("open pause not last", #","pauses":[{"from":"2026-02-01","until":null},{"from":"2026-03-01","until":"2026-04-01"}]"#),
    ("overlapping pauses", #","pauses":[{"from":"2026-02-01","until":"2026-03-01"},{"from":"2026-02-20","until":null}]"#),
    ("unordered pauses", #","pauses":[{"from":"2026-05-01","until":"2026-06-01"},{"from":"2026-02-01","until":"2026-03-01"}]"#),
    ("25 pauses", Self.pauses(25)),
  ]

  @Test("a grammar violation refuses the whole create", arguments: refusals.map(\.0))
  func refusedCreate(_ name: String) throws {
    let extra = try #require(Self.refusals.first { $0.0 == name }?.1)
    let log = try Self.folded(Self.bill(extra))
    #expect(log.kinds == ["invalid_payload"], "\(name)")
    #expect(log.state.bills["bm_1"] == nil)
  }

  @Test("a change after end is refused")
  func changeAfterEnd() throws {
    let extra = #","changes":[{"from":"2026-12-07","amount_mode":"fixed","amount_minor":"6300","tolerance_bp":0}]"#
    let log = try Self.folded(Self.bill(extra, status: "cancelled", end: #""2026-12-06""#))
    #expect(log.kinds == ["invalid_payload"])
  }

  @Test("a refused edit consumes no version; an edit with no pauses key keeps them and [] clears them; createdAt stays the create's")
  func edits() throws {
    var log = Log()
    try log.blob(Self.create(Self.bill(), at: "2026-05-01T21:30:00.000Z"))
    try log.blob(
      op(
        "bill_set", Self.bill(#","pauses":[{"from":"2026-02-01","until":null},{"from":"2026-03-01","until":null}]"#), id: 2,
        entity: ("bill", "bm_1"), parent: 1, at: "2026-10-02T08:00:00.000Z"))
    #expect(log.kinds == ["invalid_payload"])
    #expect(log.state.bills["bm_1"]?.version == 1)
    try log.blob(
      op(
        "bill_set", Self.bill(#","pauses":[{"from":"2026-02-01","until":null}]"#), id: 3, entity: ("bill", "bm_1"), parent: 1,
        at: "2026-10-03T08:00:00.000Z"))
    let b = try #require(log.state.bills["bm_1"])
    #expect(b.version == 2 && b.pauses.count == 1)
    #expect(b.createdAt == "2026-05-01T21:30:00.000Z")
    try log.blob(op("bill_set", Self.bill(), id: 4, entity: ("bill", "bm_1"), parent: 2, at: "2026-10-04T08:00:00.000Z"))
    #expect(log.state.bills["bm_1"]?.pauses.count == 1 && log.state.bills["bm_1"]?.version == 3)
    try log.blob(
      op("bill_set", Self.bill(#","pauses":[]"#), id: 5, entity: ("bill", "bm_1"), parent: 3, at: "2026-10-05T08:00:00.000Z"))
    #expect(log.state.bills["bm_1"]?.pauses.isEmpty == true && log.state.bills["bm_1"]?.version == 4)
    #expect(log.state.bills["bm_1"]?.createdAt == "2026-05-01T21:30:00.000Z")
  }

  @Test("unknown keys inside a change or a pause are ignored like unknown payload keys")
  func unknownKeys() throws {
    let extra =
      #","changes":[{"from":"2026-06-06","amount_mode":"fixed","amount_minor":"6300","tolerance_bp":0,"note":"x"}],"pauses":[{"from":"2026-02-01","until":null,"why":"travel"}]"#
    let log = try Self.folded(Self.bill(extra))
    #expect(log.kinds.isEmpty)
  }
}
