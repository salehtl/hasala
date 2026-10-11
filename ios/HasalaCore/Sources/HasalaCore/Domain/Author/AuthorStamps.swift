// This device's stamp memory for its writer (03c §1.8.2, the `own_last_ms`
// input): the newest `authored_at` handed out here, which `pending_ops` and the
// fold may not show yet (a blob built but not enqueued, or acknowledged before
// the self-pull folded it).
//
// Every author of one account shares ONE instance (`LedgerPageObserver.stamps`,
// also handed to the Gmail lane's `MailboxAuthoring`) and builds each blob
// inside `authoring`, which holds the lock from reading the floor to recording
// the blob's last stamp. Two blobs started before either is enqueued therefore
// never take the same stamp, whichever author built them.
import Synchronization

public final class AuthorStamps: Sendable {
  private let last = Mutex<Int64?>(nil)

  public init() {}

  /// The newest stamp handed out here; nil before the first blob.
  public var lastMs: Int64? { last.withLock { $0 } }

  /// Runs `body` with the newest stamp handed out here and records the newest
  /// stamp `body` reports. The lock is held across `body`, so it must be
  /// synchronous and short: it builds blobs, it never waits.
  public func authoring<T: Sendable, E: Error>(
    _ body: (_ lastMs: Int64?) throws(E) -> (value: T, lastMs: Int64?)
  ) throws(E) -> T {
    try last.withLock { (v: inout Int64?) throws(E) -> T in
      let r = try body(v)
      if let l = r.lastMs { v = max(v ?? l, l) }
      return r.value
    }
  }

  /// Builds one blob: `context` (this writer's fold, outbox and clock) raised to
  /// the newest stamp handed out here, `body`'s ops, then `build()`. Nil when
  /// `body` added no op (nothing is recorded).
  public func build(_ context: AuthorContext, _ body: (inout OpAuthor) throws(AuthorError) -> Void) throws(AuthorError)
    -> AuthoredBlob?
  {
    try authoring { (floor: Int64?) throws(AuthorError) -> (value: AuthoredBlob?, lastMs: Int64?) in
      var a = OpAuthor(context.raised(to: floor))
      try body(&a)
      guard a.count > 0 else { return (nil, nil) }
      let blob = try a.build()
      return (blob, blob.lastAuthoredMs)
    }
  }
}

extension AuthorContext {
  /// This context with `ownLastMs` at least `floor`.
  public func raised(to floor: Int64?) -> AuthorContext {
    var c = self
    c.ownLastMs = [ownLastMs, floor].compactMap { $0 }.max()
    return c
  }
}
