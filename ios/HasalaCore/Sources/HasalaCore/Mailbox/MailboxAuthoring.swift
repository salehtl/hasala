// The `MailboxOpAuthor` the production persistence calls (spec 04 §7.5 step 7e,
// §2.4 R5): each staged or fetched message's `MailboxIngestDraft` becomes one
// `txn_ingested` through CoreDomain's `OpAuthor.ingest` (stamped, validated,
// size-checked), then its canonical JSON (`Outbox.canonicalJSON`, the bytes the
// outbox would store) as a `pending_ops` row, so the op and the message's
// accounting commit in ONE transaction (`LedgerMailboxPersistence.commit`).
//
// The author rule's inputs (03c §1.8.2) are kept here, synchronously, because
// the persistence's closure cannot await: this writer's newest stamp is the
// largest of the newest pending op, the fold's `maxAuthored` that
// `RuntimeMailboxLedger` refreshes after every pull, and the device's shared
// `AuthorStamps` (the observer's), inside whose lock the blob is built. So a
// Gmail blob and a blob authored on a screen never share a stamp, and the
// observer sees a Gmail stamp before the self-pull folds it.
import CoreDomain
import CoreOutbox
import CorePrimitives
import CoreStore
import CoreSync
import CoreTime
import Foundation
import Synchronization

public final class MailboxAuthoring: Sendable {
  let store: LedgerStore
  let writerID: String
  let random: any RandomSource
  /// The device's stamp memory, shared with every other author of the account.
  public let stamps: AuthorStamps
  private let seen: Mutex<[String: Int64]>

  /// `stamps` must be the account's shared instance (`LedgerPageObserver.stamps`);
  /// `init(observer:)` wires it.
  public init(
    store: LedgerStore, writerID: String, random: any RandomSource, stamps: AuthorStamps, seen: [String: Int64] = [:]
  ) {
    self.store = store
    self.writerID = writerID
    self.random = random
    self.stamps = stamps
    self.seen = Mutex(seen)
  }

  /// The production wiring: the observer's store, writer, randomness and stamps.
  public convenience init(observer: LedgerPageObserver) {
    let c = observer.context
    self.init(store: c.store, writerID: c.writerID.string, random: c.random, stamps: observer.stamps)
  }

  /// The fold's `maxAuthored` after a pull (`LedgerPageObserver.seenStamps()`).
  public func updateSeen(_ seen: [String: Int64]) {
    self.seen.withLock { $0 = seen }
  }

  /// The author context at `nowMs` from the outbox and the fold (the shared
  /// stamps raise it when the blob is built).
  public func context(nowMs: Int64) throws -> AuthorContext {
    let pending = try store.latestPendingAuthoredAt().flatMap { try? parseInstantMs($0) }
    let seen = self.seen.withLock { $0 }
    let own = [seen[writerID], pending].compactMap { $0 }.max()
    return AuthorContext(writerID: writerID, nowMs: nowMs, ownLastMs: own, maxAuthored: seen, random: random)
  }

  /// `MailboxOpAuthor`: the drafts as one blob's `pending_ops` rows, in order.
  public func author(_ drafts: [MailboxIngestDraft], atMs: Int64) throws -> [MailboxPendingOpRow] {
    guard !drafts.isEmpty else { return [] }
    let ctx = try context(nowMs: atMs)
    let built: AuthoredBlob?
    do {
      built = try build(drafts, ctx)
    } catch {
      built = try build(drafts.map { Self.authorable($0, ctx) }, ctx)
    }
    guard let blob = built else { return [] }
    var rows: [MailboxPendingOpRow] = []
    for op in blob.ops {
      rows.append(
        MailboxPendingOpRow(
          opID: op.opID, opJSON: try Outbox.canonicalJSON(op), opType: op.type.rawValue, entityKind: op.entity?.kind,
          entityID: op.entity?.id, enqueuedAt: atMs))
    }
    return rows
  }

  private func build(_ drafts: [MailboxIngestDraft], _ ctx: AuthorContext) throws(AuthorError) -> AuthoredBlob? {
    try stamps.build(ctx) { a throws(AuthorError) in
      for d in drafts { try a.ingest(payload: d.payload, ingestID: d.ingestID) }
    }
  }

  static func authorable(_ d: MailboxIngestDraft, _ ctx: AuthorContext) -> MailboxIngestDraft {
    if accepts(d, ctx) { return d }
    let kept = MessageDisposer.refusedShape(d, keepGates: true)
    if accepts(kept, ctx) { return kept }
    return MessageDisposer.refusedShape(d, keepGates: false)
  }

  static func accepts(_ d: MailboxIngestDraft, _ ctx: AuthorContext) -> Bool {
    var a = OpAuthor(ctx)
    do {
      _ = try a.ingest(payload: d.payload, ingestID: d.ingestID)
      _ = try a.build()
      return true
    } catch {
      return false
    }
  }

  /// The closure `LedgerMailboxPersistence(tables:author:nowMs:)` takes.
  public var opAuthor: MailboxOpAuthor {
    { [self] drafts, at in try author(drafts, atMs: at) }
  }
}

extension LedgerMailboxPersistence {
  /// The production persistence: the mailbox tables of the account's
  /// `ledger.sqlite`, authoring every draft through `authoring`.
  public init(store: LedgerStore, authoring: MailboxAuthoring, nowMs: @escaping @Sendable () -> Int64) {
    self.init(tables: MailboxTableStore(writer: store.db), author: authoring.opAuthor, nowMs: nowMs)
  }
}
