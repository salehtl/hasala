// CoreTime unit tests. The wire timestamp tables (15 accepted, 23 refused)
// run against conformance/op/manifest.json in HasalaCoreConformanceTests.
import Testing

@testable import CoreTime

@Suite("civil arithmetic")
struct CivilTests {
  @Test("days_from_civil and civil_from_days are inverse across 0000-9999 and beyond")
  func roundTrip() {
    var d: Int64 = Civil.daysFromCivil(year: -1, month: 1, day: 1)
    let end = Civil.daysFromCivil(year: 10_001, month: 1, day: 1)
    var previous = Civil.civilFromDays(d - 1)
    var mismatches = 0
    while d < end {
      let c = Civil.civilFromDays(d)
      if Civil.daysFromCivil(year: c.year, month: c.month, day: c.day) != d { mismatches += 1 }
      // Consecutive days are consecutive dates.
      let next =
        c.day == 1
        ? previous.day == Civil.daysInMonth(year: previous.year, month: previous.month)
        : (c.day == previous.day + 1 && c.month == previous.month && c.year == previous.year)
      if !next { mismatches += 1 }
      previous = c
      d += 1
    }
    #expect(mismatches == 0)
  }

  @Test("fixed points: the epoch, Go's zero time, year 0 and the leap rules")
  func fixedPoints() {
    #expect(Civil.daysFromCivil(year: 1970, month: 1, day: 1) == 0)
    #expect(Civil.daysFromCivil(year: 1, month: 1, day: 1) * Civil.msPerDay == Instant.goZeroTimeMs)
    #expect(Civil.daysFromCivil(year: 0, month: 1, day: 1) * Civil.msPerDay == -62_167_219_200_000)
    #expect(Civil.isLeapYear(2000) && Civil.isLeapYear(2024) && !Civil.isLeapYear(1900) && !Civil.isLeapYear(2026))
    #expect(Civil.isLeapYear(0))  // proleptic: year 0 is a leap year
  }

  @Test("utcDay as replay/state.ts writes it, expanded years included")
  func utcDays() {
    #expect(utcDay(0) == "1970-01-01")
    #expect(utcDay(-1) == "1969-12-31")
    #expect(utcDay(86_399_999) == "1970-01-01")
    #expect(utcDay(1_780_653_600_000) == "2026-06-05")
    #expect(utcDay(-62_167_219_200_000) == "0000-01-01")
    #expect(utcDay(253_402_300_800_000) == "+010000-01-01")
    #expect(utcDay(-62_167_219_200_001) == "-000001-12-31")
  }
}

@Suite("instants")
struct InstantTests {
  @Test("parse and canonicalize: UTC, milliseconds, always .sss")
  func canonical() throws {
    #expect(try parseInstantMs("1970-01-01T00:00:00Z") == 0)
    #expect(try canonicalTime("2026-06-05T14:00:00.5+04:00") == "2026-06-05T10:00:00.500Z")
    #expect(try canonicalTime("2026-06-05T10:00:00.0019Z") == "2026-06-05T10:00:00.001Z")  // truncated
    #expect(try canonicalTime("1969-12-31T23:59:59.999Z") == "1969-12-31T23:59:59.999Z")
    #expect(try canonicalTime("0000-01-01T00:00:00Z") == "0000-01-01T00:00:00.000Z")
    #expect(Instant.iso(-1) == "1969-12-31T23:59:59.999Z")
    #expect(Instant.iso(253_402_300_800_000) == nil)
  }

  @Test("refusals name their reason")
  func refusals() {
    #expect(throws: InstantError.outOfRange("day")) { try parseInstantMs("2026-02-29T00:00:00Z") }
    #expect(throws: InstantError.outOfRange("hour")) { try parseInstantMs("2026-06-05T24:00:00Z") }
    #expect(throws: InstantError.outOfRange("offset")) { try parseInstantMs("2026-06-05T10:00:00+24:00") }
    #expect(throws: InstantError.notRFC3339) { try parseInstantMs("2026-06-05t10:00:00z") }
    #expect(throws: InstantError.notRFC3339) { try parseInstantMs("2026-06-05T10:00:00Z\n") }
    #expect(throws: InstantError.notRFC3339) { try parseInstantMs("２026-06-05T10:00:00Z") }
    #expect(throws: InstantError.zeroTime) { try parseInstantMs("0001-01-01T00:00:00Z") }
    #expect(throws: InstantError.outsideFourDigitYears) { try canonicalTime("9999-12-31T23:59:59-23:59") }
  }
}

