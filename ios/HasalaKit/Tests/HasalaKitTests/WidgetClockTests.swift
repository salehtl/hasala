import Foundation
import HasalaMocks
import HasalaModels
import HasalaWidgetData
import Testing

@Suite("Widgets · the day a snapshot belongs to")
struct WidgetClockTests {
  func utc(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

  func snapshot(on day: LocalDate) -> WidgetSnapshot {
    let now = LocalDateTime(date: day, hour: 21, minute: 0)
    let s = MayaLedger.state
    return GlanceEngine.snapshot(s, now: now, home: HomeEngine.snapshot(s, now: now), amountsHidden: false)
  }

  @Test func theDayTurnsAtLocalMidnight() {
    #expect(WidgetClock.today(at: utc("2026-10-31T19:59:59Z")) == LocalDate(2026, 10, 31))
    #expect(WidgetClock.today(at: utc("2026-10-31T20:00:00Z")) == LocalDate(2026, 11, 1))
    #expect(WidgetClock.nextMidnight(after: utc("2026-10-31T15:00:00Z")) == utc("2026-10-31T20:00:00Z"))
    #expect(WidgetClock.nextMidnight(after: utc("2026-10-31T20:00:00Z")) == utc("2026-11-01T20:00:00Z"))
  }

  @Test func aSnapshotCarriesItsDay() throws {
    let w = snapshot(on: MayaLedger.now.date)
    #expect(w.asOf == MayaLedger.now.date)
    let data = try WidgetSnapshotStore.encode(w)
    #expect(WidgetSnapshotStore.decode(data) == w)
    var old = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    old["version"] = 1
    old["asOf"] = nil
    #expect(WidgetSnapshotStore.decode(try JSONSerialization.data(withJSONObject: old)) == nil)
  }

  @Test func yesterdaysSnapshotIsStaleInTheMorning() throws {
    let w = snapshot(on: LocalDate(2026, 10, 31))
    #expect(w.spentSoFar?.billWords != nil || w.budgetPace != nil)
    let evening = WidgetReading(w, at: utc("2026-10-31T19:59:00Z"))
    #expect(evening.snapshot == w && !evening.stale)
    let november = WidgetReading(w, at: utc("2026-11-01T05:00:00Z"))
    #expect(november.snapshot == nil && november.stale)
    #expect(november.snapshot?.budgetPace?.monthGone == nil)
    let none = WidgetReading(nil, at: utc("2026-11-01T05:00:00Z"))
    #expect(none.snapshot == nil && !none.stale)
  }
}
