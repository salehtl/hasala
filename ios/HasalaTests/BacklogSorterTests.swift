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

    static func running(requests: Int = 0, day: [Int64] = []) -> Saved {
      var run = BacklogRunRecord.Run(id: "run-0", startedMs: BacklogSorterTests.start)
      run.requests = requests
      return Saved(BacklogRunRecord(run: run, day: day))
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
    let seen = Mutex<[(requests: Int, dayLeft: Int)]>([])

    init(_ steps: [Step?]) {
      self.steps = Mutex(steps)
    }

    convenience init(_ steps: [(pending: Int, calls: Int, stop: BacklogSort.Stop?)?]) {
      self.init(steps.map { $0.map { Step(pending: $0.pending, calls: $0.calls, stop: $0.stop, settled: $0.calls) } })
    }

    func run(_ memo: BacklogSort.Memo, _ dayLeft: Int) async -> BacklogSorter.PassResult? {
      seen.withLock { $0.append((memo.requests, dayLeft)) }
      let next = steps.withLock { s -> Step?? in s.isEmpty ? .none : .some(s.removeFirst()) }
      guard case .some(let maybe) = next, let step = maybe else { return nil }
      var m = memo
      m.requests += step.calls
      return BacklogSorter.PassResult(
        pass: BacklogSort.Pass(
          suggestions: [], memo: m, pending: step.pending, calls: step.calls, stop: step.stop, settled: step.settled),
        filing: BacklogSort.Filing(filed: step.filed, suggested: step.suggested))
    }

    var passes: Int { seen.withLock { $0.count } }
    var memos: [Int] { seen.withLock { $0.map(\.requests) } }
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

  func sorter(
    _ script: Script, _ saved: Saved, sleeps: Sleeps = Sleeps(), active: Flag = Flag(), importing: Bool = false,
    clock: Clock = Clock(), enabled: Flag = Flag(), network: Net = Net()
  ) -> BacklogSorter {
    BacklogSorter(
      pass: { await script.run($0, $1) }, store: saved.store, nowMs: clock.now, appActive: { active.value },
      importRunning: { importing }, enabled: { enabled.value }, network: network, sleep: sleeps.sleep, newID: { UUID().uuidString })
  }

  func waitFor(_ condition: @Sendable () async -> Bool) async {
    for _ in 0..<400 {
      if await condition() { return }
      try? await Task.sleep(for: .milliseconds(5))
    }
  }

  @Test func itRunsPassesUntilNothingIsLeftThenEnds() async {
    let saved = Saved.running(requests: 5)
    let script = Script([(2, 10, nil), (1, 10, nil), (0, 3, nil)])
    let sleeps = Sleeps()
    let s = sorter(script, saved, sleeps: sleeps)
    await s.resume()
    await s.finished()
    #expect(script.passes == 3)
    #expect(script.memos == [5, 15, 25])
    #expect(saved.run?.phase == .done && saved.run?.reason == nil && saved.run?.requests == 28)
    #expect(saved.run?.asked == 23 && saved.value.day.count == 23)
    #expect(sleeps.all.count == 2)
    #expect(sleeps.all.allSatisfy { $0 > .seconds(29) && $0 <= .milliseconds(BacklogSort.passSpacingMs) })
    #expect(await !s.isRunning)
  }

  @Test func aStartBeginsARunAndCountsItsResults() async {
    let saved = Saved()
    let script = Script([
      Step(pending: 2, calls: 12, stop: nil, filed: ["a": 2, "b": 3], suggested: ["c"], settled: 11),
      Step(pending: 0, calls: 2, stop: nil, filed: ["d": 4], settled: 2),
    ])
    let s = sorter(script, saved)
    await s.start()
    await s.finished()
    let run = saved.run
    #expect(run?.phase == .done && run?.filed == 3 && run?.suggested == 1 && run?.asked == 13 && run?.totalNames == 13)
    #expect(run?.manifest == ["a": 2, "b": 3, "d": 4])
    #expect(saved.value.canUndo && !saved.value.isActive)
  }

  @Test func threeFailedPassesEndTheRunAndFreeTheSweepAndTheDeck() async {
    let saved = Saved()
    let script = Script([(4, 10, nil), nil, nil, nil])
    let s = sorter(script, saved)
    await s.start()
    await s.finished()
    #expect(script.passes == 1 + BacklogSorter.maxFailures)
    #expect(saved.run?.phase == .done && saved.run?.reason == .failed && saved.run?.requests == 10)
    #expect(!s.activity.isActive && !saved.value.isActive && saved.run?.endedMs != nil)
    let status = LiveCloudSortController.status(
      snapshot: await s.snapshot, view: CloudSortStatusTests.view(9), enabled: true, nowMs: BacklogSorterTests.start)
    #expect(status.phase == .done && status.pendingTxnIDs.isEmpty)
    let again = Script([(0, 2, nil)])
    let t = sorter(again, saved)
    await t.start()
    await t.finished()
    #expect(again.memos == [0] && saved.run?.phase == .done && saved.run?.reason == nil)
  }

  @Test func aRunResumesAfterARelaunch() async {
    let saved = Saved.running(requests: 10)
    let next = Script([(0, 2, nil)])
    let t = sorter(next, saved)
    #expect(await t.snapshot.record == saved.value)
    await t.resume()
    await t.finished()
    #expect(next.memos == [10])
    #expect(saved.run?.phase == .done && saved.run?.requests == 12)
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
    await failing.start()
    await failing.finished()
    #expect(saved.value.day.count == 4 && saved.run?.requests == 4 && saved.run?.filed == 1 && saved.run?.manifest == ["a": 2])
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
    for reason in [BacklogRunRecord.Reason.dayCap, .runCap] {
      var run = BacklogRunRecord.Run(id: "r", startedMs: 0)
      run.phase = .paused
      run.reason = reason
      let capped = Saved(BacklogRunRecord(run: run))
      #expect(await sorter(Script([Step?]()), capped).cloudBudget() == 0)
    }
    var busy = BacklogRunRecord.Run(id: "r", startedMs: 0)
    busy.phase = .paused
    busy.reason = .busy
    #expect(await sorter(Script([Step?]()), Saved(BacklogRunRecord(run: busy))).cloudBudget() == BacklogSort.dayNames)
    let script = Script([(0, 1, nil)])
    let t = sorter(script, saved, clock: clock)
    await t.start()
    await t.finished()
    #expect(script.dayLefts == [6])
  }

  @Test func sendingBackCoversEveryRunOnThisDeviceAndNothingElse() async {
    let saved = Saved()
    let first = Script([Step(pending: 0, calls: 2, stop: nil, filed: ["a": 2, "b": 3])])
    let s = sorter(first, saved)
    await s.start()
    await s.finished()
    let second = Script([Step(pending: 0, calls: 1, stop: nil, filed: ["c": 4])])
    let t = sorter(second, saved)
    await t.start()
    await t.finished()
    #expect(saved.value.filedHere == ["a": 2, "b": 3, "c": 4] && saved.run?.manifest == ["c": 4])
    #expect(await t.undoLastRun { $0.count } == 1)
    #expect(saved.value.filedHere == ["a": 2, "b": 3])
    let given = Mutex<[String: Int64]?>(nil)
    #expect(await t.sendAllBack { m in
      given.withLock { $0 = m }
      return m.count
    } == 2)
    #expect(given.withLock { $0 } == ["a": 2, "b": 3] && saved.value.filedHere.isEmpty)
    #expect(await t.sendAllBack { _ in 9 } == 0)
  }

  @Test func aRateLimitWaitsThreeTimesThenPausesUntilATapOrALaterForeground() async {
    let saved = Saved()
    let script = Script(Array(repeating: (3, 1, BacklogSort.Stop.rateLimited), count: 4) + [(0, 1, nil)])
    let sleeps = Sleeps()
    let clock = Clock()
    let s = sorter(script, saved, sleeps: sleeps, clock: clock)
    await s.start()
    await s.finished()
    #expect(script.passes == 4)
    #expect(saved.run?.phase == .paused && saved.run?.reason == .rateLimited)
    #expect(saved.run?.untilMs == clock.now() + 600_000)
    let expected = BacklogSort.backoffMs.map { Duration.milliseconds($0) }
    #expect(sleeps.all.count == 3)
    for (got, want) in zip(sleeps.all, expected) { #expect(got <= want && got > want - .seconds(1)) }
    await s.resume()
    #expect(await !s.isRunning && script.passes == 4)
    await s.start()
    await s.finished()
    #expect(script.passes == 5 && saved.run?.phase == .done)
  }

  @Test func aGoodPassResetsTheRateLimitBackoff() async {
    let saved = Saved()
    let limited: (pending: Int, calls: Int, stop: BacklogSort.Stop?) = (3, 1, .rateLimited)
    let script = Script([limited, limited, limited, (3, 1, nil), limited, limited, limited, (0, 1, nil)])
    let sleeps = Sleeps()
    let s = sorter(script, saved, sleeps: sleeps)
    await s.start()
    await s.finished()
    #expect(script.passes == 8 && saved.run?.phase == .done)
    let backoff = BacklogSort.backoffMs.map { Duration.milliseconds($0) }
    let expected = backoff + [.milliseconds(BacklogSort.passSpacingMs)] + backoff
    #expect(sleeps.all.count == expected.count)
    for (got, want) in zip(sleeps.all, expected) { #expect(got <= want && got > want - .seconds(1)) }
  }

  @Test func aBusyServicePausesFifteenMinutesThenResumesOnTheNextForeground() async {
    let saved = Saved()
    let script = Script([(3, 1, .busy), (0, 1, nil)])
    let clock = Clock()
    let s = sorter(script, saved, clock: clock)
    await s.start()
    await s.finished()
    #expect(script.passes == 1 && saved.run?.phase == .paused && saved.run?.reason == .busy)
    #expect(saved.run?.untilMs == BacklogSorterTests.start + BacklogSort.busyPauseMs)
    #expect(saved.value.isActive)
    clock.advance(BacklogSort.busyPauseMs - 1)
    await s.resume()
    #expect(await !s.isRunning)
    clock.advance(1)
    await s.resume()
    await s.finished()
    #expect(script.passes == 2 && saved.run?.phase == .done)
  }

  @Test(arguments: [(BacklogSort.Stop.refused, BacklogRunRecord.Reason.refused), (.off, .off)])
  func aRefusalOrTheSwitchEndsTheRun(_ stop: BacklogSort.Stop, _ reason: BacklogRunRecord.Reason) async {
    let saved = Saved()
    let script = Script([(3, 1, stop), (3, 1, nil)])
    let s = sorter(script, saved)
    await s.start()
    await s.finished()
    #expect(script.passes == 1 && saved.run?.phase == .done && saved.run?.reason == reason)
  }

  @Test func aRunPausesAfter250NamesAndAStartBeginsTheNext() async {
    let saved = Saved()
    let script = Script([(40, 12, .runCap), (0, 5, nil)])
    let s = sorter(script, saved)
    await s.start()
    await s.finished()
    let first = saved.run
    #expect(first?.phase == .paused && first?.reason == .runCap && !saved.value.isActive)
    await s.resume()
    #expect(await !s.isRunning && script.passes == 1)
    await s.start()
    await s.finished()
    #expect(saved.run?.id != first?.id && script.memos == [0, 0] && saved.run?.requests == 5)
    #expect(saved.value.day.count == 17)
  }

  @Test func theDayCapPausesWithoutAPassUntilTheWindowReopens() async {
    let hour: Int64 = 3_600_000
    let full = (0..<BacklogSort.dayNames).map { BacklogSorterTests.start - 2 * hour + Int64($0) }
    let saved = Saved.running(day: full)
    let script = Script([(0, 5, nil)])
    let clock = Clock()
    let s = sorter(script, saved, clock: clock)
    await s.resume()
    await s.finished()
    #expect(script.passes == 0 && saved.run?.phase == .paused && saved.run?.reason == .dayCap)
    #expect(saved.run?.untilMs == full[0] + BacklogSort.dayWindowMs)
    await s.resume()
    #expect(await !s.isRunning)
    clock.advance(22 * hour + 10)
    await s.resume()
    await s.finished()
    #expect(script.passes == 1 && script.dayLefts.first.map { $0 > 0 && $0 <= 11 } == true)
  }

  @Test func eachPassIsToldWhatIsLeftOfTheDay() async {
    let saved = Saved.running(day: Array(repeating: BacklogSorterTests.start - 1_000, count: 395))
    let script = Script([(1, 5, .dayCap)])
    let s = sorter(script, saved)
    await s.resume()
    await s.finished()
    #expect(script.dayLefts == [5])
    #expect(saved.run?.reason == .dayCap && saved.value.day.count == 400)
  }

  @Test func nothingRunsInTheBackground() async throws {
    let saved = Saved()
    let script = Script([(0, 0, nil)])
    let active = Flag(false)
    let s = sorter(script, saved, active: active)
    await s.start()
    await waitFor { await s.snapshot.hold == .background }
    #expect(script.passes == 0 && saved.run?.phase == .running)
    active.set(true)
    await s.resume()
    await s.finished()
    #expect(script.passes == 1 && saved.run?.phase == .done)
  }

  @Test func offlinePausesAndANetworkChangeResumes() async throws {
    let saved = Saved()
    let script = Script([(0, 1, nil)])
    let net = Net(online: false)
    let s = sorter(script, saved, network: net)
    await s.watchNetwork()
    await s.start()
    await waitFor { await s.snapshot.hold == .offline }
    #expect(script.passes == 0)
    net.set(true)
    await waitFor { script.passes == 1 }
    await s.finished()
    #expect(script.passes == 1 && saved.run?.phase == .done)
  }

  @Test func stopEndsTheRunAndKeepsItsManifestForUndo() async {
    let saved = Saved()
    let script = Script([Step(pending: 3, calls: 3, stop: nil, filed: ["a": 2]), Step(pending: 3, calls: 3, stop: nil)])
    let s = sorter(script, saved)
    await s.start()
    await waitFor { script.passes >= 1 }
    await waitFor { saved.run?.manifest.isEmpty == false }
    await s.stop()
    #expect(saved.run?.phase == .done && saved.run?.reason == .stopped && saved.value.canUndo)
    let given = Mutex<[String: Int64]?>(nil)
    let n = await s.undoLastRun { m in
      given.withLock { $0 = m }
      return m.count
    }
    #expect(n == 1 && given.withLock { $0 } == ["a": 2])
    #expect(!saved.value.canUndo && saved.run?.filed == 1)
    #expect(await s.undoLastRun { _ in 9 } == 0)
  }

  @Test func aFailedUndoKeepsTheManifest() async {
    var run = BacklogRunRecord.Run(id: "r", startedMs: 0)
    run.phase = .done
    run.manifest = ["a": 2]
    let saved = Saved(BacklogRunRecord(run: run))
    let s = sorter(Script([Step?]()), saved)
    #expect(await s.undoLastRun { _ in nil } == 0)
    #expect(saved.value.canUndo)
    #expect(await s.sendAllBack { _ in 4 } == 0)
    #expect(saved.value.canUndo)
  }

  @Test func turningSuggestionsOffStopsARunAtOnce() async {
    let saved = Saved()
    let script = Script([(3, 1, nil), (3, 1, nil), (3, 1, nil)])
    let enabled = Flag()
    let s = sorter(script, saved, enabled: enabled)
    await s.start()
    await waitFor { script.passes >= 1 }
    enabled.set(false)
    await s.switchedOff()
    #expect(await !s.isRunning)
    #expect(saved.run?.phase == .done && saved.run?.reason == .off)
    await s.start()
    #expect(await !s.isRunning && saved.run?.reason == .off)
  }

  @Test func theSwitchReadOffEndsTheRunOnTheNextPass() async {
    let saved = Saved.running()
    let script = Script([(3, 1, nil)])
    let s = sorter(script, saved, enabled: Flag(false))
    await s.resume()
    #expect(saved.run?.phase == .done && saved.run?.reason == .off && script.passes == 0)
  }

  @Test func theActivityFlagFollowsTheRun() async {
    let saved = Saved()
    let script = Script([(3, 1, .busy)])
    let s = sorter(script, saved)
    #expect(!s.activity.isActive)
    await s.start()
    #expect(s.activity.isActive)
    await s.finished()
    #expect(s.activity.isActive && saved.run?.reason == .busy)
    await s.stop()
    #expect(!s.activity.isActive)
  }

  @Test func newRowsWakeASortThatWaitsForTheImport() async throws {
    let saved = Saved()
    let script = Script([(0, 2, nil), (0, 0, nil), (0, 0, nil)])
    let s = BacklogSorter(
      pass: { await script.run($0, $1) }, store: saved.store, nowMs: { BacklogSorterTests.start }, appActive: { true },
      importRunning: { true }, enabled: { true }, network: Net(),
      sleep: { d in try? await Task.sleep(for: d == BacklogSorter.idleWait ? .seconds(30) : .zero) })
    await s.start()
    await waitFor { script.passes >= 1 }
    try await Task.sleep(for: .milliseconds(20))
    #expect(script.passes == 1)
    await s.resume()
    await waitFor { script.passes >= 2 }
    #expect(script.passes == 2)
    await s.stop()
  }

  @Test func theRecordSurvivesAJSONRoundTrip() throws {
    var run = BacklogRunRecord.Run(id: "r", startedMs: 5)
    run.phase = .paused
    run.reason = .busy
    run.untilMs = 9
    run.manifest = ["a": 2]
    let r = BacklogRunRecord(run: run, day: [1, 2], filedHere: ["a": 2, "b": 4])
    #expect(try JSONDecoder().decode(BacklogRunRecord.self, from: JSONEncoder().encode(r)) == r)
    let older = try JSONDecoder().decode(BacklogRunRecord.self, from: Data(#"{"day":[1]}"#.utf8))
    #expect(older == BacklogRunRecord(day: [1]))
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

  nonisolated static func view(_ waiting: Int) -> ModelSuggestionStage.BacklogView {
    ModelSuggestionStage.BacklogView(
      counts: BacklogSort.Counts(waitingNames: waiting, waitingPayments: waiting + 3, staysOnDevice: 4, leftForYou: 6, pendingTxnIDs: ["t"]),
      cloudSorted: 7)
  }

  @Test func theSwitchOffReadsOff() {
    let s = C.status(snapshot: nil, view: Self.view(9), enabled: false, nowMs: 0)
    #expect(s.phase == .off && s.waitingNames == 9 && s.cloudSortedCount == 7)
    let idle = C.status(snapshot: nil, view: Self.view(9), enabled: true, nowMs: 0)
    #expect(idle.phase == .idle && idle.remainingToday == BacklogSort.dayNames && idle.nextRunNames == 9)
  }

  @Test func phasesMapFromTheRecord() {
    var run = BacklogRunRecord.Run(id: "r", startedMs: 0)
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
    run.reason = .runCap
    #expect(C.phase(run, hold: nil) == .paused(.runCap))
    run.reason = .dayCap
    #expect(C.phase(run, hold: nil) == .paused(.dayCap))
    run.phase = .done
    #expect(C.phase(run, hold: nil) == .done)
  }

  @Test func countsAndCapsFillTheStatus() {
    var run = BacklogRunRecord.Run(id: "r", startedMs: 0)
    run.asked = 40
    run.totalNames = 300
    run.filed = 20
    run.suggested = 5
    run.phase = .done
    run.endedMs = 99
    run.manifest = ["a": 1]
    let now: Int64 = 1_000_000_000
    let record = BacklogRunRecord(run: run, day: Array(repeating: now - 10, count: 350))
    let s = C.status(
      snapshot: BacklogSnapshot(record: record, hold: nil, looping: false), view: Self.view(300), enabled: true, nowMs: now)
    #expect(s.phase == .done && s.askedNames == 40 && s.totalNames == 300 && s.filed == 20 && s.suggested == 5)
    #expect(s.waitingPayments == 303 && s.staysOnDevice == 4 && s.leftForYou == 6 && s.pendingTxnIDs.isEmpty)
    var going = run
    going.phase = .running
    let held = C.status(
      snapshot: BacklogSnapshot(record: BacklogRunRecord(run: going), hold: nil, looping: true), view: Self.view(300), enabled: true,
      nowMs: now)
    #expect(held.pendingTxnIDs == ["t"])
    #expect(s.lastRunEndedMs == 99 && s.canUndoLastRun && s.remainingToday == 50 && s.nextRunNames == 50)
    let fresh = C.status(
      snapshot: BacklogSnapshot(record: BacklogRunRecord(run: run), hold: nil, looping: false), view: Self.view(300), enabled: true,
      nowMs: now)
    #expect(fresh.nextRunNames == BacklogSort.runNames)
  }

  @Test func theControllerFollowsTheSorter() async {
    let saved = BacklogSorterTests.Saved()
    let script = BacklogSorterTests.Script([(0, 2, nil)])
    let sorter = BacklogSorter(
      pass: { await script.run($0, $1) }, store: saved.store, nowMs: { BacklogSorterTests.start }, appActive: { true },
      importRunning: { false }, enabled: { true }, network: BacklogSorterTests.Net(), sleep: { _ in })
    let undone = Mutex(0)
    let c = LiveCloudSortController(
      sorter: sorter, view: { _ in Self.view(12) }, undo: { undone.withLock { $0 += 1 }; return 3 }, sendBack: { 5 }, enabled: { true },
      nowMs: { BacklogSorterTests.start })
    await c.refresh()
    #expect(c.status.phase == .idle && c.status.waitingNames == 12 && c.status.nextRunNames == 12)
    c.start()
    for _ in 0..<400 where c.status.phase != .done { try? await Task.sleep(for: .milliseconds(5)) }
    #expect(c.status.phase == .done && c.status.askedNames == 2)
    #expect(await c.undoLastRun() == 3 && undone.withLock { $0 } == 1)
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
      }, undo: { 0 }, sendBack: { 0 }, enabled: { true }, nowMs: { BacklogSorterTests.start })
    for _ in 0..<400 where calls.withLock({ $0 }) < 1 { try? await Task.sleep(for: .milliseconds(5)) }
    await sorter.spent(1)
    await sorter.spent(1)
    try? await Task.sleep(for: .milliseconds(20))
    #expect(calls.withLock { $0 } == 1)
    open.withLock { $0 = true }
    for _ in 0..<400 where c.status.waitingNames != 20 { try? await Task.sleep(for: .milliseconds(5)) }
    #expect(c.status.waitingNames == 20)
    try? await Task.sleep(for: .milliseconds(30))
    #expect(calls.withLock { $0 } == 2)
  }

  @Test func theMockTakesAPhaseFromItsLaunchArgument() {
    #expect(MockCloudSortController.fromLaunchArguments([]) == nil)
    let m = MockCloudSortController.fromLaunchArguments([MockCloudSortController.argument, "runCap"])
    #expect(m?.status.phase == .paused(.runCap) && m?.status.nextRunNames == 147)
    #expect(MockCloudSortController.fromLaunchArguments([MockCloudSortController.argument, "done"])?.status.canUndoLastRun == true)
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

  @Test func turningOnFromTheAskTurnsOnBothSwitchesAndAsksForARun() {
    let d = freshDefaults()
    #expect(!MerchantSuggestionsSetting.hasRunRequest(d))
    MerchantSuggestionsSetting.turnOnForFirstImport(d)
    #expect(MerchantSuggestionsSetting.isEnabled(d) && MerchantSuggestionsSetting.isAutoSortEnabled(d))
    #expect(MerchantSuggestionsConsent(defaults: d).isOn && MerchantSuggestionsConsent(defaults: d).autoSortOn)
    #expect(MerchantSuggestionsSetting.takeRunRequest(d))
    #expect(!MerchantSuggestionsSetting.takeRunRequest(d))
  }

  @Test func aFirstImportFromAnOlderBuildIsNotARequestAndIsForgotten() {
    let d = freshDefaults()
    MerchantSuggestionsSetting.setEnabled(true, d)
    d.set(Double(1_000), forKey: MerchantSuggestionsSetting.firstImportStartedKey)
    d.set(12, forKey: MerchantSuggestionsSetting.firstImportRequestsKey)
    #expect(!MerchantSuggestionsSetting.hasRunRequest(d))
    #expect(!MerchantSuggestionsSetting.takeRunRequest(d))
    #expect(d.object(forKey: MerchantSuggestionsSetting.firstImportStartedKey) == nil)
    #expect(d.object(forKey: MerchantSuggestionsSetting.firstImportRequestsKey) == nil)
  }

  @Test func turningSuggestionsOffForgetsTheRequestAndTellsTheSorter() async {
    let d = freshDefaults()
    MerchantSuggestionsSetting.turnOnForFirstImport(d)
    let consent = MerchantSuggestionsConsent(defaults: d)
    consent.requestAutoSort(false)
    #expect(MerchantSuggestionsSetting.hasRunRequest(d))
    let told = Mutex(0)
    let token = NotificationCenter.default.addObserver(forName: MerchantSuggestionsSetting.turnedOff, object: nil, queue: nil) { _ in
      told.withLock { $0 += 1 }
    }
    defer { NotificationCenter.default.removeObserver(token) }
    consent.request(false)
    #expect(!MerchantSuggestionsSetting.hasRunRequest(d) && told.withLock { $0 } == 1)
    MerchantSuggestionsSetting.setEnabled(true, d)
    #expect(!MerchantSuggestionsSetting.hasRunRequest(d))
  }

  @Test func turningOnInProfileDoesNotAskForARun() {
    let d = freshDefaults()
    let consent = MerchantSuggestionsConsent(defaults: d)
    consent.request(true)
    consent.turnOn(.suggestions)
    consent.requestAutoSort(true)
    consent.turnOn(.autoSort)
    #expect(MerchantSuggestionsSetting.isAutoSortEnabled(d))
    #expect(!MerchantSuggestionsSetting.hasRunRequest(d))
  }

  @Test func leavingThisIPhoneForgetsTheRequest() {
    let d = freshDefaults()
    MerchantSuggestionsSetting.turnOnForFirstImport(d)
    LocalAccountData.forget(defaults: d)
    #expect(!MerchantSuggestionsSetting.hasRunRequest(d))
    #expect(d.object(forKey: MerchantSuggestionsSetting.runRequestKey) == nil)
  }

  @Test func theLiveOfferMapsOntoTheTwoSwitches() {
    let d = freshDefaults()
    let offer = LiveCloudSort(runtime: { nil }, defaults: d)
    #expect(offer.isOffered == BuildSurface.showsCloudSuggestions)
    #expect(!offer.isOn)
    offer.turnOn()
    #expect(offer.isOn)
    #expect(MerchantSuggestionsSetting.isEnabled(d) && MerchantSuggestionsSetting.isAutoSortEnabled(d))
    #expect(MerchantSuggestionsSetting.hasRunRequest(d))
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
    let offer = LiveCloudSort(runtime: { nil }, defaults: d)
    #expect(!offer.answered)
    offer.notNow()
    #expect(offer.answered && !offer.isOn && !MerchantSuggestionsSetting.isEnabled(d))
    MerchantSuggestionsSetting.forget(d)
    #expect(!offer.answered)
    MerchantSuggestionsSetting.setEnabled(true, d)
    #expect(offer.answered)
    MerchantSuggestionsSetting.forget(d)
    offer.turnOn()
    #expect(offer.answered && offer.isOn)
  }
}
