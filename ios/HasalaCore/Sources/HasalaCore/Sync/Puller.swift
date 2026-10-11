// Pull (spec 04 §5.2): `GET /sync?stream=hot&after=<cursor>&limit=500` until
// `complete`, each page through spec 01 §6.6's reader (R0–R10 in order, the
// first failing step decides), then the fold hook, then ONE transaction that
// stores the rows, the heads and the cursor. A hard stop persists nothing.
//
// The reader's two network steps are taken here, each at most once per page:
// R1's roster re-fetch (`refreshRoster`) and R4's `GET /keys` (`refreshEpoch`).
import CoreAuth
import CoreCrypto
import CorePrimitives
import CoreStore
import CoreWire
import Foundation

/// One decided row of a page, handed to the fold hook before persistence.
public struct PulledRow: Sendable, Hashable {
  public let seq: Int64
  public let writerID: WriterID
  public let counter: Int64
  public let outcome: PageReader.RowOutcome
}

/// The fold seam (§5.2 steps 4–5): the fold and the incremental invariants run
/// here, before the page is persisted. Throwing (e.g.
/// `.halted(.inconsistent(...))`) keeps the whole page out.
///
/// TODO(WS-10): CoreReplay's fold and CoreInvariants' incremental set plug in
/// here; until then the app's projection reads `wire_rows` through
/// `StoredLog`.
public protocol PageObserver: Sendable {
  func fold(_ rows: [PulledRow]) async throws(SyncStop)
}

public struct PullSummary: Sendable, Hashable {
  public var rowsStored = 0
  public var opsOpened = 0
  public var setAside = 0
  /// AEAD failures on chain-valid rows (R7): each raises the integrity alarm.
  public var alarms = 0
  public var pages = 0
}

enum Puller {
  static let pageLimit = 500

  static func pull(_ ctx: SyncContext, observer: (any PageObserver)?) async throws(SyncStop) -> PullSummary {
    var summary = PullSummary()
    var emptyIncomplete = 0
    while true {
      try Task.checkCancellation(or: .cancelled)
      let state = try ctx.storeCall { () throws(StoreError) in try ctx.store.syncState() }
      let bearer = try ctx.bearer()
      let page: PullPage
      do {
        page = try await ctx.client.pull(after: state.cursorHot, limit: pageLimit, bearer: bearer)
      } catch {
        throw SyncStop.read(error)
      }
      if page.rows.isEmpty {
        if page.complete { return summary }
        emptyIncomplete += 1
        if emptyIncomplete >= 2 { throw .protocolError("two empty pages that were not complete") }
        continue
      }
      emptyIncomplete = 0
      summary.pages += 1
      try await readAndPersist(page, state: state, bearer: bearer, ctx: ctx, observer: observer, summary: &summary)
      if page.complete { return summary }
    }
  }

