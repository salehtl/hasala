import CoreDomain
import Foundation
import HasalaMocks
import HasalaModels
import Synchronization
import Testing

@testable import Hasala

@Suite("Backlog sort")
struct BacklogSorterTests {
  nonisolated static let start: Int64 = 1_800_000_000_000

  nonisolated final class Saved: Sendable {
    let record: Mutex<BacklogRunRecord>
    let saves = Mutex(0)

    init(_ record: BacklogRunRecord = BacklogRunRecord()) {
      self.record = Mutex(record)
    }

    static func running(day: [Int64] = [], lastPassMs: Int64? = nil) -> Saved {
      Saved(BacklogRunRecord(run: BacklogRunRecord.Run(), day: day, lastPassMs: lastPassMs))
    }

    static func paused(_ reason: BacklogRunRecord.Reason, untilMs: Int64? = nil, day: [Int64] = []) -> Saved {
      Saved(BacklogRunRecord(run: BacklogRunRecord.Run(phase: .paused, reason: reason, untilMs: untilMs), day: day))
    }

    static func ended(_ reason: BacklogRunRecord.Reason?) -> Saved {
      Saved(BacklogRunRecord(run: BacklogRunRecord.Run(phase: .done, reason: reason)))
    }

    var store: BacklogSorter.Store {
      BacklogSorter.Store(
        load: { self.record.withLock { $0 } },
        save: { r in
          self.record.withLock { $0 = r }
          self.saves.withLock { $0 += 1 }
        })
    }

    var value: BacklogRunRecord { record.withLock { $0 } }
    var run: BacklogRunRecord.Run? { value.run }
  }

  nonisolated struct Step: Sendable {
    var pending: Int
    var calls: Int
    var stop: BacklogSort.Stop?
    var filed: [String: Int64] = [:]
    var suggested: Set<String> = []
    var settled = 0
  }

  nonisolated final class Script: Sendable {
    let steps: Mutex<[Step?]>
    let seen = Mutex<[(asked: Int, dayLeft: Int)]>([])

    init(_ steps: [Step?]) {
      self.steps = Mutex(steps)
    }

    convenience init(_ steps: [(pending: Int, calls: Int, stop: BacklogSort.Stop?)?]) {
      self.init(steps.map { $0.map { Step(pending: $0.pending, calls: $0.calls, stop: $0.stop, settled: $0.calls) } })
    }

    func run(_ memo: BacklogSort.Memo, _ dayLeft: Int) async -> BacklogSorter.PassResult? {
      let n = seen.withLock { s in
        s.append((memo.asked.count, dayLeft))
        return s.count
      }
      let next = steps.withLock { s -> Step?? in s.isEmpty ? .none : .some(s.removeFirst()) }
      guard case .some(let maybe) = next, let step = maybe else { return nil }
      var m = memo
      for i in 0..<step.calls { m.asked.insert("pass\(n)-name\(i)") }
      return BacklogSorter.PassResult(
        pass: BacklogSort.Pass(
          suggestions: [], memo: m, pending: step.pending, calls: step.calls, stop: step.stop, settled: step.settled),
        filing: BacklogSort.Filing(filed: step.filed, suggested: step.suggested))
    }

    var passes: Int { seen.withLock { $0.count } }
    var memos: [Int] { seen.withLock { $0.map(\.asked) } }
    var dayLefts: [Int] { seen.withLock { $0.map(\.dayLeft) } }
  }

  nonisolated final class Sleeps: Sendable {
    let log = Mutex<[Duration]>([])
    var all: [Duration] { log.withLock { $0 } }
    var sleep: @Sendable (Duration) async -> Void {
      { d in
        self.log.withLock { $0.append(d) }
        try? await Task.sleep(for: .milliseconds(2))
      }
    }
  }

  nonisolated final class Net: NetworkWatching {
    let state = Mutex<(online: Bool, changed: (@Sendable () -> Void)?)>((true, nil))

    init(online: Bool = true) { state.withLock { $0.online = online } }

    var isOnline: Bool { state.withLock { $0.online } }
    func start(_ changed: @escaping @Sendable () -> Void) { state.withLock { $0.changed = changed } }
    func cancel() { state.withLock { $0.changed = nil } }

    func set(_ online: Bool) {
      let f = state.withLock { s in
        s.online = online
        return s.changed
      }
      f?()
    }
  }

  nonisolated final class Clock: Sendable {
    let ms: Mutex<Int64>
    init(_ ms: Int64 = BacklogSorterTests.start) { self.ms = Mutex(ms) }
    var now: @Sendable () -> Int64 { { self.ms.withLock { $0 } } }
    func advance(_ by: Int64) { ms.withLock { $0 += by } }
  }

  nonisolated final class Flag: Sendable {
    let on: Mutex<Bool>
    init(_ on: Bool = true) { self.on = Mutex(on) }
    var value: Bool { on.withLock { $0 } }
    func set(_ v: Bool) { on.withLock { $0 = v } }
  }

  nonisolated final class Asked: Sendable {
    let memos = Mutex<[Int]>([])
    var all: [Int] { memos.withLock { $0 } }
  }

