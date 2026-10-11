// The production fold seam (spec 04 §5.2 steps 4-5, §5.3, §4.3): every pulled
// page is folded (CoreInvariants' `LedgerFold.page`: the fold, then the
// incremental invariants) onto a copy of the state, the copy's snapshot is
// written in the page's own transaction, and once the pull ends the state is
// projected into `projection.sqlite` with the outbox overlay.
//
// One actor per bound account, built by the app's AccountRuntime and handed to
// `SyncEngine(context:observer:)`.
//
// Loading (§5.3): the snapshot is used when every check passes (version, fold
// print, bound tip, digest, decode, cursor). Otherwise the stored rows are
// folded again from genesis on this device: each verified `wire_rows` blob is
// opened again with the epoch keys this device holds and decoded through R10,
// which reproduces the reader's decision for it exactly (opened, or set aside
// with the same reason). Nothing is fetched again and no pinned head is
// dropped, so the chain's rollback protection is untouched. A row that no
// longer opens the way it did is the `inconsistent` halt.
import CoreCategorize
import CoreCrypto
import CoreDomain
import CoreInvariants
import CoreProjection
import CoreReplay
import CoreStore
import CoreWire
import Foundation

public actor LedgerPageObserver: PageObserver {
  public nonisolated let context: SyncContext
  public nonisolated let projection: ProjectionStore
  let dictionary: MerchantDictionary

  /// The folded state as committed; nil until loaded.
  private var state: State?
  /// The page being committed (`fold` → `pageCommitted`).
  private var candidate: State?
  /// A page committed since the last projection.
  private var dirty = false
  /// The latest stamp handed out by `noteAuthored` (03c §1.8.2 own-last guard).
  private var lastAuthoredMs: Int64?
  /// Why the last projection failed, if it did (content-free); nil after a success.
  public private(set) var projectionFailure: String?

  /// `dictionary` is the bundled merchant dictionary (`MerchantDictionary.bundled()`;
  /// `.empty` when its tier is disabled).
  public init(context: SyncContext, projection: ProjectionStore, dictionary: MerchantDictionary) {
    self.context = context
    self.projection = projection
    self.dictionary = dictionary
  }

  /// The reader the screens observe.
  public nonisolated var reader: LedgerReader { projection.reader }

  // MARK: Opening

  /// Loads the state (snapshot, or a cold fold of the stored rows) and projects
  /// when the projection is missing, stale or from other fold semantics. Call
  /// once when the account opens, before the first sync run.
  public func open() async throws(SyncStop) {
    let s = try loaded()
    let meta = try? projection.reader.meta()
    let pending = (try? context.store.pendingCount()) ?? 0
    let usable = (try? projection.reader.isUsable()) ?? false
    if !usable || meta?.cursorHot != s.cursors.hot || pending > 0 {
      try project(s)
    }
  }

  /// The committed state, loading it first when needed.
  public func currentState() async throws(SyncStop) -> State { try loaded() }

  private func loaded() throws(SyncStop) -> State {
    let cursor = try context.storeCall { () throws(StoreError) in try context.store.syncState().cursorHot }
    if let s = state, s.cursors.hot == cursor { return s }
    let s = try load(cursor: cursor)
    state = s
    return s
  }

  private func load(cursor: Int64) throws(SyncStop) -> State {
    let now = context.clock.nowMs()
    let store = context.store
    let result = try context.storeCall { () throws(StoreError) in
      try store.loadFoldSnapshot(foldPrint: FoldCanary.foldPrint, at: now)
    }
    switch result {
    case nil:
      return State()
    case .success(let record)?:
      if let snap = try? SnapshotCodec.decode(record.payload), snap.state.cursors.hot == record.cursorHot {
        return snap.state
      }
      try context.storeCall { () throws(StoreError) in try store.rejectFoldSnapshot(.undecodable, at: now) }
    case .failure?:
      break
    }
    let s = try coldFold(cursor: cursor)
    if let payload = try? SnapshotCodec.encode(StateSnapshot(state: s)) {
      _ = try? store.saveFoldSnapshot(foldPrint: FoldCanary.foldPrint, payload: payload, at: now)
    }
    try? store.recordFoldEvent(kind: "cold_fold", detail: "rows_to_\(cursor)", at: now)
    return s
  }

  /// Folds every stored row from genesis (§5.3 "a rejection means a cold fold").
  func coldFold(cursor: Int64) throws(SyncStop) -> State {
    let store = context.store
    let sync = try context.storeCall { () throws(StoreError) in try store.syncState() }
    let opener = Opener(epochHWM: sync.epochHWM, keys: try context.epochKeys(upTo: sync.epochHWM))
    var s = State()
    var after: Int64 = 0
    while true {
      let rows = try context.storeCall { () throws(StoreError) in try store.wireRows(after: after, limit: 250) }
      guard let last = rows.last else { break }
      var page: [FoldRow] = []
      for r in rows {
        page.append(FoldRow(seq: r.seq, writerID: r.writerID.string, counter: r.counter, outcome: try reopen(r, opener)))
      }
      do { s = try LedgerFold.page(page, onto: s) } catch { throw Self.stop(error) }
      after = last.seq
    }
    guard s.cursors.hot == cursor else { throw .halted(.inconsistent("cold_fold_cursor")) }
    return s
  }

  /// The reader's decision for a stored row, taken again (R3-R10).
  private func reopen(_ r: WireRowRecord, _ opener: Opener) throws(SyncStop) -> PageReader.RowOutcome {
    let envelope: Envelope
    do { envelope = try Envelope(userID: context.userID, writerID: r.writerID, counter: r.counter) } catch {
      throw .halted(.inconsistent("cold_fold_envelope"))
    }
    switch opener.open(r.blob, envelope: envelope, prevHash: r.prevHash) {
    case .opened(let plaintext):
      switch OpCodec.decodeR10(plaintext) {
      case .ops(let ops): return .opened(plaintext: plaintext, ops: ops)
      case .setAside(let reason, _): return .setAside(reason, alarm: false)
      case .hardStop(.updateRequired): throw .halted(.updateRequired)
      case .hardStop: throw .halted(.inconsistent("cold_fold_decode"))
      }
    case .setAside(let reason, let alarm):
      return .setAside(reason, alarm: alarm)
    case .needsUnlock(let e):
      throw .needsUnlock(epoch: e)
    case .hardStop(.updateRequired):
      throw .halted(.updateRequired)
    case .hardStop, .refreshEpoch:
      throw .halted(.inconsistent("cold_fold_open"))
    }
  }

  // MARK: PageObserver

  public func fold(_ rows: [PulledRow]) async throws(SyncStop) -> FoldSnapshotChange {
    let base = try loaded()
    let page = rows.map { FoldRow(seq: $0.seq, writerID: $0.writerID.string, counter: $0.counter, outcome: $0.outcome) }
    let folded: State
    do { folded = try LedgerFold.page(page, onto: base) } catch { throw Self.stop(error) }
    candidate = folded
    guard let payload = try? SnapshotCodec.encode(StateSnapshot(state: folded)) else { return .delete }
    return .save(foldPrint: FoldCanary.foldPrint, payload: payload)
  }

  public func pageCommitted() async {
    guard let c = candidate else { return }
    state = c
    candidate = nil
    dirty = true
  }

  public func pageAbandoned() async { candidate = nil }

  public func pullEnded() async {
    guard dirty, let s = state else { return }
    dirty = false
    try? project(s)
  }

  // MARK: Projection

  /// Re-applies the outbox overlay to the projection (after an `Outbox.enqueue`,
  /// a Gmail commit, or an acknowledged upload), so the screens show pending
  /// edits at once.
  public func reproject() async throws(SyncStop) {
    try project(try loaded())
  }

  private func project(_ s: State) throws(SyncStop) {
    let pending: [[Op]]
    do {
      pending = try context.store.pendingOps().compactMap { try? [Pusher.decodeStored($0)] }
    } catch {
      throw .store(error)
    }
    do {
      try projection.project(
        s, pending: pending, writerID: context.writerID.string, dictionary: dictionary, projectedAtMs: context.clock.nowMs())
      projectionFailure = nil
    } catch {
      projectionFailure = String(describing: type(of: error))
      try? context.store.recordFoldEvent(kind: "projection_failed", detail: projectionFailure ?? "", at: context.clock.nowMs())
      throw .halted(.inconsistent("projection"))
    }
  }

  // MARK: Authoring

  /// The `AuthorContext` for this writer now (03c §1.8.2): `own_last_ms` is the
  /// largest stamp among the fold's `maxAuthored` for this writer, every
  /// pending op, and any blob reported through `noteAuthored`.
  public func authorContext() async throws(SyncStop) -> AuthorContext {
    let s = try loaded()
    let pending = try context.storeCall { () throws(StoreError) in try context.store.latestPendingAuthoredAt() }
    var seen: [String: Int64] = [:]
    for (w, ms) in s.maxAuthored { seen[w] = ms }
    return Self.authorContext(
      writerID: context.writerID.string, nowMs: context.clock.nowMs(), maxAuthored: seen,
      pendingLatest: pending.flatMap { try? parseInstantMs($0) }, noted: lastAuthoredMs, random: context.random)
  }

  /// The 03c §1.8.2 inputs, combined: `own_last_ms` is the largest of this
  /// writer's folded stamp, the newest pending stamp and the last noted blob.
  public static func authorContext(
    writerID: String, nowMs: Int64, maxAuthored: [String: Int64], pendingLatest: Int64?, noted: Int64?,
    random: any RandomSource
  ) -> AuthorContext {
    let own = [maxAuthored[writerID], pendingLatest, noted].compactMap { $0 }.max()
    return AuthorContext(writerID: writerID, nowMs: nowMs, ownLastMs: own, maxAuthored: maxAuthored, random: random)
  }

  /// The fold's per-writer newest stamps (03c §1.8.2 `maxAuthored`), for authors
  /// that build their context synchronously (`MailboxAuthoring`).
  public func seenStamps() async throws(SyncStop) -> [String: Int64] {
    var seen: [String: Int64] = [:]
    for (w, ms) in try loaded().maxAuthored { seen[w] = ms }
    return seen
  }

  /// Records a blob authored with a context from `authorContext()`, so a second
  /// context minted before the first blob is enqueued still stamps after it.
  public func noteAuthored(_ blob: AuthoredBlob) {
    lastAuthoredMs = max(lastAuthoredMs ?? blob.lastAuthoredMs, blob.lastAuthoredMs)
  }

  // MARK: Errors

  static func stop(_ h: FoldHalt) -> SyncStop {
    switch h {
    case .updateRequired: return .halted(.updateRequired)
    case .order: return .halted(.inconsistent("order"))
    case .inconsistent(let v):
      var ids: [String] = []
      for x in v where !ids.contains(x.id) { ids.append(x.id) }
      return .halted(.inconsistent(ids.joined(separator: ",")))
    }
  }
}
