// Microsoft OAuth for the Outlook lane (the Outlook plan's shared contract), over FakeGraph's
// token endpoint. Every value is synthetic.
import CoreJSON
import CoreMailbox
import CorePrimitives
import CoreTestSupport
import CoreTime
import Foundation
import Testing

@Suite struct OutlookOAuthTests {
  let graph = FakeGraph()
  var client: MicrosoftOAuthClient { MicrosoftOAuthClient(config: OutlookRig.config, http: graph) }

  func items(_ url: URL) -> [String: String] {
    Dictionary(
      (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
      uniquingKeysWith: { a, _ in a })
  }

  @Test func authorizeURLFollowsTheContract() throws {
    let auth = try client.begin(nonce: "server-nonce", random: CountingRandom())
    #expect(auth.url.absoluteString.hasPrefix("https://login.microsoftonline.com/consumers/oauth2/v2.0/authorize?"))
    let q = items(auth.url)
    #expect(q["client_id"] == OutlookRig.config.clientID)
    #expect(q["response_type"] == "code")
    #expect(q["redirect_uri"] == "msauth.app.hasala.ios://auth")
    #expect(q["scope"] == "openid email profile offline_access https://graph.microsoft.com/Mail.Read")
    #expect(q["code_challenge_method"] == "S256")
    #expect(q["code_challenge"] == PKCE.challenge(verifier: auth.codeVerifier))
    #expect(q["prompt"] == "consent")
    #expect(q["nonce"] == "server-nonce" && auth.nonce == "server-nonce")
    #expect(q["state"] == auth.state && auth.state.count == 43)
  }

  @Test func anUnsetClientIsNotConfigured() {
    let unset = MicrosoftOAuthClient(config: MicrosoftOAuthConfig(clientID: "unset", redirectScheme: "msauth.app.hasala.ios"), http: graph)
    #expect(!unset.isConfigured)
    #expect(throws: MailOAuthError.notConfigured) { try unset.begin(nonce: "n", random: CountingRandom()) }
  }

  @Test func theCallbackIsChecked() throws {
    let auth = try client.begin(nonce: "n", random: CountingRandom())
    let good = graph.consent(authorizeURL: auth.url)
    #expect(try client.code(fromCallback: good, for: auth) == "fake-ms-code")
    #expect(throws: MailOAuthError.stateMismatch) {
      try client.code(fromCallback: URL(string: "msauth.app.hasala.ios://auth?code=c&state=forged")!, for: auth)
    }
    #expect(throws: MailOAuthError.malformedCallback) {
      try client.code(fromCallback: URL(string: "com.example.other://auth?code=c&state=\(auth.state)")!, for: auth)
    }
    #expect(throws: MailOAuthError.cancelled) {
      try client.code(fromCallback: URL(string: "msauth.app.hasala.ios://auth?error=access_denied&state=\(auth.state)")!, for: auth)
    }
  }

  @Test func theExchangeNeedsARefreshTokenAnIDTokenAndMailRead() async throws {
    let auth = try client.begin(nonce: "n", random: CountingRandom())
    _ = graph.consent(authorizeURL: auth.url)
    let grant = try await client.exchange(code: "fake-ms-code", auth: auth)
    #expect(grant.refreshToken == "fake-ms-refresh-0" && grant.idToken != nil)
    let form = Dictionary(graph.requests.last!.form, uniquingKeysWith: { a, _ in a })
    #expect(form["grant_type"] == "authorization_code" && form["code_verifier"] == auth.codeVerifier)
    #expect(form["redirect_uri"] == "msauth.app.hasala.ios://auth" && form["client_secret"] == nil)

    graph.omitMailScope = true
    await #expect(throws: MailOAuthError.missingGrant) { try await client.exchange(code: "c", auth: auth) }
    graph.omitMailScope = false
    graph.omitRefreshToken = true
    await #expect(throws: MailOAuthError.missingGrant) { try await client.exchange(code: "c", auth: auth) }
  }

  @Test func mailReadIsRecognisedWithOrWithoutTheResource() {
    #expect(MicrosoftOAuthConfig.grantsMailRead("openid Mail.Read"))
    #expect(MicrosoftOAuthConfig.grantsMailRead("https://graph.microsoft.com/Mail.Read email"))
    #expect(!MicrosoftOAuthConfig.grantsMailRead("Mail.ReadBasic openid"))
    #expect(!MicrosoftOAuthConfig.grantsMailRead(nil))
  }

  @Test func identityReadsTheConsumerTokenOnly() {
    let tid = MicrosoftOAuthConfig.consumersTenantID
    let ok = client.identity(idToken: FakeGraph.idToken(email: "someone@outlook.example", tid: tid, nonce: "n1"))
    #expect(ok == MailIdentity(email: "someone@outlook.example", nonce: "n1"))
    // A work or school account (another tenant) is not supported.
    #expect(client.identity(idToken: FakeGraph.idToken(email: "a@b.example", tid: "11111111-1111-4111-8111-111111111111", nonce: "n")) == nil)
    #expect(client.identity(idToken: FakeGraph.idToken(email: nil, tid: tid, nonce: "n"))?.email == nil)
    #expect(client.identity(idToken: "not-a-jwt") == nil)
  }

  @Test func revokeSendsNothing() async throws {
    try await client.revoke(token: "fake-ms-refresh-0")
    #expect(graph.requests.isEmpty)
  }

  @Test func aRotatedRefreshTokenIsKept() async throws {
    let store = MemoryMailRefreshTokenStore(token: "fake-ms-refresh-0")
    let clock = ManualClock(OutlookRig.t0)
    let tokens = RefreshingMailTokenProvider(oauth: client, store: store, clock: clock)
    _ = try await tokens.accessToken(forceRefresh: false)
    #expect(try store.read() == "fake-ms-refresh-1")
    _ = try await tokens.accessToken(forceRefresh: true)
    #expect(try store.read() == "fake-ms-refresh-2")
  }

  @Test func invalidGrantOnRefreshDeletesTheToken() async throws {
    let store = MemoryMailRefreshTokenStore(token: "fake-ms-refresh-0")
    graph.invalidGrant = true
    let tokens = RefreshingMailTokenProvider(oauth: client, store: store, clock: ManualClock(OutlookRig.t0))
    await #expect(throws: MailAuthError.reconnectRequired) { try await tokens.accessToken(forceRefresh: false) }
    #expect(try store.read() == nil)
  }
}
