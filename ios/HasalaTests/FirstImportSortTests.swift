import CoreDomain
import Foundation
import HasalaMocks
import HasalaModels
import Synchronization
import Testing

@testable import Hasala

@Suite("First import sort")
struct FirstImportSorterTests {
  final class Saved: Sendable {
    let state: Mutex<(startedMs: Int64, requests: Int)?>
    let ended = Mutex(0)

    init(startedMs: Int64 = 1_000, requests: Int = 0) {
      state = Mutex((startedMs, requests))
    }

    var store: FirstImportSorter.Store {
      FirstImportSorter.Store(
        state: { self.state.withLock { $0 } },
        record: { n in self.state.withLock { s in s = s.map { ($0.startedMs, n) } } },
        end: {
          self.state.withLock { $0 = nil }
          self.ended.withLock { $0 += 1 }
        })
    }

    var requests: Int? { state.withLock { $0?.requests } }
    var endCount: Int { ended.withLock { $0 } }
  }

  final class Script: Sendable {
    let steps: Mutex<[(pending: Int, calls: Int, stop: FirstImportSort.Stop?)?]>
    let seen = Mutex<[Int]>([])

    init(_ steps: [(pending: Int, calls: Int, stop: FirstImportSort.Stop?)?]) {
      self.steps = Mutex(steps)
    }

    func run(_ memo: FirstImportSort.Memo) async -> FirstImportSort.Pass? {
      seen.withLock { $0.append(memo.requests) }
      let next = steps.withLock { s -> (pending: Int, calls: Int, stop: FirstImportSort.Stop?)? in
        s.isEmpty ? nil : s.removeFirst()
      }
      guard let step = next else { return nil }
      var m = memo
      m.requests += step.calls
      return FirstImportSort.Pass(suggestions: [], memo: m, pending: step.pending, calls: step.calls, stop: step.stop)
    }

    var passes: Int { seen.withLock { $0.count } }
    var memos: [Int] { seen.withLock { $0 } }
  }

  final class Sleeps: Sendable {
    let log = Mutex<[Duration]>([])
    var all: [Duration] { log.withLock { $0 } }
    var sleep: @Sendable (Duration) async -> Void {
      { d in
        self.log.withLock { $0.append(d) }
        try? await Task.sleep(for: .milliseconds(2))
      }
    }
  }

  func sorter(
    _ script: Script, _ saved: Saved, sleeps: Sleeps = Sleeps(), active: Bool = true, importing: Bool = false,
    now: Int64 = 2_000
  ) -> FirstImportSorter {
    FirstImportSorter(
      pass: { await script.run($0) }, store: saved.store, nowMs: { now }, appActive: { active }, importRunning: { importing },
      sleep: sleeps.sleep)
  }

  @Test func itRunsPassesUntilNothingIsLeftThenEnds() async {
    let saved = Saved(requests: 5)
    let script = Script([(2, 10, nil), (1, 10, nil), (0, 3, nil)])
    let sleeps = Sleeps()
    let s = sorter(script, saved, sleeps: sleeps)
    await s.start()
    await s.finished()
    #expect(script.passes == 3)
    #expect(script.memos == [5, 15, 25])
    #expect(saved.endCount == 1 && saved.requests == nil)
    #expect(sleeps.all.count == 2)
    #expect(sleeps.all.allSatisfy { $0 > .seconds(29) && $0 <= .milliseconds(FirstImportSort.passSpacingMs) })
    #expect(await !s.isRunning)
  }

  @Test func theRequestCountIsKeptForARelaunch() async {
    let saved = Saved(requests: 0)
    let script = Script([(4, 10, nil), nil, nil, nil])
    let s = sorter(script, saved)
    await s.start()
    await s.finished()
    #expect(script.passes == 4)
    #expect(saved.endCount == 1)
    let again = Saved(requests: 10)
    let next = Script([(0, 0, nil)])
    let t = sorter(next, again)
    await t.start()
    await t.finished()
    #expect(next.memos == [10])
  }

