import CoreReplay
import CoreTime
import Testing

@testable import CoreDomain

@Suite("BillMatcher")
struct BillMatcherTests {
  static func d(_ s: String) -> CivilDate { CivilDate(wire: s)! }

  static func bill(
    keys: [String] = ["netflix"], currency: String = "AED", unit: String = "month", every: Int64 = 1, anchor: String = "2026-07-06",
    start: String = "2026-07-06", end: String? = nil, status: String? = nil, mode: String = "fixed", amount: Int64 = 5_600,
    tolerance: Int64? = 200, changes: [BillChange] = [], pauses: [BillPause] = [], createdAt: String? = nil, firstSeq: Int64 = 1
  ) -> CoreReplay.Bill {
    CoreReplay.Bill(
      name: "Bill", keys: keys, direction: "debit", currency: currency, amountMode: mode, amountMinor: amount,
      toleranceBp: mode == "fixed" ? tolerance : nil, cadence: BillCadence(unit: unit, every: every), anchor: anchor, start: start,
      end: end, source: "manual", status: status ?? (end == nil ? "active" : "cancelled"), changes: changes, pauses: pauses,
      createdAt: createdAt, firstSeq: firstSeq, version: 1)
  }

  static func row(
    _ id: String, _ day: String, _ amount: Int64 = 5_600, key: String = "netflix", direction: String = "debit", currency: String = "AED",
    home: Int64? = nil, eligible: Bool = true, settles: Bool = true
  ) -> MatchRow {
    MatchRow(
      txnID: id, merchantKey: key, direction: direction, amountMinor: amount, currency: currency, homeMinor: home, day: d(day),
      eligible: eligible, settles: settles)
  }

  @Test("a row that does not settle leaves the due open and yields it to a row that does")
  func aRowThatDoesNotSettle() {
    let b = Self.bill(createdAt: "2026-08-20T10:00:00.000Z")
    let waiting = Self.row("waiting", "2026-10-06", settles: false)
    let alone = Self.run([("a", b)], [waiting], today: "2026-10-08")
    #expect(alone.matches.isEmpty && alone.notices.isEmpty)
    #expect(alone.status(bill: "a", due: Self.d("2026-10-06"), today: Self.d("2026-10-08")) == .late)
    let beside = Self.run([("a", b)], [waiting, Self.row("filed", "2026-10-14")], today: "2026-10-20")
    #expect(beside.status(bill: "a", due: Self.d("2026-10-06"), today: Self.d("2026-10-20")) == .paid(txnID: "filed", explicit: false))
  }

  @Test("the person's link settles a due with a row that does not settle by itself")
  func anExplicitLinkStays() {
    let b = Self.bill(createdAt: "2026-08-20T10:00:00.000Z")
    let r = Self.run(
      [("a", b)], [Self.row("waiting", "2026-10-06", settles: false)],
      resolutions: [BillResolution(bill: "a", due: "2026-10-06", resolution: "paid", txn: "waiting", atSeq: 1)], today: "2026-10-08")
    #expect(r.status(bill: "a", due: Self.d("2026-10-06"), today: Self.d("2026-10-08")) == .paid(txnID: "waiting", explicit: true))
  }

  @Test("a row that does not settle is still offered for the link")
  func stillOffered() {
    let terms = BillTerms(variable: false, amountMinor: 5_600, toleranceBp: 200)
    let rows = BillMatcher.suggestions(
      keys: ["netflix"], terms: terms, currency: "AED", rows: [Self.row("waiting", "2026-10-06", settles: false)], taken: [], limit: 5)
    #expect(rows.map(\.txnID) == ["waiting"])
  }

  static func run(
    _ bills: [(String, CoreReplay.Bill)], _ rows: [MatchRow], resolutions: [BillResolution] = [], today: String = "2026-10-20"
  ) -> BillMatcherResult {
    BillMatcher.run(bills: bills.map { BillMatchInput(id: $0.0, bill: $0.1) }, resolutions: resolutions, rows: rows, today: d(today))
  }

  static func pairs(_ r: BillMatcherResult) -> [String] {
    r.matches.map { "\($0.bill) \($0.due.wire) \($0.txnID)\($0.explicit ? " explicit" : "")" }
  }

