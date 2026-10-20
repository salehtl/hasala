import CoreMailbox
import CoreSync
import Synchronization
import Testing

@testable import Hasala

/// The trigger coordinator (spec 04 §3 "one entry point"): one run in flight, one
/// trailing rerun, the stages in order, and the stops only the gate acts on.
@Suite("Work coordinator")
struct WorkCoordinatorTests {
  nonisolated final class Log: Sendable {
    let entries = Mutex<[String]>([])
    let syncStop = Mutex<SyncStop?>(nil)
    func add(_ s: String) { entries.withLock { $0.append(s) } }
    var all: [String] { entries.withLock { $0 } }
  }

  static func coordinator(_ log: Log, mailbox: Bool = true, delay: Duration = .milliseconds(50)) -> WorkCoordinator {
    let mail: WorkCoordinator.MailboxStage = { trigger, _ in
      log.add("mail.\(trigger.rawValue)")
      return CycleReport()
    }
    let sync: WorkCoordinator.SyncStage = { trigger, _ in
      log.add("sync.\(trigger.rawValue)")
      try? await Task.sleep(for: delay)
      let stop: SyncStop? = log.syncStop.withLock { $0 }
      return (newData: true, stop: stop)
    }
    let committed: WorkCoordinator.CommittedStage = { log.add("committed") }
    let stopped: WorkCoordinator.StoppedStage = { stop in log.add("stopped.\(stop)") }
    let stages = WorkCoordinator.Stages(sync: sync, mailbox: mailbox ? mail : nil, committed: committed, stopped: stopped)
    return WorkCoordinator(stages: stages)
  }

  @Test func aRunIsSyncThenMailThenTheScreens() async {
    let log = Log()
    let c = Self.coordinator(log)
    let out = await c.run(.launch)
    #expect(out.newData && !out.failed)
    #expect(log.all == ["sync.launch", "mail.launch", "committed"])
  }

  @Test func tryAgainRunsTheMailCycleAsARetry() async {
    let log = Log()
    _ = await Self.coordinator(log).run(.retryMail)
    #expect(log.all == ["sync.refresh", "mail.retry", "committed"])
    #expect(WorkCoordinator.Trigger.retryMail.strength > WorkCoordinator.Trigger.refresh.strength)
  }

  @Test func anAuthoredRunReadsNoMail() async {
    let log = Log()
    _ = await Self.coordinator(log).run(.authored)
    #expect(log.all == ["sync.authored", "committed"])
  }

  @Test func aBurstOfTriggersIsOneRunAndOneRerun() async {
    let log = Log()
    let c = Self.coordinator(log)
    await withTaskGroup(of: Void.self) { g in
      g.addTask { _ = await c.run(.authored) }
      try? await Task.sleep(for: .milliseconds(10))
      for _ in 0..<5 { g.addTask { _ = await c.run(.authored) } }
      g.addTask { _ = await c.run(.silentPush) }
    }
    // The first run, then ONE trailing rerun with the strongest trigger asked for.
    #expect(await c.runs == 2)
    #expect(log.all.filter { $0.hasPrefix("sync.") } == ["sync.authored", "sync.silentPush"])
  }

  @Test func aDeletedAccountStopsTheRunAndTellsTheGate() async {
    let log = Log()
    log.syncStop.withLock { $0 = .wipe }
    let out = await Self.coordinator(log).run(.silentPush)
    #expect(out.failed)
    #expect(log.all == ["sync.silentPush", "stopped.wipe"])
  }

  @Test func offlineSkipsTheMailAndStillReloads() async {
    let log = Log()
    log.syncStop.withLock { $0 = .offline }
    let out = await Self.coordinator(log).run(.foreground)
    #expect(out.failed)
    #expect(log.all == ["sync.foreground", "committed"])
  }

  @Test func anUpdateRequiredIsShownAndTheMailWaits() async {
    let log = Log()
    log.syncStop.withLock { $0 = .halted(.updateRequired) }
    let out = await Self.coordinator(log).run(.launch)
    #expect(out.failed)
    let all = log.all
    #expect(all.count == 3 && all.first == "sync.launch" && all.last == "committed")
    #expect(all.count == 3 && all[1].hasPrefix("stopped.halted") && all[1].contains("updateRequired"))
  }

  // MARK: Budgets and cancellation

  nonisolated final class Probe: Sendable {
    let deadlines = Mutex<[ContinuousClock.Instant?]>([])
    let mailSawCancel = Mutex<Bool>(false)
    let committed = Mutex<Int>(0)
  }

  static func probed(_ p: Probe, syncFor: Duration, mailFor: Duration = .zero) -> WorkCoordinator {
    WorkCoordinator(
      stages: .init(
        sync: { _, deadline in
          p.deadlines.withLock { $0.append(deadline) }
          try? await Task.sleep(for: syncFor)
          return (newData: false, stop: nil)
        },
        mailbox: { _, _ in
          try? await Task.sleep(for: mailFor)
          if Task.isCancelled { p.mailSawCancel.withLock { $0 = true } }
          return CycleReport()
        },
        committed: { p.committed.withLock { $0 += 1 } }, stopped: { _ in }))
  }

