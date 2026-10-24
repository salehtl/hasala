import CoreCategorize
import CoreDomain
import CoreJSON
import CoreStore
import Foundation
import SwiftUI
import Synchronization
import Testing

@testable import Hasala

@Suite("Model suggestion stage")
struct ModelSuggestionStageTests {
  struct Fake: CategoryModel {
    let modelTag: String
    let state: ModelAvailability
    func availability() -> ModelAvailability { state }
    func suggest(subject: String, allowed: [AllowedCategory]) async -> ModelAnswer { .unknown }
  }

  let apple = Fake(modelTag: "apple-fm/27.1", state: .available)

  @Test func clefRunsFirstWhenTheSwitchIsOn() {
    let stages = ModelSuggestionStage.stages(
      onDevice: apple, cloud: Fake(modelTag: "cf-clef/1", state: .available), onDeviceAlone: false)
    #expect(stages.map(\.model.modelTag) == ["cf-clef/1", "apple-fm/27.1"])
    #expect(stages[0].accepts("مطعم الياسمين الشعبي"))
    #expect(!stages[1].accepts("مطعم الياسمين الشعبي"))
  }

  @Test func noModelRunsInReleaseWhenTheSwitchIsOff() {
    let off = Fake(modelTag: "cf-clef/1", state: .notEnabled)
    #expect(ModelSuggestionStage.stages(onDevice: apple, cloud: off, onDeviceAlone: false).isEmpty)
    #expect(ModelSuggestionStage.stages(onDevice: apple, cloud: nil, onDeviceAlone: false).isEmpty)
  }

  @Test func debugRunsTheOnDeviceModelAloneWhenTheSwitchIsOff() {
    let off = Fake(modelTag: "cf-clef/1", state: .notEnabled)
    #expect(ModelSuggestionStage.stages(onDevice: apple, cloud: off, onDeviceAlone: true).map(\.model.modelTag) == ["apple-fm/27.1"])
    #expect(ModelSuggestionStage.stages(onDevice: apple, cloud: nil, onDeviceAlone: true).map(\.model.modelTag) == ["apple-fm/27.1"])
  }

