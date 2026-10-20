import CoreMailbox
import CoreSync
import Foundation

/// The one entry point for an account's work (spec 04 §3): every trigger (launch,
/// foreground, pull to refresh, an authored edit, a silent push, the two BGTaskScheduler tasks) asks for a
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
/// out by the server, frozen, keys gone, an update required) is handed to `stopped`.
///
/// Budgets and cancellation are per caller:
/// - A caller with a budget (a silent push or a refresh task, 25 s) waits at most that
///   long, even behind a run it did not start; the run carries on without it.
/// - The trailing rerun runs to the most generous deadline of the callers that asked for
///   it (none when any of them has no budget), never to the first run's.
/// - A cancelled caller (a BGTask's expiration handler) returns at once. When no caller
///   is left waiting on the run, the run is cancelled: the Gmail cycle stops at its next
///   check and no later stage starts.
actor WorkCoordinator {
  nonisolated enum Trigger: String, Sendable, CaseIterable {
    /// `refresh` is pull to refresh: a foreground run the person asked for, so it skips
    /// the once-a-minute spacing and the Gmail cycle lists even when the mailbox's history
    /// hasn't moved.
    case launch, foreground, refresh, retryMail, authored, silentPush, bgRefresh, bgProcessing

    var sync: SyncTrigger {
      switch self {
      case .launch: .launch
      case .foreground: .foreground
      case .refresh, .retryMail: .refresh
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
      case .refresh: .refresh
      case .retryMail: .retry
      case .authored: nil
      case .silentPush: .silentPush
      case .bgRefresh: .appRefresh
      case .bgProcessing: .processing
      }
    }

    /// A rerun keeps the strongest trigger: anything that reads mail beats `authored`.
    var strength: Int {
      switch self {
      case .authored: 0
      case .retryMail: 2
      default: 1
      }
    }
  }

  nonisolated struct Outcome: Sendable, Equatable {
    /// Rows stored, ops acknowledged, or mail read (the silent push's `.newData`).
    var newData = false
    /// Why the sync stage stopped early, if it did (`.notNow` when this caller's budget ran
    /// out first, `.cancelled` when it was cancelled).
    var stop: SyncStop?

    /// The silent push's `.failed`: the run could not reach the server or stopped.
    var failed: Bool { stop.map { !WorkCoordinator.tolerable($0) } ?? false }
  }

  typealias SyncStage = @Sendable (SyncTrigger, ContinuousClock.Instant?) async -> (newData: Bool, stop: SyncStop?)
  typealias MailboxStage = @Sendable (MailboxTrigger, Int64?) async -> CycleReport
  typealias CategorizeStage = @Sendable (Trigger) async -> Bool
  typealias CommittedStage = @Sendable () async -> Void
  typealias StoppedStage = @Sendable (SyncStop) async -> Void

  /// The stages, as closures over the account's pieces (tests pass their own).
  nonisolated struct Stages: Sendable {
    /// The sync engine's run: whether rows were stored or ops acknowledged, and its stop.
    var sync: @Sendable (_ trigger: SyncTrigger, _ deadline: ContinuousClock.Instant?) async -> (newData: Bool, stop: SyncStop?)
    /// The Gmail cycle; nil when the build has no Google client.
    var mailbox: (@Sendable (_ trigger: MailboxTrigger, _ deadlineMs: Int64?) async -> CycleReport)?
    var categorize: CategorizeStage?
    /// After every run: the screens reload.
    var committed: @Sendable () async -> Void
    /// A stop only the account gate can act on.
    var stopped: @Sendable (_ stop: SyncStop) async -> Void

    init(
      sync: @escaping SyncStage, mailbox: MailboxStage?, categorize: CategorizeStage? = nil, committed: @escaping CommittedStage,
      stopped: @escaping StoppedStage
    ) {
      self.sync = sync
      self.mailbox = mailbox
      self.categorize = categorize
      self.committed = committed
      self.stopped = stopped
    }
  }

  /// How far a trailing rerun may run: the most generous deadline of the callers that
  /// asked for it.
  private enum RerunLimit {
    case unasked
    case unbounded
    case until(ContinuousClock.Instant)

    func widened(by deadline: ContinuousClock.Instant?) -> RerunLimit {
      guard let deadline else { return .unbounded }
      switch self {
      case .unasked: return .until(deadline)
      case .unbounded: return .unbounded
      case .until(let d): return .until(max(d, deadline))
      }
    }

    var deadline: ContinuousClock.Instant? {
      if case .until(let d) = self { return d }
      return nil
    }
  }

  /// Foreground runs at least this far apart (spec 04 §7.9).
  static let foregroundSpacing: Duration = .seconds(60)

  private let stages: Stages
  private var inFlight: Task<Outcome, Never>?
  private var current: Trigger?
  private var rerun: Trigger?
  private var rerunLimit = RerunLimit.unasked
  /// The callers waiting, by id, with the run each waits on.
  private var waiters: [Int: Task<Outcome, Never>] = [:]
  private var nextWaiter = 0
  private var lastForeground: ContinuousClock.Instant?
  private var closed = false
  private var paused = false
  private(set) var runs = 0

  init(stages: Stages) {
    self.stages = stages
  }

  /// Stops accepting runs (sign-out, wipe). A run in flight finishes its current stage.
  func close() {
    closed = true
    rerun = nil
    inFlight?.cancel()
  }

  /// Holds new runs and waits for the one in flight to end: the account is about to be
  /// deleted, and its store wiped. `resume()` undoes it when the deletion did not happen.
  func pause() async {
    paused = true
    rerun = nil
    if let t = inFlight { _ = await t.value }
  }

  func resume() {
    paused = false
  }

  /// Runs once, coalescing with a run in flight. `budget` bounds how long this caller
  /// waits and how long a run it starts may take (a silent push or a refresh task gets
  /// 25 s); nil waits until done.
  @discardableResult
  func run(_ trigger: Trigger, budget: Duration? = nil) async -> Outcome {
    guard !closed, !paused else { return Outcome() }
    if trigger == .foreground {
      let now = ContinuousClock.now
      if let last = lastForeground, now - last < Self.foregroundSpacing { return Outcome() }
      lastForeground = now
    }
    let deadline = budget.map { ContinuousClock.now + $0 }
    let task: Task<Outcome, Never>
    if let t = inFlight {
      if !Self.joins(trigger, running: current, queued: rerun) {
        if rerun == nil || trigger.strength > (rerun?.strength ?? 0) { rerun = trigger }
        rerunLimit = rerunLimit.widened(by: deadline)
      }
      task = t
    } else {
      task = Task { await self.loop(trigger, deadline: deadline) }
      inFlight = task
    }
    let id = nextWaiter
    nextWaiter += 1
    waiters[id] = task
    let out = await Self.wait(
      for: task, until: deadline, timedOut: Outcome(newData: false, stop: .notNow),
      cancelled: Outcome(newData: false, stop: .cancelled))
    let waited = waiters.removeValue(forKey: id)
    if Task.isCancelled, let waited { cancelIfUnwatched(waited) }
    return out
  }

  static func joins(_ trigger: Trigger, running: Trigger?, queued: Trigger?) -> Bool {
    trigger == .refresh && [running, queued].contains { $0?.mailbox != nil }
  }

  /// A caller was cancelled: when nobody else waits on its run, the run is cancelled.
  private func cancelIfUnwatched(_ task: Task<Outcome, Never>) {
    guard task == inFlight, !waiters.values.contains(task) else { return }
    rerun = nil
    rerunLimit = .unasked
    task.cancel()
  }

  private func loop(_ trigger: Trigger, deadline: ContinuousClock.Instant?) async -> Outcome {
    var out = await once(trigger, deadline: deadline)
    while let next = rerun, !closed, !paused, !Task.isCancelled {
      let limit = rerunLimit
      rerun = nil
      rerunLimit = .unasked
      if out.stop.map(Self.endsTheAccount) == true { break }
      let again = await once(next, deadline: limit.deadline)
      out.newData = out.newData || again.newData
      out.stop = again.stop
    }
    rerun = nil
    rerunLimit = .unasked
    inFlight = nil
    current = nil
    return out
  }

  private func once(_ trigger: Trigger, deadline: ContinuousClock.Instant?) async -> Outcome {
    runs += 1
    current = trigger
    var out = Outcome()
    // The sync engine runs in a task of its own, so a cancellation can't reach it; the
    // run stops waiting for it instead (it finishes, or stops at its deadline).
    let sync = stages.sync
    let syncTask = Task { await sync(trigger.sync, deadline) }
    let synced = await Self.wait(
      for: syncTask, until: nil, timedOut: (newData: false, stop: SyncStop?.some(.cancelled)),
      cancelled: (newData: false, stop: SyncStop?.some(.cancelled)))
    out.newData = synced.newData
    out.stop = synced.stop
    if Task.isCancelled { return Outcome(newData: out.newData, stop: .cancelled) }
    if let stop = synced.stop, Self.surfaces(stop) {
      await stages.stopped(stop)
      if Self.endsTheAccount(stop) { return out }
    }
    if !closed, let mailbox = stages.mailbox, let mt = trigger.mailbox, synced.stop.map(Self.tolerable) ?? true {
      let deadlineMs = deadline.map { d -> Int64 in
        let left = ContinuousClock.now.duration(to: d)
        let leftMs = left.components.seconds * 1000 + left.components.attoseconds / 1_000_000_000_000_000
        return Int64(Date().timeIntervalSince1970 * 1000) + leftMs
      }
      let report = await mailbox(mt, deadlineMs)
      if report.ops > 0 { out.newData = true }
    }
    if Task.isCancelled { return Outcome(newData: out.newData, stop: .cancelled) }
    if !closed, let categorize = stages.categorize, synced.stop.map(Self.tolerable) ?? true {
      if await categorize(trigger) { out.newData = true }
    }
    if Task.isCancelled { return Outcome(newData: out.newData, stop: .cancelled) }
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

  /// A stop the gate shows: one that ends the account, or the server's "update Hasala"
  /// (`426`, spec 04 §6.5 RD-1), after which every call is refused.
  static func surfaces(_ stop: SyncStop) -> Bool {
    endsTheAccount(stop) || stop == .halted(.updateRequired)
  }

  /// A stop the screens read through (the last projection is still good).
  static func tolerable(_ stop: SyncStop) -> Bool {
    switch stop {
    case .rateLimited, .latched, .suspended, .notNow, .cancelled: true
    default: false
    }
  }

  // MARK: Waiting

  /// Waits for `task`, returning `timedOut` once `deadline` passes and `cancelled` as soon
  /// as the caller is cancelled, whichever comes first. The task itself is left running.
  nonisolated static func wait<T: Sendable>(
    for task: Task<T, Never>, until deadline: ContinuousClock.Instant?, timedOut: T, cancelled: T
  ) async -> T {
    let first = FirstOf<T>()
    Task { first.finish(await task.value) }
    let timer: Task<Void, Never>? = deadline.map { d in
      Task {
        do {
          try await Task.sleep(until: d, clock: .continuous)
          first.finish(timedOut)
        } catch {}
      }
    }
    defer { timer?.cancel() }
    return await withTaskCancellationHandler {
      await withCheckedContinuation { first.install($0) }
    } onCancel: {
      first.finish(cancelled)
    }
  }
}

/// The first of several racing results, handed to one continuation.
nonisolated final class FirstOf<T: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<T, Never>?
  private var result: T?
  private var done = false

  func install(_ k: CheckedContinuation<T, Never>) {
    let ready: T? = lock.withLock {
      if done { return result }
      continuation = k
      return nil
    }
    if let ready { k.resume(returning: ready) }
  }

  /// Returns whether this call decided the result.
  @discardableResult
  func finish(_ value: T) -> Bool {
    let k: CheckedContinuation<T, Never>?? = lock.withLock {
      guard !done else { return nil }
      done = true
      result = value
      defer { continuation = nil }
      return .some(continuation)
    }
    guard let k else { return false }
    k?.resume(returning: value)
    return true
  }
}
