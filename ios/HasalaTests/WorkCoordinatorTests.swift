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
}
