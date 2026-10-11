// Everything one account's sync needs, and the reads that turn a missing or
// locked secret into the right stop (spec 04 §4.4 null-vs-throw: a throw is
// "not now", never "absent").
import CoreAuth
import CoreCrypto
import CorePrimitives
import CoreStore
import CoreTime
import CoreWire
import Foundation

public final class SyncContext: Sendable {
  public let userID: UserID
  public let writerID: WriterID
  public let store: LedgerStore
  public let secrets: Secrets
  public let client: AuthClient
  public let clock: any CoreTime.Clock
  public let random: any RandomSource

  public init(
    userID: UserID, writerID: WriterID, store: LedgerStore, secrets: Secrets, client: AuthClient, clock: any CoreTime.Clock,
    random: any RandomSource
  ) {
    self.userID = userID
    self.writerID = writerID
    self.store = store
    self.secrets = secrets
    self.client = client
    self.clock = clock
    self.random = random
  }

  /// The bearer token; no session → `needsSignIn`; a pending logout is
  /// treated as signed out (§4.7 row 1).
  func bearer() throws(SyncStop) -> String {
    let s: SessionRecord?
    do { s = try secrets.session() } catch { throw .notNow }
    guard let s, !s.pending_logout else { throw .needsSignIn }
    return s.token
  }

  /// Every `K_e` this device holds for epochs `1...hwm`.
  func epochKeys(upTo hwm: UInt32) throws(SyncStop) -> [EpochKey] {
    var out: [EpochKey] = []
    for e in 1...max(1, hwm) {
      let d: Data?
      do { d = try secrets.epochKey(userID: userID, epoch: e) } catch { throw .notNow }
      if let d, let k = try? EpochKey(epoch: e, key: d) { out.append(k) }
    }
    return out
  }

  /// The DWK seed; absent → the device is unenrolled (§6.5 `unenrolled`).
  func writerSeed() throws(SyncStop) -> SecureBytes {
    let s: SecureBytes?
    do { s = try secrets.writerSeed(userID: userID, writerID: writerID) } catch { throw .notNow }
    guard let s else { throw .needsSignIn }
    return s
  }

  func storeCall<T>(_ body: () throws(StoreError) -> T) throws(SyncStop) -> T {
    do { return try body() } catch { throw .store(error) }
  }
}
