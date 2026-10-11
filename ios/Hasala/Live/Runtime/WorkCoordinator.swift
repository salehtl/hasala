import CoreMailbox
import CoreSync
import Foundation

/// The one entry point for an account's work (spec 04 §3): every trigger (launch,
/// foreground, an authored edit, a silent push, the two BGTaskScheduler tasks) asks for a
/// run here, and a run is the stages in order:
///
///   1. sync: reconcile the in-flight batch, pull (fold, snapshot, project), flush
///      (`SyncEngine`; the observer projects at the end of each pull)
///   2. mailbox: the Gmail cycle, when this device holds the link and the trigger is one
///      that reads mail (an `authored` run does not)
///   3. committed: the screens' ledger reloads from the projection
///
/// At most one run is in flight; a trigger that arrives meanwhile asks for ONE trailing
/// rerun (the strongest trigger asked for wins) and waits for it, so a burst of edits is
/// one upload. A stop that only the account gate can act on (deleted elsewhere, signed
/// out by the server, frozen, keys gone) is handed to `stopped` and ends the run.
actor WorkCoordinator {
  nonisolated enum Trigger: String, Sendable, CaseIterable {
    case launch, foreground, authored, silentPush, bgRefresh, bgProcessing

    var sync: SyncTrigger {
      switch self {
      case .launch: .launch
      case .foreground: .foreground
      case .authored: .authored
      case .silentPush: .silentPush
      case .bgRefresh: .bgRefresh
      case .bgProcessing: .bgProcessing
      }
    }

    /// The Gmail cycle this trigger runs; nil for an authored run (nothing new to read).
    var mailbox: MailboxTrigger? {
      switch self {
      case .launch: .launch
      case .foreground: .foreground
      case .authored: nil
      case .silentPush: .silentPush
      case .bgRefresh: .appRefresh
      case .bgProcessing: .processing
      }
    }

    /// A rerun keeps the strongest trigger: anything that reads mail beats `authored`.
    var strength: Int { self == .authored ? 0 : 1 }
  }

  nonisolated struct Outcome: Sendable, Equatable {
    /// Rows stored, ops acknowledged, or mail read (the silent push's `.newData`).
    var newData = false
    /// Why the sync stage stopped early, if it did.
    var stop: SyncStop?

    /// The silent push's `.failed`: the run could not reach the server or stopped.
    var failed: Bool { stop.map { !WorkCoordinator.tolerable($0) } ?? false }
  }

  typealias SyncStage = @Sendable (SyncTrigger, ContinuousClock.Instant?) async -> (newData: Bool, stop: SyncStop?)
  typealias MailboxStage = @Sendable (MailboxTrigger, Int64?) async -> CycleReport
  typealias CommittedStage = @Sendable () async -> Void
  typealias StoppedStage = @Sendable (SyncStop) async -> Void

  /// The stages, as closures over the account's pieces (tests pass their own).
  nonisolated struct Stages: Sendable {
    /// The sync engine's run: whether rows were stored or ops acknowledged, and its stop.
    var sync: @Sendable (_ trigger: SyncTrigger, _ deadline: ContinuousClock.Instant?) async -> (newData: Bool, stop: SyncStop?)
    /// The Gmail cycle; nil when the build has no Google client.
    var mailbox: (@Sendable (_ trigger: MailboxTrigger, _ deadlineMs: Int64?) async -> CycleReport)?
    /// After every run: the screens reload.
    var committed: @Sendable () async -> Void
    /// A stop only the account gate can act on.
    var stopped: @Sendable (_ stop: SyncStop) async -> Void

    init(sync: @escaping SyncStage, mailbox: MailboxStage?, committed: @escaping CommittedStage, stopped: @escaping StoppedStage) {
      self.sync = sync
      self.mailbox = mailbox
      self.committed = committed
      self.stopped = stopped
    }
  }

  /// Foreground runs at least this far apart (spec 04 §7.9).
  static let foregroundSpacing: Duration = .seconds(60)

  private let stages: Stages
  private var inFlight: Task<Outcome, Never>?
  private var rerun: Trigger?
  private var lastForeground: ContinuousClock.Instant?
  private var closed = false
  private(set) var runs = 0

  init(stages: Stages) {
    self.stages = stages
  }

  /// Stops accepting runs (sign-out, wipe). A run in flight finishes its current stage.
  func close() {
    closed = true
    rerun = nil
  }

  /// Runs once, coalescing with a run in flight. `budget` bounds the run (a silent push or
  /// a refresh task gets 25 s); nil runs until done.
  @discardableResult
  func run(_ trigger: Trigger, budget: Duration? = nil) async -> Outcome {
    guard !closed else { return Outcome() }
    if trigger == .foreground {
      let now = ContinuousClock.now
      if let last = lastForeground, now - last < Self.foregroundSpacing { return Outcome() }
      lastForeground = now
    }
    if let t = inFlight {
      if rerun == nil || trigger.strength > (rerun?.strength ?? 0) { rerun = trigger }
      return await t.value
    }
    let deadline = budget.map { ContinuousClock.now + $0 }
    let task = Task { await self.loop(trigger, deadline: deadline) }
    inFlight = task
    return await task.value
  }

  private func loop(_ trigger: Trigger, deadline: ContinuousClock.Instant?) async -> Outcome {
    var out = await once(trigger, deadline: deadline)
    while let next = rerun, !closed {
      rerun = nil
      if out.stop.map(Self.endsTheAccount) == true { break }
      let again = await once(next, deadline: deadline)
      out.newData = out.newData || again.newData
      out.stop = again.stop
    }
    inFlight = nil
    return out
  }

  private func once(_ trigger: Trigger, deadline: ContinuousClock.Instant?) async -> Outcome {
    runs += 1
    var out = Outcome()
    let synced = await stages.sync(trigger.sync, deadline)
    out.newData = synced.newData
    out.stop = synced.stop
    if let stop = synced.stop, Self.endsTheAccount(stop) {
      await stages.stopped(stop)
      return out
    }
    if !closed, let mailbox = stages.mailbox, let mt = trigger.mailbox, synced.stop.map(Self.tolerable) ?? true {
      let deadlineMs = deadline.map { d -> Int64 in
        let left = ContinuousClock.now.duration(to: d)
        return Int64(Date().timeIntervalSince1970 * 1000) + Int64(left.components.seconds * 1000)
      }
      let report = await mailbox(mt, deadlineMs)
      if report.ops > 0 { out.newData = true }
    }
    await stages.committed()
    return out
  }

  /// A stop the account gate acts on: the account was deleted (410), the session is gone,
  /// the account is frozen, or this iPhone's keys or writer are gone.
  static func endsTheAccount(_ stop: SyncStop) -> Bool {
    switch stop {
    case .wipe, .needsSignIn, .needsRebind, .frozen, .needsUnlock, .keysRequired: true
    default: false
    }
  }

  /// A stop the screens read through (the last projection is still good).
  static func tolerable(_ stop: SyncStop) -> Bool {
    switch stop {
    case .rateLimited, .latched, .suspended, .notNow, .cancelled: true
    default: false
    }
  }
}
