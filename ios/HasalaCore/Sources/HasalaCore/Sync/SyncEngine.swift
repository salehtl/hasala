// The sync engine (spec 04 §5.1, §3): one actor per bound account.
//
// One run is `reconcile in-flight → pull → fold → flush → self-pull`; the
// projection and signals stages belong to the app's WorkCoordinator, which
// calls `run` and then projects. Triggers coalesce: a call while a run is in
// flight sets a single trailing rerun and waits for it, never a second
// concurrent run (§3 "One entry point").
//
// Every stop maps to a phase (§5.1). Halts and latches never wipe data; a wipe
// is reported (`.wiping`) and performed by the app (`AccountWipe`).
import CoreAuth
import CorePrimitives
import CoreStore
import CoreWire
import Foundation

public enum SyncTrigger: String, Sendable, Hashable, CaseIterable {
  case launch, foreground, refresh, authored, pathUp, silentPush, bgRefresh, bgProcessing, foregroundTimer

  /// Whether the run re-verifies the key history first (01 §10.13). An
  /// `authored` run follows the user's own edit and keeps the pinned roster
  /// (R1 still re-fetches it for an unknown writer).
  public var refreshesRoster: Bool { self != .authored }
}

public struct RunOutcome: Sendable, Hashable {
  /// Any row stored or any op acknowledged (the silent-push `.newData`).
  public var newData = false
  public var pulled = PullSummary()
  public var pushed = PushSummary()
  /// Why the run stopped early, if it did.
  public var stop: SyncStop?
}

