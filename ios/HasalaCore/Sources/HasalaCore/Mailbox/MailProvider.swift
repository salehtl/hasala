// The mailbox provider seam: what MailboxEngine needs from one mail service (Gmail today,
// Outlook next). The engine owns every decision (retries, accounting, the watermark, the trust
// gate); a provider only speaks its service's wire and names its trust rule.
//
//   MailProvider      the provider's id, its OAuth client, a MailSource per access token, and
//                     the Authentication-Results verdict it trusts
//   MailOAuthClient   PKCE authorize URL, callback check, code exchange, refresh, revoke
//   MailSource        the change detector, the sender-filtered listing, metadata, raw, push
//
// The neutral value and error types below are what the Gmail types were; the Gmail names stay
// as typealiases (GmailClient.swift, GmailOAuth.swift, TokenProvider.swift).
import CoreJSON
import CoreMail
import CorePrimitives
import Foundation

/// The provider ids of the shared contract: the strings used in the database, the API, the op's
/// `provenance.provider` and the server's address HMAC.
public enum MailProviderID: String, Sendable, Hashable, CaseIterable {
  case gmail
  case outlook

  public var prefersEphemeralSession: Bool { self == .outlook }
}

public protocol MailProvider: Sendable {
  var id: MailProviderID { get }
  var oauth: any MailOAuthClient { get }
  /// The mail API as the holder of `accessToken`.
  func source(accessToken: AccessToken) -> any MailSource
  /// The Authentication-Results verdict for a header block (the trust gate, spec 04 §7.6): which
  /// header the provider's own receiving server wrote, and what it said. Fails closed.
  func analyzeAuthResults(_ headerBlock: String) -> AuthResults.Analysis
  /// At most this many message downloads at once (the engine's width is capped by it).
  var maxDownloadWidth: Int { get }
  /// Whether `MailSource.stop` ends only this iPhone's push (Outlook: one subscription id, kept
  /// here). Gmail's `users.stop` ends the mailbox's watch for every client, so an iPhone that
  /// lost the link must not call it.
  var stopIsDeviceScoped: Bool { get }
  /// Keeps what `PUT /mailbox/link` returned for this provider (Outlook: the `clientState`).
  func installLink(_ result: MailboxLinkResult) throws(MailAuthError)
  /// Forgets what `installLink` kept (unlink, takeover, a link deleted elsewhere). The refresh
  /// token is the token provider's, not this.
  func forgetLink()
}

extension MailProvider {
  public var maxDownloadWidth: Int { Int.max }
  public var stopIsDeviceScoped: Bool { false }
  public func installLink(_ result: MailboxLinkResult) throws(MailAuthError) {}
  public func forgetLink() {}
}

// MARK: - OAuth

/// One authorization attempt: what was sent, and what the callback must echo.
public struct MailAuthorization: Sendable, Equatable {
  public let url: URL
  public let state: String
  public let codeVerifier: String
  public let nonce: String

  public init(url: URL, state: String, codeVerifier: String, nonce: String) {
    self.url = url
    self.state = state
    self.codeVerifier = codeVerifier
    self.nonce = nonce
  }
}

public enum MailOAuthError: Error, Sendable, Equatable {
  /// The user closed the sheet.
  case cancelled
  /// The callback's `state` differs from the one sent (forged or stale redirect).
  case stateMismatch
  /// The provider answered `error=...` on the redirect (e.g. `access_denied`).
  case denied(String)
  /// The callback carried no code, or was not our redirect.
  case malformedCallback
  /// The token response lacked a refresh token, an id_token or the mail-read scope
  /// ("Hasala needs permission to read your bank emails": a granular-consent untick).
  case missingGrant
  /// `invalid_grant` on refresh: the token was revoked or expired (`reconnect_required`).
  case invalidGrant
  /// Any other non-2xx from the token endpoint (status only, never a body).
  case http(Int)
  case offline
  /// A 2xx whose body this code cannot read.
  case malformedResponse
  /// The build has no client configured for this provider.
  case notConfigured
}

public struct MailTokenGrant: Sendable, Equatable {
  public let accessToken: String
  /// Seconds from the response.
  public let expiresIn: Int64
  /// Present on the code exchange (required there), absent on a refresh.
  public let refreshToken: String?
  public let idToken: String?
  public let scope: String?

