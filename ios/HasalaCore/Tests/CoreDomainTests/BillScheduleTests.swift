import CoreReplay
import CoreTime
import Testing

@testable import CoreDomain

@Suite("BillScheduleView")
struct BillScheduleTests {
  static func d(_ s: String) -> CivilDate { CivilDate(wire: s)! }

  static func bill(
    unit: String = "month", every: Int64 = 1, anchor: String, start: String, end: String? = nil, mode: String = "fixed",
    amount: Int64 = 5_600, tolerance: Int64? = 200, changes: [BillChange] = [], pauses: [BillPause] = [], createdAt: String? = nil
  ) -> CoreReplay.Bill {
    CoreReplay.Bill(
      name: "Netflix", keys: ["netflix"], direction: "debit", currency: "AED", amountMode: mode, amountMinor: amount,
      toleranceBp: mode == "fixed" ? tolerance : nil, cadence: BillCadence(unit: unit, every: every), anchor: anchor, start: start,
      end: end, source: "manual", status: end == nil ? "active" : "cancelled", changes: changes, pauses: pauses, createdAt: createdAt,
      firstSeq: 1, version: 1)
  }

  static func view(_ b: CoreReplay.Bill) throws -> BillScheduleView { try #require(BillScheduleView(b)) }

  static func wires(_ ds: [CivilDate]) -> [String] { ds.map(\.wire) }

  @Test("monthly dues keep the anchor day, clamped to short months and leap Februaries")
  func monthlyClamp() throws {
    let v = try Self.view(Self.bill(anchor: "2027-10-31", start: "2027-10-31"))
    #expect(
      Self.wires(v.dues(from: Self.d("2027-10-01"), through: Self.d("2028-05-31")))
        == ["2027-10-31", "2027-11-30", "2027-12-31", "2028-01-31", "2028-02-29", "2028-03-31", "2028-04-30", "2028-05-31"])
    #expect(Self.wires(v.dues(from: Self.d("2029-02-01"), through: Self.d("2029-03-01"))) == ["2029-02-28"])
  }

