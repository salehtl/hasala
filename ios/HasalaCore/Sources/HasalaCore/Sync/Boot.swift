// The boot decision (spec 04 §6.5, port of `v2/boot.ts`; never rejects) and
// the launch probe (§6.5 "The launch run starts with GET /api/v1/meta and GET
// /api/v1/auth/session").
//
//   installCheck (HasalaKeychain.InstallCheck) ── .notNow ──► waitingForUnlock
//   bindingCheck
//     no binding, no DB, no session ──────────► signedOut
//     no binding, session present ────────────► onboardingKeys      (C1 interrupted, R-04)
//     binding ≠ DB user / session user ───────► foreignData
//     binding ok → secretsCheck
//       a secret unreadable now ──────────────► waitingForUnlock
//       K_e missing ──────────────────────────► needsUnlock
//       DWK missing ──────────────────────────► unenrolled
//       session missing ──────────────────────► signedOutBound
//       ledger.sqlite absent ─────────────────► restoring          (same-iPhone restore, §4.7 row 8)
//       ok ───────────────────────────────────► opening
//
// TODO(WS-14): `restoring` (recreate the store, full pull, authored head :=
// the verified server head) and the roster's `key_lost`/`revoked` states of
// `unenrolled` are decided here but not yet carried out.
import CoreAuth
import CorePrimitives
import CoreStore
import CoreWire
import Foundation

public enum BootState: Sendable, Hashable {
  case waitingForUnlock
  case signedOut
  case onboardingKeys
  case foreignData
  case needsUnlock
  case unenrolled
  case signedOutBound
  case restoring
  /// Open the pools, then onboarding or `ready(offline: true)`.
  case opening(AccountBinding)
}

/// The facts boot decides from; `gather` reads them, `decide` is pure.
public struct BootFacts: Sendable, Hashable {
  public var binding: AccountBinding?
  public var session: SessionRecord?
  /// The store's `store_meta.user_id`, when a store exists.
  public var storeUserID: UserID?
  public var storeExists: Bool
  public var epochKeyPresent: Bool
  public var writerKeyPresent: Bool
  /// A Keychain read threw (before first unlock).
  public var unreadable: Bool

  public init(
    binding: AccountBinding?, session: SessionRecord?, storeUserID: UserID?, storeExists: Bool,
    epochKeyPresent: Bool, writerKeyPresent: Bool, unreadable: Bool = false
  ) {
    self.binding = binding
    self.session = session
    self.storeUserID = storeUserID
    self.storeExists = storeExists
    self.epochKeyPresent = epochKeyPresent
    self.writerKeyPresent = writerKeyPresent
    self.unreadable = unreadable
  }
}

public enum Boot {
  public static func decide(_ f: BootFacts) -> BootState {
    if f.unreadable { return .waitingForUnlock }
    let liveSession = f.session.flatMap { $0.pending_logout ? nil : $0 }
    guard let binding = f.binding else {
      if liveSession != nil { return .onboardingKeys }
      return f.storeExists ? .foreignData : .signedOut
    }
    if let s = f.storeUserID, s.string != binding.user_id { return .foreignData }
    if let s = liveSession, s.user_id != binding.user_id { return .foreignData }
    guard binding.userID != nil, binding.writerID != nil else { return .foreignData }
    if !f.epochKeyPresent { return .needsUnlock }
    if !f.writerKeyPresent { return .unenrolled }
    if liveSession == nil { return .signedOutBound }
    if !f.storeExists { return .restoring }
    return .opening(binding)
  }

  /// Reads the facts. Call only after `InstallCheck` returned `.done`.
  public static func gather(_ env: AccountEnvironment) -> BootFacts {
    var f = BootFacts(
      binding: nil, session: nil, storeUserID: nil, storeExists: false, epochKeyPresent: false,
      writerKeyPresent: false)
    do {
      f.binding = try env.secrets.binding()
      f.session = try env.secrets.session()
      if let b = f.binding, let u = b.userID, let w = b.writerID {
        f.epochKeyPresent = try env.secrets.epochKey(userID: u, epoch: b.key_epoch) != nil
        f.writerKeyPresent = try env.secrets.writerSeed(userID: u, writerID: w) != nil
        if let dir = env.storeDirectory(for: u) {
          f.storeExists = FileManager.default.fileExists(atPath: dir.appendingPathComponent("ledger.sqlite").path)
          if f.storeExists, let s = try? LedgerStore.open(directory: dir) { f.storeUserID = try? s.meta()?.userID }
        }
      }
    } catch {
      f.unreadable = true
    }
    return f
  }
}

/// What the launch run's probe found (§6.5).
public enum LaunchProbe: Sendable, Hashable {
  case ok
  /// The session is not bound to a writer: re-bind (C2b / C2b-P).
  case unbound
  /// A restricted session or a frozen account (§6.11).
  case frozen
  /// `meta.min_ios_build` is above this build (§6.5 RD-1).
  case updateRequired
  case stop(SyncStop)

  /// `GET /meta` then `GET /auth/session`. `build` is `CFBundleVersion`.
  public static func run(_ ctx: SyncContext, build: Int) async -> LaunchProbe {
    do {
      let meta = try await ctx.client.meta()
      if let min = meta.min_ios_build, min > build { return .updateRequired }
      let token = try ctx.bearer()
      let s = try await ctx.client.session(bearer: token)
      if s.restricted == true { return .frozen }
      guard let w = s.writer_id else { return .unbound }
      return w == ctx.writerID.string ? .ok : .unbound
    } catch let e as APIError {
      let stop = await ctx.settled(SyncStop.read(e))
      return stop == .frozen ? .frozen : stop == .halted(.updateRequired) ? .updateRequired : .stop(stop)
    } catch let e as SyncStop {
      return .stop(e)
    } catch {
      return .stop(.offline)
    }
  }
}