  public init(accessToken: String, expiresIn: Int64, refreshToken: String?, idToken: String?, scope: String?) {
    self.accessToken = accessToken
    self.expiresIn = expiresIn
    self.refreshToken = refreshToken
    self.idToken = idToken
    self.scope = scope
  }
}

/// What the app reads from an id_token it does not verify (the server verifies it): the address
/// it shows on Bank alerts and the nonce it checks against the one it sent.
public struct MailIdentity: Sendable, Equatable {
  public let email: String?
  public let nonce: String?

  public init(email: String?, nonce: String?) {
    self.email = email
    self.nonce = nonce
  }
}

/// The token-endpoint half of a provider's OAuth (a public client, PKCE S256, no secret).
public protocol MailOAuthClient: Sendable {
  /// False while the build carries no client for this provider: connecting is then unavailable.
  var isConfigured: Bool { get }
  /// The callback URL scheme the browser sheet waits for.
  var redirectScheme: String { get }
  /// The authorize URL with fresh PKCE and state; `nonce` is the server's link-challenge nonce.
  func begin(nonce: String, random: any RandomSource) throws(MailOAuthError) -> MailAuthorization
  /// Checks the redirect (state first, in constant time) and returns the authorization code.
  func code(fromCallback callback: URL, for auth: MailAuthorization) throws(MailOAuthError) -> String
  /// The code exchange. The grant must carry a refresh token, an id_token and the mail-read
  /// scope, else `missingGrant`.
  func exchange(code: String, auth: MailAuthorization) async throws(MailOAuthError) -> MailTokenGrant
  /// A refresh. `invalid_grant` is `invalidGrant`.
  func refresh(refreshToken: String) async throws(MailOAuthError) -> MailTokenGrant
  /// Ends the grant at the provider, best effort. A provider without a revoke endpoint
  /// (Microsoft) returns without sending anything.
  func revoke(token: String) async throws(MailOAuthError)
  /// The unverified claims of the exchange's id_token; nil when it cannot be read.
  func identity(idToken: String) -> MailIdentity?
}

/// The browser half, implemented by the app (ASWebAuthenticationSession with
/// `callback: .customScheme(callbackScheme)`; ephemeral per `MailProviderID.prefersEphemeralSession`).
public protocol MailAuthSessionPresenter: Sendable {
  /// Shows the provider's consent page for `url` and returns the callback URL; throws
  /// `MailOAuthError.cancelled` when the user closes the sheet.
  func authorize(url: URL, callbackScheme: String) async throws(MailOAuthError) -> URL
}

// MARK: - The mail API

public enum MailAPIError: Error, Sendable, Equatable {
  /// A non-2xx answer, or a 2xx without the field the call needs (status kept). A provider maps
  /// its "slow down" answers to 429.
  case status(Int, op: String)
  case offline
  /// The caller asked for an unfiltered listing (a programming error, refused locally).
  case unfilteredListing
  /// "Slow down" with a `Retry-After` (seconds): the run stops at once, with no quick retry, and
  /// the engine starts no cycle before it has passed. Counts as a 429.
  case throttled(retryAfterSec: Int64, op: String)
  /// The account has no mailbox this provider's API can read (Graph's
  /// `MailboxNotEnabledForRESTAPI`: a Microsoft account on a non-Microsoft address). The user is
  /// told; retrying cannot fix it.
  case noMailbox
  /// A listing page held a message from outside the requested senders: the provider ignored the
  /// filter. The page is dropped unread (PO G) and the run halts.
  case filterNotApplied

  public var status: Int? {
    switch self {
    case .status(let s, _): s
    case .throttled: 429
    default: nil
    }
  }
}

public struct MailListPage: Sendable, Equatable {
  public let ids: [String]
  public let nextPageToken: String?

  public init(ids: [String], nextPageToken: String?) {
    self.ids = ids
    self.nextPageToken = nextPageToken
  }
}