  @Test("dues step back from the anchor to start, and stop at end")
  func startAndEnd() throws {
    let v = try Self.view(Self.bill(anchor: "2026-09-15", start: "2026-06-20", end: "2026-12-15"))
    #expect(
      Self.wires(v.dues(from: Self.d("2026-01-01"), through: Self.d("2027-12-31")))
        == ["2026-07-15", "2026-08-15", "2026-09-15", "2026-10-15", "2026-11-15", "2026-12-15"])
    #expect(v.due(onOrAfter: Self.d("2026-12-16")) == nil)
    #expect(v.due(onOrAfter: Self.d("2026-12-15")) == Self.d("2026-12-15"))
    #expect(v.due(onOrAfter: Self.d("2026-01-01")) == Self.d("2026-07-15"))
    #expect(v.due(before: Self.d("2026-07-15")) == nil)
    #expect(v.due(before: Self.d("2026-07-16")) == Self.d("2026-07-15"))
    #expect(v.due(before: Self.d("2027-06-01")) == Self.d("2026-12-15"))
    #expect(v.due(before: Self.d("2026-12-15")) == Self.d("2026-11-15"))
    #expect(v.dues(from: Self.d("2026-12-16"), through: Self.d("2027-01-31")).isEmpty)
    #expect(v.dues(from: Self.d("2026-10-20"), through: Self.d("2026-10-01")).isEmpty)
  }

  @Test("weekly, daily, yearly and every > 1")
  func cadences() throws {
    let weekly = try Self.view(Self.bill(unit: "week", every: 2, anchor: "2026-10-05", start: "2026-09-01"))
    #expect(
      Self.wires(weekly.dues(from: Self.d("2026-09-01"), through: Self.d("2026-10-31")))
        == ["2026-09-07", "2026-09-21", "2026-10-05", "2026-10-19"])
    let daily = try Self.view(Self.bill(unit: "day", every: 3, anchor: "2026-10-01", start: "2026-10-01"))
    #expect(Self.wires(daily.dues(from: Self.d("2026-10-02"), through: Self.d("2026-10-10"))) == ["2026-10-04", "2026-10-07", "2026-10-10"])
    let yearly = try Self.view(Self.bill(unit: "year", anchor: "2028-02-29", start: "2028-02-29"))
    #expect(
      Self.wires(yearly.dues(from: Self.d("2028-01-01"), through: Self.d("2032-12-31")))
        == ["2028-02-29", "2029-02-28", "2030-02-28", "2031-02-28", "2032-02-29"])
    let quarterly = try Self.view(Self.bill(every: 3, anchor: "2026-11-30", start: "2026-01-01"))
    #expect(
      Self.wires(quarterly.dues(from: Self.d("2026-01-01"), through: Self.d("2027-06-30")))
        == ["2026-02-28", "2026-05-30", "2026-08-30", "2026-11-30", "2027-02-28", "2027-05-30"])
    let biennial = try Self.view(Self.bill(unit: "year", every: 2, anchor: "2027-03-10", start: "2026-01-01"))
    #expect(biennial.due(onOrAfter: Self.d("2026-01-01")) == Self.d("2027-03-10"))
    #expect(biennial.due(onOrAfter: Self.d("2027-03-11")) == Self.d("2029-03-10"))
  }

  @Test("dues agree with the app's former stepping schedule over many shapes")
  func agreesWithReference() throws {
    var seed: UInt64 = 0x9e37_79b9_7f4a_7c15
    func next(_ n: Int) -> Int {
      seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      return Int((seed >> 33) % UInt64(n))
    }
    let base = Self.d("2026-01-01")
    for _ in 0..<400 {
      let unit = ["day", "week", "month", "year"][next(4)]
      let every = 1 + next(unit == "year" ? 3 : 6)
      let anchor = base.adding(days: next(900))!
      let start = base.adding(days: next(900))!
      let end = next(3) == 0 ? start.adding(days: 1 + next(700)) : nil
      let from = base.adding(days: next(1200) - 100)!
      let through = from.adding(days: next(800))!
      let v = try Self.view(
        Self.bill(unit: unit, every: Int64(every), anchor: anchor.wire, start: start.wire, end: end?.wire))
      let want = Self.reference(anchor: anchor, start: start, end: end, unit: unit, every: every, horizon: through)
        .filter { $0 >= from }
      #expect(v.dues(from: from, through: through) == want, "\(unit) \(every) \(anchor) \(start) \(String(describing: end)) \(from) \(through)")
      let probe = base.adding(days: next(1300))!
      let all = Self.reference(anchor: anchor, start: start, end: end, unit: unit, every: every, horizon: probe.adding(days: 2_000)!)
      #expect(v.due(onOrAfter: probe) == all.first { $0 >= probe }, "\(unit) \(every) \(anchor) \(start) \(probe)")
      #expect(v.due(before: probe) == all.last { $0 < probe })
    }
  }

  static func reference(anchor: CivilDate, start: CivilDate, end: CivilDate?, unit: String, every: Int, horizon: CivilDate) -> [CivilDate] {
    func clamp(_ y: Int, _ m: Int, _ day: Int) -> CivilDate {
      CivilDate(year: y, month: m, day: min(day, Civil.daysInMonth(year: Int64(y), month: m)))!
    }
    func due(_ k: Int) -> CivilDate {
      switch unit {
      case "day": return anchor.adding(days: k * every)!
      case "week": return anchor.adding(days: 7 * k * every)!
      case "year": return clamp(anchor.year + k * every, anchor.month, anchor.day)
      default:
        let index = anchor.year * 12 + (anchor.month - 1) + k * every
        return clamp(index / 12, index % 12 + 1, anchor.day)
      }
    }
    var k = 0
    while due(k) > start, k > -2_000 { k -= 1 }
    var out: [CivilDate] = []
    while out.count < 10_000 {
      let d = due(k)
      k += 1
      if d < start { continue }
      if let end, d > end { break }
      if d > horizon { break }
      out.append(d)
    }
    return out
  }

  @Test("terms: the original until the first change, then the last change on or before the due")
  func terms() throws {
    let v = try Self.view(
      Self.bill(
        anchor: "2026-01-06", start: "2026-01-06",
        changes: [
          BillChange(from: "2026-06-06", amountMode: "fixed", amountMinor: 6_300, toleranceBp: 100),
          BillChange(from: "2026-09-06", amountMode: "variable", amountMinor: 7_000),
        ]))
    #expect(v.terms(at: Self.d("2026-05-06")) == BillTerms(variable: false, amountMinor: 5_600, toleranceBp: 200))
    #expect(v.terms(at: Self.d("2026-06-05")) == BillTerms(variable: false, amountMinor: 5_600, toleranceBp: 200))
    #expect(v.terms(at: Self.d("2026-06-06")) == BillTerms(variable: false, amountMinor: 6_300, toleranceBp: 100))
    #expect(v.terms(at: Self.d("2026-08-06")) == BillTerms(variable: false, amountMinor: 6_300, toleranceBp: 100))
    #expect(v.terms(at: Self.d("2026-09-06")) == BillTerms(variable: true, amountMinor: 7_000, toleranceBp: 0))
    let variable = try Self.view(Self.bill(anchor: "2026-01-06", start: "2026-01-06", mode: "variable", amount: 48_915))
    #expect(variable.terms(at: Self.d("2026-03-06")) == BillTerms(variable: true, amountMinor: 48_915, toleranceBp: 0))
  }

  @Test("isPaused: from inclusive, until exclusive, open to the end; openPause is the last range")
  func paused() throws {
    let v = try Self.view(
      Self.bill(
        anchor: "2026-01-06", start: "2026-01-06",
        pauses: [BillPause(from: "2026-02-01", until: "2026-03-06"), BillPause(from: "2026-08-06", until: nil)]))
    #expect(!v.isPaused(Self.d("2026-01-31")))
    #expect(v.isPaused(Self.d("2026-02-01")) && v.isPaused(Self.d("2026-02-06")) && v.isPaused(Self.d("2026-03-05")))
    #expect(!v.isPaused(Self.d("2026-03-06")) && !v.isPaused(Self.d("2026-08-05")))
    #expect(v.isPaused(Self.d("2026-08-06")) && v.isPaused(Self.d("2030-01-01")))
    #expect(v.openPause?.from == Self.d("2026-08-06") && v.openPause?.until == nil)
    let none = try Self.view(Self.bill(anchor: "2026-01-06", start: "2026-01-06"))
    #expect(none.openPause == nil && !none.isPaused(Self.d("2026-02-06")))
  }

  @Test("trackingSince: the later of start and the create's local (+04:00) day; start without createdAt")
  func trackingSince() throws {
    #expect(
      try Self.view(Self.bill(anchor: "2026-01-06", start: "2026-01-06", createdAt: "2026-05-01T21:30:00.000Z")).trackingSince
        == Self.d("2026-05-02"))
    #expect(
      try Self.view(Self.bill(anchor: "2026-01-06", start: "2026-01-06", createdAt: "2026-05-01T19:59:59.999Z")).trackingSince
        == Self.d("2026-05-01"))
    #expect(
      try Self.view(Self.bill(anchor: "2026-01-06", start: "2026-07-06", createdAt: "2026-05-01T08:00:00.000Z")).trackingSince
        == Self.d("2026-07-06"))
    #expect(try Self.view(Self.bill(anchor: "2026-01-06", start: "2026-01-06")).trackingSince == Self.d("2026-01-06"))
  }

  @Test(
    "trackingSince is the fixed +04:00 day whatever the device's zone: 22:30Z is the next day, the boundary is 20:00Z",
    arguments: [
      ("2026-11-05T22:30:00.000Z", "2026-11-06"), ("2026-11-05T20:00:00.000Z", "2026-11-06"),
      ("2026-11-05T19:59:59.999Z", "2026-11-05"), ("2026-11-06T19:59:59.999Z", "2026-11-06"),
    ])
  func trackingSinceIsZoneFree(_ created: String, _ day: String) throws {
    let v = try Self.view(Self.bill(anchor: "2026-01-06", start: "2026-01-06", createdAt: created))
    #expect(v.trackingSince == Self.d(day))
    #expect(LocalClock.localDate(try Instant.parseMs(created)) == Self.d(day))
  }

  @Test("halfWindowDays: monthly 15, weekly 3, daily 0, yearly 30, scaled by every, at most 45")
  func windows() throws {
    func w(_ unit: String, _ every: Int64) throws -> Int {
      try Self.view(Self.bill(unit: unit, every: every, anchor: "2026-01-06", start: "2026-01-06")).halfWindowDays(at: Self.d("2026-02-06"))
    }
    #expect(try w("month", 1) == 15 && w("week", 1) == 3 && w("day", 1) == 0 && w("year", 1) == 30)
    #expect(try w("month", 2) == 30 && w("week", 2) == 6 && w("day", 14) == 7 && w("month", 3) == 45 && w("year", 2) == 45)
  }

  @Test("a date that does not parse gives no view")
  func unparsable() {
    #expect(BillScheduleView(Self.bill(anchor: "2026-02-30", start: "2026-01-06")) == nil)
    #expect(BillScheduleView(Self.bill(anchor: "2026-01-06", start: "x")) == nil)
    #expect(BillScheduleView(Self.bill(anchor: "2026-01-06", start: "2026-01-06", end: "2026-13-01")) == nil)
    #expect(
      BillScheduleView(
        Self.bill(anchor: "2026-01-06", start: "2026-01-06", changes: [BillChange(from: "soon", amountMode: "fixed", amountMinor: 1, toleranceBp: 0)]))
        == nil)
    #expect(BillScheduleView(Self.bill(anchor: "2026-01-06", start: "2026-01-06", pauses: [BillPause(from: "2026-02-01", until: "later")])) == nil)
  }
}
