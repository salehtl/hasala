// The outbox (spec 04 §5.4): authored ops become durable `pending_ops` rows
// in one transaction before `enqueue` returns, then a debounced `authored`
// trigger (1.5 s) asks the WorkCoordinator for a run. While the outbox is
// latched, enqueue still succeeds (local work is never lost) and the flush does
// nothing; the UI shows the latch banner.
//
// Ops arrive as `Op` values (CoreWire), which only HasalaCore code can build
// (R5: `Op`'s initializer is `package`); CoreDomain's `OpAuthor` is the one
// intended author. Each op is validated (`OpCodec.validateOp`) and refused above
// 8 KiB of canonical JSON (S7, `OpTooLarge`) before anything is written, so one
// bad op can never cost its whole blob on every device.
import CoreSync
import Foundation

public enum OutboxError: Error, Sendable, Hashable {
  /// The op failed `validateOp` (a programming error in its author).
  case invalidOp(String)
  /// The op's canonical JSON exceeds 8 KiB (S7).
  case opTooLarge(opID: String)
  case store(StoreError)
}

public actor Outbox {
  public static let maxOpBytes = 8 * 1024
  public static let debounce: Duration = .milliseconds(1500)

  let store: LedgerStore
  let clock: any CoreTime.Clock
  let onAuthored: @Sendable () async -> Void
  let debounceWindow: Duration
  private var pendingTrigger: Task<Void, Never>?

  /// `onAuthored` is the coordinator's `run(.authored)`. `debounce` is §5.4's
  /// 1.5 s; tests pass a shorter one.
  public init(
    store: LedgerStore, clock: any CoreTime.Clock, debounce: Duration = Outbox.debounce,
    onAuthored: @escaping @Sendable () async -> Void
  ) {
    self.store = store
    self.clock = clock
    self.debounceWindow = debounce
    self.onAuthored = onAuthored
  }

  /// `sync_state.outbox_latch`.
  public var latch: OutboxLatch? { (try? store.syncState().latch) ?? nil }

  public func pendingCount() -> Int { (try? store.pendingCount()) ?? 0 }

  /// Validates, then inserts every op in ONE transaction; durable on return.
  public func enqueue(_ ops: [Op]) throws(OutboxError) {
    guard !ops.isEmpty else { return }
    let now = clock.nowMs()
    var rows: [PendingOp] = []
    for op in ops {
      let json = try Self.canonicalJSON(op)
      guard json.count <= Self.maxOpBytes else { throw .opTooLarge(opID: op.opID) }
      rows.append(
        PendingOp(
          opID: op.opID, opJSON: json, opType: op.type.rawValue, entityKind: op.entity?.kind, entityID: op.entity?.id,
          enqueuedAt: now))
    }
    do { try store.enqueue(rows) } catch { throw .store(error) }
    scheduleTrigger()
  }

  /// The op's canonical JSON object, exactly as it will travel inside a blob.
  public static func canonicalJSON(_ op: Op) throws(OutboxError) -> Data {
    let blob: [UInt8]
    do { blob = try OpCodec.encodeBlobOps([op]) } catch {
      switch error {
      case .invalid(let m), .unknownNewerVersion(let m): throw .invalidOp(m)
      }
    }
    guard let doc = try? JSONParser.parse(blob), let first = doc["ops"]?.arrayValue?.first else {
      throw .invalidOp("encode")
    }
    return Data(JSONWriter().bytes(first))
  }

  private func scheduleTrigger() {
    pendingTrigger?.cancel()
    let run = onAuthored
    let wait = debounceWindow
    pendingTrigger = Task {
      try? await Task.sleep(for: wait)
      guard !Task.isCancelled else { return }
      await run()
    }
  }

  /// Fires a scheduled trigger now (tests; app going to background).
  public func flushTriggerNow() async {
    pendingTrigger?.cancel()
    pendingTrigger = nil
    await onAuthored()
  }
}
