// Microsoft identity platform OAuth for the Outlook lane, the pure half (the Outlook plan's
// shared contract; docs/decisions/outlook-mailbox.md §6): PKCE S256, `state`, the authorize URL
// on the `consumers` tenant, the callback check, and the token endpoint (exchange, refresh) over
// an injected `HTTPExchange`. Hand-written like `GoogleOAuthClient`: no MSAL, no SDK.
//
// A public client: no secret anywhere, and the client id reaches this code only from BuildInfo.
// Personal Microsoft accounts only (the `consumers` tenant). The refresh token goes to the
// Keychain (`app.hasala.outlook.refresh`); the access token lives in memory only. Microsoft has
// no revoke endpoint: `revoke` sends nothing, and Disconnect points the user to
// account.live.com/consent/Manage.
import CoreJSON
import CorePrimitives
import Foundation

public struct MicrosoftOAuthConfig: Sendable, Equatable {
  /// The Entra app's client id (`BuildInfo.outlookClientID`).
  public let clientID: String
  /// `msauth.app.hasala.ios` (`BuildInfo.outlookRedirectScheme`); never in CFBundleURLTypes.
  public let redirectScheme: String
  public let authorizeEndpoint: String
  public let tokenEndpoint: String

  /// The `consumers` tenant: personal Microsoft accounts (outlook.com, hotmail.com, live.com).
  public static let consumersTenantID = "9188040d-6c67-4c5b-b112-36a304b66dad"
  public static let mailReadScope = "https://graph.microsoft.com/Mail.Read"
  public static let scopes = "openid email profile offline_access \(mailReadScope)"
  /// Where a user ends the app's consent (there is no revoke endpoint).
  public static let consentManagementURL = "https://account.live.com/consent/Manage"

  public init(
    clientID: String, redirectScheme: String,
    authorizeEndpoint: String = "https://login.microsoftonline.com/consumers/oauth2/v2.0/authorize",
    tokenEndpoint: String = "https://login.microsoftonline.com/consumers/oauth2/v2.0/token"
  ) {
    self.clientID = clientID
    self.redirectScheme = redirectScheme
    self.authorizeEndpoint = authorizeEndpoint
    self.tokenEndpoint = tokenEndpoint
  }

  /// `msauth.app.hasala.ios://auth`, registered under "Mobile and desktop applications".
  public var redirectURI: String { "\(redirectScheme)://auth" }

  /// False while the build still carries the `unset` placeholder: "Outlook" is then not offered.
  public var isConfigured: Bool {
    !clientID.isEmpty && clientID != "unset" && !redirectScheme.isEmpty && redirectScheme != "unset"
  }

  /// Whether a token response's `scope` grants reading mail. Microsoft names Graph scopes with or
  /// without the resource prefix.
  public static func grantsMailRead(_ scope: String?) -> Bool {
    guard let scope else { return false }
    return scope.split(separator: " ").contains { s in
      let l = s.lowercased()
      return l == mailReadScope.lowercased() || l == "mail.read"
    }
  }
}

/// The claims of a Microsoft id_token the app reads. The app does NOT verify the signature (the
/// server does, `msjwt`); it reads the address it shows and checks the nonce and the tenant.
/// `preferred_username` comes with the `profile` scope: it is read only as a fallback when it
/// holds an address.
public struct MicrosoftIDTokenClaims: Sendable, Equatable {
  public let email: String?
  public let preferredUsername: String?
  public let nonce: String?
  public let tid: String?

  public init?(idToken: String) {
    guard let o = OAuthWire.claims(idToken) else { return nil }
    email = o["email"]?.stringValue
    preferredUsername = o["preferred_username"]?.stringValue
    nonce = o["nonce"]?.stringValue
    tid = o["tid"]?.stringValue
  }

  /// `email`, else `preferred_username` when it is an address.
  public var address: String? {
    if let e = email, !e.isEmpty { return e }
    if let p = preferredUsername, p.contains("@") { return p }
    return nil
  }
}