public actor SyncEngine {
  public let context: SyncContext
  let observer: (any PageObserver)?
  public private(set) var status = SyncStatus()
  private var inFlight: Task<RunOutcome, Never>?
  /// The trailing rerun asked for while a run was in flight, if any.
  private var rerun: SyncTrigger?
  private var continuations: [UUID: AsyncStream<SyncStatus>.Continuation] = [:]
  private var offlineAttempts = 0
  private var accountFullAtMs: Int64?
  public static let accountFullPauseMs: Int64 = 15 * 60_000

  public init(context: SyncContext, observer: (any PageObserver)? = nil) {
    self.context = context
    self.observer = observer
  }

  /// Every status change, starting with the current one.
  public func statusUpdates() -> AsyncStream<SyncStatus> {
    let (stream, c) = AsyncStream<SyncStatus>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let id = context.random.uuidV4Lenient()
    continuations[id] = c
    c.yield(status)
    c.onTermination = { [weak self] _ in Task { await self?.drop(id) } }
    return stream
  }

  private func drop(_ id: UUID) { continuations[id] = nil }

  private func publish() {
    for c in continuations.values { c.yield(status) }
  }

  private func set(_ phase: SyncPhase) {
    status.phase = phase
    publish()
  }

  /// The app acknowledged the integrity-alarm sheet (§5.7).
  public func acknowledgeAlarms() {
    status.integrityAlarms = 0
    publish()
  }

  /// The suggested wait before the next automatic retry after `offline`: 2 s ×
  /// 2ⁿ, capped at 5 min, ±20 % jitter (§5.5).
  public func retryDelaySeconds() -> Double {
    let base = min(300.0, 2.0 * pow(2.0, Double(max(0, offlineAttempts - 1))))
    let r = (try? context.random.bytes(1)[0]) ?? 128
    return base * (0.8 + 0.4 * Double(r) / 255.0)
  }

  /// Runs once, coalescing with a run in flight: a call while a run is in
  /// flight asks for one trailing rerun and returns the merged outcome.
  @discardableResult
  public func run(_ trigger: SyncTrigger, deadline: ContinuousClock.Instant? = nil) async -> RunOutcome {
    if let t = inFlight {
      // The rerun keeps the strongest trigger asked for: one that re-verifies
      // the roster wins over `authored`.
      if rerun == nil || trigger.refreshesRoster { rerun = trigger }
      return await t.value
    }
    let task = Task { await self.loop(trigger, deadline: deadline) }
    inFlight = task
    return await task.value
  }

  /// Every run's body. `inFlight` is cleared here, in the same actor step as
  /// the last `rerun` check (no suspension between them), so a `run` call can
  /// never set `rerun` after that check and still be handed this outcome.
  private func loop(_ trigger: SyncTrigger, deadline: ContinuousClock.Instant?) async -> RunOutcome {
    var out = await once(trigger, deadline: deadline)
    while let next = rerun {
      rerun = nil
      if out.stop != nil { break }
      let again = await once(next, deadline: deadline)
      out.newData = out.newData || again.newData
      out.pulled.rowsStored += again.pulled.rowsStored
      out.pulled.opsOpened += again.pulled.opsOpened
      out.pushed.add(again.pushed)
      out.stop = again.stop
    }
    inFlight = nil
    return out
  }

  private func once(_ trigger: SyncTrigger, deadline: ContinuousClock.Instant?) async -> RunOutcome {
    var out = RunOutcome()
    do {
      try resumeAfterAccountFull(trigger)
      // Reconcile: an in-flight batch goes first, byte-identical.
      set(.reconciling)
      let hasInflight = !(try context.storeCall { () throws(StoreError) in try context.store.inflight() }).isEmpty
      if hasInflight {
        set(.pushing)
        await observer?.willPush()
        out.pushed = try await latchAware { () async throws(SyncStop) in try await Pusher.reconcile(context) }
      }
      set(.pulling)
      if trigger.refreshesRoster { try await refreshRoster() }
      out.pulled = try await Puller.pull(context, observer: observer)
      status.integrityAlarms += out.pulled.alarms
      set(.pushing)
      await observer?.willPush()
      let pushed = try await latchAware { () async throws(SyncStop) in
        try await Pusher.flush(context, deadline: deadline) { [observer] in await observer?.willPush() }
      }
      out.pushed.add(pushed)
      if pushed.batches > 0 || hasInflight {
        set(.selfPull)
        let again = try await Puller.pull(context, observer: observer)
        out.pulled.rowsStored += again.rowsStored
        out.pulled.opsOpened += again.opsOpened
        status.integrityAlarms += again.alarms
      }
      offlineAttempts = 0
      status.lastSuccessAt = context.clock.nowMs()
      status.retryAfterSeconds = nil
      status.suspended = false
      status.phase = .idle
    } catch {
      out.stop = await apply(await context.settled(error))
    }
    out.newData = out.pulled.rowsStored > 0 || out.pushed.opsAcknowledged > 0
    status.pendingCount = (try? context.store.pendingCount()) ?? status.pendingCount
    status.latch = (try? context.store.syncState().latch) ?? status.latch
    publish()
    return out
  }

  /// 01 §10.13: the key history is verified again on every launch, unlock and
  /// wake (a wake's payload is the same for every reason, so a security wake
  /// cannot be told apart), so a revocation pins its final head before the
  /// next page is read.
  private func refreshRoster() async throws(SyncStop) {
    let state = try context.storeCall { () throws(StoreError) in try context.store.syncState() }
    guard let pinned = PinnedRoster.decode(state.rosterJSON) else { throw .halted(.rosterInvalid) }
    let fresh = try await RosterService.refetch(client: context.client, bearer: try context.bearer(), pinned: pinned)
    if fresh != pinned { try context.storeCall { () throws(StoreError) in try context.store.setRoster(fresh.encoded()) } }
  }

  private func resumeAfterAccountFull(_ trigger: SyncTrigger) throws(SyncStop) {
    let state = try context.storeCall { () throws(StoreError) in try context.store.syncState() }
    guard state.latch == .accountFull else { return }
    let asked = trigger == .launch || trigger == .foreground || trigger == .refresh
    if !asked, let at = accountFullAtMs, context.clock.nowMs() - at < Self.accountFullPauseMs { return }
    try context.storeCall { () throws(StoreError) in try context.store.setLatch(nil) }
    accountFullAtMs = nil
    status.latch = nil
  }

  /// A latch stops the flush but not the pull (§5.4: reads continue).
  private func latchAware(_ push: () async throws(SyncStop) -> PushSummary) async throws(SyncStop) -> PushSummary {
    do {
      return try await push()
    } catch {
      if case .latched(let l, let alarm) = error {
        status.latch = l
        if alarm { status.integrityAlarms += 1 }
        if l == .accountFull { accountFullAtMs = context.clock.nowMs() }
        if l == .accountFull || l == .sealerFault || l == .chainBreak || l == .hardStop {
          return PushSummary()
        }
      }
      if error == .suspended {
        status.suspended = true
        return PushSummary()
      }
      throw error
    }
  }

  /// Maps a stop onto the phase (§5.1) and returns it.
  private func apply(_ stop: SyncStop) async -> SyncStop {
    switch stop {
    case .offline, .protocolError:
      offlineAttempts += 1
      if case .offline(let since) = status.phase {
        status.phase = .offline(sinceMs: since)
      } else {
        status.phase = .offline(sinceMs: context.clock.nowMs())
      }
    case .rateLimited(let r):
      status.retryAfterSeconds = min(r ?? 60, 300)
      status.phase = .idle
    case .halted(let h):
      status.phase = .halted(await restoredOr(h))
    case .latched(let l, let alarm):
      status.latch = l
      if alarm { status.integrityAlarms += 1 }
      status.phase = .idle
    case .frozen: status.phase = .frozen
    case .needsSignIn: status.phase = .needsSignIn
    case .needsRebind: status.phase = .needsRebind
    case .needsUnlock(let e): status.phase = .needsUnlock(epoch: e)
    case .keysRequired: status.phase = .keysRequired
    case .wipe: status.phase = .wiping
    case .revocationClaimed: status.phase = .halted(.rosterInvalid)
    case .suspended:
      status.suspended = true
      status.phase = .idle
    case .notNow, .cancelled: status.phase = .idle
    case .store: status.phase = .halted(.inconsistent("store"))
    }
    return stop
  }

  /// R-10: a chain condition while `meta.log_generation` differs from the one
  /// seen at enrolment is `server_restored`, not tampering.
  private func restoredOr(_ h: HaltKind) async -> HaltKind {
    switch h {
    case .tampered(.chainBreak), .tampered(.ownChainConflict), .tamperedResend: break
    default: return h
    }
    guard let stored = try? context.store.syncState().logGeneration,
      let meta = try? await context.client.meta(), let now = meta.log_generation, now != stored
    else { return h }
    return .serverRestored
  }
}

extension RandomSource {
  /// A UUID for local bookkeeping (never on the wire).
  func uuidV4Lenient() -> UUID {
    (try? uuidV4()).flatMap(UUID.init(uuidString:)) ?? UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
  }
}