/// A message's From and Authentication-Results headers and its received time; nothing else.
public struct MailMessageMetadata: Sendable, Equatable {
  public let id: String
  /// ms since the epoch as a decimal string, or "" when absent.
  public let internalDate: String
  public let sizeEstimate: Int64?
  /// The returned headers, in the message's order.
  public let headers: [(name: String, value: String)]

  public init(id: String, internalDate: String, sizeEstimate: Int64?, headers: [(name: String, value: String)]) {
    self.id = id
    self.internalDate = internalDate
    self.sizeEstimate = sizeEstimate
    self.headers = headers
  }

  public static func == (a: Self, b: Self) -> Bool {
    a.id == b.id && a.internalDate == b.internalDate && a.sizeEstimate == b.sizeEstimate
      && a.headers.elementsEqual(b.headers) { $0.name == $1.name && $0.value == $1.value }
  }

  /// The headers re-serialized as a header block (`Name: value\r\n`...), for CoreMail's
  /// Authentication-Results analysis. Only the requested headers are present.
  public var headerBlock: String {
    headers.map { "\($0.name): \($0.value)" }.joined(separator: "\r\n")
  }

  public var from: String { headers.first { $0.name.caseInsensitiveCompare("From") == .orderedSame }?.value ?? "" }
}

public struct MailRawMessage: Sendable, Equatable {
  public let id: String
  /// The RFC 822 bytes as base64url (unpadded), undecoded: the engine decodes strictly and
  /// hashes the bytes. A provider that serves the bytes themselves encodes them.
  public let rawBase64URL: String
  /// ms since the epoch as a decimal string.
  public let internalDate: String

  public init(id: String, rawBase64URL: String, internalDate: String) {
    self.id = id
    self.rawBase64URL = rawBase64URL
    self.internalDate = internalDate
  }
}

/// A live push subscription (Gmail `users.watch`, a Graph subscription).
public struct MailSubscription: Sendable, Equatable {
  /// Epoch ms.
  public let expiresAtMs: Int64

  public init(expiresAtMs: Int64) { self.expiresAtMs = expiresAtMs }
}

/// The provider's mail API as one account's holder. It never retries and never interprets: a
/// non-2xx answer is a typed `MailAPIError` carrying the status, and the engine decides what it
/// means (`gone`, `retry`, `fatal`).
///
/// The listing invariant (PO G): `list` ALWAYS filters by sender. The rest of the mailbox, its
/// ids and its headers included, never reaches the phone. A source refuses an empty sender list
/// (`unfilteredListing`) rather than send an unfiltered request, and has no "list everything
/// new" call (Gmail's `history.list` is deliberately absent).
public protocol MailSource: Sendable {
  /// At most this many senders per `list` call; the engine cuts the trusted set into groups.
  var maxSendersPerList: Int { get }
  /// A cheap "did anything change?" value (Gmail's historyId). nil when the provider has none:
  /// the engine then lists on every cycle.
  func changeToken() async throws(MailAPIError) -> String?
  /// One page of the ids of mail from `senders` (domains) received at or after `since` (epoch
  /// seconds). Includes junk / spam, excludes trash where the provider can.
  func list(senders: [String], since: Int64, pageToken: String?) async throws(MailAPIError) -> MailListPage
  func metadata(id: String) async throws(MailAPIError) -> MailMessageMetadata
  /// The RFC 822 message. A 2xx without the body is reported as that status (`gone`).
  func raw(id: String) async throws(MailAPIError) -> MailRawMessage
  /// Starts push for this mailbox; nil when `push` gives this provider nothing to subscribe with.
  func subscribe(_ push: MailboxPushConfig) async throws(MailAPIError) -> MailSubscription?
  /// Extends the live subscription; nil as for `subscribe`.
  func renew(_ push: MailboxPushConfig) async throws(MailAPIError) -> MailSubscription?
  /// Ends push for this mailbox.
  func stop() async throws(MailAPIError)
  /// Proves the account has a mailbox this API reads, before anything is linked (`noMailbox`
  /// when it has none). Reads no message.
  func checkMailbox() async throws(MailAPIError)
}

extension MailSource {
  public func checkMailbox() async throws(MailAPIError) {}
}

public enum SenderProbeResult: Sendable, Equatable {
  case found([String])
  case notReading
  case reconnectRequired
  case offline
}