  @Test func aRateLimitBacksOffThreeTimesThenStops() async {
    let saved = Saved()
    let script = Script(Array(repeating: (3, 1, FirstImportSort.Stop.rateLimited), count: 5))
    let sleeps = Sleeps()
    let s = sorter(script, saved, sleeps: sleeps)
    await s.start()
    await s.finished()
    #expect(script.passes == 4)
    #expect(saved.endCount == 1)
    let expected = FirstImportSort.backoffMs.map { Duration.milliseconds($0) }
    #expect(sleeps.all.count == 3)
    for (got, want) in zip(sleeps.all, expected) { #expect(got <= want && got > want - .seconds(1)) }
  }

  @Test(arguments: [FirstImportSort.Stop.capped, .refused, .off, .budgetSpent])
  func aCapOrRefusalStopsAtOnce(_ stop: FirstImportSort.Stop) async {
    let saved = Saved()
    let script = Script([(3, 1, stop), (3, 1, nil)])
    let s = sorter(script, saved)
    await s.start()
    await s.finished()
    #expect(script.passes == 1 && saved.endCount == 1)
  }

  @Test func nothingRunsWhileTheAppIsInTheBackground() async throws {
    let saved = Saved()
    let script = Script([(0, 0, nil)])
    let s = sorter(script, saved, active: false)
    await s.start()
    try await Task.sleep(for: .milliseconds(60))
    #expect(script.passes == 0 && saved.endCount == 0)
    await s.stop()
    #expect(await !s.isRunning)
  }

  @Test func anExpiredSortEndsWithoutAPass() async {
    let saved = Saved(startedMs: 0)
    let script = Script([(5, 5, nil)])
    let s = sorter(script, saved, now: FirstImportSort.lifetimeMs)
    await s.start()
    await s.finished()
    #expect(script.passes == 0 && saved.endCount == 1)
  }

  @Test func withNoSavedSortNothingStarts() async {
    let saved = Saved()
    saved.state.withLock { $0 = nil }
    let script = Script([(5, 5, nil)])
    let s = sorter(script, saved)
    await s.start()
    await s.nudge()
    #expect(await !s.isRunning)
    #expect(script.passes == 0)
  }

  @Test func turningTheSwitchOffEndsTheLoop() async {
    let saved = Saved()
    let script = Script([(3, 1, nil), (3, 1, nil)])
    let s = FirstImportSorter(
      pass: { m in
        let p = await script.run(m)
        saved.state.withLock { $0 = nil }
        return p
      }, store: saved.store, nowMs: { 2_000 }, appActive: { true }, importRunning: { false }, sleep: Sleeps().sleep)
    await s.start()
    await s.finished()
    #expect(script.passes == 1 && saved.endCount == 0)
  }

  @Test func repeatedReadFailuresEndTheSort() async {
    let saved = Saved()
    let script = Script([nil, nil, nil, (0, 0, nil)])
    let s = sorter(script, saved)
    await s.start()
    await s.finished()
    #expect(script.passes == FirstImportSorter.maxFailures && saved.endCount == 1)
  }

  @Test func newRowsWakeASortThatWaitsForTheImport() async throws {
    let saved = Saved()
    let script = Script([(0, 2, nil), (0, 0, nil), (0, 0, nil)])
    let s = FirstImportSorter(
      pass: { await script.run($0) }, store: saved.store, nowMs: { 2_000 }, appActive: { true }, importRunning: { true },
      sleep: { d in try? await Task.sleep(for: d == FirstImportSorter.idleWait ? .seconds(30) : .zero) })
    await s.start()
    for _ in 0..<200 where script.passes < 1 { try await Task.sleep(for: .milliseconds(5)) }
    try await Task.sleep(for: .milliseconds(20))
    #expect(script.passes == 1)
    await s.nudge()
    for _ in 0..<200 where script.passes < 2 { try await Task.sleep(for: .milliseconds(5)) }
    #expect(script.passes == 2)
    await s.stop()
  }

  @Test func theGateRunsOneSweepAtATime() async {
    let gate = SweepGate()
    let inside = Mutex((now: 0, most: 0))
    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<6 {
        group.addTask {
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
@Suite("First import sort setting")
struct FirstImportSettingTests {
  private func freshDefaults() -> UserDefaults {
    let name = "test.firstImport.\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
  }

  @Test func turningOnFromSetupTurnsOnBothSwitchesAndStartsTheSort() {
    let d = freshDefaults()
    #expect(MerchantSuggestionsSetting.firstImport(d) == nil)
    MerchantSuggestionsSetting.turnOnForFirstImport(nowMs: 1_000, d)
    #expect(MerchantSuggestionsSetting.isEnabled(d) && MerchantSuggestionsSetting.isAutoSortEnabled(d))
    #expect(MerchantSuggestionsSetting.firstImport(d)?.startedMs == 1_000)
    #expect(MerchantSuggestionsConsent(defaults: d).isOn && MerchantSuggestionsConsent(defaults: d).autoSortOn)
    MerchantSuggestionsSetting.recordFirstImport(requests: 12, d)
    MerchantSuggestionsSetting.turnOnForFirstImport(nowMs: 9_000, d)
    #expect(MerchantSuggestionsSetting.firstImport(d)?.startedMs == 1_000)
    #expect(MerchantSuggestionsSetting.firstImport(d)?.requests == 12)
  }

  @Test func turningSuggestionsOffInProfileEndsTheSort() {
    let d = freshDefaults()
    MerchantSuggestionsSetting.turnOnForFirstImport(nowMs: 1_000, d)
    let consent = MerchantSuggestionsConsent(defaults: d)
    consent.requestAutoSort(false)
    #expect(MerchantSuggestionsSetting.firstImport(d) != nil)
    consent.request(false)
    #expect(MerchantSuggestionsSetting.firstImport(d) == nil)
    MerchantSuggestionsSetting.setEnabled(true, d)
    #expect(MerchantSuggestionsSetting.firstImport(d) == nil)
    MerchantSuggestionsSetting.recordFirstImport(requests: 3, d)
    #expect(MerchantSuggestionsSetting.firstImport(d) == nil)
  }

  @Test func turningOnInProfileDoesNotStartTheSort() {
    let d = freshDefaults()
    let consent = MerchantSuggestionsConsent(defaults: d)
    consent.request(true)
    consent.turnOn(.suggestions)
    consent.requestAutoSort(true)
    consent.turnOn(.autoSort)
    #expect(MerchantSuggestionsSetting.isAutoSortEnabled(d))
    #expect(MerchantSuggestionsSetting.firstImport(d) == nil)
  }

  @Test func leavingThisIPhoneForgetsTheSort() {
    let d = freshDefaults()
    MerchantSuggestionsSetting.turnOnForFirstImport(nowMs: 1_000, d)
    LocalAccountData.forget(defaults: d)
    #expect(MerchantSuggestionsSetting.firstImport(d) == nil)
    #expect(d.object(forKey: MerchantSuggestionsSetting.firstImportStartedKey) == nil)
    #expect(d.object(forKey: MerchantSuggestionsSetting.firstImportRequestsKey) == nil)
  }

  @Test func theLiveOfferMapsOntoTheTwoSwitches() {
    let d = freshDefaults()
    let offer = LiveCloudSort(runtime: { nil }, defaults: d)
    #expect(offer.isOffered == BuildSurface.showsCloudSuggestions)
    #expect(!offer.isOn)
    offer.turnOn()
    #expect(offer.isOn)
    #expect(MerchantSuggestionsSetting.isEnabled(d) && MerchantSuggestionsSetting.isAutoSortEnabled(d))
    #expect(MerchantSuggestionsSetting.firstImport(d) != nil)
  }
}

@MainActor
@Suite("Setup: sorting the first import")
struct SetupCloudSortTests: AccountSuite {
  func reachResult(_ cloudSort: MockCloudSort?) async -> (SetupModel, AccountServices) {
    var s = services(MockAccountService(existing: .passkey, signedIn: true))
    s.cloudSort = cloudSort
    let m = SetupModel(services: s, displayName: "Maya Rahman", facts: .init(hasSession: true, keysReady: true)) {}
    await m.continueWithBanks()
    m.pickProvider(.gmail)
    await m.connectMail(.gmail)
    m.planWhileScanning()
    for d in [2, 5, 0, 0, 0] { m.incomeEntry.type(.digit(d)) }
    m.continueWithIncome()
    await m.savePlan()
    return (m, s)
  }

  @Test func theOfferComesAfterTheResultAndTurnsOnOnce() async {
    let cloud = MockCloudSort(offered: true)
    let (m, _) = await reachResult(cloud)
    #expect(m.path.last == .result && m.offersCloudSort)
    m.afterResult()
    #expect(m.path.last == .sort && !m.cloudSortOn)
    m.turnOnCloudSort()
    #expect(cloud.turnOnCalls == 1 && m.cloudSortOn && m.path.last == .notifications)
    m.back()
    #expect(m.path.last == .sort && m.cloudSortOn)
    m.turnOnCloudSort()
    #expect(cloud.turnOnCalls == 1 && m.path.last == .notifications)
  }

  @Test func notNowLeavesBothSwitchesOff() async {
    let cloud = MockCloudSort(offered: true)
    let (m, _) = await reachResult(cloud)
    m.afterResult()
    m.cloudSortNotNow()
    #expect(cloud.turnOnCalls == 0 && !cloud.isOn && !m.cloudSortOn && m.path.last == .notifications)
    await m.allowNotifications()
    #expect(m.path.last == .done)
  }

  @Test func aBuildWithoutTheServiceSkipsTheStep() async {
    for cloud in [nil, MockCloudSort(offered: false)] {
      let (m, _) = await reachResult(cloud)
      #expect(!m.offersCloudSort)
      m.afterResult()
      #expect(m.path.last == .notifications)
    }
  }

  @Test func withoutAFirstScanThereIsNothingToSort() async {
    var s = services(MockAccountService(existing: .passkey, signedIn: true))
    s.cloudSort = MockCloudSort(offered: true)
    let m = SetupModel(services: s, displayName: "Maya Rahman", facts: .init(hasSession: true, keysReady: true)) {}
    m.skipBanks()
    await m.savePlan(skip: true)
    #expect(!m.offersCloudSort && m.path.last == .notifications)
  }
}
