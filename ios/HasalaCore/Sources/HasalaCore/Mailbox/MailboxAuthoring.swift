// The `MailboxOpAuthor` the production persistence calls (spec 04 §7.5 step 7e,
// §2.4 R5): each staged or fetched message's `MailboxIngestDraft` becomes one
// `txn_ingested` through CoreDomain's `OpAuthor.ingest` (stamped, validated,
// size-checked), then its canonical JSON (`Outbox.canonicalJSON`, the bytes the
// outbox would store) as a `pending_ops` row, so the op and the message's
// accounting commit in ONE transaction (`LedgerMailboxPersistence.commit`).
//
// The author rule's inputs (03c §1.8.2) are kept here, synchronously, because
// the persistence's closure cannot await: this writer's newest stamp is the
// largest of the newest pending op, the last blob authored here and the fold's
// `maxAuthored` that `RuntimeMailboxLedger` refreshes after every pull.
import CoreDomain
import CoreOutbox
import CorePrimitives
import CoreStore
import CoreTime
import Foundation
import Synchronization

public final class MailboxAuthoring: Sendable {
  let store: LedgerStore
  let writerID: String
  let random: any RandomSource
  private let stamps: Mutex<(seen: [String: Int64], last: Int64?)>

  public init(store: LedgerStore, writerID: String, random: any RandomSource, seen: [String: Int64] = [:]) {
    self.store = store
    self.writerID = writerID
    self.random = random
    stamps = Mutex((seen, nil))
  }

  /// The fold's `maxAuthored` after a pull (`LedgerPageObserver.seenStamps()`).
  public func updateSeen(_ seen: [String: Int64]) {
    stamps.withLock { $0.seen = seen }
  }

  /// The author context at `nowMs`.
  public func context(nowMs: Int64) throws -> AuthorContext {
    let pending = try store.latestPendingAuthoredAt().flatMap { try? parseInstantMs($0) }
    let (seen, last) = stamps.withLock { ($0.seen, $0.last) }
    let own = [seen[writerID], pending, last].compactMap { $0 }.max()
    return AuthorContext(writerID: writerID, nowMs: nowMs, ownLastMs: own, maxAuthored: seen, random: random)
  }

  /// `MailboxOpAuthor`: the drafts as one blob's `pending_ops` rows, in order.
  /// Throws (and nothing is committed) when any op fails its checks.
  public func author(_ drafts: [MailboxIngestDraft], atMs: Int64) throws -> [MailboxPendingOpRow] {
    guard !drafts.isEmpty else { return [] }
    var a = OpAuthor(try context(nowMs: atMs))
    for d in drafts { try a.ingest(payload: d.payload, ingestID: d.ingestID) }
    let blob = try a.build()
    var rows: [MailboxPendingOpRow] = []
    for op in blob.ops {
      rows.append(
        MailboxPendingOpRow(
          opID: op.opID, opJSON: try Outbox.canonicalJSON(op), opType: op.type.rawValue, entityKind: op.entity?.kind,
          entityID: op.entity?.id, enqueuedAt: atMs))
    }
    stamps.withLock { $0.last = max($0.last ?? blob.lastAuthoredMs, blob.lastAuthoredMs) }
    return rows
  }

  /// The closure `LedgerMailboxPersistence(tables:author:nowMs:)` takes.
  public var opAuthor: MailboxOpAuthor {
    { [self] drafts, at in try author(drafts, atMs: at) }
  }
}
