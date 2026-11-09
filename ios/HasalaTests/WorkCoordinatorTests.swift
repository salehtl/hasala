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

  static func coordinator(
    _ log: Log, mailbox: Bool = true, delay: Duration = .milliseconds(50), mailHalt: MailboxHaltCode? = nil
  ) -> WorkCoordinator {
    let mail: WorkCoordinator.MailboxStage = { trigger, _ in
      log.add("mail.\(trigger.rawValue)")
      var report = CycleReport()
      report.haltedOn = mailHalt
      return report
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

  @Test(arguments: [HaltKind.tampered(.chainBreak), .serverRestored, .tamperedResend, .inconsistent("fold"), .rosterInvalid, .unprovedRevocation, .unexpectedGone])
  func everyHaltIsShownAndTheMailWaits(_ halt: HaltKind) async {
    let log = Log()
    log.syncStop.withLock { $0 = .halted(halt) }
    let out = await Self.coordinator(log).run(.foreground)
    #expect(out.failed)
    #expect(log.all == ["sync.foreground", "stopped.\(SyncStop.halted(halt))", "committed"])
  }

  @Test func aStopThatIsNoHaltIsNotShown() {
    for stop: SyncStop in [.offline, .rateLimited(retryAfter: 5), .protocolError("x"), .notNow, .cancelled, .suspended] {
      #expect(!WorkCoordinator.surfaces(stop), "\(stop)")
    }
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

  @Test(.timeLimit(.minutes(1))) func closingLeavesNoSyncRunningOnceFinished() async {
    let log = Log()
    let c = WorkCoordinator(
      stages: .init(
        sync: { _, _ in
          log.add("sync.start")
          try? await Task.sleep(for: .milliseconds(300))
          log.add("sync.end")
          return (newData: false, stop: nil)
        }, mailbox: nil, committed: {}, stopped: { _ in }))
    let watcher = Task { await c.run(.foreground) }
    try? await Task.sleep(for: .milliseconds(50))
    await c.close()
    await c.finished()
    #expect(log.all == ["sync.start", "sync.end"])
    _ = await watcher.value
  }

  @Test(.timeLimit(.minutes(1))) func closingWaitsForTheMailStageToStop() async {
    let log = Log()
    let c = WorkCoordinator(
      stages: .init(
        sync: { _, _ in (newData: false, stop: nil) },
        mailbox: { _, _ in
          log.add("mail.start")
          try? await Task.sleep(for: .milliseconds(100))
          let ended = ContinuousClock.now + .milliseconds(100)
          while ContinuousClock.now < ended { await Task.yield() }
          log.add("mail.end")
          return CycleReport()
        }, committed: {}, stopped: { _ in }))
    let watcher = Task { await c.run(.foreground) }
    try? await Task.sleep(for: .milliseconds(50))
    await c.close()
    await c.finished()
    #expect(log.all == ["mail.start", "mail.end"])
    _ = await watcher.value
  }

  @Test(.timeLimit(.minutes(1))) func aStopThatClosesTheAccountDoesNotWaitForItsOwnRun() async {
    let log = Log()
    let holder = Mutex<WorkCoordinator?>(nil)
    let c = WorkCoordinator(
      stages: .init(
        sync: { _, _ in (newData: false, stop: .needsSignIn) }, mailbox: nil, committed: {},
        stopped: { _ in
          let me = holder.withLock { $0 }
          await me?.close()
          await me?.finished()
          log.add("closed")
        }))
    holder.withLock { $0 = c }
    _ = await c.run(.foreground)
    #expect(log.all == ["closed"])
  }

  @Test(.timeLimit(.minutes(1))) func aStopThatClosesTheAccountIsNotCancelledByThatClose() async {
    let log = Log()
    let holder = Mutex<WorkCoordinator?>(nil)
    let c = WorkCoordinator(
      stages: .init(
        sync: { _, _ in (newData: false, stop: .wipe) }, mailbox: nil, committed: {},
        stopped: { _ in
          let me = holder.withLock { $0 }
          await me?.close()
          log.add("cancelled: \(Task.isCancelled)")
        }))
    holder.withLock { $0 = c }
    _ = await c.run(.foreground)
    #expect(log.all == ["cancelled: false"])
  }

  @Test(.timeLimit(.minutes(1))) func aCallerGivingUpDoesNotCancelTheStopBeingHandled() async {
    let log = Log()
    let c = WorkCoordinator(
      stages: .init(
        sync: { _, _ in (newData: false, stop: .wipe) }, mailbox: nil, committed: {},
        stopped: { _ in
          try? await Task.sleep(for: .milliseconds(150))
          log.add("cancelled: \(Task.isCancelled)")
        }))
    let job = Task { await c.run(.bgProcessing) }
    try? await Task.sleep(for: .milliseconds(50))
    job.cancel()
    _ = await job.value
    await c.close()
    while log.all.isEmpty { await Task.yield() }
    #expect(log.all == ["cancelled: false"])
  }

  @Test(.timeLimit(.minutes(1))) func aPauseWaitsForASyncItsCallerGaveUpOn() async {
    let log = Log()
    let c = WorkCoordinator(
      stages: .init(
        sync: { _, _ in
          try? await Task.sleep(for: .milliseconds(300))
          log.add("sync.end")
          return (newData: false, stop: nil)
        }, mailbox: nil, committed: {}, stopped: { _ in }))
    let job = Task { await c.run(.bgProcessing) }
    try? await Task.sleep(for: .milliseconds(50))
    job.cancel()
    _ = await job.value
    await c.pause()
    #expect(log.all == ["sync.end"])
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

  @Test func aPullJoinsARunThatReadsMail() async {
    let log = Log()
    let c = Self.coordinator(log, delay: .milliseconds(80))
    await withTaskGroup(of: Void.self) { g in
      g.addTask { _ = await c.run(.launch) }
      try? await Task.sleep(for: .milliseconds(20))
      g.addTask { _ = await c.run(.refresh) }
      g.addTask { _ = await c.run(.refresh) }
    }
    #expect(await c.runs == 1)
    #expect(log.all == ["sync.launch", "mail.launch", "committed"])
  }

  @Test func aPullBehindAnUploadStillReadsMail() async {
    let log = Log()
    let c = Self.coordinator(log, delay: .milliseconds(80))
    await withTaskGroup(of: Void.self) { g in
      g.addTask { _ = await c.run(.authored) }
      try? await Task.sleep(for: .milliseconds(20))
      g.addTask { _ = await c.run(.refresh) }
    }
    #expect(await c.runs == 2)
    #expect(log.all.filter { $0.hasPrefix("mail.") } == ["mail.refresh"])
    #expect(WorkCoordinator.joins(.refresh, running: .authored, queued: .silentPush))
    #expect(!WorkCoordinator.joins(.refresh, running: .authored, queued: nil))
    #expect(!WorkCoordinator.joins(.silentPush, running: .launch, queued: nil))
  }

  @Test func aRunThatWentThroughSaysUpdated() async {
    let out = await Self.coordinator(Log()).run(.refresh)
    #expect(out.ran)
    #expect(out.settled == .updated)
    #expect(out.announcement == "Updated")
  }

  @Test func aSpacedForegroundRunSaysNothing() async {
    let c = Self.coordinator(Log())
    _ = await c.run(.foreground)
    let skipped = await c.run(.foreground)
    #expect(!skipped.ran)
    #expect(skipped.settled == .notRun)
    #expect(skipped.announcement == nil)
  }

  @Test func aCallerWhoseBudgetRanOutNeverHearsUpdated() async {
    let c = Self.coordinator(Log(), delay: .milliseconds(400))
    let out = await c.run(.refresh, budget: .milliseconds(50))
    #expect(out.timedOut)
    #expect(out.settled == .stillRunning)
    #expect(out.announcement == nil)
  }

  @Test func offlineIsNotUpdated() async {
    let log = Log()
    log.syncStop.withLock { $0 = .offline }
    let out = await Self.coordinator(log).run(.refresh)
    #expect(out.settled == .offline)
    #expect(out.announcement == "Couldn't check. No connection.")
  }

  @Test(arguments: [MailboxHaltCode.reconnectRequired, .accountFull, .templatesUnavailable, .noMailbox])
  func aMailStopIsNotUpdated(halt: MailboxHaltCode) async {
    let c = Self.coordinator(Log(), mailHalt: halt)
    let out = await c.run(.refresh)
    #expect(out.mailHalt == halt)
    #expect(out.settled == .mailStopped)
    #expect(out.announcement == "Bank alerts stopped")
  }

  @Test func aMailCycleThatCouldNotConnectIsOffline() async {
    let out = await Self.coordinator(Log(), mailHalt: .offline).run(.refresh)
    #expect(out.settled == .offline)
  }

  @Test func aStagingPauseIsStillUpdated() async {
    let out = await Self.coordinator(Log(), mailHalt: .stagingFull).run(.refresh)
    #expect(out.settled == .updated)
  }

  @Test func aRunThatDidNotStartDoesNotLookLikeACleanRun() async {
    let c = Self.coordinator(Log(), delay: .zero)
    _ = await c.run(.foreground)
    let spaced = await c.run(.foreground)
    await c.pause()
    let paused = await c.run(.refresh)
    await c.close()
    let closed = await c.run(.refresh)
    for out in [spaced, paused, closed] {
      #expect(!out.ran && out.stop == .notNow)
      #expect(!out.failed && out.settled == .notRun)
    }
  }

  @Test func whatWasAskedForDuringAPauseComesBackAtResume() async {
    let c = Self.coordinator(Log(), delay: .zero)
    await c.pause()
    _ = await c.run(.authored)
    _ = await c.run(.silentPush)
    _ = await c.run(.authored)
    #expect(await c.runs == 0)
    #expect(await c.resume() == .silentPush)
    #expect(await c.resume() == nil)
  }

  @Test func aRerunWaitingWhenThePauseStartsComesBackAtResume() async {
    let p = Probe()
    let c = Self.probed(p, syncFor: .milliseconds(200))
    let running = Task { await c.run(.launch) }
    try? await Task.sleep(for: .milliseconds(50))
    let waiting = Task { await c.run(.authored) }
    try? await Task.sleep(for: .milliseconds(20))
    #expect(await c.queued == .authored)
    await c.pause()
    #expect(await c.runs == 1)
    #expect(await c.resume() == .authored)
    _ = await (running.value, waiting.value)
  }

  @Test func aPauseWithNothingAskedForResumesToNothing() async {
    let c = Self.coordinator(Log(), delay: .zero)
    await c.pause()
    #expect(await c.resume() == nil)
  }

  @Test func closingForgetsWhatWasAskedForDuringAPause() async {
    let c = Self.coordinator(Log(), delay: .zero)
    await c.pause()
    _ = await c.run(.authored)
    await c.close()
    #expect(await c.resume() == nil)
  }

  @Test(arguments: [WorkCoordinator.Trigger.authored, .silentPush])
  func aSpacedForegroundDuringAPauseDoesNotTakeOverWhatWasHeld(_ trigger: WorkCoordinator.Trigger) async {
    let c = Self.coordinator(Log(), delay: .zero)
    _ = await c.run(.foreground)
    await c.pause()
    _ = await c.run(trigger)
    _ = await c.run(.foreground)
    let held = await c.resume()
    #expect(held == trigger)
    if let held { _ = await c.run(held) }
    #expect(await c.runs == 2)
  }

  @Test(arguments: [WorkCoordinator.Trigger.authored, .silentPush])
  func aSpacedForegroundBeforeTheHeldWorkIsNotKept(_ trigger: WorkCoordinator.Trigger) async {
    let c = Self.coordinator(Log(), delay: .zero)
    _ = await c.run(.foreground)
    await c.pause()
    _ = await c.run(.foreground)
    _ = await c.run(trigger)
    #expect(await c.resume() == trigger)
  }

  @Test func aSpacedForegroundAloneDuringAPauseLeavesNothingToRun() async {
    let c = Self.coordinator(Log(), delay: .zero)
    _ = await c.run(.foreground)
    await c.pause()
    let out = await c.run(.foreground)
    #expect(!out.ran && out.stop == .notNow)
    #expect(await c.resume() == nil)
  }

  @Test func aForegroundDueDuringAPauseRunsAtResume() async {
    let c = Self.coordinator(Log(), delay: .zero)
    await c.pause()
    _ = await c.run(.authored)
    _ = await c.run(.foreground)
    let held = await c.resume()
    #expect(held == .foreground)
    if let held { _ = await c.run(held) }
    #expect(await c.runs == 1)
  }

  static func slowStop(_ log: Log, _ stop: SyncStop, after: Duration = .milliseconds(150)) -> WorkCoordinator {
    WorkCoordinator(
      stages: .init(
        sync: { _, _ in
          try? await Task.sleep(for: after)
          return (newData: false, stop: stop)
        }, mailbox: nil, committed: { log.add("committed") }, stopped: { log.add("stopped.\($0)") }))
  }

  @Test(.timeLimit(.minutes(1)), arguments: [SyncStop.wipe, .needsSignIn, .frozen, .halted(.serverRestored)])
  func aStopFoundAfterTheOnlyCallerGaveUpStillReachesTheGate(_ stop: SyncStop) async {
    let log = Log()
    let c = Self.slowStop(log, stop)
    let job = Task { await c.run(.bgProcessing) }
    try? await Task.sleep(for: .milliseconds(50))
    job.cancel()
    #expect(await job.value.stop == .cancelled)
    #expect(log.all.isEmpty)
    await c.finished()
    #expect(log.all == ["stopped.\(stop)"])
  }

  @Test(.timeLimit(.minutes(1))) func aStopFoundAfterTheAccountClosedIsDropped() async {
    let log = Log()
    let c = Self.slowStop(log, .wipe)
    let job = Task { await c.run(.foreground) }
    try? await Task.sleep(for: .milliseconds(50))
    await c.close()
    _ = await job.value
    await c.finished()
    try? await Task.sleep(for: .milliseconds(50))
    #expect(log.all.isEmpty)
  }

  @Test(.timeLimit(.minutes(1))) func aCleanSyncAfterTheOnlyCallerGaveUpTellsTheGateNothing() async {
    let log = Log()
    let c = WorkCoordinator(
      stages: .init(
        sync: { _, _ in
          try? await Task.sleep(for: .milliseconds(150))
          return (newData: false, stop: .offline)
        }, mailbox: nil, committed: {}, stopped: { log.add("stopped.\($0)") }))
    let job = Task { await c.run(.bgProcessing) }
    try? await Task.sleep(for: .milliseconds(50))
    job.cancel()
    _ = await job.value
    await c.finished()
    #expect(log.all.isEmpty)
  }

  @Test(.timeLimit(.minutes(1))) func aStopSeenByARunAndByTheOneItsCallerLeftIsHandledOnce() async {
    let log = Log()
    let c = WorkCoordinator(
      stages: .init(
        sync: { _, _ in
          try? await Task.sleep(for: .milliseconds(150))
          return (newData: false, stop: .wipe)
        }, mailbox: nil, committed: {},
        stopped: {
          log.add("start.\($0)")
          try? await Task.sleep(for: .milliseconds(200))
          log.add("end.\($0)")
        }))
    let job = Task { await c.run(.bgProcessing) }
    try? await Task.sleep(for: .milliseconds(50))
    job.cancel()
    _ = await job.value
    try? await Task.sleep(for: .milliseconds(20))
    _ = await c.run(.foreground)
    for _ in 0..<200 where log.all.count < 2 { try? await Task.sleep(for: .milliseconds(5)) }
    try? await Task.sleep(for: .milliseconds(50))
    #expect(log.all == ["start.\(SyncStop.wipe)", "end.\(SyncStop.wipe)"])
  }

  @Test(.timeLimit(.minutes(1))) func aHandlerClosingTheAccountDoesNotWaitForItsOwnHandOver() async {
    let log = Log()
    let holder = Mutex<WorkCoordinator?>(nil)
    let c = WorkCoordinator(
      stages: .init(
        sync: { _, _ in
          try? await Task.sleep(for: .milliseconds(150))
          return (newData: false, stop: .wipe)
        }, mailbox: nil, committed: {},
        stopped: { _ in
          let me = holder.withLock { $0 }
          await me?.close()
          await me?.finished()
          log.add("closed")
        }))
    holder.withLock { $0 = c }
    let job = Task { await c.run(.bgProcessing) }
    try? await Task.sleep(for: .milliseconds(50))
    job.cancel()
    _ = await job.value
    await c.finished()
    #expect(log.all == ["closed"])
  }

  @Test(.timeLimit(.minutes(1))) func aHandlerClosingThroughAnotherTaskDoesNotWaitForItsOwnHandOver() async {
    let log = Log()
    let holder = Mutex<WorkCoordinator?>(nil)
    let c = WorkCoordinator(
      stages: .init(
        sync: { _, _ in (newData: false, stop: .wipe) }, mailbox: nil, committed: {},
        stopped: { _ in
          let me = holder.withLock { $0 }
          await Task {
            await me?.close()
            await me?.finished()
          }.value
          log.add("closed")
        }))
    holder.withLock { $0 = c }
    let out = await c.run(.launch)
    #expect(out.stop == .wipe)
    #expect(log.all == ["closed"])
  }

  static func handingSlowly(
    _ log: Log, commitFor: Duration = .zero, sync: @escaping WorkCoordinator.SyncStage
  ) -> WorkCoordinator {
    WorkCoordinator(
      stages: .init(
        sync: sync, mailbox: nil,
        committed: {
          try? await Task.sleep(for: commitFor)
          log.add("committed")
        },
        stopped: {
          log.add("start.\($0)")
          try? await Task.sleep(for: .milliseconds(200))
          log.add("end.\($0)")
        }))
  }

  static func untilLogged(_ log: Log, _ entry: String) async {
    for _ in 0..<400 where !log.all.contains(entry) { try? await Task.sleep(for: .milliseconds(5)) }
  }

  @Test(.timeLimit(.minutes(1))) func anOutsideWaitCoversAHandOverAlreadyUnderWay() async {
    let log = Log()
    let c = Self.handingSlowly(log) { _, _ in
      try? await Task.sleep(for: .milliseconds(100))
      return (newData: false, stop: .wipe)
    }
    let job = Task { await c.run(.bgProcessing) }
    try? await Task.sleep(for: .milliseconds(30))
    job.cancel()
    _ = await job.value
    await Self.untilLogged(log, "start.\(SyncStop.wipe)")
    await c.finished()
    #expect(log.all == ["start.\(SyncStop.wipe)", "end.\(SyncStop.wipe)"])
  }

  @Test(.timeLimit(.minutes(1))) func anOutsideWaitCoversTheRunThatIsHandingOver() async {
    let log = Log()
    let c = Self.handingSlowly(log) { _, _ in (newData: false, stop: .halted(.serverRestored)) }
    let job = Task { await c.run(.launch) }
    await Self.untilLogged(log, "start.\(SyncStop.halted(.serverRestored))")
    await c.finished()
    #expect(log.all.contains("end.\(SyncStop.halted(.serverRestored))"))
    #expect(log.all.contains("committed"))
    #expect(await c.runs == 1)
    _ = await job.value
  }

  @Test(.timeLimit(.minutes(1))) func aPauseWaitsForAHandOverAndANewerRun() async {
    let log = Log()
    let calls = Mutex(0)
    let c = Self.handingSlowly(log, commitFor: .milliseconds(400)) { _, _ in
      let n = calls.withLock {
        $0 += 1
        return $0
      }
      if n > 1 { return (newData: false, stop: nil) }
      try? await Task.sleep(for: .milliseconds(100))
      return (newData: false, stop: .wipe)
    }
    let job = Task { await c.run(.bgProcessing) }
    try? await Task.sleep(for: .milliseconds(30))
    job.cancel()
    _ = await job.value
    await Self.untilLogged(log, "start.\(SyncStop.wipe)")
    let newer = Task { await c.run(.authored) }
    try? await Task.sleep(for: .milliseconds(20))
    await c.pause()
    #expect(log.all.contains("end.\(SyncStop.wipe)"))
    #expect(log.all.contains("committed"))
    _ = await newer.value
  }

  @Test(.timeLimit(.minutes(1))) func aWaitCoversAStopHandedOverAfterTheRunWasCancelled() async {
    let log = Log()
    let c = Self.handingSlowly(log) { _, _ in
      try? await Task.sleep(for: .milliseconds(150))
      return (newData: false, stop: .needsSignIn)
    }
    let job = Task { await c.run(.bgProcessing) }
    try? await Task.sleep(for: .milliseconds(30))
    job.cancel()
    await c.finished()
    #expect(log.all == ["start.\(SyncStop.needsSignIn)", "end.\(SyncStop.needsSignIn)"])
    _ = await job.value
  }
}