  func sorter(
    _ script: Script, _ saved: Saved, sleeps: Sleeps = Sleeps(), active: Flag = Flag(), importing: Bool = false,
    clock: Clock = Clock(), enabled: Flag = Flag(), network: Net = Net(), waiting: Flag = Flag(), asked: Asked = Asked()
  ) -> BacklogSorter {
    BacklogSorter(
      pass: { await script.run($0, $1) },
      waiting: { memo in
        asked.memos.withLock { $0.append(memo.asked.count) }
        return waiting.value
      }, store: saved.store, nowMs: clock.now, appActive: { active.value }, importRunning: { importing }, enabled: { enabled.value },
      network: network, sleep: sleeps.sleep)
  }

  func waitFor(_ condition: @Sendable () async -> Bool) async {
    for _ in 0..<400 {
      if await condition() { return }
      try? await Task.sleep(for: .milliseconds(5))
    }
  }

  @Test func aRunStartsByItselfOnOpenWithTheSwitchOnAndNamesWaiting() async {
    let saved = Saved()
    let script = Script([
      Step(pending: 2, calls: 12, stop: nil, filed: ["a": 2, "b": 3], suggested: ["c"], settled: 11),
      Step(pending: 0, calls: 2, stop: nil, filed: ["d": 4], settled: 2),
    ])
    let s = sorter(script, saved)
    await s.ensure(retry: true)
    await s.finished()
    #expect(script.passes == 2)
    #expect(saved.run?.phase == .done && saved.run?.reason == nil && !saved.value.isActive)
    #expect(saved.value.filedHere == ["a": 2, "b": 3, "d": 4] && saved.value.day.count == 14)
    #expect(saved.value.lastPassMs == BacklogSorterTests.start)
  }

  @Test func nothingStartsWithTheSwitchOffOrWithNothingWaiting() async {
    let saved = Saved()
    let script = Script([(0, 1, nil)])
    let enabled = Flag(false)
    let waiting = Flag(false)
    let asked = Asked()
    let s = sorter(script, saved, enabled: enabled, waiting: waiting, asked: asked)
    await s.ensure(retry: true)
    #expect(saved.run == nil && asked.all.isEmpty && script.passes == 0 && saved.saves.withLock { $0 } == 0)
    enabled.set(true)
    await s.ensure()
    #expect(saved.run == nil && asked.all == [0] && script.passes == 0)
    waiting.set(true)
    await s.ensure()
    await s.finished()
    #expect(script.passes == 1 && saved.run?.phase == .done)
  }

  @Test func itRunsPassesUntilNothingIsLeftThenEnds() async {
    let saved = Saved.running()
    let script = Script([(2, 10, nil), (1, 10, nil), (0, 3, nil)])
    let sleeps = Sleeps()
    let s = sorter(script, saved, sleeps: sleeps)
    await s.ensure()
    await s.finished()
    #expect(script.passes == 3)
    #expect(script.memos == [0, 10, 20])
    #expect(saved.run?.phase == .done && saved.run?.reason == nil && saved.value.day.count == 23)
    #expect(sleeps.all.count == 2)
    #expect(sleeps.all.allSatisfy { $0 == .milliseconds(BacklogSort.passSpacingMs) })
    #expect(await !s.isRunning)
  }

  @Test func theMemoCarriesAcrossRunsUntilTheNextOpen() async {
    let saved = Saved()
    let script = Script([(0, 3, nil), (0, 2, nil), (0, 1, nil)])
    let asked = Asked()
    let s = sorter(script, saved, asked: asked)
    await s.ensure(retry: true)
    await s.finished()
    await s.ensure()
    await s.finished()
    #expect(script.memos == [0, 3] && asked.all == [0, 3])
    let next = sorter(script, saved, asked: asked)
    await next.ensure(retry: true)
    await next.finished()
    #expect(script.memos == [0, 3, 0] && asked.all == [0, 3, 0])
  }

  @Test func ensureDoesNotRestartAPausedRun() async {
    let until = BacklogSorterTests.start + 60_000
    for saved in [Saved.paused(.busy, untilMs: until), Saved.paused(.rateLimited, untilMs: until)] {
      let script = Script([(0, 1, nil)])
      let asked = Asked()
      let s = sorter(script, saved, asked: asked)
      await s.ensure(retry: true)
      await s.ensure()
      #expect(await !s.isRunning && script.passes == 0 && asked.all.isEmpty)
      #expect(saved.run?.phase == .paused && saved.run?.untilMs == until)
    }
  }

