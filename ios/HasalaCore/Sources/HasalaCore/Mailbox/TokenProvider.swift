// Token custody (spec 04 §7.3, port of the PWA's mailboxToken.ts contract).
//
// The refresh token lives in the Keychain item `.mailRefresh(provider, user)` (§4.4), reached
// through `MailRefreshTokenStore` so the core never imports Security (R1). The access token lives
// in memory only, inside `RefreshingMailTokenProvider` (an actor), with its expiry; it is
// refreshed when fewer than 60 s remain, and never written to disk or logged.
//
// The null-vs-throw contract: `read()` returning nil means "no token" (not connected), and a
// throw means "present but unreadable right now" (before first unlock). A throw maps to
// `MailAuthError.notNow`, never to "absent": treating it as absent would make a locked phone
// look disconnected.
import CoreTime
import Foundation

public struct AccessToken: Sendable, Equatable {
  public let value: String
  /// Epoch ms.
  public let expiresAtMs: Int64
  public init(value: String, expiresAtMs: Int64) {
    self.value = value
    self.expiresAtMs = expiresAtMs
  }
}

public enum MailAuthError: Error, Sendable, Equatable {
  /// No refresh token, or the provider refused it (`invalid_grant`): the user must reconnect.
  case reconnectRequired
  /// The Keychain is unreadable (before first unlock): try again later, change nothing.
  case notNow
  case offline
  /// The token was revoked on purpose (disconnect, other device took over).
  case revoked
}

public typealias GmailAuthError = MailAuthError

/// spec 04 §2.7.
public protocol MailTokenProvider: Sendable {
  func accessToken(forceRefresh: Bool) async throws(MailAuthError) -> AccessToken
}

public typealias GmailTokenProvider = MailTokenProvider

public struct SecretUnavailable: Error, Sendable, Equatable {
  public init() {}
}

/// The Keychain item `.mailRefresh(provider, user)`; implemented over `Secrets`
/// (`SecretsMailRefreshTokenStore`) and by an in-memory store in tests.
public protocol MailRefreshTokenStore: Sendable {
  /// nil = absent; throws = present but unreadable now.
  func read() throws(SecretUnavailable) -> String?
  /// Writes and reads back (a mismatch throws).
  func write(_ token: String) throws(SecretUnavailable)
  func delete() throws(SecretUnavailable)
}

public typealias GmailRefreshTokenStore = MailRefreshTokenStore

/// An in-memory `MailRefreshTokenStore` (tests, previews). `locked` simulates before-first-unlock.
public final class MemoryMailRefreshTokenStore: MailRefreshTokenStore, @unchecked Sendable {
  private let lock = NSLock()
  private var token: String?
  public var locked = false

  public init(token: String? = nil) { self.token = token }

  public func read() throws(SecretUnavailable) -> String? {
    lock.lock()
    defer { lock.unlock() }
    if locked { throw SecretUnavailable() }
    return token
  }
  public func write(_ t: String) throws(SecretUnavailable) {
    lock.lock()
    defer { lock.unlock() }
    if locked { throw SecretUnavailable() }
    token = t
  }
  public func delete() throws(SecretUnavailable) {
    lock.lock()
    defer { lock.unlock() }
    if locked { throw SecretUnavailable() }
    token = nil
  }
}

public typealias MemoryGmailRefreshTokenStore = MemoryMailRefreshTokenStore

/// `KeychainGmailTokenProvider` of spec 04 §7.1, for any provider's OAuth client, with the
/// Keychain behind `MailRefreshTokenStore`.
public actor RefreshingMailTokenProvider: MailTokenProvider {
  let oauth: any MailOAuthClient
  let store: any MailRefreshTokenStore
  let clock: any Clock
  private var cached: AccessToken?

  /// Refresh when fewer than this many ms remain.
  public static let refreshMarginMs: Int64 = 60_000

  public init(oauth: any MailOAuthClient, store: any MailRefreshTokenStore, clock: any Clock) {
    self.oauth = oauth
    self.store = store
    self.clock = clock
  }

  public func accessToken(forceRefresh: Bool) async throws(MailAuthError) -> AccessToken {
    if !forceRefresh, let c = cached, c.expiresAtMs - clock.nowMs() > Self.refreshMarginMs { return c }
    let refresh: String?
    do { refresh = try store.read() } catch { throw .notNow }
    guard let refresh, !refresh.isEmpty else {
      cached = nil
      throw .reconnectRequired
    }
    do {
      let grant = try await oauth.refresh(refreshToken: refresh)
      let t = AccessToken(value: grant.accessToken, expiresAtMs: clock.nowMs() + grant.expiresIn * 1000)
      cached = t
      return t
    } catch .invalidGrant {
      cached = nil
      try? store.delete()
      throw .reconnectRequired
    } catch .offline {
      throw .offline
    } catch {
      // A 5xx or an unreadable body: not the user's fault, retried on the next trigger.
      throw .offline
    }
  }

  /// Stores the refresh token of a fresh grant and primes the access token.
  public func install(grant: MailTokenGrant) throws(MailAuthError) {
    guard let r = grant.refreshToken else { throw .reconnectRequired }
    do { try store.write(r) } catch { throw .notNow }
    cached = AccessToken(value: grant.accessToken, expiresAtMs: clock.nowMs() + grant.expiresIn * 1000)
  }

  /// Whether a refresh token is present (nil: unreadable now).
  public func hasRefreshToken() -> Bool? {
    do { return try store.read() != nil } catch { return nil }
  }

  /// Deletes the Keychain item without revoking at the provider: another iPhone became the
  /// holder (spec 04 §7.4). Both iPhones use the same iOS client id, and a revoke ends the app's
  /// whole grant for that account, the new holder's tokens included.
  public func forget() {
    cached = nil
    try? store.delete()
  }

  /// Revokes the refresh token at the provider (best effort; a no-op where it has no revoke
  /// endpoint) and deletes the Keychain item. Used on Disconnect (spec 04 §7.4), where ending the
  /// grant is the point.
  public func revokeAndForget() async {
    cached = nil
    if let token = try? store.read() {
      try? await oauth.revoke(token: token)
    }
    try? store.delete()
  }

  /// Drops the in-memory access token (a 401 from the mail API).
  public func invalidate() { cached = nil }
}

public typealias RefreshingGmailTokenProvider = RefreshingMailTokenProvider
