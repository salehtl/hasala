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
// folded again from genesis on this device, and each is checked against what
// the reader decided when it was pulled:
//   - the chain, per writer from genesis: consecutive counters, each
//     `prev_hash` the previous row's hash, each `blob_hash` the hash of the
//     stored bytes, and the result agrees with the pinned heads;
//   - the blob is opened again with the epoch keys this device holds and
//     decoded through R10, and the outcome must be the stored `disposition`
//     (folded = opened, set_aside = set aside, alarm = AEAD failure).
// Any difference (a corrupted blob or key, a row that no longer opens the way
// it did) records an `integrity_alarm` fold event and halts `inconsistent`;
// nothing is dropped from the state quietly. Nothing is fetched again and no
// pinned head is dropped, so the chain's rollback protection is untouched.
import CoreAuth
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
  /// This writer's stamp memory, shared by every author of the account (the
  /// Gmail lane's `MailboxAuthoring` takes the same instance).
  public nonisolated let stamps: AuthorStamps
  let dictionary: MerchantDictionary

  /// The folded state as committed; nil until loaded.
  private var state: State?
  /// The page being committed (`fold` → `pageCommitted`).
  private var candidate: State?
  /// A page committed since the last projection.
  private var dirty = false
  /// Sample batches were handed out by this observer (the load is one-shot).
  private var sampleIssued = false
  /// Why the last projection failed, if it did (content-free); nil after a success.
  public private(set) var projectionFailure: String?

  /// `dictionary` is the bundled merchant dictionary (`MerchantDictionary.bundled()`;
  /// `.empty` when its tier is disabled).
  public init(
    context: SyncContext, projection: ProjectionStore, dictionary: MerchantDictionary, stamps: AuthorStamps = AuthorStamps()
  ) {
    self.context = context
    self.projection = projection
    self.dictionary = dictionary
    self.stamps = stamps
  }

  /// The reader the screens observe.
  public nonisolated var reader: LedgerReader { projection.reader }

  // MARK: Opening

  /// Protects the projection's files (§4.1), loads the state (snapshot, or a
  /// cold fold of the stored rows) and projects when the projection is missing,
  /// stale, from other fold semantics, or written with an outbox overlay. Call
  /// once when the account opens, before the first sync run.
  public func open() async throws(SyncStop) {
    if let url = projection.url {
      // The account directory (protection class, out of backup) is the
      // guarantee for every file in it, journals included; the file marks are
      // a second layer.
      do {
        try FileHygiene.prepareDirectory(url.deletingLastPathComponent())
        try FileHygiene.excludeDatabaseFiles(at: url)
      } catch {
        throw .notNow
      }
    }
    let s = try loaded()
    let meta = try? projection.reader.meta()
    let pending = (try? context.store.pendingCount()) ?? 0
    let usable = (try? projection.reader.isUsable()) ?? false
    if !usable || meta?.cursorHot != s.cursors.hot || pending > 0 || (meta?.pendingOps ?? 0) > 0 {
      try project(s)
    }
  }

  /// The committed state, loading it first when needed.
  public func currentState() async throws(SyncStop) -> State { try loaded() }

  private func loaded() throws(SyncStop) -> State {
    let cursor = try context.storeCall { () throws(StoreError) in try context.store.syncState().cursorHot }
    if let s = state, s.cursors.hot == cursor { return s }
    // A page whose transaction committed while its `pageCommitted` is still on the way.
    if let c = candidate, c.cursors.hot == cursor { return c }
    let s = try load(cursor: cursor)
    state = s
    return s
  }

  private func load(cursor: Int64) throws(SyncStop) -> State {
    let now = context.clock.nowMs()
    let store = context.store
    let result = try context.storeCall { () throws(StoreError) in
      try store.loadFoldSnapshot(foldPrint: FoldCanary.foldPrint, at: now) { (record: FoldSnapshotRecord) -> State? in
        guard let snap = try? SnapshotCodec.decode(record.payload), snap.state.cursors.hot == record.cursorHot else {
          return nil
        }
        return snap.state
      }
    }
    if case .success(let loaded)? = result { return loaded.decoded }
    if result == nil, cursor == 0 { return State() }
    let s = try coldFold(cursor: cursor)
    if let payload = try? SnapshotCodec.encode(StateSnapshot(state: s)) {
      _ = try? store.saveFoldSnapshot(foldPrint: FoldCanary.foldPrint, payload: payload, at: now)
    }
    try? store.recordFoldEvent(kind: "cold_fold", detail: "rows_to_\(cursor)", at: now)
    return s
  }

  /// Folds every stored row from genesis up to `cursor` (rows a concurrent
  /// page adds above it are left for that page): what any snapshot rejection
  /// falls back to (§5.3). The stored chain is checked first, as R2 comes
  /// before R3 in the reader; then each row is opened again and its outcome
  /// compared with its stored disposition before it is folded.
  func coldFold(cursor: Int64) throws(SyncStop) -> State {
    let store = context.store
    let sync = try context.storeCall { () throws(StoreError) in try store.syncState() }
    try checkStoredChain(upTo: cursor)
    let opener = Opener(epochHWM: sync.epochHWM, keys: try context.epochKeys(upTo: sync.epochHWM))
    var s = State()
    try storedPages(upTo: cursor) { (rows: [WireRowRecord]) throws(SyncStop) in
      var page: [FoldRow] = []
      for r in rows {
        let outcome = try reopen(r, opener)
        guard WireRowRecord.Disposition(outcome) == r.disposition else { throw integrityHalt("cold_fold_disposition") }
        page.append(FoldRow(seq: r.seq, writerID: r.writerID.string, counter: r.counter, outcome: outcome))
      }
      s = try Self.fold(page, onto: s)
    }
    guard s.cursors.hot == cursor else { throw .halted(.inconsistent("cold_fold_cursor")) }
    return s
  }

  /// The stored rows up to `cursor` as R2 verified them: per writer from
  /// genesis, consecutive counters, each `prev_hash` the previous hash, each
  /// `blob_hash` the hash of the stored bytes, ending at the pinned head (a
  /// writer may be further on only when a concurrent page stored rows above
  /// `cursor`).
  private func checkStoredChain(upTo cursor: Int64) throws(SyncStop) {
    let pinned = try context.storeCall { () throws(StoreError) in try context.store.chainHeads() }
    var heads: [WriterID: Chain.Head] = [:]
    try storedPages(upTo: cursor) { (rows: [WireRowRecord]) throws(SyncStop) in
      for r in rows {
        let head = heads[r.writerID] ?? .genesis
        guard r.counter == head.counter + 1, r.prevHash == head.hash, Chain.hash(prev: r.prevHash, frame: r.blob) == r.blobHash
        else { throw integrityHalt("cold_fold_chain") }
        heads[r.writerID] = Chain.Head(counter: r.counter, hash: r.blobHash)
      }
    }
    for (w, h) in heads {
      guard let p = pinned[w], p.counter >= h.counter, p.counter > h.counter || p.hash == h.hash else {
        throw integrityHalt("cold_fold_heads")
      }
    }
  }

  /// `wire_rows` from seq 1 to `cursor`, oldest first, a page at a time.
  private func storedPages(upTo cursor: Int64, _ each: ([WireRowRecord]) throws(SyncStop) -> Void) throws(SyncStop) {
    var after: Int64 = 0
    while after < cursor {
      let rows = try context.storeCall { () throws(StoreError) in try context.store.wireRows(after: after, limit: 250) }
      guard let last = rows.last else { return }
      let page = rows.filter { $0.seq <= cursor }
      if !page.isEmpty { try each(page) }
      after = last.seq
    }
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

  /// A stored row that no longer checks out: the integrity alarm (04 §5.7
  /// A-32) as a content-free fold event, and the `inconsistent` halt.
  private func integrityHalt(_ what: String) -> SyncStop {
    try? context.store.recordFoldEvent(kind: "integrity_alarm", detail: what, at: context.clock.nowMs())
    return .halted(.inconsistent(what))
  }

  // MARK: PageObserver

  public func fold(_ rows: [PulledRow]) async throws(SyncStop) -> FoldSnapshotChange {
    let base = try loaded()
    let page = rows.map { FoldRow(seq: $0.seq, writerID: $0.writerID.string, counter: $0.counter, outcome: $0.outcome) }
    let folded = try Self.fold(page, onto: base)
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

  /// The outbox, one op per overlay blob, in order.
  private func pendingOverlay() throws(SyncStop) -> [[Op]] {
    do {
      return try context.store.pendingOps().compactMap { try? [Pusher.decodeStored($0)] }
    } catch {
      throw .store(error)
    }
  }

  private func project(_ s: State) throws(SyncStop) {
    let pending = try pendingOverlay()
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
  /// largest of the fold's `maxAuthored` for this writer, every pending op, and
  /// the newest stamp handed out on this device (`stamps`). Build the blob
  /// inside `stamps.build(context) { a in … }`, which records its stamps under
  /// the same lock, so two blobs started together never share a stamp.
  public func authorContext() async throws(SyncStop) -> AuthorContext {
    try baseContext().raised(to: stamps.lastMs)
  }

  /// The context from the fold and the outbox alone (`stamps` raise it).
  private func baseContext() throws(SyncStop) -> AuthorContext {
    let s = try loaded()
    let pending = try context.storeCall { () throws(StoreError) in try context.store.latestPendingAuthoredAt() }
    var seen: [String: Int64] = [:]
    for (w, ms) in s.maxAuthored { seen[w] = ms }
    return Self.authorContext(
      writerID: context.writerID.string, nowMs: context.clock.nowMs(), maxAuthored: seen,
      pendingLatest: pending.flatMap { try? parseInstantMs($0) }, noted: nil, random: context.random)
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

  /// Records a blob built outside `stamps.build` (with a context from
  /// `authorContext()`), so the next context stamps after it.
  public func noteAuthored(_ blob: AuthoredBlob) {
    stamps.authoring { _ in ((), blob.lastAuthoredMs) }
  }

  // MARK: Sample data (04 §6.13)

  /// "Use sample data": the bundled seed as blobs for `Outbox.enqueue`, in
  /// order, when the gate allows it, and nothing otherwise. `account` must be
  /// this account's `GET /account` (#40), fetched live for this tap; the gate
  /// also reads the ledger itself (folded and pending): any transaction, or any
  /// sample row, refuses. The load is one-shot per observer as well, so a
  /// second tap before the first load is enqueued is refused too.
  public func sampleBatches(account: AccountInfo) async throws(SampleLoadError) -> [AuthoredBlob] {
    try sampleBatches(account: account) { () throws(SampleSeedError) in try SampleSeed.bundled() }
  }

  func sampleBatches(account: AccountInfo, seed: () throws(SampleSeedError) -> Data) throws(SampleLoadError)
    -> [AuthoredBlob]
  {
    let review = account.user_id == context.userID.string ? account.review_account : false
    let ledger: State
    let base: AuthorContext
    do {
      ledger = Projector.overlay(try loaded(), pending: try pendingOverlay(), writerID: context.writerID.string).0
      base = try baseContext()
    } catch {
      throw .sync(error)
    }
    let sampleLoaded = sampleIssued || ledger.txns.values.contains { SampleSeed.isSampleMessageID($0.mailboxMessageID) }
    do {
      let permit = try SampleSeed.permit(
        reviewAccount: review, holdsTransactions: !ledger.txns.isEmpty, sampleLoaded: sampleLoaded)
      let data = try seed()
      let blobs = try stamps.authoring {
        (floor: Int64?) throws(SampleSeedError) -> (value: [AuthoredBlob], lastMs: Int64?) in
        let ctx = base.raised(to: floor)
        let b = try SampleSeed.batches(data, nowMs: ctx.nowMs, context: ctx, permit: permit)
        return (b, b.last?.lastAuthoredMs)
      }
      sampleIssued = true
      return blobs
    } catch {
      throw .seed(error)
    }
  }

  // MARK: Errors

  /// `LedgerFold.page`, its halts as sync stops.
  static func fold(_ page: [FoldRow], onto s: State) throws(SyncStop) -> State {
    do { return try LedgerFold.page(page, onto: s) } catch { throw stop(error) }
  }

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

/// Why `LedgerPageObserver.sampleBatches(account:)` authored nothing.
public enum SampleLoadError: Error, Sendable, Equatable {
  /// The ledger could not be read (the sync stop says why).
  case sync(SyncStop)
  /// The gate refused (`.refused`), or the seed did not load or author.
  case seed(SampleSeedError)
}

extension WireRowRecord.Disposition {
  /// How `wire_rows` records a reader outcome.
  init(_ outcome: PageReader.RowOutcome) {
    switch outcome {
    case .opened: self = .folded
    case .setAside(_, let alarm): self = alarm ? .alarm : .setAside
    }
  }
}