  @Test func threeFailedPassesEndTheRunAndItIsTriedAgainAtTheNextOpenOnly() async {
    let saved = Saved()
    let script = Script([(4, 10, nil), nil, nil, nil, (0, 2, nil)])
    let asked = Asked()
    let s = sorter(script, saved, asked: asked)
    await s.ensure(retry: true)
    await s.finished()
    #expect(script.passes == 1 + BacklogSorter.maxFailures)
    #expect(saved.run?.phase == .done && saved.run?.reason == .failed && saved.value.day.count == 10)
    #expect(!s.activity.isActive && !saved.value.isActive)
    let status = LiveCloudSortController.status(snapshot: await s.snapshot, view: CloudSortStatusTests.view(9), enabled: true)
    #expect(status.phase == .done && status.pendingTxnIDs.isEmpty)
    for _ in 0..<3 {
      await s.ensure()
      #expect(await !s.isRunning)
    }
    #expect(script.passes == 4 && asked.all.count == 1 && saved.run?.reason == .failed)
    let reopened = sorter(script, saved)
    await reopened.ensure(retry: true)
    await reopened.finished()
    #expect(script.passes == 5 && saved.run?.phase == .done && saved.run?.reason == nil)
  }

  @Test func aRunResumesAfterARelaunch() async {
    let saved = Saved.running()
    let next = Script([(0, 2, nil)])
    let t = sorter(next, saved)
    #expect(await t.snapshot.record == saved.value)
    await t.ensure(retry: true)
    await t.finished()
    #expect(next.passes == 1 && saved.run?.phase == .done)
  }

  @Test func theSpacingHoldsAcrossARestart() async {
    let saved = Saved.running(lastPassMs: BacklogSorterTests.start - 10_000)
    let script = Script([(0, 1, nil)])
    let sleeps = Sleeps()
    let s = sorter(script, saved, sleeps: sleeps)
    await s.ensure(retry: true)
    await s.finished()
    #expect(sleeps.all == [.seconds(20)] && script.passes == 1)
    #expect(saved.value.lastPassMs == BacklogSorterTests.start)

    let fresh = Saved(BacklogRunRecord(lastPassMs: BacklogSorterTests.start - 10_000))
    let again = Script([(0, 1, nil)])
    let restSleeps = Sleeps()
    let t = sorter(again, fresh, sleeps: restSleeps)
    await t.ensure(retry: true)
    await t.finished()
    #expect(restSleeps.all == [.seconds(20)] && again.passes == 1)

    let old = Saved.running(lastPassMs: BacklogSorterTests.start - 45_000)
    let noRest = Sleeps()
    let u = sorter(Script([(0, 1, nil)]), old, sleeps: noRest)
    await u.ensure(retry: true)
    await u.finished()
    #expect(noRest.all.isEmpty)

    let ahead = Saved.running(lastPassMs: BacklogSorterTests.start + 3_600_000)
    let capped = Sleeps()
    let v = sorter(Script([(0, 1, nil)]), ahead, sleeps: capped)
    await v.ensure(retry: true)
    await v.finished()
    #expect(capped.all == [.milliseconds(BacklogSort.passSpacingMs)])
  }

  @Test func aFailedPassStillCountsItsRequestsAgainstTheDay() async {
    let saved = Saved()
    let script = Script([Step(pending: 3, calls: 4, stop: nil, filed: ["a": 2]), nil, nil])
    let failing = BacklogSorter(
      pass: { memo, left in
        guard var r = await script.run(memo, left) else { return nil }
        r.pass = .failed(r.pass.memo, calls: r.pass.calls)
        return r
      }, store: saved.store, nowMs: Clock().now, appActive: { true }, importRunning: { false }, enabled: { true }, network: Net(),
      sleep: Sleeps().sleep)
    await failing.ensure(retry: true)
    await failing.finished()
    #expect(saved.value.day.count == 4 && saved.run?.reason == .failed)
    #expect(saved.value.filedHere == ["a": 2])
  }

  @Test func theForegroundSweepSharesTheDayLedgerAndStopsAtTheCaps() async {
    let clock = Clock()
    let saved = Saved(BacklogRunRecord(day: Array(repeating: BacklogSorterTests.start - 10, count: 390)))
    let s = sorter(Script([Step?]()), saved, clock: clock)
    #expect(await s.cloudBudget() == 10)
    await s.spent(4)
    let left = await s.cloudBudget()
    #expect(saved.value.day.count == 394 && left == 6)
    await s.spent(0)
    #expect(saved.value.day.count == 394)
    #expect(await sorter(Script([Step?]()), Saved.paused(.dayCap)).cloudBudget() == 0)
    #expect(await sorter(Script([Step?]()), Saved.paused(.busy)).cloudBudget() == BacklogSort.dayNames)
    let script = Script([(0, 1, nil)])
    let t = sorter(script, saved, clock: clock)
    await t.ensure(retry: true)
    await t.finished()
    #expect(script.dayLefts == [6])
  }

