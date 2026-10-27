import CoreJSON
import CoreReplay
import CoreTime
import CoreWire
import Testing

@testable import CoreDomain

@Suite("SamePurchase")
struct SamePurchaseTests {
  static let day: Int64 = 86_400_000
  static let t0: Int64 = 1_791_000_000_000

  static func f(
    _ id: String = "f", minor: Int64 = 2_500, home: Int64? = 9_181, stated: Bool = false, at: Int64 = t0, merchant: String = "amazon",
    last4: String = "4412", bank: String? = "enbd", direction: String = "debit"
  ) -> SamePurchase.Row {
    SamePurchase.Row(
      id: id, amountMinor: minor, currency: "USD", amountHomeMinor: home, homeStated: stated, direction: direction, bank: bank,
      last4: last4, postedMs: at, merchantKey: merchant)
  }

  static func a(
    _ id: String = "a", minor: Int64 = 9_300, after: Int64 = 2 * day, merchant: String = "amazon", last4: String = "4412",
    bank: String? = "enbd", direction: String = "debit"
  ) -> SamePurchase.Row {
    SamePurchase.Row(
      id: id, amountMinor: minor, currency: "AED", amountHomeMinor: minor, direction: direction, bank: bank, last4: last4,
      postedMs: t0 + after, merchantKey: merchant)
  }

  static func pairs(_ rows: [SamePurchase.Row]) -> [String] {
    SamePurchase.pairs(rows, home: "AED").map { "\($0.foreign)>\($0.home)" }
  }

  @Test("a merged AED alert names its foreign purchase; a plain archive does not")
  func mergedForeign() {
    var merged = Self.a()
    merged.archived = true
    let settled = Self.f(home: 9_300)
    let note = SamePurchase.note(foreignMinor: 2_500, currency: "USD")
    #expect(SamePurchase.mergedForeign(of: merged, note: note, among: [settled], home: "AED") == "f")
    #expect(SamePurchase.mergedForeign(of: merged, note: "Lunch", among: [settled], home: "AED") == nil)
    #expect(SamePurchase.mergedForeign(of: merged, note: nil, among: [settled], home: "AED") == nil)
    #expect(SamePurchase.mergedForeign(of: merged, note: note, among: [Self.f()], home: "AED") == nil)
    #expect(SamePurchase.mergedForeign(of: Self.a(), note: note, among: [settled], home: "AED") == nil)
    var gone = settled
    gone.archived = true
    #expect(SamePurchase.mergedForeign(of: merged, note: note, among: [gone], home: "AED") == nil)
    #expect(SamePurchase.mergedForeign(of: merged, note: note, among: [Self.f(home: 9_300, last4: "0001")], home: "AED") == nil)
  }

  @Test("a USD alert and a later AED posting of the same purchase pair")
  func basic() {
    #expect(Self.pairs([Self.f(), Self.a()]) == ["f>a"])
    #expect(SamePurchase.pairs([Self.a(), Self.f()], home: "AED") == [SamePurchase.Pair(foreign: "f", home: "a", merchantMissing: false)])
  }

  @Test("the 7-day window: from F's posted time to F + 7 days, inclusive")
  func window() {
    #expect(Self.pairs([Self.f(), Self.a(after: 0)]) == ["f>a"])
    #expect(Self.pairs([Self.f(), Self.a(after: 7 * Self.day)]) == ["f>a"])
    #expect(Self.pairs([Self.f(), Self.a(after: 7 * Self.day + 1)]).isEmpty)
    #expect(Self.pairs([Self.f(), Self.a(after: -1)]).isEmpty)
  }

  @Test("±5% of an estimate, ±1% of a stated value, both inclusive")
  func tolerance() {
    #expect(Self.pairs([Self.f(home: 10_000), Self.a(minor: 10_500)]) == ["f>a"])
    #expect(Self.pairs([Self.f(home: 10_000), Self.a(minor: 9_500)]) == ["f>a"])
    #expect(Self.pairs([Self.f(home: 10_000), Self.a(minor: 10_501)]).isEmpty)
    #expect(Self.pairs([Self.f(home: 10_000), Self.a(minor: 9_499)]).isEmpty)
    #expect(Self.pairs([Self.f(home: 10_000, stated: true), Self.a(minor: 10_100)]) == ["f>a"])
    #expect(Self.pairs([Self.f(home: 10_000, stated: true), Self.a(minor: 10_101)]).isEmpty)
    #expect(Self.pairs([Self.f(home: 10_000, stated: true), Self.a(minor: 9_899)]).isEmpty)
  }