  @Test("each row pays its nearest due, and status reads paid, late, due, upcoming and not tracked")
  func basic() {
    let b = Self.bill(createdAt: "2026-08-20T10:00:00.000Z")
    let r = Self.run(
      [("b1", b)],
      [Self.row("t1", "2026-07-07"), Self.row("t2", "2026-08-04"), Self.row("t3", "2026-10-06"), Self.row("t4", "2026-10-30")])
    #expect(Self.pairs(r) == ["b1 2026-07-06 t1", "b1 2026-08-06 t2", "b1 2026-10-06 t3", "b1 2026-11-06 t4"])
    let today = Self.d("2026-10-20")
    #expect(r.status(bill: "b1", due: Self.d("2026-07-06"), today: today) == .paid(txnID: "t1", explicit: false))
    #expect(r.matches.allSatisfy { !$0.explicit })
    #expect(r.notices.isEmpty)

    let unpaid = Self.run([("b1", b)], [], today: "2026-10-06")
    #expect(unpaid.status(bill: "b1", due: Self.d("2026-08-06"), today: Self.d("2026-10-06")) == .notTracked)
    #expect(unpaid.status(bill: "b1", due: Self.d("2026-09-06"), today: Self.d("2026-10-06")) == .late)
    #expect(unpaid.status(bill: "b1", due: Self.d("2026-10-06"), today: Self.d("2026-10-06")) == .due)
    #expect(unpaid.status(bill: "b1", due: Self.d("2026-11-06"), today: Self.d("2026-10-06")) == .upcoming)
  }

  @Test("rows outside every window stay unmatched, and a row midway between dues goes to the earlier one")
  func windowsAndTies() {
    let b = Self.bill(anchor: "2027-01-28", start: "2027-01-28")
    let r = Self.run([("b1", b)], [Self.row("mid", "2027-03-14")])
    #expect(Self.pairs(r) == ["b1 2027-02-28 mid"])
    let monthly = Self.bill()
    let far = Self.run([("b1", monthly)], [Self.row("t1", "2026-07-22"), Self.row("t2", "2026-07-21"), Self.row("t0", "2026-06-01")])
    #expect(Self.pairs(far) == ["b1 2026-07-06 t2", "b1 2026-08-06 t1"])
    let weekly = Self.bill(unit: "week", anchor: "2026-10-05", start: "2026-10-05", amount: 2_000)
    let w = Self.run(
      [("w", weekly)], [Self.row("a", "2026-10-08", 2_000), Self.row("b", "2026-10-16", 2_000), Self.row("c", "2026-10-20", 2_000)])
    #expect(Self.pairs(w) == ["w 2026-10-05 a", "w 2026-10-19 c"])
  }

  @Test("a 31st anchor matches the clamped end of February, also in a leap year")
  func shortMonths() {
    let b = Self.bill(anchor: "2027-01-31", start: "2027-01-31")
    let r = Self.run(
      [("b1", b)], [Self.row("feb27", "2027-02-26"), Self.row("feb28", "2028-02-29"), Self.row("mar", "2028-03-30")])
    #expect(Self.pairs(r) == ["b1 2027-02-28 feb27", "b1 2028-02-29 feb28", "b1 2028-03-31 mar"])
  }

  @Test("two charges in one cycle: the nearer one pays the due, the other stays free")
  func twoInOneCycle() {
    let r = Self.run([("b1", Self.bill())], [Self.row("early", "2026-10-01"), Self.row("near", "2026-10-07")])
    #expect(Self.pairs(r) == ["b1 2026-10-06 near"])
    let both = Self.run([("b1", Self.bill())], [Self.row("x", "2026-10-05"), Self.row("y", "2026-10-08")])
    #expect(Self.pairs(both) == ["b1 2026-10-06 x"])
  }

  @Test("refunds, credits, archived rows and other keys never match")
  func ineligible() {
    let r = Self.run(
      [("b1", Self.bill())],
      [
        Self.row("credit", "2026-10-06", direction: "credit"), Self.row("archived", "2026-10-06", eligible: false),
        Self.row("refund", "2026-10-06", -5_600), Self.row("zero", "2026-10-06", 0), Self.row("other", "2026-10-06", key: "spotify"),
      ])
    #expect(r.matches.isEmpty)
    #expect(r.notices.isEmpty)
  }

