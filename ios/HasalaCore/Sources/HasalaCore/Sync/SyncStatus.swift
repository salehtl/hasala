// What the sync engine tells the app (spec 04 §5.1, §5.7): its phase, the
// halts and latches, and how every server answer maps onto them.
import CoreAuth
import CoreStore
import CoreWire
import Foundation

/// Halts: non-dismissable walls; nothing is wiped (§5.7).
public enum HaltKind: Sendable, Hashable {
  case updateRequired
  case tampered(TamperReason)
  /// A `409 conflict` resend found a stored row whose hash differs from ours.
  case tamperedResend
  /// `meta.log_generation` moved AND a chain condition appeared (R-10).
  case serverRestored
  /// A fold or invariant contradiction (raised by the fold hook).
  case inconsistent(String)
  /// The key history failed verification or disagreed with `GET /writers`
  /// (01 §10.13; the integrity alarm, kept as a halt because the reader cannot
  /// run without a verified roster).
  case rosterInvalid
}

public enum SyncPhase: Sendable, Hashable {
  case idle
  case reconciling
  case pulling
  case folding
  case pushing
  case selfPull
  case offline(sinceMs: Int64)
  case halted(HaltKind)
  /// `403 account_frozen` or a restricted session (§6.11).
  case frozen
  /// `401`: foreground shows the sign-in sheet; background stops silently.
  case needsSignIn
  /// `403 writer_unbound` / `writer_mismatch`: sign in again with the device binding.
  case needsRebind
  /// R6 or `409 stale_epoch`: the key for `epoch` is not on this device.
  case needsUnlock(epoch: UInt32)
  /// `403 keys_required`: onboarding step `keys`.
  case keysRequired
  /// `410 account_deleted` or `403 writer_revoked`: wipe (§4.7 row 3).
  case wiping
}

/// Published after every stage (§5.1 `SyncStatus`).
public struct SyncStatus: Sendable, Hashable {
  public var phase: SyncPhase = .idle
  public var lastSuccessAt: Int64?
  public var latch: OutboxLatch?
  public var pendingCount: Int = 0
  /// `403 account_suspended`: reads continue, writes stay queued.
  public var suspended: Bool = false
  /// New integrity-alarm occurrences since the app last acknowledged (A-32).
  public var integrityAlarms: Int = 0
  /// `Hasala-Request-Id` of the last failing call (diagnostics, §18.2).
  /// TODO(WS-18): not set yet; `SyncStop` does not carry the failing
  /// response's request id, and the diagnostics screen is not built.
  public var lastFailingRequestID: String?
  /// `Retry-After` of the last `429`, seconds.
  public var retryAfterSeconds: Int?

  public init() {}
}

/// Why a stage stopped. The engine turns each into a phase.
public enum SyncStop: Error, Sendable, Hashable {
  case offline
  case rateLimited(retryAfter: Int?)
  case halted(HaltKind)
  /// `alarm`: the cause also raises the integrity alarm (§5.5: `bad_signature`, `plaintext_refused`).
  case latched(OutboxLatch, alarm: Bool = false)
  case frozen
  case needsSignIn
  case needsRebind
  case needsUnlock(epoch: UInt32)
  case keysRequired
  case wipe
  case suspended
  /// A secret could not be read now (before first unlock): return `.noData`.
  case notNow
  /// A local store failure (by code; never shown as tampering).
  case store(StoreError)
  /// A 2xx with an unexpected body, or two empty incomplete pages (§5.2):
  /// offline-class, retried.
  case protocolError(String)
  case cancelled
}

extension SyncStop {
  /// The answers every route shares (§5.5 table, §6.4). `nil` = the caller's
  /// own table decides.
  static func common(_ e: APIError) -> SyncStop? {
    switch e {
    case .transport(.cancelled): return .cancelled
    case .transport: return .offline
    case .malformed(let m): return .protocolError(m)
    case .refused(let f):
      switch (f.status, f.code) {
      case (401, _): return .needsSignIn
      case (403, "account_frozen"): return .frozen
      case (403, "account_suspended"): return .suspended
      case (403, "writer_revoked"), (410, _): return .wipe
      case (403, "writer_unbound"), (403, "writer_mismatch"): return .needsRebind
      case (403, "keys_required"): return .keysRequired
      case (426, _): return .halted(.updateRequired)
      case (429, _): return .rateLimited(retryAfter: f.retryAfterSeconds)
      case (500..., _): return .offline
      default: return nil
      }
    }
  }

  /// Every other refusal on a read path: a protocol error (retried).
  static func read(_ e: APIError) -> SyncStop {
    if let f = e.failure, f.status == 409, f.code == "cursor_ahead" { return .halted(.tampered(.chainBreak)) }
    return common(e) ?? .protocolError("refused \(e.failure?.status ?? 0) \(e.failure?.code ?? "")")
  }
}