  @Test("direction, bank and last4 must agree; an empty last4 or a missing bank never pairs")
  func identity() {
    #expect(Self.pairs([Self.f(), Self.a(direction: "credit")]).isEmpty)
    #expect(Self.pairs([Self.f(), Self.a(bank: "dib")]).isEmpty)
    #expect(Self.pairs([Self.f(bank: nil), Self.a(bank: nil)]).isEmpty)
    #expect(Self.pairs([Self.f(), Self.a(last4: "9999")]).isEmpty)
    #expect(Self.pairs([Self.f(last4: ""), Self.a(last4: "")]).isEmpty)
    #expect(Self.pairs([Self.f(direction: "credit"), Self.a(direction: "credit")]) == ["f>a"])
  }

  @Test("merchant keys equal or one a prefix of the other; a missing merchant pairs and says so")
  func merchants() {
    #expect(Self.pairs([Self.f(merchant: "amazon"), Self.a(merchant: "amazon mktplace")]) == ["f>a"])
    #expect(Self.pairs([Self.f(merchant: "amazon mktplace"), Self.a(merchant: "amazon")]) == ["f>a"])
    #expect(Self.pairs([Self.f(merchant: "amazon"), Self.a(merchant: "noon")]).isEmpty)
    #expect(Self.pairs([Self.f(merchant: "amazon"), Self.a(merchant: "amazo")]) == ["f>a"])
    let p = SamePurchase.pairs([Self.f(), Self.a(merchant: "")], home: "AED")
    #expect(p == [SamePurchase.Pair(foreign: "f", home: "a", merchantMissing: true)])
    #expect(SamePurchase.pairs([Self.f(), Self.a()], home: "AED").first?.merchantMissing == false)
  }

  @Test("F must be live, parsed, foreign and valued; A live, parsed, home, not archived, not manual, not a held copy")
  func eligibility() {
    var f = Self.f()
    f.live = false
    #expect(Self.pairs([f, Self.a()]).isEmpty)
    f = Self.f()
    f.unparsed = true
    #expect(Self.pairs([f, Self.a()]).isEmpty)
    #expect(Self.pairs([Self.f(home: nil), Self.a()]).isEmpty)
    f = Self.f()
    f.currency = "AED"
    #expect(Self.pairs([f, Self.a()]).isEmpty)
    f = Self.f()
    f.archived = true
    #expect(Self.pairs([f, Self.a()]).isEmpty)
    f = Self.f()
    f.heldCopy = true
    #expect(Self.pairs([f, Self.a()]).isEmpty)
    for change in [
      { (r: inout SamePurchase.Row) in r.live = false }, { $0.unparsed = true }, { $0.archived = true }, { $0.manual = true },
      { $0.heldCopy = true }, { $0.currency = "USD" }, { $0.possibleDuplicateOf = "other" },
    ] {
      var a = Self.a()
      change(&a)
      #expect(Self.pairs([Self.f(), a]).isEmpty)
    }
    #expect(SamePurchase.pairs([Self.f(), Self.a()], home: "USD").isEmpty)
  }

  @Test("a declined pair never asks again")
  func declined() {
    var a = Self.a()
    a.possibleDuplicateOf = "f"
    a.duplicateDisposition = "different"
    #expect(SamePurchase.declined(Self.f(), a))
    #expect(Self.pairs([Self.f(), a]).isEmpty)
    #expect(Self.pairs([Self.f(), Self.f("f2"), a]).isEmpty)
  }