  /// A silent push behind a long launch run returns when its own 25 s (here 200 ms) run
  /// out, not when the launch run ends.
  @Test func aBudgetedCallerWaitsNoLongerThanItsBudget() async {
    let p = Probe()
    let c = Self.probed(p, syncFor: .milliseconds(1500))
    let launch = Task { await c.run(.launch) }
    try? await Task.sleep(for: .milliseconds(100))
    let start = ContinuousClock.now
    let out = await c.run(.silentPush, budget: .milliseconds(200))
    let waited = ContinuousClock.now - start
    #expect(waited < .milliseconds(1000))
    #expect(out.stop == .notNow && !out.failed)
    _ = await launch.value
  }

  /// The trailing rerun runs to its own callers' deadline: none when one of them has no
  /// budget, never the first run's (long past here).
  @Test func theRerunRunsToItsCallersDeadline() async {
    let p = Probe()
    let c = Self.probed(p, syncFor: .milliseconds(300))
    let push = Task { await c.run(.silentPush, budget: .milliseconds(100)) }
    try? await Task.sleep(for: .milliseconds(50))
    _ = await c.run(.launch)
    _ = await push.value
    let ds = p.deadlines.withLock { $0 }
    #expect(ds.count == 2)
    #expect(ds.first.flatMap { $0 } != nil)
    #expect(ds.count == 2 && ds[1] == nil)
  }

  @Test func aRerunAskedForByBudgetedCallersGetsTheLatestDeadline() async {
    let p = Probe()
    let c = Self.probed(p, syncFor: .milliseconds(200))
    let first = Task { await c.run(.authored) }
    try? await Task.sleep(for: .milliseconds(50))
    let asked = ContinuousClock.now
    async let a = c.run(.silentPush, budget: .seconds(5))
    async let b = c.run(.bgRefresh, budget: .seconds(10))
    _ = await (a, b)
    _ = await first.value
    let ds = p.deadlines.withLock { $0 }
    #expect(ds.count == 2)
    if ds.count == 2, let d = ds[1] {
      #expect(d > asked + .seconds(9))
    } else {
      Issue.record("the rerun had no deadline")
    }
  }

  /// A BGTask's expiration cancels its job: the caller returns at once, and with nobody
  /// else waiting the run stops (the Gmail cycle sees the cancellation, no reload).
  @Test func cancellingTheOnlyCallerStopsTheRun() async {
    let p = Probe()
    let c = Self.probed(p, syncFor: .milliseconds(50), mailFor: .milliseconds(800))
    let job = Task { await c.run(.bgProcessing) }
    try? await Task.sleep(for: .milliseconds(150))
    let start = ContinuousClock.now
    job.cancel()
    let out = await job.value
    #expect(ContinuousClock.now - start < .milliseconds(400))
    #expect(out.stop == .cancelled)
    try? await Task.sleep(for: .milliseconds(200))
    #expect(p.mailSawCancel.withLock { $0 })
    #expect(p.committed.withLock { $0 } == 0)
  }

  @Test func cancellingOneOfTwoCallersLeavesTheRunGoing() async {
    let p = Probe()
    let c = Self.probed(p, syncFor: .milliseconds(50), mailFor: .milliseconds(300))
    let job = Task { await c.run(.bgProcessing) }
    try? await Task.sleep(for: .milliseconds(20))
    let other = Task { await c.run(.foreground) }
    try? await Task.sleep(for: .milliseconds(100))
    job.cancel()
    #expect(await job.value.stop == .cancelled)
    _ = await other.value
    #expect(!p.mailSawCancel.withLock { $0 })
    #expect(p.committed.withLock { $0 } >= 1)
  }

  /// Before a deletion wipes the store: the run in flight ends first, and nothing new
  /// starts until `resume`.
  @Test func pauseWaitsForTheRunAndHoldsNewOnes() async {
    let p = Probe()
    let c = Self.probed(p, syncFor: .milliseconds(200))
    let running = Task { await c.run(.authored) }
    try? await Task.sleep(for: .milliseconds(50))
    await c.pause()
    #expect(p.committed.withLock { $0 } == 1)
    _ = await c.run(.authored)
    #expect(await c.runs == 1)
    await c.resume()
    _ = await c.run(.authored)
    #expect(await c.runs == 2)
    _ = await running.value
  }

  @Test func foregroundRunsAreSpacedAndAClosedCoordinatorRunsNothing() async {
    let log = Log()
    let c = Self.coordinator(log, mailbox: false, delay: .zero)
    _ = await c.run(.foreground)
    _ = await c.run(.foreground)
    #expect(await c.runs == 1)
    await c.close()
    _ = await c.run(.launch)
    #expect(await c.runs == 1)
  }

  @Test func closingCancelsTheRunInFlight() async {
    let p = Probe()
    let c = Self.probed(p, syncFor: .milliseconds(50), mailFor: .milliseconds(800))
    let watcher = Task { await c.run(.foreground) }
    try? await Task.sleep(for: .milliseconds(150))
    await c.close()
    _ = await watcher.value
    #expect(p.mailSawCancel.withLock { $0 })
  }

  @Test func pullToRefreshIsNotSpacedAndReadsMail() async {
    let log = Log()
    let c = Self.coordinator(log, delay: .zero)
    _ = await c.run(.foreground)
    _ = await c.run(.refresh)
    _ = await c.run(.refresh)
    #expect(await c.runs == 3)
    #expect(log.all.filter { $0.hasPrefix("mail.") } == ["mail.foreground", "mail.refresh", "mail.refresh"])
  }
}