  @Test("a foreign charge matches an AED bill by its home amount only")
  func foreignCurrency() {
    let r = Self.run(
      [("b1", Self.bill())],
      [Self.row("usd", "2026-10-06", 1_525, currency: "USD", home: 5_600), Self.row("nohome", "2026-11-06", 1_525, currency: "USD")])
    #expect(Self.pairs(r) == ["b1 2026-10-06 usd"])
    let usdBill = Self.bill(currency: "USD", amount: 1_525)
    let u = Self.run(
      [("u", usdBill)],
      [Self.row("aed", "2026-10-06", 5_600, home: 5_600), Self.row("usd", "2026-11-06", 1_525, currency: "USD", home: 5_600)])
    #expect(Self.pairs(u) == ["u 2026-11-06 usd"])
  }

  @Test("weekly and yearly bills")
  func cadences() {
    let weekly = Self.bill(keys: ["gym"], unit: "week", every: 2, anchor: "2026-09-07", start: "2026-09-07", amount: 10_000)
    let w = Self.run(
      [("g", weekly)],
      [
        Self.row("a", "2026-09-08", 10_000, key: "gym"), Self.row("b", "2026-09-19", 10_000, key: "gym"),
        Self.row("c", "2026-09-25", 10_000, key: "gym"),
      ])
    #expect(Self.pairs(w) == ["g 2026-09-07 a", "g 2026-09-21 b"])
    let yearly = Self.bill(keys: ["icloud"], unit: "year", anchor: "2024-02-29", start: "2024-02-29", amount: 39_900)
    let y = Self.run(
      [("y", yearly)],
      [
        Self.row("a", "2025-03-20", 39_900, key: "icloud"), Self.row("b", "2026-04-15", 39_900, key: "icloud"),
        Self.row("c", "2028-02-01", 39_900, key: "icloud"),
      ])
    #expect(Self.pairs(y) == ["y 2025-02-28 a", "y 2028-02-29 c"])
  }