  @Test("one to one: the nearest amount wins, then the nearest date, then the ids")
  func oneToOne() {
    #expect(Self.pairs([Self.f(home: 10_000), Self.a("a1", minor: 10_300), Self.a("a2", minor: 10_100)]) == ["f>a2"])
    #expect(Self.pairs([Self.f(home: 10_000), Self.a("a1", minor: 10_100, after: 3 * Self.day), Self.a("a2", minor: 9_900, after: Self.day)]) == ["f>a2"])
    #expect(Self.pairs([Self.f("f1", home: 10_000), Self.f("f2", home: 10_200), Self.a(minor: 10_200)]) == ["f2>a"])
    let two = Self.pairs([Self.f("f1", home: 10_000), Self.f("f2", home: 10_200), Self.a("a1", minor: 10_200), Self.a("a2", minor: 10_000)])
    #expect(Set(two) == ["f1>a2", "f2>a1"])
    #expect(Self.pairs([Self.f("f2"), Self.f("f1"), Self.a()]) == ["f1>a"])
    #expect(Self.pairs([Self.f("f1", at: Self.t0), Self.f("f2", at: Self.t0 + Self.day), Self.a(after: 2 * Self.day)]) == ["f2>a"])
  }

  @Test("the settled note names the original amount")
  func note() {
    #expect(SamePurchase.note(foreignMinor: 2_500, currency: "USD") == "Settled the USD 25.00 purchase")
  }

  static let w = "ios-0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"

  static func payload(_ minor: String, _ currency: String, _ at: String, _ merchant: String) -> JSONObject {
    JSONObject([
      ("amount_minor", .string(minor)), ("currency", .string(currency)), ("direction", .string("debit")),
      ("posted_at", .string(at)), ("merchant_raw", .string(merchant)), ("last4", .string("4412")),
      ("tier", .string("template")), ("needs_review", .bool(false)), ("entry_method", .string("mailbox")), ("bank", .string("enbd")),
      ("posted_precision", .string("time")), ("category", .string("shopping")),
    ])
  }

  static func row(_ t: Txn) -> SamePurchase.Row {
    SamePurchase.Row(
      id: t.id, live: t.isLive, unparsed: t.unparsed, archived: t.annotation("archived") != nil,
      manual: t.entryMethod == "manual", amountMinor: t.amountMinor, currency: t.currency, amountHomeMinor: t.amountHomeMinor,
      direction: t.direction, bank: t.bank, last4: t.last4, postedMs: try! parseInstantMs(t.postedAt),
      merchantKey: DuplicateRules.merchantKey(t.merchantRaw), possibleDuplicateOf: t.possibleDuplicateOf,
      duplicateDisposition: t.duplicateDisposition, heldCopy: t.isHeldCopy)
  }

  static func fold(_ ops: [Op], _ s: inout State, seq: Int64) throws {
    try Replay.foldOps(ops, seq: seq, writerID: w, into: &s)
    #expect(s.anomalies.isEmpty, "\(s.anomalies)")
  }

  static func seeded() throws -> (State, String, String, Int64) {
    var s = State()
    var a = OpAuthor(ctx())
    a.setHomeCurrency("AED")
    try a.setRate(currency: "USD", rateMicro: 3_672_500)
    let f = try a.ingest(payload: payload("2500", "USD", "2026-10-09T15:12:00.000Z", "AMAZON"), ingestID: String(repeating: "a", count: 64))
    let h = try a.ingest(
      payload: payload("9300", "AED", "2026-10-11T08:00:00.000Z", "AMAZON MKTPLACE"), ingestID: String(repeating: "b", count: 64))
    let blob = try a.build()
    try fold(blob.ops, &s, seq: 1)
    return (s, f, h, blob.lastAuthoredMs)
  }

  @Test("confirm: F takes A's amount as its stated AED value, A is archived with a note; undo puts both back")
  func confirm() throws {
    var (s, f, h, last) = try Self.seeded()
    #expect(s.txns[f]?.amountHomeMinor == 9_181)
    #expect(SamePurchase.pairs(s.txns.values.map(Self.row), home: "AED") == [SamePurchase.Pair(foreign: f, home: h, merchantMissing: false)])
    var c = OpAuthor(ctx(own: last))
    c.confirmSamePurchase(foreignID: f, foreignVersion: s.txns[f]!.version, homeID: h, homeAmountMinor: 9_300, foreignMinor: 2_500, foreignCurrency: "USD")
    let blob = try c.build()
    #expect(blob.ops.map(\.type) == [.txnEdited, .txnAnnotated])
    try Self.fold(blob.ops, &s, seq: 2)
    #expect(s.txns[f]?.amountHomeMinor == 9_300 && s.txns[f]?.amountMinor == 2_500 && s.txns[f]?.currency == "USD")
    #expect(s.txns[h]?.annotation("archived") == "user" && s.txns[h]?.annotation("note") == "Settled the USD 25.00 purchase")
    #expect(s.txns[h]?.isLive == true && ReviewQueue.lane(s.txns[h]!) == nil)
    #expect(SamePurchase.pairs(s.txns.values.map(Self.row), home: "AED").isEmpty)

    var u = OpAuthor(ctx(own: blob.lastAuthoredMs))
    u.undoSamePurchase(foreignID: f, foreignVersion: s.txns[f]!.version, previousHomeMinor: 9_181, homeID: h, previousNote: nil)
    try Self.fold(try u.build().ops, &s, seq: 3)
    #expect(s.txns[f]?.amountHomeMinor == 9_181)
    #expect(s.txns[h]?.annotation("archived") == nil && s.txns[h]?.annotation("note") == nil)
  }