public struct MicrosoftOAuthClient: Sendable {
  public let config: MicrosoftOAuthConfig
  let http: any HTTPExchange

  public init(config: MicrosoftOAuthConfig, http: any HTTPExchange) {
    self.config = config
    self.http = http
  }

  /// The authorize URL with fresh PKCE and state; `nonce` is the server's link-challenge nonce.
  /// `prompt=consent` so the Mail.Read consent is always shown and granted afresh.
  public func begin(nonce: String, random: any RandomSource) throws(MailOAuthError) -> MailAuthorization {
    guard config.isConfigured else { throw .notConfigured }
    let verifier: String
    let state: String
    do {
      verifier = try PKCE.makeVerifier(random: random)
      state = try PKCE.makeState(random: random)
    } catch {
      throw .malformedResponse
    }
    let url = URL.build(
      config.authorizeEndpoint, "",
      [
        ("client_id", config.clientID), ("response_type", "code"), ("redirect_uri", config.redirectURI),
        ("response_mode", "query"), ("scope", MicrosoftOAuthConfig.scopes),
        ("code_challenge", PKCE.challenge(verifier: verifier)), ("code_challenge_method", "S256"),
        ("state", state), ("nonce", nonce), ("prompt", "consent"),
      ])
    return MailAuthorization(url: url, state: state, codeVerifier: verifier, nonce: nonce)
  }

  public func code(fromCallback callback: URL, for auth: MailAuthorization) throws(MailOAuthError) -> String {
    try OAuthWire.code(fromCallback: callback, scheme: config.redirectScheme, state: auth.state)
  }

  /// `grant_type=authorization_code`. The answer must carry a refresh token (`offline_access`),
  /// an id_token and Mail.Read, else the tokens are discarded (`missingGrant`).
  public func exchange(code: String, auth: MailAuthorization) async throws(MailOAuthError) -> MailTokenGrant {
    let grant = try await OAuthWire.token(
      http: http, endpoint: config.tokenEndpoint,
      form: [
        ("client_id", config.clientID), ("grant_type", "authorization_code"), ("code", code),
        ("redirect_uri", config.redirectURI), ("code_verifier", auth.codeVerifier),
        ("scope", MicrosoftOAuthConfig.scopes),
      ])
    guard let r = grant.refreshToken, !r.isEmpty, let id = grant.idToken, !id.isEmpty,
      MicrosoftOAuthConfig.grantsMailRead(grant.scope)
    else { throw .missingGrant }
    return grant
  }

  /// `grant_type=refresh_token`. Microsoft answers with a new refresh token, which the token
  /// provider keeps. `invalid_grant` (revoked consent, a 90-day idle token) is `invalidGrant`.
  public func refresh(refreshToken: String) async throws(MailOAuthError) -> MailTokenGrant {
    try await OAuthWire.token(
      http: http, endpoint: config.tokenEndpoint,
      form: [
        ("client_id", config.clientID), ("grant_type", "refresh_token"), ("refresh_token", refreshToken),
        ("scope", MicrosoftOAuthConfig.scopes),
      ])
  }
}

extension MicrosoftOAuthClient: MailOAuthClient {
  public var isConfigured: Bool { config.isConfigured }
  public var redirectScheme: String { config.redirectScheme }

  /// Microsoft has no revoke endpoint: nothing is sent.
  public func revoke(token: String) async throws(MailOAuthError) {}

  /// nil when the token is unreadable or names another tenant than `consumers` (a work or school
  /// account: not supported, and the server would refuse it).
  public func identity(idToken: String) -> MailIdentity? {
    guard let c = MicrosoftIDTokenClaims(idToken: idToken), c.tid == MicrosoftOAuthConfig.consumersTenantID else {
      return nil
    }
    return MailIdentity(email: c.address, nonce: c.nonce)
  }
}