  @Test("a charge outside a fixed bill's tolerance proposes a price change; one at the new price after a change does not")
  func priceChange() {
    let b = Self.bill(changes: [BillChange(from: "2026-11-06", amountMode: "fixed", amountMinor: 6_300, toleranceBp: 200)])
    let r = Self.run(
      [("b1", b)],
      [
        Self.row("ok", "2026-09-06", 5_650), Self.row("new", "2026-10-06", 6_300), Self.row("after", "2026-11-06", 6_300),
        Self.row("again", "2026-12-06", 5_600),
      ])
    #expect(Self.pairs(r) == ["b1 2026-09-06 ok", "b1 2026-10-06 new", "b1 2026-11-06 after", "b1 2026-12-06 again"])
    #expect(
      r.notices == [
        BillNoticeCore(bill: "b1", txnID: "again", kind: .priceChange(due: Self.d("2026-12-06"), usualMinor: 6_300, chargedMinor: 5_600)),
        BillNoticeCore(bill: "b1", txnID: "new", kind: .priceChange(due: Self.d("2026-10-06"), usualMinor: 5_600, chargedMinor: 6_300)),
      ])
    let far = Self.run([("b1", b)], [Self.row("double", "2026-10-06", 11_300), Self.row("half", "2026-09-06", 2_700)])
    #expect(far.matches.isEmpty)
  }

  @Test("a variable bill matches within 50% and never proposes a price change")
  func variable() {
    let b = Self.bill(keys: ["dewa"], mode: "variable", amount: 40_000)
    let r = Self.run(
      [("v", b)],
      [
        Self.row("lo", "2026-08-06", 20_000, key: "dewa"), Self.row("hi", "2026-09-06", 60_000, key: "dewa"),
        Self.row("out", "2026-10-06", 60_001, key: "dewa"), Self.row("in", "2026-07-06", 19_999, key: "dewa"),
      ])
    #expect(Self.pairs(r) == ["v 2026-08-06 lo", "v 2026-09-06 hi"])
    #expect(r.notices.isEmpty)
  }

  @Test("paused dues read paused; a charge on one pays it and raises charged while paused")
  func pauses() {
    let b = Self.bill(pauses: [BillPause(from: "2026-08-01", until: "2026-09-10"), BillPause(from: "2026-11-01")])
    let r = Self.run([("b1", b)], [Self.row("p", "2026-08-05"), Self.row("q", "2026-12-07")])
    #expect(Self.pairs(r) == ["b1 2026-08-06 p", "b1 2026-12-06 q"])
    #expect(
      r.notices == [
        BillNoticeCore(bill: "b1", txnID: "p", kind: .chargedWhilePaused(due: Self.d("2026-08-06"))),
        BillNoticeCore(bill: "b1", txnID: "q", kind: .chargedWhilePaused(due: Self.d("2026-12-06"))),
      ])
    let today = Self.d("2026-10-20")
    #expect(r.status(bill: "b1", due: Self.d("2026-08-06"), today: today) == .paid(txnID: "p", explicit: false))
    #expect(r.status(bill: "b1", due: Self.d("2026-09-06"), today: today) == .paused)
    #expect(r.status(bill: "b1", due: Self.d("2026-10-06"), today: today) == .late)
    #expect(r.status(bill: "b1", due: Self.d("2026-11-06"), today: today) == .paused)
    #expect(r.status(bill: "b1", due: Self.d("2027-05-06"), today: today) == .paused)
  }

  @Test("an ended bill matches only dues up to end, and a later charge raises charged after end")
  func ended() {
    let b = Self.bill(end: "2026-09-06")
    let r = Self.run(
      [("b1", b)],
      [Self.row("last", "2026-09-08"), Self.row("after", "2026-10-07", 5_900), Self.row("late", "2026-10-22"), Self.row("way", "2026-12-06")])
    #expect(Self.pairs(r) == ["b1 2026-09-06 last"])
    #expect(r.notices == [BillNoticeCore(bill: "b1", txnID: "after", kind: .chargedAfterEnd(day: Self.d("2026-10-07"), chargedMinor: 5_900))])
    let edge = Self.run([("b1", b)], [Self.row("edge", "2026-10-21")])
    #expect(edge.notices == [BillNoticeCore(bill: "b1", txnID: "edge", kind: .chargedAfterEnd(day: Self.d("2026-10-21"), chargedMinor: 5_600))])
    let other = Self.run([("b1", b), ("b2", Self.bill(firstSeq: 2))], [Self.row("after", "2026-10-07")])
    #expect(Self.pairs(other) == ["b2 2026-10-06 after"])
    #expect(other.notices.isEmpty)
  }

  @Test("dismissed bills never match and raise nothing")
  func dismissed() {
    let r = Self.run([("b1", Self.bill(status: "dismissed")), ("b2", Self.bill(end: "2026-09-06", status: "dismissed"))], [
      Self.row("t", "2026-10-06")
    ])
    #expect(r.matches.isEmpty)
    #expect(r.notices.isEmpty)
  }

  @Test("explicit resolutions win over derived matches")
  func explicitWins() {
    let res = [
      BillResolution(bill: "b1", due: "2026-08-06", resolution: "paid", txn: "chosen", atSeq: 10),
      BillResolution(bill: "b1", due: "2026-09-06", resolution: "skipped", atSeq: 11),
      BillResolution(bill: "b1", due: "2026-10-06", resolution: "snoozed", until: "2026-10-25", atSeq: 12),
      BillResolution(bill: "b1", due: "2026-07-06", resolution: "paid", atSeq: 13),
      BillResolution(bill: "b1", due: "2026-11-06", resolution: "skipped", atSeq: 14),
      BillResolution(bill: "b1", due: "2026-11-06", resolution: "clear", atSeq: 15),
    ]
    let r = Self.run(
      [("b1", Self.bill())],
      [
        Self.row("chosen", "2026-09-05"), Self.row("near8", "2026-08-06"), Self.row("near9", "2026-09-06"), Self.row("near10", "2026-10-06"),
        Self.row("near11", "2026-11-06"),
      ], resolutions: res)
    #expect(Self.pairs(r) == ["b1 2026-08-06 chosen explicit", "b1 2026-11-06 near11"])
    let today = Self.d("2026-10-20")
    #expect(r.status(bill: "b1", due: Self.d("2026-07-06"), today: today) == .paid(txnID: nil, explicit: true))
    #expect(r.status(bill: "b1", due: Self.d("2026-08-06"), today: today) == .paid(txnID: "chosen", explicit: true))
    #expect(r.status(bill: "b1", due: Self.d("2026-09-06"), today: today) == .skipped)
    #expect(r.status(bill: "b1", due: Self.d("2026-10-06"), today: today) == .snoozed(until: Self.d("2026-10-25")))
    #expect(r.status(bill: "b1", due: Self.d("2026-11-06"), today: today) == .paid(txnID: "near11", explicit: false))
    let otherBill = Self.run(
      [("b1", Self.bill()), ("b2", Self.bill(firstSeq: 2))], [Self.row("chosen", "2026-08-06")],
      resolutions: [BillResolution(bill: "b1", due: "2026-08-06", resolution: "paid", txn: "chosen", atSeq: 1)])
    #expect(Self.pairs(otherBill) == ["b1 2026-08-06 chosen explicit"])
  }

  @Test("an explicit link at another price proposes a price change; an archived linked row does not")
  func explicitPrice() {
    let res = [
      BillResolution(bill: "b1", due: "2026-08-06", resolution: "paid", txn: "linked", atSeq: 1),
      BillResolution(bill: "b1", due: "2026-09-06", resolution: "paid", txn: "gone", atSeq: 2),
    ]
    let r = Self.run(
      [("b1", Self.bill())], [Self.row("linked", "2026-08-06", 6_300), Self.row("gone", "2026-09-06", 6_300, eligible: false)],
      resolutions: res)
    #expect(Self.pairs(r) == ["b1 2026-08-06 linked explicit", "b1 2026-09-06 gone explicit"])
    #expect(r.notices == [BillNoticeCore(bill: "b1", txnID: "linked", kind: .priceChange(due: Self.d("2026-08-06"), usualMinor: 5_600, chargedMinor: 6_300))])
  }

  @Test("two bills with one key: closest amount first, then the older bill")
  func sharedKey() {
    let mobile = Self.bill(keys: ["etisalat"], amount: 15_000, tolerance: 500, firstSeq: 5)
    let home = Self.bill(keys: ["etisalat"], anchor: "2026-07-08", start: "2026-07-08", amount: 38_900, tolerance: 500, firstSeq: 9)
    let r = Self.run(
      [("home", home), ("mobile", mobile)],
      [Self.row("m", "2026-10-07", 15_000, key: "etisalat"), Self.row("h", "2026-10-06", 38_900, key: "etisalat")])
    #expect(Self.pairs(r) == ["mobile 2026-10-06 m", "home 2026-10-08 h"])
    let twin = Self.run(
      [("newer", Self.bill(firstSeq: 7)), ("older", Self.bill(firstSeq: 3))], [Self.row("a", "2026-10-06"), Self.row("b", "2026-10-07")])
    #expect(Self.pairs(twin) == ["older 2026-10-06 a"])
  }

  @Test("the result does not depend on the order of bills, resolutions or rows")
  func orderIndependent() {
    let bills: [(String, CoreReplay.Bill)] = [
      ("a", Self.bill(changes: [BillChange(from: "2026-09-06", amountMode: "fixed", amountMinor: 6_300, toleranceBp: 200)], firstSeq: 1)),
      ("b", Self.bill(keys: ["netflix", "nflx"], amount: 6_000, tolerance: 1_000, firstSeq: 2)),
      ("c", Self.bill(keys: ["gym"], unit: "week", anchor: "2026-07-01", start: "2026-07-01", amount: 10_000, firstSeq: 3)),
      ("d", Self.bill(keys: ["dewa"], end: "2026-09-06", mode: "variable", amount: 40_000, firstSeq: 4)),
      ("e", Self.bill(keys: ["gym"], amount: 10_000, pauses: [BillPause(from: "2026-08-01", until: "2026-09-01")], firstSeq: 4)),
    ]
    var rows: [MatchRow] = []
    var seed: UInt64 = 0x2545_f491_4f6c_dd1d
    func next(_ n: Int) -> Int {
      seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      return Int((seed >> 33) % UInt64(n))
    }
    let keys = ["netflix", "nflx", "gym", "dewa", "other"]
    let amounts: [Int64] = [5_600, 6_000, 6_300, 10_000, 40_000, 9_900]
    let base = Self.d("2026-07-01")
    for i in 0..<120 {
      let day = base.adding(days: next(150))!
      rows.append(
        MatchRow(
          txnID: "t\(i)", merchantKey: keys[next(keys.count)], direction: next(10) == 0 ? "credit" : "debit",
          amountMinor: amounts[next(amounts.count)], currency: "AED", homeMinor: nil, day: day, eligible: next(12) != 0, settles: true))
    }
    let res = [
      BillResolution(bill: "a", due: "2026-08-06", resolution: "paid", txn: "t3", atSeq: 1),
      BillResolution(bill: "c", due: "2026-07-15", resolution: "skipped", atSeq: 2),
    ]
    let reference = Self.run(bills, rows, resolutions: res)
    #expect(!reference.matches.isEmpty)
    var shuffledRows = rows
    var shuffledBills = bills
    for _ in 0..<20 {
      for i in stride(from: shuffledRows.count - 1, to: 0, by: -1) { shuffledRows.swapAt(i, next(i + 1)) }
      for i in stride(from: shuffledBills.count - 1, to: 0, by: -1) { shuffledBills.swapAt(i, next(i + 1)) }
      let r = Self.run(shuffledBills, shuffledRows, resolutions: next(2) == 0 ? res : res.reversed())
      #expect(r.matches == reference.matches)
      #expect(r.notices == reference.notices)
    }
  }

  @Test("huge amounts do not trap")
  func overflow() {
    let b = Self.bill(amount: Int64.max, tolerance: 5_000)
    let r = Self.run([("b1", b)], [Self.row("max", "2026-10-06", Int64.max), Self.row("one", "2026-11-06", 1)])
    #expect(Self.pairs(r) == ["b1 2026-10-06 max"])
    #expect(BillMatcher.within(Int64.max, 1, bp: 5_000) == false)
    #expect(BillMatcher.within(1, Int64.max, bp: 10_000) == true)
  }

  @Test("suggestions: same key, within the terms, in the currency, not taken, newest first, limited")
  func suggestions() {
    let rows = [
      Self.row("old", "2026-07-06"), Self.row("mid", "2026-08-06", 5_700), Self.row("new", "2026-09-06"),
      Self.row("taken", "2026-10-06"), Self.row("far", "2026-10-07", 6_300), Self.row("usd", "2026-10-08", 1_525, currency: "USD", home: 5_600),
      Self.row("usdNoHome", "2026-10-09", 1_525, currency: "USD"), Self.row("archived", "2026-10-10", eligible: false),
      Self.row("credit", "2026-10-11", direction: "credit"), Self.row("alias", "2026-09-06", key: "nflx"),
      Self.row("spotify", "2026-10-12", key: "spotify"),
    ]
    let fixed = BillTerms(variable: false, amountMinor: 5_600, toleranceBp: 200)
    let got = BillMatcher.suggestions(keys: ["netflix", "nflx"], terms: fixed, currency: "AED", rows: rows, taken: ["taken"], limit: 10)
    #expect(got.map(\.txnID) == ["usd", "alias", "new", "mid", "old"])
    let limited = BillMatcher.suggestions(keys: ["netflix", "nflx"], terms: fixed, currency: "AED", rows: rows, taken: ["taken"], limit: 2)
    #expect(limited.map(\.txnID) == ["usd", "alias"])
    #expect(BillMatcher.suggestions(keys: ["netflix"], terms: fixed, currency: "AED", rows: rows, taken: [], limit: 0).isEmpty)
    let variable = BillTerms(variable: true, amountMinor: 5_600, toleranceBp: 0)
    let loose = BillMatcher.suggestions(keys: ["netflix"], terms: variable, currency: "AED", rows: rows, taken: [], limit: 10)
    #expect(loose.map(\.txnID) == ["usd", "far", "taken", "new", "mid", "old"])
  }
}
