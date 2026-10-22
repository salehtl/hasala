import CoreJSON
import CoreReplay
import CoreTime
import CoreWire
import Foundation
import Testing

@testable import CoreDomain

@Suite("OpAuthor: bill changes and pauses")
struct OpAuthorBillChangesTests {
  static func d(_ s: String) -> CivilDate { CivilDate(wire: s)! }

  static let base = OpAuthor.BillDraft(
    name: "Netflix", keys: ["netflix"], mode: .fixed(toleranceBp: 200), amountMinor: 5_600, anchor: d("2026-03-06"),
    start: d("2026-03-06"), category: "subscriptions")

  static func authored(_ draft: OpAuthor.BillDraft) throws(AuthorError) -> [Op] {
    var a = OpAuthor(ctx())
    try a.setBill(id: "bm_1", draft)
    return try a.build().ops
  }

  static func refused(_ draft: OpAuthor.BillDraft) -> Bool {
    do {
      _ = try authored(draft)
      return false
    } catch {
      if case .refused = error { return true }
      return false
    }
  }

  static func modeJSON(_ m: OpAuthor.AmountMode) -> (String, String) {
    switch m {
    case .fixed(let bp): ("fixed", String(bp))
    case .variable: ("variable", "null")
    }
  }

  static func raw(_ draft: OpAuthor.BillDraft) -> String {
    let (mode, bp) = modeJSON(draft.mode)
    var s =
      #"{"name":"\#(draft.name)","keys":["netflix"],"direction":"debit","currency":"AED","amount_mode":"\#(mode)","amount_minor":"\#(draft.amountMinor)","tolerance_bp":\#(bp),"cadence":{"unit":"month","every":1},"anchor":"\#(draft.anchor.wire)","start":"\#(draft.start.wire)","end":\#(draft.end.map { "\"\($0.wire)\"" } ?? "null"),"category":\#(draft.category.map { "\"\($0)\"" } ?? "null"),"account":null,"source":"manual","status":"\#(draft.status.rawValue)""#
    if !draft.changes.isEmpty {
      s += #","changes":["#
        + draft.changes.map { c in
          let (m, t) = modeJSON(c.terms.mode)
          return #"{"from":"\#(c.from.wire)","amount_mode":"\#(m)","amount_minor":"\#(c.terms.amountMinor)","tolerance_bp":\#(t)}"#
        }.joined(separator: ",") + "]"
    }
    if !draft.pauses.isEmpty {
      s += #","pauses":["#
        + draft.pauses.map { p in #"{"from":"\#(p.from.wire)","until":\#(p.until.map { "\"\($0.wire)\"" } ?? "null")}"# }
          .joined(separator: ",") + "]"
    }
    return s + "}"
  }

  static func foldRaw(_ draft: OpAuthor.BillDraft) throws -> State {
    let op =
      #"{"v":4,"type":"bill_set","op_id":"op-raw","authored_at":"2026-10-01T08:00:00.000Z","entity":{"kind":"bill","id":"bm_1"},"parent_version":null,"payload":\#(raw(draft))}"#
    let ops = try OpCodec.decodeBlobOps(Array(#"{"v":4,"kind":"ops","ops":[\#(op)]}"#.utf8))
    var s = State()
    try Replay.foldOps(ops, seq: 1, writerID: w, into: &s)
    return s
  }

  @Test("empty lists are omitted; non-empty ones follow status, in the decoder's shape")
  func payload() throws {
    let plain = try Self.authored(Self.base)
    #expect(!JSONWriter().string(plain[0].payload).contains("changes"))
    #expect(!JSONWriter().string(plain[0].payload).contains("pauses"))
    #expect(JSONWriter().string(plain[0].payload) == Self.raw(Self.base))
    var draft = Self.base
    draft.changes = [
      .init(from: Self.d("2026-06-06"), terms: .init(mode: .fixed(toleranceBp: 100), amountMinor: 6_300)),
      .init(from: Self.d("2026-09-06"), terms: .init(mode: .variable, amountMinor: 7_000)),
    ]
    draft.pauses = [.init(from: Self.d("2026-04-01"), until: Self.d("2026-05-01")), .init(from: Self.d("2026-10-01"))]
    let ops = try Self.authored(draft)
    let text = JSONWriter().string(ops[0].payload)
    #expect(
      text.hasSuffix(
        #""status":"active","changes":[{"from":"2026-06-06","amount_mode":"fixed","amount_minor":"6300","tolerance_bp":100},{"from":"2026-09-06","amount_mode":"variable","amount_minor":"7000","tolerance_bp":null}],"pauses":[{"from":"2026-04-01","until":"2026-05-01"},{"from":"2026-10-01","until":null}]}"#
      ))
    #expect(text == Self.raw(draft))
    var s = State()
    try Replay.foldOps(ops, seq: 1, writerID: w, into: &s)
    #expect(s.anomalies.isEmpty)
    let b = try #require(s.bills["bm_1"])
    #expect(b.changes.map(\.amountMinor) == [6_300, 7_000] && b.changes[1].toleranceBp == nil)
    #expect(b.pauses == [BillPause(from: "2026-04-01", until: "2026-05-01"), BillPause(from: "2026-10-01", until: nil)])
    #expect(b.createdAt != nil)
  }

  @Test("an edit always names both lists, [] when empty, so clearing them is expressible; a create omits empty ones")
  func editNamesBothLists() throws {
    var a = OpAuthor(ctx())
    try a.setBill(id: "bm_1", Self.base)
    var withLists = Self.base
    withLists.changes = [.init(from: Self.d("2026-06-06"), terms: .init(mode: .fixed(toleranceBp: 200), amountMinor: 6_300))]
    withLists.pauses = [.init(from: Self.d("2026-08-01"))]
    try a.setBill(id: "bm_1", parentVersion: 1, withLists)
    try a.setBill(id: "bm_1", parentVersion: 2, Self.base)
    let ops = try a.build().ops
    #expect(!JSONWriter().string(ops[0].payload).contains("changes"))
    #expect(JSONWriter().string(ops[2].payload).hasSuffix(#""status":"active","changes":[],"pauses":[]}"#))
    var s = State()
    try Replay.foldOps(Array(ops[0..<2]), seq: 1, writerID: w, into: &s)
    #expect(s.bills["bm_1"]?.changes.count == 1 && s.bills["bm_1"]?.pauses.count == 1)
    try Replay.foldOps([ops[2]], seq: 2, writerID: w, into: &s)
    #expect(s.anomalies.isEmpty && s.bills["bm_1"]?.changes == [] && s.bills["bm_1"]?.pauses == [] && s.bills["bm_1"]?.version == 3)
  }

  @Test("billRecord(inheritingFrom:) reads an edit with no lists as the fold does; a create never inherits")
  func recordInherits() throws {
    var a = OpAuthor(ctx())
    try a.setBill(id: "bm_1", Self.base)
    var withLists = Self.base
    withLists.changes = [.init(from: Self.d("2026-06-06"), terms: .init(mode: .fixed(toleranceBp: 200), amountMinor: 6_300))]
    try a.setBill(id: "bm_1", parentVersion: 1, withLists)
    let ops = try a.build().ops
    var s = State()
    try Replay.foldOps(ops, seq: 1, writerID: w, into: &s)
    let head = try #require(s.bills["bm_1"])
    let oldShape = #"{"v":4,"type":"bill_set","op_id":"op-old","authored_at":"2026-10-01T08:00:00.000Z","entity":{"kind":"bill","id":"bm_1"},"parent_version":2,"payload":\#(Self.raw(Self.base))}"#
    let old = try OpCodec.decodeBlobOps(Array(#"{"v":4,"kind":"ops","ops":[\#(oldShape)]}"#.utf8))[0]
    #expect(Replay.billRecord(old)?.changes == [])
    #expect(Replay.billRecord(old, inheritingFrom: head)?.changes == head.changes)
    #expect(Replay.billRecord(old, inheritingFrom: nil) == nil)
    #expect(Replay.billRecord(ops[0], inheritingFrom: head)?.changes == [])
    #expect(Replay.billRecord(ops[1], inheritingFrom: nil)?.changes.count == 1)
  }

  @Test("author-side refusals, each one the decoder's")
  func refusals() throws {
    func change(_ from: String, _ mode: OpAuthor.AmountMode = .fixed(toleranceBp: 0), _ amount: Int64 = 6_300)
      -> OpAuthor.BillChangeDraft
    { .init(from: Self.d(from), terms: .init(mode: mode, amountMinor: amount)) }
    func pause(_ from: String, _ until: String?) -> OpAuthor.BillPauseDraft {
      .init(from: Self.d(from), until: until.map(Self.d))
    }
    var cases: [(String, OpAuthor.BillDraft)] = []
    func add(_ name: String, _ f: (inout OpAuthor.BillDraft) -> Void) {
      var x = Self.base
      f(&x)
      cases.append((name, x))
    }
    add("change before start") { $0.changes = [change("2026-03-05")] }
    add("change after end") {
      $0.end = Self.d("2026-09-06")
      $0.changes = [change("2026-09-07")]
    }
    add("zero amount") { $0.changes = [change("2026-06-06", .fixed(toleranceBp: 0), 0)] }
    add("tolerance over 5000") { $0.changes = [change("2026-06-06", .fixed(toleranceBp: 5_001))] }
    add("negative tolerance") { $0.changes = [change("2026-06-06", .fixed(toleranceBp: -1))] }
    add("duplicate from") { $0.changes = [change("2026-06-06"), change("2026-06-06")] }
    add("decreasing from") { $0.changes = [change("2026-07-06"), change("2026-06-06")] }
    add("25 changes") { d in d.changes = (0..<25).map { i in .init(from: Self.d("2026-04-01").adding(days: i)!, terms: .init(mode: .variable, amountMinor: 1)) } }
    add("pause before start") { $0.pauses = [pause("2026-03-05", nil)] }
    add("empty pause") { $0.pauses = [pause("2026-04-01", "2026-04-01")] }
    add("backwards pause") { $0.pauses = [pause("2026-04-01", "2026-03-20")] }
    add("open pause not last") { $0.pauses = [pause("2026-04-01", nil), pause("2026-05-01", "2026-06-01")] }
    add("overlap") { $0.pauses = [pause("2026-04-01", "2026-05-01"), pause("2026-04-20", nil)] }
    add("25 pauses") { d in
      d.pauses = (0..<25).map { i in .init(from: Self.d("2026-04-01").adding(days: i)!, until: Self.d("2026-04-01").adding(days: i + 1)!) }
    }
    for (name, draft) in cases {
      #expect(Self.refused(draft), "\(name)")
      #expect(try Self.foldRaw(draft).anomalies.map(\.kind) == ["invalid_payload"], "\(name)")
    }
    var edges = Self.base
    edges.end = Self.d("2026-09-06")
    edges.status = .cancelled
    edges.changes = [change("2026-03-06"), change("2026-09-06")]
    edges.pauses = (0..<24).map { i in .init(from: Self.d("2026-04-01").adding(days: i)!, until: Self.d("2026-04-01").adding(days: i + 1)!) }
    #expect(!Self.refused(edges))
    #expect(try Self.foldRaw(edges).anomalies.isEmpty)
  }

  @Test("author and decoder agree on generated drafts")
  func agreement() throws {
    var seed: UInt64 = 0x2545_f491_4f6c_dd1d
    func next(_ n: Int) -> Int {
      seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      return Int((seed >> 33) % UInt64(n))
    }
    let origin = Self.d("2026-02-25")
    func day() -> CivilDate { origin.adding(days: next(300))! }
    var accepted = 0
    var refusedCount = 0
    for _ in 0..<600 {
      var draft = Self.base
      if next(3) == 0 {
        draft.end = Self.d("2026-11-06")
        draft.status = .cancelled
      }
      draft.changes = (0..<next(4)).map { _ in
        let mode: OpAuthor.AmountMode = next(3) == 0 ? .variable : .fixed(toleranceBp: [-1, 0, 200, 5_000, 5_001][next(5)])
        return .init(from: day(), terms: .init(mode: mode, amountMinor: [0, 1, 6_300][next(3)]))
      }
      if next(2) == 0 { draft.changes.sort { $0.from < $1.from } }
      draft.pauses = (0..<next(4)).map { _ in
        let from = day()
        return .init(from: from, until: next(3) == 0 ? nil : from.adding(days: next(60) - 5))
      }
      if next(2) == 0 { draft.pauses.sort { $0.from < $1.from } }
      let authorRefuses = Self.refused(draft)
      let s = try Self.foldRaw(draft)
      #expect(authorRefuses == !s.anomalies.isEmpty, "\(Self.raw(draft))")
      if authorRefuses {
        refusedCount += 1
        continue
      }
      accepted += 1
      let ops = try Self.authored(draft)
      #expect(JSONWriter().string(ops[0].payload) == Self.raw(draft))
      let b = try #require(s.bills["bm_1"])
      #expect(b.changes.map(\.from) == draft.changes.map(\.from.wire) && b.pauses.map(\.until) == draft.pauses.map { $0.until?.wire })
    }
    #expect(accepted > 50 && refusedCount > 50)
  }
}
