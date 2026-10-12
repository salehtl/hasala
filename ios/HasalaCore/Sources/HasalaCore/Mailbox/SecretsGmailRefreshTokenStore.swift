// The Gmail refresh token's custody (spec 04 §7.3, §4.4): the Keychain item
// `.gmailRefresh(userID)` behind CoreStore's `SecretStore`, the same store, access
// group and accessibility as every other item of the account, so
// `Secrets.wipeAccount` (sign-out, deletion, a foreign-data reset) always takes
// it with the rest.
//
// The null-vs-throw contract carries through: an absent item reads nil; any
// failure to read it (before first unlock) throws `SecretUnavailable`, which
// the token provider maps to "not now", never to "disconnected". An item that
// reads but holds no token (empty, or not UTF-8) can never refresh, so it is
// deleted and read as absent: the account shows "disconnected" and can be
// linked again, instead of "not now" on every cycle.
import CorePrimitives
import CoreStore
import Foundation

public struct SecretsGmailRefreshTokenStore: GmailRefreshTokenStore {
  let store: any SecretStore
  let item: SecretItem

  public init(secrets: Secrets, userID: UserID) {
    store = secrets.store
    item = .gmailRefresh(userID: userID)
  }

  public func read() throws(SecretUnavailable) -> String? {
    let d: Data?
    do { d = try store.read(item) } catch { throw SecretUnavailable() }
    guard let d else { return nil }
    guard let s = String(data: d, encoding: .utf8), !s.isEmpty else {
      do { try store.delete(item) } catch { throw SecretUnavailable() }
      return nil
    }
    return s
  }

  /// Writes, then reads back: a mismatch throws (§4.4).
  public func write(_ token: String) throws(SecretUnavailable) {
    let bytes = Data(token.utf8)
    do {
      try store.write(item, bytes)
      guard try store.read(item) == bytes else { throw SecretUnavailable() }
    } catch {
      throw SecretUnavailable()
    }
  }

  public func delete() throws(SecretUnavailable) {
    do { try store.delete(item) } catch { throw SecretUnavailable() }
  }
}