  @Test func sendingBackCoversEveryRunOnThisDeviceAndNothingElse() async {
    let saved = Saved()
    let script = Script([
      Step(pending: 0, calls: 2, stop: nil, filed: ["a": 2, "b": 3]), Step(pending: 0, calls: 1, stop: nil, filed: ["c": 4]),
    ])
    let s = sorter(script, saved)
    await s.ensure(retry: true)
    await s.finished()
    await s.ensure()
    await s.finished()
    #expect(script.passes == 2 && saved.value.filedHere == ["a": 2, "b": 3, "c": 4])
    #expect(await s.sendAllBack { _ in nil } == 0)
    #expect(saved.value.filedHere == ["a": 2, "b": 3, "c": 4])
    let given = Mutex<[String: Int64]?>(nil)
    #expect(await s.sendAllBack { m in
      given.withLock { $0 = m }
      return m.count
    } == 3)
    #expect(given.withLock { $0 } == ["a": 2, "b": 3, "c": 4] && saved.value.filedHere.isEmpty)
    #expect(await s.sendAllBack { _ in 9 } == 0)
  }

  @Test func aRateLimitWaitsThreeTimesThenPausesUntilALaterForeground() async {
    let saved = Saved()
    let script = Script(Array(repeating: (3, 1, BacklogSort.Stop.rateLimited), count: 4) + [(0, 1, nil)])
    let sleeps = Sleeps()
    let clock = Clock()
    let s = sorter(script, saved, sleeps: sleeps, clock: clock)
    await s.ensure(retry: true)
    await s.finished()
    #expect(script.passes == 4)
    #expect(saved.run?.phase == .paused && saved.run?.reason == .rateLimited)
    #expect(saved.run?.untilMs == clock.now() + 600_000)
    let expected = BacklogSort.backoffMs.map { Duration.milliseconds($0) }
    #expect(sleeps.all == expected)
    await s.ensure()
    #expect(await !s.isRunning && script.passes == 4)
    clock.advance(600_000)
    await s.ensure()
    await s.finished()
    #expect(script.passes == 5 && saved.run?.phase == .done)
  }

  @Test func aGoodPassResetsTheRateLimitBackoff() async {
    let saved = Saved()
    let limited: (pending: Int, calls: Int, stop: BacklogSort.Stop?) = (3, 1, .rateLimited)
    let script = Script([limited, limited, limited, (3, 1, nil), limited, limited, limited, (0, 1, nil)])
    let sleeps = Sleeps()
    let s = sorter(script, saved, sleeps: sleeps)
    await s.ensure(retry: true)
    await s.finished()
    #expect(script.passes == 8 && saved.run?.phase == .done)
    let backoff = BacklogSort.backoffMs.map { Duration.milliseconds($0) }
    #expect(sleeps.all == backoff + [.milliseconds(BacklogSort.passSpacingMs)] + backoff)
  }

  @Test func aBusyServicePausesFifteenMinutesThenResumesOnTheNextForeground() async {
    let saved = Saved()
    let script = Script([(3, 1, .busy), (0, 1, nil)])
    let clock = Clock()
    let s = sorter(script, saved, clock: clock)
    await s.ensure(retry: true)
    await s.finished()
    #expect(script.passes == 1 && saved.run?.phase == .paused && saved.run?.reason == .busy)
    #expect(saved.run?.untilMs == BacklogSorterTests.start + BacklogSort.busyPauseMs)
    #expect(saved.value.isActive)
    clock.advance(BacklogSort.busyPauseMs - 1)
    await s.ensure()
    #expect(await !s.isRunning)
    clock.advance(1)
    await s.ensure()
    await s.finished()
    #expect(script.passes == 2 && saved.run?.phase == .done)
  }

  @Test(arguments: [(BacklogSort.Stop.refused, BacklogRunRecord.Reason.refused), (.off, .off)])
  func aRefusalOrAnUnavailableServiceEndsTheRunUntilTheNextOpen(_ stop: BacklogSort.Stop, _ reason: BacklogRunRecord.Reason) async {
    let saved = Saved()
    let script = Script([(3, 1, stop), (0, 1, nil)])
    let s = sorter(script, saved)
    await s.ensure(retry: true)
    await s.finished()
    #expect(script.passes == 1 && saved.run?.phase == .done && saved.run?.reason == reason)
    await s.ensure()
    #expect(await !s.isRunning && script.passes == 1)
    let reopened = sorter(script, saved)
    await reopened.ensure(retry: true)
    await reopened.finished()
    #expect(script.passes == 2 && saved.run?.reason == nil)
  }

  @Test func theDayCapPausesWithoutAPassUntilTheWindowReopens() async {
    let hour: Int64 = 3_600_000
    let full = (0..<BacklogSort.dayNames).map { BacklogSorterTests.start - 2 * hour + Int64($0) }
    let saved = Saved.running(day: full)
    let script = Script([(0, 5, nil)])
    let clock = Clock()
    let s = sorter(script, saved, clock: clock)
    await s.ensure()
    await s.finished()
    #expect(script.passes == 0 && saved.run?.phase == .paused && saved.run?.reason == .dayCap)
    #expect(saved.run?.untilMs == full[0] + BacklogSort.dayWindowMs)
    await s.ensure(retry: true)
    #expect(await !s.isRunning && saved.run?.reason == .dayCap)
    clock.advance(22 * hour + 10)
    await s.ensure()
    await s.finished()
    #expect(script.passes == 1 && script.dayLefts.first.map { $0 > 0 && $0 <= 11 } == true)
  }

  @Test func aNewRunOnASpentDayPausesWithoutAPass() async {
    let full = Array(repeating: BacklogSorterTests.start - 1_000, count: BacklogSort.dayNames)
    let saved = Saved(BacklogRunRecord(day: full))
    let script = Script([(0, 5, nil)])
    let s = sorter(script, saved)
    await s.ensure(retry: true)
    await s.finished()
    #expect(script.passes == 0 && saved.run?.phase == .paused && saved.run?.reason == .dayCap)
    #expect(await s.cloudBudget() == 0)
  }

  @Test func eachPassIsToldWhatIsLeftOfTheDay() async {
    let saved = Saved.running(day: Array(repeating: BacklogSorterTests.start - 1_000, count: 395))
    let script = Script([(1, 5, .dayCap)])
    let s = sorter(script, saved)
    await s.ensure()
    await s.finished()
    #expect(script.dayLefts == [5])
    #expect(saved.run?.reason == .dayCap && saved.value.day.count == 400)
  }

  @Test func nothingStartsOrRunsInTheBackground() async throws {
    let saved = Saved()
    let script = Script([(0, 0, nil)])
    let active = Flag(false)
    let asked = Asked()
    let s = sorter(script, saved, active: active, asked: asked)
    await s.ensure(retry: true)
    #expect(saved.run == nil && asked.all.isEmpty && script.passes == 0)
    active.set(true)
    await s.ensure()
    await s.finished()
    #expect(script.passes == 1 && saved.run?.phase == .done)

    let running = Saved.running()
    let later = Script([(0, 0, nil)])
    let away = Flag(false)
    let t = sorter(later, running, active: away)
    await t.ensure()
    await waitFor { await t.snapshot.hold == .background }
    #expect(later.passes == 0 && running.run?.phase == .running)
    away.set(true)
    await t.ensure()
    await t.finished()
    #expect(later.passes == 1 && running.run?.phase == .done)
  }

  @Test func offlinePausesAndANetworkChangeResumes() async throws {
    let saved = Saved()
    let script = Script([(0, 1, nil)])
    let net = Net(online: false)
    let s = sorter(script, saved, network: net)
    await s.watchNetwork()
    await s.ensure(retry: true)
    await waitFor { await s.snapshot.hold == .offline }
    #expect(script.passes == 0)
    net.set(true)
    await waitFor { script.passes == 1 }
    await s.finished()
    #expect(script.passes == 1 && saved.run?.phase == .done)
  }

  @Test func turningSuggestionsOffStopsARunAtOnceAndTurningOnStartsAgain() async {
    let saved = Saved()
    let script = Script([(3, 1, nil), (3, 1, nil), (3, 1, nil), (3, 1, nil), (0, 1, nil)])
    let enabled = Flag()
    let s = sorter(script, saved, enabled: enabled)
    await s.ensure(retry: true)
    await waitFor { script.passes >= 1 }
    enabled.set(false)
    await s.switchedOff()
    #expect(await !s.isRunning)
    #expect(saved.run?.phase == .done && saved.run?.reason == .off)
    let stopped = script.passes
    await s.ensure()
    #expect(await !s.isRunning && saved.run?.reason == .off && script.passes == stopped)
    enabled.set(true)
    await s.ensure()
    #expect(await !s.isRunning && saved.run?.reason == .off)
    await s.ensure(retry: true)
    await s.finished()
    #expect(saved.run?.phase == .done && saved.run?.reason == nil && script.passes == 5)
  }

  @Test func theSwitchReadOffEndsTheRunWithoutAPass() async {
    let saved = Saved.running()
    let script = Script([(3, 1, nil)])
    let s = sorter(script, saved, enabled: Flag(false))
    await s.ensure(retry: true)
    #expect(saved.run?.phase == .done && saved.run?.reason == .off && script.passes == 0)
  }

  @Test func theActivityFlagFollowsTheRun() async {
    let saved = Saved()
    let script = Script([(3, 1, .busy)])
    let s = sorter(script, saved)
    #expect(!s.activity.isActive)
    await s.ensure(retry: true)
    #expect(s.activity.isActive)
    await s.finished()
    #expect(s.activity.isActive && saved.run?.reason == .busy)
    await s.switchedOff()
    #expect(!s.activity.isActive)
  }

  @Test func newRowsWakeASortThatWaitsForTheImport() async throws {
    let saved = Saved()
    let script = Script([(0, 2, nil), (0, 0, nil), (0, 0, nil)])
    let clock = Clock()
    let s = BacklogSorter(
      pass: { memo, left in
        clock.advance(40_000)
        return await script.run(memo, left)
      }, store: saved.store, nowMs: clock.now, appActive: { true }, importRunning: { true }, enabled: { true }, network: Net(),
      sleep: { d in try? await Task.sleep(for: d == BacklogSorter.idleWait ? .seconds(30) : .zero) })
    await s.ensure(retry: true)
    await waitFor { script.passes >= 1 }
    try await Task.sleep(for: .milliseconds(20))
    #expect(script.passes == 1)
    await s.ensure()
    await waitFor { script.passes >= 2 }
    #expect(script.passes == 2)
    await s.suspend()
  }

  @Test func theRecordSurvivesAJSONRoundTrip() throws {
    let r = BacklogRunRecord(
      run: BacklogRunRecord.Run(phase: .paused, reason: .busy, untilMs: 9), day: [1, 2], filedHere: ["a": 2, "b": 4], lastPassMs: 7)
    #expect(try JSONDecoder().decode(BacklogRunRecord.self, from: JSONEncoder().encode(r)) == r)
    let older = try JSONDecoder().decode(BacklogRunRecord.self, from: Data(#"{"day":[1]}"#.utf8))
    #expect(older == BacklogRunRecord(day: [1]))
  }

  @Test func aRecordFromTheRunCardBuildKeepsItsDayAndFilingsAndEndsItsRun() throws {
    func decode(_ json: String) throws -> BacklogRunRecord {
      try JSONDecoder().decode(BacklogRunRecord.self, from: Data(json.utf8))
    }
    let capped = try decode(
      #"{"run":{"id":"r","startedMs":5,"requests":250,"asked":3,"totalNames":9,"filed":2,"suggested":1,"phase":"paused","reason":"runCap","untilMs":4,"manifest":{"a":2}},"day":[1,2],"filedHere":{"a":2}}"#
    )
    #expect(capped == BacklogRunRecord(run: BacklogRunRecord.Run(phase: .done), day: [1, 2], filedHere: ["a": 2]))
    let stopped = try decode(#"{"run":{"id":"r","startedMs":5,"phase":"done","reason":"stopped","endedMs":6,"manifest":{}},"day":[3]}"#)
    #expect(stopped.run == BacklogRunRecord.Run(phase: .done) && stopped.day == [3])
    let busy = try decode(#"{"run":{"id":"r","startedMs":5,"requests":4,"phase":"paused","reason":"busy","untilMs":8,"manifest":{}}}"#)
    #expect(busy.run == BacklogRunRecord.Run(phase: .paused, reason: .busy, untilMs: 8))
  }

  @Test nonisolated func theGateRunsOneSweepAtATime() async {
    let gate = SweepGate()
    let inside = Mutex((now: 0, most: 0))
    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<6 {
        group.addTask { @Sendable in
          await gate.run {
            inside.withLock { s in
              s.now += 1
              s.most = max(s.most, s.now)
            }
            try? await Task.sleep(for: .milliseconds(3))
            inside.withLock { $0.now -= 1 }
          }
        }
      }
    }
    #expect(inside.withLock { $0.most } == 1)
  }
}

@MainActor
@Suite("Cloud sort status")
struct CloudSortStatusTests {
  typealias C = LiveCloudSortController

  nonisolated static func view(_ cloudSorted: Int) -> ModelSuggestionStage.BacklogView {
    ModelSuggestionStage.BacklogView(pendingTxnIDs: ["t"], cloudSorted: cloudSorted)
  }

  @Test func theSwitchOffReadsOff() {
    let s = C.status(snapshot: nil, view: Self.view(7), enabled: false)
    #expect(s == CloudSortStatus(phase: .off, pendingTxnIDs: [], cloudSortedCount: 7))
    let idle = C.status(snapshot: nil, view: Self.view(7), enabled: true)
    #expect(idle.phase == .idle && idle.pendingTxnIDs.isEmpty)
  }

  @Test func phasesMapFromTheRecord() {
    var run = BacklogRunRecord.Run()
    #expect(C.phase(run, hold: nil) == .running)
    #expect(C.phase(run, hold: .offline) == .paused(.offline))
    #expect(C.phase(run, hold: .background) == .paused(.background))
    #expect(C.phase(run, hold: .waiting(untilMs: 5)) == .paused(.rateLimited(untilMs: 5)))
    run.phase = .paused
    run.untilMs = 7
    run.reason = .busy
    #expect(C.phase(run, hold: nil) == .paused(.busy(untilMs: 7)))
    run.reason = .rateLimited
    #expect(C.phase(run, hold: nil) == .paused(.rateLimited(untilMs: 7)))
    run.reason = .dayCap
    #expect(C.phase(run, hold: nil) == .paused(.dayCap))
    run.phase = .done
    #expect(C.phase(run, hold: nil) == .done)
  }

  @Test func waitingRowsAreHeldBackOnlyWhileARunIsActive() {
    for (phase, held) in [(BacklogRunRecord.Phase.running, true), (.paused, true), (.done, false)] {
      let record = BacklogRunRecord(run: BacklogRunRecord.Run(phase: phase, reason: phase == .paused ? .busy : nil))
      let s = C.status(snapshot: BacklogSnapshot(record: record, hold: nil, looping: false), view: Self.view(3), enabled: true)
      #expect(s.pendingTxnIDs == (held ? ["t"] : []) && s.cloudSortedCount == 3)
    }
  }

  @Test func theControllerFollowsTheSorter() async {
    let saved = BacklogSorterTests.Saved()
    let script = BacklogSorterTests.Script([(0, 2, nil)])
    let sorter = BacklogSorter(
      pass: { await script.run($0, $1) }, store: saved.store, nowMs: { BacklogSorterTests.start }, appActive: { true },
      importRunning: { false }, enabled: { true }, network: BacklogSorterTests.Net(), sleep: { _ in })
    let c = LiveCloudSortController(sorter: sorter, view: { _ in Self.view(12) }, sendBack: { 5 }, enabled: { true })
    await c.refresh()
    #expect(c.status.phase == .idle && c.status.cloudSortedCount == 12)
    await sorter.ensure(retry: true)
    for _ in 0..<400 where c.status.phase != .done { try? await Task.sleep(for: .milliseconds(5)) }
    #expect(c.status.phase == .done)
    #expect(await c.sendAllBack() == 5)
  }

  @Test func aRecountAskedForWhileOneRunsRunsOnceMore() async {
    let saved = BacklogSorterTests.Saved()
    let sorter = BacklogSorter(
      pass: { _, _ in nil }, store: saved.store, nowMs: { BacklogSorterTests.start }, appActive: { true },
      importRunning: { false }, enabled: { true }, network: BacklogSorterTests.Net(), sleep: { _ in })
    let calls = Mutex(0)
    let open = Mutex(false)
    let c = LiveCloudSortController(
      sorter: sorter,
      view: { _ in
        let n = calls.withLock { n -> Int in
          n += 1
          return n
        }
        while !open.withLock({ $0 }) { try? await Task.sleep(for: .milliseconds(2)) }
        return Self.view(n * 10)
      }, sendBack: { 0 }, enabled: { true })
    for _ in 0..<400 where calls.withLock({ $0 }) < 1 { try? await Task.sleep(for: .milliseconds(5)) }
    await sorter.spent(1)
    await sorter.spent(1)
    try? await Task.sleep(for: .milliseconds(20))
    #expect(calls.withLock { $0 } == 1)
    open.withLock { $0 = true }
    for _ in 0..<400 where c.status.cloudSortedCount != 20 { try? await Task.sleep(for: .milliseconds(5)) }
    #expect(c.status.cloudSortedCount == 20)
    try? await Task.sleep(for: .milliseconds(30))
    #expect(calls.withLock { $0 } == 2)
  }

  nonisolated final class Gate: Sendable {
    let calls = Mutex(0)
    let open = Mutex(false)

    func view(slow: Int, fast: Int) -> @Sendable ([String: Int64]) async -> ModelSuggestionStage.BacklogView? {
      { _ in
        let n = self.calls.withLock { c in
          c += 1
          return c
        }
        guard n == 1 else { return CloudSortStatusTests.view(fast) }
        while !self.open.withLock({ $0 }) { try? await Task.sleep(for: .milliseconds(5)) }
        return CloudSortStatusTests.view(slow)
      }
    }
  }

  static func idleSorter() -> BacklogSorter {
    BacklogSorter(
      pass: { _, _ in nil }, store: BacklogSorterTests.Saved().store, nowMs: { BacklogSorterTests.start }, appActive: { true },
      importRunning: { false }, enabled: { true }, network: BacklogSorterTests.Net(), sleep: { _ in })
  }

  @Test func anOlderCountCannotOverwriteANewerOne() async throws {
    let gate = Gate()
    let c = LiveCloudSortController(sorter: Self.idleSorter(), view: gate.view(slow: 5, fast: 40), sendBack: { 0 }, enabled: { true })
    let first = Task { await c.refresh() }
    try await LiveLedgerMapperTests.eventually { gate.calls.withLock { $0 } == 1 }
    await c.refresh()
    #expect(c.status.cloudSortedCount == 40)
    gate.open.withLock { $0 = true }
    await first.value
    #expect(c.status.cloudSortedCount == 40)
  }

  @Test func countChangesAreCoalesced() async throws {
    let gate = Gate()
    let c = LiveCloudSortController(sorter: Self.idleSorter(), view: gate.view(slow: 5, fast: 40), sendBack: { 0 }, enabled: { true })
    c.countsChanged()
    try await LiveLedgerMapperTests.eventually { gate.calls.withLock { $0 } == 1 }
    for _ in 0..<30 { c.countsChanged() }
    gate.open.withLock { $0 = true }
    try await LiveLedgerMapperTests.eventually { c.status.cloudSortedCount == 40 }
    try await Task.sleep(for: .milliseconds(100))
    #expect(gate.calls.withLock { $0 } == 2)
    #expect(c.status.cloudSortedCount == 40)
  }
}

@MainActor
@Suite("Backlog sort setting")
struct BacklogSortSettingTests {
  private func freshDefaults() -> UserDefaults {
    let name = "test.backlogSort.\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
  }

  nonisolated final class Told: Sendable {
    let count = Mutex(0)
    var value: Int { count.withLock { $0 } }
  }

  private func counting(_ name: Notification.Name, _ d: UserDefaults) -> (Told, NSObjectProtocol) {
    let told = Told()
    let token = NotificationCenter.default.addObserver(forName: name, object: d, queue: nil) { _ in
      told.count.withLock { $0 += 1 }
    }
    return (told, token)
  }

  @Test func turningOnFromTheAskTurnsOnBothSwitchesAndTellsTheSorterOnce() {
    let d = freshDefaults()
    let (on, token) = counting(MerchantSuggestionsSetting.turnedOn, d)
    defer { NotificationCenter.default.removeObserver(token) }
    MerchantSuggestionsSetting.turnOnBoth(d)
    #expect(MerchantSuggestionsSetting.isEnabled(d) && MerchantSuggestionsSetting.isAutoSortEnabled(d))
    #expect(MerchantSuggestionsSetting.reviewAskAnswered(d))
    #expect(MerchantSuggestionsConsent(defaults: d).isOn && MerchantSuggestionsConsent(defaults: d).autoSortOn)
    #expect(on.value == 1)
  }

  @Test func turningSuggestionsOnOrOffInProfileTellsTheSorter() {
    let d = freshDefaults()
    let (on, onToken) = counting(MerchantSuggestionsSetting.turnedOn, d)
    let (off, offToken) = counting(MerchantSuggestionsSetting.turnedOff, d)
    defer {
      NotificationCenter.default.removeObserver(onToken)
      NotificationCenter.default.removeObserver(offToken)
    }
    let consent = MerchantSuggestionsConsent(defaults: d)
    consent.request(true)
    consent.turnOn(.suggestions)
    #expect(on.value == 1 && off.value == 0)
    consent.requestAutoSort(true)
    consent.turnOn(.autoSort)
    #expect(MerchantSuggestionsSetting.isAutoSortEnabled(d) && on.value == 1)
    consent.request(false)
    #expect(off.value == 1 && !MerchantSuggestionsSetting.isAutoSortEnabled(d))
  }

  @Test func leavingThisIPhoneForgetsTheOldRunKeys() {
    let d = freshDefaults()
    let old = MerchantSuggestionsSetting.retiredKeys + ["app.hasala.prefs.cloudSort.runOffer", "app.hasala.prefs.cloudSort.dismissedRun"]
    for key in old { d.set(true, forKey: key) }
    MerchantSuggestionsSetting.turnOnBoth(d)
    LocalAccountData.forget(defaults: d)
    for key in old { #expect(d.object(forKey: key) == nil, "\(key)") }
    #expect(!MerchantSuggestionsSetting.isEnabled(d))
  }

  @Test func theLiveOfferMapsOntoTheTwoSwitches() {
    let d = freshDefaults()
    let offer = LiveCloudSort(defaults: d)
    #expect(offer.isOffered == BuildSurface.showsCloudSuggestions)
    #expect(!offer.isOn)
    offer.turnOn()
    #expect(offer.isOn && offer.answered)
    #expect(MerchantSuggestionsSetting.isEnabled(d) && MerchantSuggestionsSetting.isAutoSortEnabled(d))
  }
}

@MainActor
@Suite("Review: asking about the cloud sort")
struct ReviewCloudSortAskTests {
  @Test func theAskShowsUntilTheDeviceAnswersAndTurnsOnOnce() {
    let cloud = MockCloudSort(offered: true)
    #expect(ReviewTabView.asksCloudSort(cloud, reviewAccount: false, toSort: 12))
    cloud.turnOn()
    #expect(cloud.turnOnCalls == 1 && cloud.isOn)
    #expect(!ReviewTabView.asksCloudSort(cloud, reviewAccount: false, toSort: 12))
  }

  @Test func notNowLeavesBothSwitchesOffAndStopsAsking() {
    let cloud = MockCloudSort(offered: true)
    cloud.notNow()
    #expect(cloud.turnOnCalls == 0 && !cloud.isOn)
    #expect(!ReviewTabView.asksCloudSort(cloud, reviewAccount: false, toSort: 12))
  }

  @Test func onlyWhenThereIsSomethingToSortOnARealAccountInABuildThatOffersIt() {
    #expect(!ReviewTabView.asksCloudSort(MockCloudSort(offered: true), reviewAccount: false, toSort: 0))
    #expect(!ReviewTabView.asksCloudSort(MockCloudSort(offered: true), reviewAccount: true, toSort: 12))
    #expect(!ReviewTabView.asksCloudSort(MockCloudSort(offered: false), reviewAccount: false, toSort: 12))
    #expect(!ReviewTabView.asksCloudSort(nil, reviewAccount: false, toSort: 12))
  }

  @Test func theLiveAnswerIsKeptOnThisIPhoneUntilTheAccountLeaves() {
    let d = UserDefaults(suiteName: "review-ask-\(UUID().uuidString)")!
    let offer = LiveCloudSort(defaults: d)
    #expect(!offer.answered)
    offer.notNow()
    #expect(offer.answered && !offer.isOn && !MerchantSuggestionsSetting.isEnabled(d))
    MerchantSuggestionsSetting.forget(d)
    #expect(!offer.answered)
    MerchantSuggestionsSetting.setEnabled(true, d)
    #expect(offer.answered)
    MerchantSuggestionsSetting.setEnabled(false, d)
    #expect(offer.answered && !offer.isOn)
    MerchantSuggestionsSetting.forget(d)
    offer.turnOn()
    #expect(offer.answered && offer.isOn)
  }
}