  @Test func applesModelRunsWhenTheSwitchIsOnButTheServiceRefusedThisVersion() {
    let refused = Fake(modelTag: "cf-clef/1", state: .notEligible)
    #expect(
      ModelSuggestionStage.stages(onDevice: apple, cloud: refused, onDeviceAlone: false).map(\.model.modelTag) == ["apple-fm/27.1"])
    #expect(
      ModelSuggestionStage.stages(onDevice: apple, cloud: refused, onDeviceAlone: true).map(\.model.modelTag) == ["apple-fm/27.1"])
  }

  nonisolated final class Counting: CategoryModel, Sendable {
    let modelTag: String
    let answer: ModelAnswer
    let after: @Sendable () -> Void
    let log = Mutex<[String]>([])
    init(_ tag: String, answer: ModelAnswer, after: @escaping @Sendable () -> Void = {}) {
      modelTag = tag
      self.answer = answer
      self.after = after
    }
    func availability() -> ModelAvailability { .available }
    func suggest(subject: String, allowed: [AllowedCategory]) async -> ModelAnswer {
      log.withLock { $0.append(subject) }
      after()
      return answer
    }
    var calls: [String] { log.withLock { $0 } }
  }

  @MainActor
  static func waiting(_ a: LiveLedgerMapperTests.Account, suite: String) async throws -> [String] {
    var ids: [String] = []
    var blobs: [AuthoredBlob] = []
    let merchants = [("QWERTY BISTRO", "10:00:00", "4100", "3"), ("ASDF GRILL", "12:00:00", "5200", "4"),
                     ("ZXCV NOODLES", "14:00:00", "6300", "5")]
    if let b = try a.observer.stamps.build(try await a.observer.authorContext(), { o throws(AuthorError) in
      for (i, m) in merchants.enumerated() {
        var row = LiveUndoTests.alert(grant: "u/mbx-a", message: "w\(i)", at: m.1, merchant: m.0, minor: m.2)
        row["category"] = .null
        row["category_source"] = nil
        row["needs_review"] = .bool(true)
        row["gates"] = .object(JSONObject([
          ("ar", .string("pass")), ("sender", .string("trusted")), ("template", .string("dib.card.v1@1")), ("card", .string("known")),
          ("forwarded", .bool(false)),
        ]))
        ids.append(try o.ingest(payload: row, ingestID: String(repeating: m.3, count: 64)))
      }
    }) { blobs.append(b) }
    _ = try await LiveUndoTests.store(a, suite: suite, extra: blobs)
    return ids
  }

  @MainActor
  @Test func theForegroundSweepSpendsTheSharedDayBudgetAndSkipsClefWhenNoneIsLeft() async throws {
    let a = try LiveLedgerMapperTests.account()
    _ = try await Self.waiting(a, suite: "stage.budget.tests")
    let anchor = LiveLedgerMapperTests.anchor
    let budget = Mutex(0)
    let spent = Mutex<[Int]>([])
    let device = Counting("apple-fm/27.1", answer: .unknown)
    let cloud = Counting("cf-clef/1", answer: .unknown)
    let stage = ModelSuggestionStage(
      observer: a.observer, outbox: a.outbox, cache: FMCache(a.context.store), dictionary: AccountRuntime.dictionary,
      onDevice: device, cloud: cloud, onDeviceAlone: false, nowMs: { anchor },
      cloudBudget: { budget.withLock { $0 } }, cloudSpent: { n in spent.withLock { $0.append(n) } }, appActive: { true })
    _ = await stage.run(.foreground)
    #expect(cloud.calls.isEmpty)
    #expect(device.calls.count >= 3)
    #expect(spent.withLock { $0 }.isEmpty)
    budget.withLock { $0 = 2 }
    _ = await stage.run(.foreground)
    #expect(cloud.calls.count == 2 && spent.withLock { $0 } == [2])
  }

  @MainActor
  @Test func theBackgroundStageWaitsOnlyForNamesCloudflareMayStillBeAsked() async throws {
    let a = try LiveLedgerMapperTests.account()
    _ = try await Self.waiting(a, suite: "stage.waiting.tests")
    let anchor = LiveLedgerMapperTests.anchor
    let cloud = Counting("cf-clef/1", answer: .unknown)
    func stage(_ cloud: (any CategoryModel)?) -> ModelSuggestionStage {
      ModelSuggestionStage(
        observer: a.observer, outbox: a.outbox, cache: FMCache(a.context.store), dictionary: AccountRuntime.dictionary,
        onDevice: Counting("apple-fm/27.1", answer: .unknown), cloud: cloud, onDeviceAlone: false, nowMs: { anchor },
        appActive: { true })
    }
    #expect(await stage(cloud).backlogWaiting(BacklogSort.Memo()))
    #expect(await !stage(nil).backlogWaiting(BacklogSort.Memo()))
    #expect(await !stage(Fake(modelTag: "cf-clef/1", state: .notEnabled)).backlogWaiting(BacklogSort.Memo()))
    let r = await stage(cloud).backlogPass(BacklogSort.Memo(), dayLeft: 100)
    #expect(r?.pass.calls == 3 && cloud.calls.count == 3)
    #expect(await !stage(cloud).backlogWaiting(BacklogSort.Memo()))
    #expect(cloud.calls.count == 3)
  }

  nonisolated final class Ledger: Sendable {
    private let log = Mutex<[Int]>([])
    func add(_ n: Int) { log.withLock { $0.append(n) } }
    var spent: [Int] { log.withLock { $0 } }
  }

  nonisolated final class Door: Sendable {
    private let state = Mutex<(open: Bool, waiter: CheckedContinuation<Void, Never>?)>((false, nil))
    var waiting: Bool { state.withLock { $0.waiter != nil } }

    func pass() async {
      await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
        let go = state.withLock { s -> Bool in
          if s.open { return true }
          s.waiter = k
          return false
        }
        if go { k.resume() }
      }
    }

    func open() {
      let k = state.withLock { s -> CheckedContinuation<Void, Never>? in
        s.open = true
        defer { s.waiter = nil }
        return s.waiter
      }
      k?.resume()
    }
  }

  static func until(_ condition: () async -> Bool) async throws {
    for _ in 0..<150 {
      if await condition() { return }
      try await Task.sleep(for: .milliseconds(20))
    }
    Issue.record("the condition never held")
  }

  @MainActor
  static func rig(suite: String, on: OnScreen, cloud: Counting = Counting("cf-clef/1", answer: .unknown)) async throws
    -> (stage: ModelSuggestionStage, ledger: Ledger)
  {
    let a = try LiveLedgerMapperTests.account()
    _ = try await waiting(a, suite: suite)
    let anchor = LiveLedgerMapperTests.anchor
    let ledger = Ledger()
    let stage = ModelSuggestionStage(
      observer: a.observer, outbox: a.outbox, cache: FMCache(a.context.store), dictionary: AccountRuntime.dictionary,
      onDevice: Counting("apple-fm/27.1", answer: .unknown), cloud: cloud, onDeviceAlone: false, nowMs: { anchor },
      cloudBudget: { 40 }, cloudSpent: { ledger.add($0) }, appActive: { on.isOn })
    return (stage, ledger)
  }

  static func coordinator(
    _ stage: ModelSuggestionStage, sync: @escaping @Sendable () async -> Void = {},
    committed: @escaping WorkCoordinator.CommittedStage = {}
  ) -> WorkCoordinator {
    WorkCoordinator(
      stages: WorkCoordinator.Stages(
        sync: { _, _ in
          await sync()
          return (newData: false, stop: nil)
        }, mailbox: nil, categorize: { await stage.run($0) }, committed: committed, stopped: { _ in }))
  }

  @MainActor
  @Test func noModelIsAskedAndNothingIsSpentWhileTheAppIsInTheBackground() async throws {
    let on = OnScreen()
    on.set(true)
    on.update(UIApplication.State.background)
    #expect(!on.isOn)
    let cloud = Counting("cf-clef/1", answer: .unknown)
    let r = try await Self.rig(suite: "stage.background.tests", on: on, cloud: cloud)
    for trigger in [WorkCoordinator.Trigger.launch, .refresh, .foreground] {
      let out = await r.stage.run(trigger)
      #expect(!out.newData && out.offScreen)
    }
    #expect(cloud.calls.isEmpty && r.ledger.spent.isEmpty)
    on.update(UIApplication.State.active)
    let out = await r.stage.run(.launch)
    #expect(!out.offScreen)
    #expect(cloud.calls.count == 3 && r.ledger.spent == [3])
  }

  @MainActor
  @Test func theFlagFollowsTheAppLeavingAndComingBack() {
    let center = NotificationCenter()
    let on = OnScreen()
    on.follow(.background, center: center)
    #expect(!on.isOn)
    center.post(name: UIApplication.willEnterForegroundNotification, object: nil)
    #expect(on.isOn)
    center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
    #expect(!on.isOn)
    center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
    #expect(on.isOn)
    center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
    #expect(!on.isOn)
    let started = OnScreen()
    started.follow(.inactive, center: NotificationCenter())
    #expect(started.isOn)
  }

  @MainActor
  @Test func aForegroundSweepRunsWhileTheAppIsInactiveOnScreen() async throws {
    let on = OnScreen()
    on.update(ScenePhase.inactive)
    #expect(on.isOn)
    on.update(UIApplication.State.inactive)
    #expect(on.isOn)
    let cloud = Counting("cf-clef/1", answer: .unknown)
    let r = try await Self.rig(suite: "stage.inactive.tests", on: on, cloud: cloud)
    _ = await Self.coordinator(r.stage).run(.foreground)
    #expect(cloud.calls.count == 3 && r.ledger.spent == [3])
    on.update(ScenePhase.background)
    #expect(!on.isOn)
  }

  @MainActor
  @Test func aSweepSkippedOffScreenDoesNotHoldBackTheNextForegroundSweep() async throws {
    let on = OnScreen()
    let cloud = Counting("cf-clef/1", answer: .unknown)
    let r = try await Self.rig(suite: "stage.spacing.tests", on: on, cloud: cloud)
    let coordinator = Self.coordinator(r.stage)
    _ = await coordinator.run(.launch)
    _ = await coordinator.run(.foreground)
    #expect(cloud.calls.isEmpty && r.ledger.spent.isEmpty)
    on.set(true)
    _ = await coordinator.run(.foreground)
    #expect(cloud.calls.count == 3 && r.ledger.spent == [3])
    _ = await coordinator.run(.foreground)
    #expect(await coordinator.runs == 3)
  }

  @MainActor
  @Test func aForegroundBehindAQueuedSilentPushSweeps() async throws {
    let on = OnScreen()
    let cloud = Counting("cf-clef/1", answer: .unknown)
    let r = try await Self.rig(suite: "stage.queued.tests", on: on, cloud: cloud)
    let door = Door()
    let coordinator = Self.coordinator(r.stage, committed: { await door.pass() })
    let launch = Task { await coordinator.run(.launch) }
    try await Self.until { door.waiting }
    let push = Task { await coordinator.run(.silentPush) }
    try await Self.until { await coordinator.queued == .silentPush }
    #expect(cloud.calls.isEmpty)
    on.set(true)
    let foreground = Task { await coordinator.run(.foreground) }
    try await Self.until { await coordinator.queued == .foreground }
    door.open()
    _ = await (launch.value, push.value, foreground.value)
    #expect(cloud.calls.count == 3 && r.ledger.spent == [3])
    #expect(WorkCoordinator.queues(.foreground, over: .bgRefresh) && WorkCoordinator.queues(.foreground, over: .bgProcessing))
    #expect(!WorkCoordinator.queues(.foreground, over: .retryMail) && !WorkCoordinator.queues(.silentPush, over: .foreground))
  }

  @MainActor
  @Test func aForegroundReplacedByATryAgainSetsNoSpacing() async throws {
    let on = OnScreen()
    on.set(true)
    let cloud = Counting("cf-clef/1", answer: .unknown)
    let r = try await Self.rig(suite: "stage.retry.tests", on: on, cloud: cloud)
    let door = Door()
    let coordinator = Self.coordinator(r.stage, sync: { await door.pass() })
    let launch = Task { await coordinator.run(.launch) }
    try await Self.until { door.waiting }
    let foreground = Task { await coordinator.run(.foreground) }
    try await Self.until { await coordinator.queued == .foreground }
    let retry = Task { await coordinator.run(.retryMail) }
    try await Self.until { await coordinator.queued == .retryMail }
    door.open()
    _ = await (launch.value, foreground.value, retry.value)
    #expect(await coordinator.runs == 2)
    _ = await coordinator.run(.foreground)
    #expect(await coordinator.runs == 3)
  }

  @MainActor
  @Test func aSkippedBackgroundLaunchKeepsTheSpacingOfTheForegroundBehindIt() async throws {
    let on = OnScreen()
    let cloud = Counting("cf-clef/1", answer: .unknown)
    let r = try await Self.rig(suite: "stage.behind.tests", on: on, cloud: cloud)
    let door = Door()
    let coordinator = Self.coordinator(r.stage, sync: { await door.pass() }, committed: { on.set(true) })
    let launch = Task { await coordinator.run(.launch) }
    try await Self.until { door.waiting }
    let foreground = Task { await coordinator.run(.foreground) }
    try await Self.until { await coordinator.queued == .foreground }
    door.open()
    _ = await (launch.value, foreground.value)
    #expect(cloud.calls.count == 3 && r.ledger.spent == [3])
    #expect(await coordinator.runs == 2)
    _ = await coordinator.run(.foreground)
    #expect(await coordinator.runs == 2)
  }

  @MainActor
  @Test func aSweepThatFinishedOnScreenKeepsTheSpacingWhenTheAppLeavesAfterIt() async throws {
    let on = OnScreen()
    on.set(true)
    let asked = Ledger()
    let cloud = Counting("cf-clef/1", answer: .category("dining")) {
      asked.add(1)
      if asked.spent.count == 3 { on.set(false) }
    }
    let r = try await Self.rig(suite: "stage.finished.tests", on: on, cloud: cloud)
    let coordinator = Self.coordinator(r.stage)
    _ = await coordinator.run(.foreground)
    #expect(cloud.calls.count == 3 && r.ledger.spent == [3] && !on.isOn)
    on.set(true)
    _ = await coordinator.run(.foreground)
    #expect(await coordinator.runs == 1)
  }

  @MainActor
  @Test func noRequestStartsAndNothingIsSpentAfterTheAppLeavesTheScreenMidSweep() async throws {
    let on = OnScreen()
    on.set(true)
    let cloud = Counting("cf-clef/1", answer: .unknown, after: { on.set(false) })
    let r = try await Self.rig(suite: "stage.midsweep.tests", on: on, cloud: cloud)
    let out = await r.stage.run(.foreground)
    #expect(out.offScreen)
    #expect(cloud.calls.count == 1 && r.ledger.spent == [1])
    on.set(true)
    _ = await r.stage.run(.foreground)
    #expect(cloud.calls.count == 2 && Set(cloud.calls).count == 2 && r.ledger.spent == [1, 1])
  }

  @Test func onlyForegroundTriggersRunTheSweep() {
    let runs = WorkCoordinator.Trigger.allCases.filter(ModelSuggestionStage.runs)
    #expect(Set(runs) == [.launch, .foreground, .refresh])
  }
}