  @Test("undo with the live rate re-freezes F as an estimate at that rate")
  func undoRefreezes() throws {
    var (s, f, h, last) = try Self.seeded()
    #expect(s.txns[f]?.homeSource == .rate && s.txns[f]?.homeRateMicro == 3_672_500)
    var c = OpAuthor(ctx(own: last))
    c.confirmSamePurchase(foreignID: f, foreignVersion: s.txns[f]!.version, homeID: h, homeAmountMinor: 9_300, foreignMinor: 2_500, foreignCurrency: "USD")
    let blob = try c.build()
    try Self.fold(blob.ops, &s, seq: 2)
    #expect(s.txns[f]?.homeSource == .stated)

    var u = OpAuthor(ctx(own: blob.lastAuthoredMs))
    u.undoSamePurchase(
      foreignID: f, foreignVersion: s.txns[f]!.version, previousHomeMinor: nil, homeID: h, previousNote: nil,
      refreeze: (currency: "USD", micro: 3_672_500))
    let undo = try u.build()
    #expect(undo.ops.map(\.type) == [.txnEdited, .rateSet, .txnAnnotated])
    try Self.fold(undo.ops, &s, seq: 3)
    #expect(s.txns[f]?.amountHomeMinor == 9_181)
    #expect(s.txns[f]?.homeSource == .rate && s.txns[f]?.homeRateMicro == 3_672_500)
    #expect(s.txns[h]?.annotation("archived") == nil)
  }

  @Test("an archived foreign row is never offered as the same purchase")
  func archivedForeign() throws {
    var (s, f, _, last) = try Self.seeded()
    var a = OpAuthor(ctx(own: last))
    a.annotate(txnID: f, set: [("archived", "user")])
    try Self.fold(try a.build().ops, &s, seq: 2)
    #expect(SamePurchase.pairs(s.txns.values.map(Self.row), home: "AED").isEmpty)
  }

  @Test("decline: A names F as a possible duplicate, settled different; it never asks again; undo asks again")
  func decline() throws {
    var (s, f, h, last) = try Self.seeded()
    var d = OpAuthor(ctx(own: last))
    d.declineSamePurchase(homeID: h, homeVersion: s.txns[h]!.version, foreignID: f)
    let blob = try d.build()
    #expect(blob.ops.map(\.type) == [.txnEdited, .txnDuplicateDisposition])
    try Self.fold(blob.ops, &s, seq: 2)
    let a = try #require(s.txns[h])
    #expect(a.possibleDuplicateOf == f && a.duplicateDisposition == "different")
    #expect(ReviewQueue.lane(a) == nil && a.annotation("archived") == nil && a.amountHomeMinor == 9_300)
    #expect(s.txns[f]?.amountHomeMinor == 9_181)
    #expect(SamePurchase.pairs(s.txns.values.map(Self.row), home: "AED").isEmpty)

    var u = OpAuthor(ctx(own: blob.lastAuthoredMs))
    u.undoDeclineSamePurchase(homeID: h, homeVersion: a.version)
    try Self.fold(try u.build().ops, &s, seq: 3)
    #expect(s.txns[h]?.possibleDuplicateOf == nil && s.txns[h]?.duplicateDisposition == nil)
    #expect(SamePurchase.pairs(s.txns.values.map(Self.row), home: "AED").count == 1)
  }
}