@Suite("CivilDate, CivilMonth, LocalClock (03c §1.5)")
struct LocalTests {
  @Test("base-05: the CivilDate wire grammar is a real date in 2000-2099")
  func civilDateGrammar() {
    #expect(CivilDate(wire: "2026-02-29") == nil)
    #expect(CivilDate(wire: "2028-02-29")?.wire == "2028-02-29")
    #expect(CivilDate(wire: "1999-12-31") == nil)
    #expect(CivilDate(wire: "2100-01-01") == nil)
    for bad in ["2026-1-01", "2026-01-1", "2026-00-10", "2026-13-01", "2026-04-31", "2026-01-01 ", "2026/01/01", "٢٠٢٦-٠١-٠١"] {
      #expect(CivilDate(wire: bad) == nil)
    }
    #expect(CivilMonth(wire: "2026-10")?.wire == "2026-10")
    #expect(CivilMonth(wire: "1999-12") == nil && CivilMonth(wire: "2026-13") == nil && CivilMonth(wire: "2026-1") == nil)
  }

  @Test("base-06: the local date is the UTC+04:00 civil date")
  func localDate() throws {
    #expect(LocalClock.localDate(try parseInstantMs("2026-09-30T20:00:00.000Z"))?.wire == "2026-10-01")
    #expect(LocalClock.localDate(try parseInstantMs("2026-09-30T19:59:59.999Z"))?.wire == "2026-09-30")
    #expect(LocalClock.localMonth(try parseInstantMs("2026-09-30T20:00:00.000Z"))?.wire == "2026-10")
    let d = CivilDate(wire: "2026-10-01")!
    #expect(LocalClock.startOfDay(d) == (try parseInstantMs("2026-09-30T20:00:00Z")))
    #expect(LocalClock.localDate(LocalClock.startOfDay(d)) == d)
    #expect(LocalClock.localDate(LocalClock.startOfDay(d) - 1) == d.adding(days: -1))
  }

  @Test("month index, month arithmetic and monthsBetween")
  func months() {
    let m = CivilMonth(wire: "2026-01")!
    #expect(m.index == 2026 * 12)
    #expect(m.adding(months: -1)?.wire == "2025-12")
    #expect(m.adding(months: 13)?.wire == "2027-02")
    #expect(CivilMonth(index: m.index) == m)
    #expect(monthsBetween(m, CivilMonth(wire: "2026-10")!) == 9)
    #expect(monthsBetween(CivilMonth(wire: "2026-10")!, m) == -9)
    #expect(CivilMonth(wire: "2028-02")!.daysInMonth == 29 && CivilMonth(wire: "2026-02")!.daysInMonth == 28)
    #expect(CivilMonth(wire: "2026-02")!.lastDay.wire == "2026-02-28")
    #expect(CivilMonth(index: -1) == nil)
  }

  @Test("ISO weekdays, Monday first")
  func weekdays() {
    #expect(CivilDate(year: 1970, month: 1, day: 1)!.isoWeekday == 4)  // Thursday
    #expect(CivilDate(wire: "2026-10-12")!.isoWeekday == 1)  // Monday
    #expect(CivilDate(wire: "2026-10-11")!.isoWeekday == 7)  // Sunday
    #expect(CivilDate(year: 1969, month: 12, day: 29)!.isoWeekday == 1)
  }

  @Test("date ordering and arithmetic")
  func dates() {
    let a = CivilDate(wire: "2026-12-31")!
    #expect(a.adding(days: 1)?.wire == "2027-01-01")
    #expect(a < a.adding(days: 1)!)
    #expect(a.yearMonth.wire == "2026-12")
    #expect(CivilDate(year: 9999, month: 12, day: 31)!.adding(days: 1) == nil)
  }

  @Test("the clock seam: CoreTime.Clock is not Swift.Clock")
  func clockSeam() {
    struct Pinned: CoreTime.Clock { func nowMs() -> Int64 { 1_780_653_600_000 } }
    let c: any CoreTime.Clock = Pinned()
    #expect(LocalClock.localDate(c.nowMs())?.wire == "2026-06-05")
    #expect(SystemClock().nowMs() > 1_780_000_000_000)
  }
}