  static func readAndPersist(
    _ page: PullPage, state: SyncStateRow, bearer: String, ctx: SyncContext, observer: (any PageObserver)?,
    summary: inout PullSummary
  ) async throws(SyncStop) {
    // R0's page-level checks the row checker cannot see: seqs strictly
    // increasing above the cursor (I1), `next` = the last seq.
    var seqs: [Int64] = []
    var last = state.cursorHot
    for r in page.rows {
      guard let s = Int64(r.seq), ASCIIDigits.only(r.seq), s > last else {
        throw .halted(.tampered(.rowShape))
      }
      seqs.append(s)
      last = s
    }
    guard page.next == String(last) else { throw .halted(.tampered(.rowShape)) }

    var rows: [PageReader.Row] = []
    for r in page.rows {
      guard let blob = try? Base64.decode(r.blob), let prev = try? Hex.decode(r.prev_hash),
        let hash = try? Hex.decode(r.blob_hash)
      else { throw .halted(.tampered(.rowShape)) }
      var sig: Data?
      if let hs = r.head_sig {
        guard let d = try? Base64.decode(hs) else { throw .halted(.tampered(.rowShape)) }
        sig = d
      }
      guard r.type_flag == "edit" else { throw .halted(.tampered(.rowShape)) }
      rows.append(
        PageReader.Row(
          stream: r.stream, writerID: r.writer_id, counter: r.writer_counter, sizeBucket: r.size_bucket, prevHash: prev,
          blobHash: hash, headSig: sig, blob: blob))
    }

    var roster = PinnedRoster.decode(state.rosterJSON)
    guard let pinned = roster, pinned.authorityPublicKey != nil else { throw .halted(.rosterInvalid) }
    let heads = try ctx.storeCall { () throws(StoreError) in try ctx.store.chainHeads() }
    let inflightTop = try ctx.storeCall { () throws(StoreError) in try ctx.store.inflight().last?.counter } ?? 0
    let own = (writer: ctx.writerID, authoredHead: max(state.authoredHead.counter, inflightTop))
    var hwm = state.epochHWM
    var serverEpoch: UInt32?
    var rosterRefreshed = false
    var epochRefreshed = false

    while true {
      let opener = Opener(epochHWM: hwm, keys: try ctx.epochKeys(upTo: max(hwm, serverEpoch ?? 1)))
      let readerState = PageReader.State(
        userID: ctx.userID, opener: opener, serverEpoch: serverEpoch, pinnedHeads: heads,
        roster: (roster ?? pinned).forReader(), rosterRefreshed: rosterRefreshed, own: own)
      let result = PageReader.read(rows, state: readerState)
      switch result.stop {
      case .refreshRoster?:
        guard !rosterRefreshed else { throw .halted(.tampered(.unknownWriter)) }
        let fresh = try await RosterService.refetch(client: ctx.client, bearer: bearer, pinned: pinned)
        try ctx.storeCall { () throws(StoreError) in try ctx.store.setRoster(fresh.encoded()) }
        roster = fresh
        rosterRefreshed = true
        continue
      case .refreshEpoch(let e)?:
        guard !epochRefreshed else { throw .halted(.tampered(.epochInvalid)) }
        let keys: KeysResponse
        do { keys = try await ctx.client.keys(bearer: bearer) } catch { throw SyncStop.read(error) }
        guard keys.current_epoch >= 1, keys.current_epoch <= Int(Int32.max) else {
          throw .halted(.tampered(.epochInvalid))
        }
        serverEpoch = UInt32(keys.current_epoch)
        epochRefreshed = true
        if serverEpoch! >= e {
          hwm = max(hwm, serverEpoch!)
          try ctx.storeCall { () throws(StoreError) in try ctx.store.setEpochHWM(hwm) }
        }
        continue
      case .needsUnlock(let e)?:
        throw .needsUnlock(epoch: e)
      case .hardStop(let h)?:
        switch h {
        case .updateRequired: throw .halted(.updateRequired)
        case .tampered(let t): throw .halted(.tampered(t))
        }
      case nil:
        break
      }

      // Fold seam, then ONE transaction.
      var decided: [PulledRow] = []
      var records: [WireRowRecord] = []
      var newHeads: [WriterID: Chain.Head] = [:]
      for (i, outcome) in result.rows.enumerated() {
        let r = rows[i]
        guard let w = WriterID(r.writerID), let c = Int64(r.counter), let bh = Hash32(r.blobHash),
          let ph = Hash32(r.prevHash)
        else { throw .halted(.tampered(.rowShape)) }
        decided.append(PulledRow(seq: seqs[i], writerID: w, counter: c, outcome: outcome))
        let disposition: WireRowRecord.Disposition
        switch outcome {
        case .opened(_, let ops):
          disposition = .folded
          summary.opsOpened += ops.count
        case .setAside(_, let alarm):
          disposition = alarm ? .alarm : .setAside
          summary.setAside += 1
          if alarm { summary.alarms += 1 }
        }
        records.append(
          WireRowRecord(
            seq: seqs[i], writerID: w, counter: c, sizeBucket: r.sizeBucket, blobHash: bh, prevHash: ph,
            createdAt: page.rows[i].created_at, blob: r.blob, headSig: r.headSig, disposition: disposition))
        newHeads[w] = Chain.Head(counter: c, hash: bh)
      }
      if let observer { try await observer.fold(decided) }
      let now = ctx.clock.nowMs()
      try ctx.storeCall { () throws(StoreError) in
        try ctx.store.persistPage(rows: records, heads: newHeads, cursor: last, at: now)
      }
      if summary.alarms > 0 {
        try? ctx.store.recordFoldEvent(kind: "integrity_alarm", detail: "aead_failed", at: now)
      }
      summary.rowsStored += records.count
      return
    }
  }
}

enum ASCIIDigits {
  static func only(_ s: String) -> Bool { !s.isEmpty && s.utf8.allSatisfy { (0x30...0x39).contains($0) } }
}

extension Task where Success == Never, Failure == Never {
  static func checkCancellation(or stop: SyncStop) throws(SyncStop) {
    if Task.isCancelled { throw stop }
  }
}
