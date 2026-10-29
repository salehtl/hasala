// Unit tests for CoreMailbox's pure parts (spec 04 §7.2, §7.5, §7.6): OAuth, token custody,
// the sender query, the Gmail client's request shapes and the disposition table. The engine's
// cycle is in MailboxEngineTests. Every message is synthetic (CoreTestSupport.SyntheticMail).
import CoreJSON
import CoreMail
import CoreMailbox
import CorePrimitives
import CoreTemplate
import CoreTestSupport
import Foundation
import Testing

@Suite struct OAuthTests {
  let config = GmailOAuthConfig(clientID: "synthetic-client.apps.googleusercontent.com", redirectScheme: "com.googleusercontent.apps.synthetic-client")

  @Test func pkceMatchesRFC7636AppendixB() {
    #expect(PKCE.challenge(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
  }

  @Test func verifierIs43Base64URLCharacters() throws {
    let v = try PKCE.makeVerifier(random: CountingRandom())
    #expect(v.utf8.count == 43)
    #expect(!v.contains("=") && !v.contains("+") && !v.contains("/"))
  }

  @Test func authorizeURLCarriesExactlyTheSpecParameters() throws {
    let oauth = GoogleOAuthClient(config: config, http: FakeGmail())
    let a = try oauth.begin(nonce: "the-nonce", random: CountingRandom())
    let c = URLComponents(url: a.url, resolvingAgainstBaseURL: false)!
    #expect(c.host == "accounts.google.com" && c.path == "/o/oauth2/v2/auth")
    let items = c.queryItems!.map { "\($0.name)=\($0.value ?? "")" }
    #expect(items == [
      "client_id=synthetic-client.apps.googleusercontent.com",
      "redirect_uri=com.googleusercontent.apps.synthetic-client:/oauth2redirect", "response_type=code",
      "scope=openid email https://www.googleapis.com/auth/gmail.readonly",
      "code_challenge=\(PKCE.challenge(verifier: a.codeVerifier))", "code_challenge_method=S256", "state=\(a.state)",
      "nonce=the-nonce", "prompt=select_account consent", "access_type=offline",
    ])
    // Spaces are %20, never '+', so Google reads the scope list as three scopes.
    #expect(a.url.absoluteString.contains("scope=openid%20email%20https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fgmail.readonly"))
  }

  @Test func onlyMicrosoftPrefersAPrivateSignInSession() {
    #expect(MailProviderID.outlook.prefersEphemeralSession)
    #expect(!MailProviderID.gmail.prefersEphemeralSession)
  }

  @Test func unconfiguredBuildRefusesToStart() {
    let oauth = GoogleOAuthClient(config: GmailOAuthConfig(clientID: "unset", redirectScheme: "unset"), http: FakeGmail())
    #expect(throws: GmailOAuthError.notConfigured) { try oauth.begin(nonce: "n", random: CountingRandom()) }
  }

  @Test func callbackStateIsChecked() throws {
    let oauth = GoogleOAuthClient(config: config, http: FakeGmail())
    let a = try oauth.begin(nonce: "n", random: CountingRandom())
    let good = URL(string: "com.googleusercontent.apps.synthetic-client:/oauth2redirect?code=abc&state=\(a.state)")!
    #expect(try oauth.code(fromCallback: good, for: a) == "abc")
    let forged = URL(string: "com.googleusercontent.apps.synthetic-client:/oauth2redirect?code=abc&state=other")!
    #expect(throws: GmailOAuthError.stateMismatch) { try oauth.code(fromCallback: forged, for: a) }
    let denied = URL(string: "com.googleusercontent.apps.synthetic-client:/oauth2redirect?error=access_denied&state=\(a.state)")!
    #expect(throws: GmailOAuthError.cancelled) { try oauth.code(fromCallback: denied, for: a) }
    let wrongScheme = URL(string: "evil:/oauth2redirect?code=abc&state=\(a.state)")!
    #expect(throws: GmailOAuthError.malformedCallback) { try oauth.code(fromCallback: wrongScheme, for: a) }
  }

  @Test func exchangeSendsPKCEAndNoSecret() async throws {
    let g = FakeGmail()
    let oauth = GoogleOAuthClient(config: config, http: g)
    let a = try oauth.begin(nonce: "n", random: CountingRandom())
    _ = g.consent(authorizeURL: a.url)
    let grant = try await oauth.exchange(code: "fake-auth-code", auth: a)
    #expect(grant.refreshToken == "fake-refresh-token")
    let form = g.requests.last!.form
    #expect(form.map(\.0) == ["grant_type", "code", "client_id", "code_verifier", "redirect_uri"])
    #expect(!form.contains { $0.0 == "client_secret" })
    #expect(GoogleIDTokenClaims(idToken: grant.idToken!)?.nonce == "n")
  }

  @Test func exchangeWithoutGmailScopeIsDiscarded() async throws {
    let g = FakeGmail()
    g.omitGmailScope = true
    let oauth = GoogleOAuthClient(config: config, http: g)
    let a = try oauth.begin(nonce: "n", random: CountingRandom())
    await #expect(throws: GmailOAuthError.missingGrant) { try await oauth.exchange(code: "c", auth: a) }
    g.omitGmailScope = false
    g.omitRefreshToken = true
    await #expect(throws: GmailOAuthError.missingGrant) { try await oauth.exchange(code: "c", auth: a) }
  }
}

@Suite struct TokenCustodyTests {
  func provider(_ g: FakeGmail, _ store: MemoryGmailRefreshTokenStore, _ clock: ManualClock) -> RefreshingGmailTokenProvider {
    RefreshingGmailTokenProvider(
      oauth: GoogleOAuthClient(config: GmailOAuthConfig(clientID: "c", redirectScheme: "s"), http: g), store: store, clock: clock)
  }

  @Test func cachesUntilSixtySecondsRemain() async throws {
    let g = FakeGmail()
    let clock = ManualClock(1_000_000)
    let p = provider(g, MemoryGmailRefreshTokenStore(token: "fake-refresh-token"), clock)
    _ = try await p.accessToken(forceRefresh: false)
    _ = try await p.accessToken(forceRefresh: false)
    #expect(g.requests.count == 1)
    clock.advance((3600 - 59) * 1000)
    _ = try await p.accessToken(forceRefresh: false)
    #expect(g.requests.count == 2)
    #expect(g.requests.last!.form.first { $0.0 == "grant_type" }?.1 == "refresh_token")
  }

  @Test func invalidGrantDeletesTheTokenAndAsksToReconnect() async throws {
    let g = FakeGmail()
    g.invalidGrant = true
    let store = MemoryGmailRefreshTokenStore(token: "fake-refresh-token")
    let p = provider(g, store, ManualClock(0))
    await #expect(throws: GmailAuthError.reconnectRequired) { try await p.accessToken(forceRefresh: false) }
    #expect(try store.read() == nil)
  }

  @Test func absentTokenIsReconnectAndLockedKeychainIsNotNow() async {
    let store = MemoryGmailRefreshTokenStore()
    let p = provider(FakeGmail(), store, ManualClock(0))
    await #expect(throws: GmailAuthError.reconnectRequired) { try await p.accessToken(forceRefresh: false) }
    store.locked = true
    await #expect(throws: GmailAuthError.notNow) { try await p.accessToken(forceRefresh: false) }
  }

  @Test func offlineIsNotAReconnect() async throws {
    let g = FakeGmail()
    g.offline = true
    let store = MemoryGmailRefreshTokenStore(token: "fake-refresh-token")
    let p = provider(g, store, ManualClock(0))
    await #expect(throws: GmailAuthError.offline) { try await p.accessToken(forceRefresh: false) }
    #expect(try store.read() == "fake-refresh-token")
  }
}

@Suite struct BankDomainTests {
  @Test func queryShape() {
    #expect(GmailClient.senderQuery(["dib.ae", "emiratesnbd.com"], sinceSec: 1_700_000_000) == "{from:dib.ae from:emiratesnbd.com} after:1700000000 -in:trash")
    #expect(BankDomains.sinceSec(watermarkMs: 1_700_000_000_000) == 1_700_000_000 - 172_800)
  }

  @Test func groupsOfTwenty() {
    let d = (0..<45).map { "bank\($0).ae" }
    #expect(BankDomains.groups(d).map(\.count) == [20, 20, 5])
  }

  @Test func trustedSetExcludesForwardersSharedSuffixesAndUnsafe() {
    let t = BankDomains.effectiveTrusted([
      "emiratesnbd.com": true, "dib.ae": true, "gmail.com": true, "mail.outlook.com": true, "co.ae": true,
      "bank.co.ae": true, "bad domain.ae": true, "untrusted.ae": false, "UPPER.ae": true,
    ])
    #expect(t == ["bank.co.ae", "dib.ae", "emiratesnbd.com"])
  }

  @Test func membershipIsDomainAware() {
    #expect(BankDomains.isMember("alerts.dib.ae", of: ["dib.ae"]))
    #expect(BankDomains.isMember("dib.ae", of: ["dib.ae"]))
    #expect(!BankDomains.isMember("notdib.ae", of: ["dib.ae"]))
    #expect(!BankDomains.isMember("dib.ae.evil.example", of: ["dib.ae"]))
  }

  @Test func typedSenderNormalization() throws {
    #expect(try BankDomains.normalizeTyped("  Alerts@EmiratesNBD.com. ") == "emiratesnbd.com")
    #expect(throws: BankDomains.TypedDomainError.forwarder) { try BankDomains.normalizeTyped("me@gmail.com") }
    #expect(throws: BankDomains.TypedDomainError.sharedSuffix) { try BankDomains.normalizeTyped("co.ae") }
    #expect(throws: BankDomains.TypedDomainError.nonASCII) { try BankDomains.normalizeTyped("بنك.ae") }
    #expect(throws: BankDomains.TypedDomainError.notQuerySafe) { try BankDomains.normalizeTyped("a\"b.ae") }
  }

  @Test func bankTemplateDomains() {
    let defs = BundledTemplates.load(channel: .mail).templates.map(\.definition)
    #expect(BankDomains.templateDomains(bank: "dib", templates: defs) == ["dib.ae"])
    #expect(BankDomains.templateDomains(bank: "enbd", templates: defs) == ["emiratesnbd.com"])
  }

  @Test func domainOfFromHeader() {
    #expect(BankDomains.domainOf("DIB Alerts <Alerts@DIB.ae>") == "dib.ae")
    #expect(BankDomains.domainOf("plain@x.example") == "x.example")
    #expect(BankDomains.domainOf("no address") == "")
  }
}

@Suite struct GmailClientTests {
  @Test func quota403ReasonsReadAsRateLimits() {
    func body(_ s: String) -> Data { Data(s.utf8) }
    #expect(GmailClient.isRateLimit(errorBody: body(#"{"error":{"code":403,"errors":[{"domain":"usageLimits","reason":"userRateLimitExceeded"}]}}"#)))
    #expect(GmailClient.isRateLimit(errorBody: body(#"{"error":{"code":403,"errors":[{"reason":"rateLimitExceeded"}]}}"#)))
    #expect(GmailClient.isRateLimit(errorBody: body(#"{"error":{"code":429,"status":"RESOURCE_EXHAUSTED"}}"#)))
    #expect(GmailClient.isRateLimit(errorBody: body(#"{"error":{"details":[{"reason":"RATE_LIMIT_EXCEEDED"}]}}"#)))
    #expect(!GmailClient.isRateLimit(errorBody: body(#"{"error":{"code":403,"errors":[{"reason":"insufficientPermissions"}],"status":"PERMISSION_DENIED"}}"#)))
    #expect(!GmailClient.isRateLimit(errorBody: body("not json")))
    #expect(!GmailClient.isRateLimit(errorBody: Data()))
  }

  @Test func aGoogleAccountWithoutGmailIsNoMailbox() async {
    func body(_ s: String) -> Data { Data(s.utf8) }
    #expect(GmailClient.isMailServiceNotEnabled(errorBody: body(FakeGmail.noMailboxBody)))
    #expect(GmailClient.isMailServiceNotEnabled(errorBody: body(#"{"error":{"code":400,"message":"Mail service not enabled","status":"FAILED_PRECONDITION"}}"#)))
    #expect(GmailClient.isMailServiceNotEnabled(errorBody: body(#"{"error":{"code":400,"errors":[{"message":"Mail service not enabled","domain":"global","reason":"failedPrecondition"}]}}"#)))
    #expect(!GmailClient.isMailServiceNotEnabled(errorBody: body(#"{"error":{"code":400,"message":"Precondition check failed.","errors":[{"message":"Precondition check failed.","domain":"global","reason":"failedPrecondition"}],"status":"FAILED_PRECONDITION"}}"#)))
    #expect(!GmailClient.isMailServiceNotEnabled(errorBody: body(#"{"error":{"code":400,"message":"Mail service not enabled","status":"INVALID_ARGUMENT"}}"#)))
    #expect(!GmailClient.isMailServiceNotEnabled(errorBody: body("not json")))
    #expect(!GmailClient.isMailServiceNotEnabled(errorBody: Data()))

    let fake = FakeGmail()
    fake.noMailbox = true
    let c = GmailClient(http: fake, accessToken: "t")
    await #expect(throws: GmailAPIError.noMailbox) { try await c.checkMailbox() }
    await #expect(throws: GmailAPIError.noMailbox) { _ = try await c.profileHistoryID() }
    #expect(fake.requests.last?.path == "/gmail/v1/users/me/profile")
    #expect(fake.requests.last?.query.contains { $0 == ("fields", "historyId") } == true)

    let other = FakeGmail()
    other.fail("/profile", with: [400])
    other.fail("/profile", with: [403], reason: "failedPrecondition")
    other.fail("/profile", with: [500])
    let o = GmailClient(http: other, accessToken: "t")
    await #expect(throws: GmailAPIError.status(400, op: "mailbox")) { try await o.checkMailbox() }
    await #expect(throws: GmailAPIError.status(403, op: "mailbox")) { try await o.checkMailbox() }
    await #expect(throws: GmailAPIError.status(500, op: "mailbox")) { try await o.checkMailbox() }
    try? await o.checkMailbox()
    other.offline = true
    await #expect(throws: GmailAPIError.offline) { try await o.checkMailbox() }
  }

  @Test func quota403SurfacesAs429() async {
    let fake = FakeGmail()
    fake.fail("/profile", with: [403], reason: "userRateLimitExceeded")
    fake.fail("/profile", with: [403], reason: "insufficientPermissions")
    let c = GmailClient(http: fake, accessToken: "t")
    await #expect(throws: GmailAPIError.status(429, op: "profile")) { _ = try await c.profileHistoryID() }
    await #expect(throws: GmailAPIError.status(403, op: "profile")) { _ = try await c.profileHistoryID() }
  }

  @Test func refusesAnUnfilteredListing() async {
    let c = GmailClient(http: FakeGmail(), accessToken: "t")
    await #expect(throws: GmailAPIError.unfilteredListing) { try await c.messagesList(query: "newer_than:30d", pageToken: nil) }
  }

  @Test func listAndMetadataRequestShapes() async throws {
    let g = FakeGmail()
    g.add(SyntheticMail.dibCard(id: "m1", dateMs: Rig.t0))
    let c = GmailClient(http: g, accessToken: "t")
    let page = try await c.messagesList(query: GmailClient.senderQuery(["dib.ae"], sinceSec: 0), pageToken: nil)
    #expect(page.ids == ["m1"])
    let list = g.requests[0]
    #expect(list.authorization == "Bearer t")
    #expect(list.query.contains { $0 == ("includeSpamTrash", "true") })
    #expect(list.query.contains { $0 == ("fields", "messages(id),nextPageToken") })
    let meta = try await c.messageMetadata(id: "m1")
    #expect(g.requests[1].query.filter { $0.0 == "metadataHeaders" }.map(\.1) == ["From", "Authentication-Results"])
    #expect(g.requests[1].query.contains { $0 == ("fields", "id,internalDate,sizeEstimate,payload/headers") })
    #expect(meta.headers.map(\.name) == ["Authentication-Results", "From"])
    #expect(meta.internalDate == String(Rig.t0))
  }
}

@Suite struct DispositionTests {
  let templates = BundledTemplates.load(channel: .mail).templates
  let trusted = ["dib.ae", "emiratesnbd.com"]

  func parse(_ m: FakeGmail.Message) -> MessageDisposer.Parse {
    MessageDisposer.parse(
      raw: m.raw, messageID: m.id, internalDateMs: m.internalDateMs, topLevelFrom: m.from, templates: templates,
      bankDomains: trusted, trusted: trusted, provider: .gmail, linkedAddress: SyntheticMail.defaultTo, spam: false, analyze: AuthResults.analyze)
  }

  func mail(_ m: FakeGmail.Message) throws -> ParsedMail {
    guard case .mail(let p) = parse(m) else { throw CancellationError() }
    return p
  }

  @Test func dibCardReadsAndDatesAtLocalMidnight() throws {
    let p = try mail(SyntheticMail.dibCard(id: "m1", dateMs: Rig.t0))
    #expect(p.bank == "dib")
    #expect(p.last4 == "1234")
    #expect(p.gates.template == "dib.card.v1@\(templates.first { $0.definition.id == "dib.card.v1" }!.definition.version)")
    #expect(p.gates.ar == "pass" && p.gates.senderTrusted && !p.gates.forwarded)
    let f = try #require(p.fields)
    #expect(f.amountMinor == 25000 && f.currency == "AED" && f.direction == "debit")
    #expect(f.merchant == "SYNTHETIC GROCER DUBAI")
    // Bank printed 05-06-2026 (a bare date): local midnight = 2026-06-04T20:00Z (03c §1.5).
    #expect(f.postedAt == "2026-06-04T20:00:00.000Z" && f.precision == "day")
    #expect(p.ingestID == Hex.encode(sha256(Data(SyntheticMail.dibCard(id: "m1", dateMs: Rig.t0).raw))))
  }

  @Test func dibCardOnTheArrivalDayTakesTheArrivalTime() throws {
    let p = try mail(SyntheticMail.dibCard(id: "m1", day: "29-05-2026", dateMs: Rig.t0))
    let f = try #require(p.fields)
    #expect(f.postedAt == "2026-05-28T20:26:40.000Z" && f.precision == "time")
  }

  @Test func dibCardOnAnotherDayStaysAtLocalMidnight() throws {
    let p = try mail(SyntheticMail.dibCard(id: "m1", day: "28-05-2026", dateMs: Rig.t0))
    let f = try #require(p.fields)
    #expect(f.postedAt == "2026-05-27T20:00:00.000Z" && f.precision == "day")
  }

  @Test func enbdAlertIsDatedByGmail() throws {
    let p = try mail(SyntheticMail.enbdAlert(id: "m2", dateMs: Rig.t0))
    let f = try #require(p.fields)
    #expect(f.amountMinor == 1234 && f.direction == "debit")
    #expect(p.last4 == "8642" && p.bank == "enbd")
    #expect(f.postedAt == "2026-05-28T20:26:40.000Z" && f.precision == "time")
  }

  @Test func filedOnlyWithEveryGate() throws {
    let p = try mail(SyntheticMail.dibCard(id: "m1", dateMs: Rig.t0))
    let filed = MessageDisposer.finalize(p, provider: .gmail, grantID: "g", categorizer: GroceryCategorizer())
    #expect(!filed.needsReview)
    #expect(filed.payload["needs_review"] == .bool(false))
    #expect(filed.payload["category"] == .string("groceries"))
    #expect(filed.payload["gates"]?["card"] == nil)
    #expect(filed.payload["gates"]?.objectValue?.keys == ["ar", "sender", "template", "forwarded"])
    #expect(filed.payload.keys == [
      "amount_minor", "currency", "direction", "posted_at", "posted_precision", "merchant_raw", "last4", "category",
      "category_source", "needs_review", "unparsed", "tier", "entry_method", "provenance", "bank", "gates", "dedupe",
    ])
    #expect(filed.payload["amount_minor"] == .string("25000"))
    #expect(filed.payload["provenance"] == .object(JSONObject([("provider", .string("gmail")), ("grant_id", .string("g")), ("message_id", .string("m1"))])))

    let uncategorized = MessageDisposer.finalize(p, provider: .gmail, grantID: "g", categorizer: NoCategorizer())
    #expect(!uncategorized.needsReview && uncategorized.payload["category"] == nil)
  }

  @Test func untrustedOrForeignVerdictStaysInReview() throws {
    // A foreign A-R above Gmail's: not_topmost, so the sender is not verified.
    let p = try mail(SyntheticMail.dibCard(id: "m1", dateMs: Rig.t0, arTopmost: false))
    #expect(p.gates.ar == "not_topmost" && !p.gates.senderTrusted)
    let d = MessageDisposer.finalize(p, provider: .gmail, grantID: "g", categorizer: NoCategorizer())
    #expect(d.needsReview)
    #expect(d.payload["gates"]?["sender"] == .string("untrusted"))
    #expect(d.payload["amount_minor"] == .string("25000"))  // prefilled
    // Verified, but for a domain outside T.
    let q = try mail(SyntheticMail.dibCard(id: "m3", dateMs: Rig.t0, authDomain: "mailer.example"))
    #expect(q.gates.ar == "fail" && !q.gates.senderTrusted)
  }

  @Test func mailAddressedToAnotherMailboxStaysInReview() throws {
    let other = try mail(SyntheticMail.dibCard(id: "r1", dateMs: Rig.t0, to: "Someone Else <someone.else@example.net>"))
    #expect(other.gates.ar == "pass" && other.gates.senderTrusted && other.recipient == .mismatch)
    let d = MessageDisposer.finalize(other, provider: .gmail, grantID: "g", categorizer: NoCategorizer())
    #expect(d.needsReview && d.payload["amount_minor"] == .string("25000"))
    let base = MessageDisposer.finalize(try mail(SyntheticMail.dibCard(id: "r0", dateMs: Rig.t0)), provider: .gmail, grantID: "g", categorizer: NoCategorizer())
    #expect(!base.needsReview && d.payload["gates"] == base.payload["gates"])

    let named = "\"\(SyntheticMail.defaultTo)\" <someone.else@example.net>, (\(SyntheticMail.defaultTo)) x@example.net"
    #expect(try mail(SyntheticMail.dibCard(id: "r2", dateMs: Rig.t0, to: named)).recipient == .mismatch)

    let cc = SyntheticMail.dibCard(
      id: "r3", dateMs: Rig.t0, to: "someone.else@example.net\r\nCc: Me <\(SyntheticMail.defaultTo)>", signedHeaders: "From:To:Cc:Subject")
    #expect(try mail(cc).recipient == .confirmed)

    guard case .mail(let unlinked) = MessageDisposer.parse(
      raw: SyntheticMail.dibCard(id: "r4", dateMs: Rig.t0).raw, messageID: "r4", internalDateMs: Rig.t0,
      topLevelFrom: "DIB Alerts <alerts@dib.ae>", templates: templates, bankDomains: trusted, trusted: trusted,
      provider: .gmail, linkedAddress: nil, spam: false, analyze: AuthResults.analyze)
    else { throw CancellationError() }
    #expect(unlinked.recipient == .mismatch)
    #expect(MessageDisposer.finalize(unlinked, provider: .gmail, grantID: "g", categorizer: NoCategorizer()).needsReview)
  }

  @Test func anUnconfirmedRecipientFilesAnyCard() throws {
    func review(_ p: ParsedMail) -> Bool {
      MessageDisposer.finalize(p, provider: .gmail, grantID: "g", categorizer: NoCategorizer()).needsReview
    }
    let signed = try mail(SyntheticMail.dibCard(id: "u0", dateMs: Rig.t0))
    #expect(signed.recipient == .confirmed && !review(signed))

    let unsigned = try mail(SyntheticMail.dibCard(id: "u1", last4: "7777", dateMs: Rig.t0, signedHeaders: "From:Subject"))
    #expect(unsigned.recipient == .unconfirmed && unsigned.last4 == "7777" && !review(unsigned))

    let noTo = try mail(SyntheticMail.dibCard(id: "u2", dateMs: Rig.t0, to: nil))
    #expect(noTo.recipient == .unconfirmed && !review(noTo))

    let twice = try mail(SyntheticMail.dibCard(
      id: "u3", dateMs: Rig.t0, to: "\(SyntheticMail.defaultTo)\r\nTo: \(SyntheticMail.defaultTo)"))
    #expect(twice.recipient == .unconfirmed)
    let oversigned = try mail(SyntheticMail.dibCard(
      id: "u4", dateMs: Rig.t0, to: "\(SyntheticMail.defaultTo)\r\nTo: \(SyntheticMail.defaultTo)", signedHeaders: "From:To:To:Subject"))
    #expect(oversigned.recipient == .confirmed)

    let raw = String(decoding: SyntheticMail.dibCard(id: "u5", dateMs: Rig.t0).raw, as: UTF8.self)
      .replacingOccurrences(of: "header.b=c3ludGhl", with: "header.b=b3RoZXJz")
    guard case .mail(let otherSig) = MessageDisposer.parse(
      raw: Array(raw.utf8), messageID: "u5", internalDateMs: Rig.t0, topLevelFrom: "DIB Alerts <alerts@dib.ae>",
      templates: templates, bankDomains: trusted, trusted: trusted, provider: .gmail,
      linkedAddress: SyntheticMail.defaultTo, spam: false, analyze: AuthResults.analyze)
    else { throw CancellationError() }
    #expect(otherSig.recipient == .unconfirmed && !review(otherSig))
  }

  @Test func spamStaysInReview() throws {
    let m = SyntheticMail.dibCard(id: "s1", dateMs: Rig.t0)
    guard case .mail(let p) = MessageDisposer.parse(
      raw: m.raw, messageID: m.id, internalDateMs: m.internalDateMs, topLevelFrom: m.from, templates: templates,
      bankDomains: trusted, trusted: trusted, provider: .gmail, linkedAddress: SyntheticMail.defaultTo, spam: true,
      analyze: AuthResults.analyze)
    else { throw CancellationError() }
    let d = MessageDisposer.finalize(p, provider: .gmail, grantID: "g", categorizer: NoCategorizer())
    #expect(d.needsReview && d.payload["amount_minor"] == .string("25000"))
  }

  @Test func stagedMailWithoutRecipientFactsStaysInReview() throws {
    let p = try mail(SyntheticMail.dibCard(id: "o1", dateMs: Rig.t0))
    #expect(!MessageDisposer.finalize(p, provider: .gmail, grantID: "g", categorizer: NoCategorizer()).needsReview)
    var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(p)) as! [String: Any]
    json.removeValue(forKey: "recipient")
    json.removeValue(forKey: "spam")
    let old = try JSONDecoder().decode(ParsedMail.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(MessageDisposer.finalize(old, provider: .gmail, grantID: "g", categorizer: NoCategorizer()).needsReview)
  }

  @Test func unparsedBankMailIsTheEmptyReviewShape() throws {
    let p = try mail(SyntheticMail.bankNotice(id: "m4", dateMs: Rig.t0))
    #expect(p.fields == nil)
    let d = MessageDisposer.finalize(p, provider: .gmail, grantID: "g", categorizer: GroceryCategorizer())
    #expect(d.needsReview)
    let mid = MessageIDEvidence.hash(headers: "Message-ID: <\(Rig.t0).synthetic@example.invalid>") ?? ""
    #expect(d.payload.canonical == #"{"unparsed":true,"needs_review":true,"posted_at":"2026-05-28T20:00:00.000Z","posted_precision":"day","merchant_raw":"","last4":"","category":null,"entry_method":"mailbox","provenance":{"provider":"gmail","grant_id":"g","message_id":"m4"},"gates":{"ar":"pass","sender":"trusted","template":"none","forwarded":false},"dedupe":{"message_id":"\#(mid)"}}"#)
  }

  @Test func dibTransferNoticesFileAsDebits() throws {
    let arabic = try mail(SyntheticMail.dibTransferNotice(id: "n0", day: "29-05-2026", dateMs: Rig.t0))
    #expect(arabic.bank == "dib" && arabic.gates.template == "dib.transfer.v1@1" && arabic.last4 == "8701")
    let f = try #require(arabic.fields)
    #expect(f.amountMinor == 314_159 && f.currency == "AED" && f.direction == "debit" && f.merchant == "DIB TRANSFER")
    #expect(f.postedAt == "2026-05-28T20:26:40.000Z" && f.precision == "time" && f.isTransfer)
    let d = MessageDisposer.finalize(arabic, provider: .gmail, grantID: "g", categorizer: NoCategorizer())
    #expect(!d.needsReview && d.payload["unparsed"] == .bool(false) && d.payload["direction"] == .string("debit"))
    #expect(d.payload["amount_minor"] == .string("314159") && d.payload["is_transfer"] == nil)

    let english =
      "Money Transfer\nDear Customer,\nThis is to notify you that a Domestic Fund Transfer transaction has been initiated on "
      + "07-23-2026 11:12:13 with the following details.\nAmount\n1,234.56\nFrom\nAE0000000000000XXXXX101\n"
      + "[From Account FRM]\nTo\nAE0000000000000XXXXX002\nBeneficiary Bank\nSample Bank PJSC\nStatus\n"
      + "Credited to beneficiary\nReference Number\n[Reference Number]"
    let from = "DIB <notification@dib.ae>"
    let en = try mail(
      FakeGmail.Message(
        id: "n1", raw: SyntheticMail.rfc822(from: from, subject: "DIB Notification", body: english, dateMs: Rig.t0, authDomain: "dib.ae"),
        internalDateMs: Rig.t0, from: from))
    #expect(en.gates.template == "dib.money-transfer.v1@1")
    #expect(en.fields?.amountMinor == 123_456 && en.fields?.direction == "debit" && en.fields?.merchant == "Sample Bank PJSC")
    #expect(en.fields?.postedAt == "2026-05-28T20:26:40.000Z")

    let forwarded = try mail(SyntheticMail.dibTransferNotice(id: "n2", day: "29-05-2026", dateMs: Rig.t0, to: "someone.else@example.net"))
    #expect(forwarded.recipient == .mismatch && forwarded.fields?.direction == "debit")
    #expect(MessageDisposer.finalize(forwarded, provider: .gmail, grantID: "g", categorizer: NoCategorizer()).needsReview)

    for status in ["قيد التنفيذ", "قيد الأنتظار"] {
      let pending = try mail(SyntheticMail.dibTransferNotice(id: "n3", day: "29-05-2026", status: status, dateMs: Rig.t0))
      #expect(pending.fields == nil && pending.gates.template == nil)
      let empty = MessageDisposer.finalize(pending, provider: .gmail, grantID: "g", categorizer: NoCategorizer())
      #expect(empty.needsReview && empty.payload["unparsed"] == .bool(true))
    }
  }

  @Test func dibDebitAlertStillFilesAndANoticeIsNotACredit() throws {
    let alert = try mail(SyntheticMail.dibDebitAlert(id: "a0", day: "29-05-2026", dateMs: Rig.t0))
    #expect(alert.gates.template == "dib.account.v1@4")
    #expect(alert.fields?.direction == "debit" && alert.fields?.amountMinor == 314_159 && alert.fields?.merchant == "MB FUND TRANSFER DEBIT")
    let notice = try mail(SyntheticMail.dibTransferNotice(id: "a1", day: "29-05-2026", dateMs: Rig.t0))
    #expect(notice.gates.template != "dib.account.v1@4" && notice.fields?.direction == "debit")
  }

  @Test func dibCardRefundsAndReversalsFileAsCredits() throws {
    let from = "DIB <notification@dib.ae>"
    func dib(_ id: String, _ body: String) throws -> ParsedMail {
      try mail(
        FakeGmail.Message(
          id: id, raw: SyntheticMail.rfc822(from: from, subject: "DIB Notification", body: body, dateMs: Rig.t0, authDomain: "dib.ae"),
          internalDateMs: Rig.t0, from: from))
    }
    let refund = try dib(
      "r0", "عزيزي المتعامل,\nتم إرجاع مبلغ 1,234.50 درهم على بطاقة بنك دبي الإسلامي الخاصة بك والمنتهية بالرقم XX1234.\nمع اطيب التحيات،")
    #expect(refund.bank == "dib" && refund.gates.template == "dib.card-refund.v1@1" && refund.last4 == "1234")
    let rf = try #require(refund.fields)
    #expect(rf.amountMinor == 123_450 && rf.currency == "AED" && rf.direction == "credit" && rf.merchant == "DIB CARD REFUND")
    #expect(rf.postedAt == "2026-05-28T20:26:40.000Z" && rf.precision == "time")
    let d = MessageDisposer.finalize(refund, provider: .gmail, grantID: "g", categorizer: NoCategorizer())
    #expect(d.payload["unparsed"] == .bool(false) && d.payload["direction"] == .string("credit"))
    #expect(d.payload["category"] == .string("refunds"))
    let source = try #require(d.payload["category_source"]?.objectValue)
    #expect(source["kind"] == .string("dictionary") && source["entry"] == .string("template:dib.card-refund.v1"))

    let reversal = try dib(
      "r1",
      "عزيزي المتعامل,\nA transaction to the value of AED 52.00 made at SAMPLE SHOP LLC on your DIB card ending with XX1234 has been reversed.")
    #expect(reversal.gates.template == "dib.card-reversal.v1@1" && reversal.last4 == "1234")
    #expect(reversal.fields?.amountMinor == 5_200 && reversal.fields?.direction == "credit" && reversal.fields?.merchant == "SAMPLE SHOP LLC")
    let rd = MessageDisposer.finalize(reversal, provider: .gmail, grantID: "g", categorizer: GroceryCategorizer())
    #expect(rd.payload["category"] == .string("refunds"))

    let grocer = try dib(
      "r4",
      "A transaction to the value of AED 9.00 made at SAMPLE GROCER on your DIB card ending with XX1234 has been reversed.")
    let gd = MessageDisposer.finalize(grocer, provider: .gmail, grantID: "g", categorizer: GroceryCategorizer())
    #expect(gd.payload["category"] == .string("groceries"))

    let approved = try dib(
      "r3",
      "عزيزي المتعامل,\nA transaction to the value of AED 52.00 made at SAMPLE SHOP LLC on your DIB card ending with XX1234 has been approved.")
    #expect(approved.fields == nil && approved.gates.template == nil)
    let ad = MessageDisposer.finalize(approved, provider: .gmail, grantID: "g", categorizer: NoCategorizer())
    #expect(ad.needsReview && ad.payload["unparsed"] == .bool(true))

    let dollars = try dib("r2", "تم إرجاع مبلغ 12.50 دولار على بطاقة بنك دبي الإسلامي الخاصة بك والمنتهية بالرقم XX1234.")
    #expect(dollars.fields == nil && dollars.gates.template == nil)
  }

  @Test func aCancelledTemplateRunIsInterruptedNotAnEmptyReviewRow() async {
    let m = SyntheticMail.dibCard(id: "m1", dateMs: Rig.t0)
    let me = self
    let r = await Task { () -> MessageDisposer.Parse in
      withUnsafeCurrentTask { $0?.cancel() }
      return me.parse(m)
    }.value
    #expect(r == .interrupted)
  }

  @Test func anAmountOverTheMailBoundIsTheEmptyReviewShape() throws {
    let over = try mail(SyntheticMail.dibCard(id: "m1", amount: "100,000,000,000.00", dateMs: Rig.t0))
    #expect(over.fields == nil && over.gates.template == nil)
    let d = MessageDisposer.finalize(over, provider: .gmail, grantID: "g", categorizer: NoCategorizer())
    #expect(d.needsReview && d.payload["unparsed"] == .bool(true) && d.payload["amount_minor"] == nil)
    let atBound = try mail(SyntheticMail.dibCard(id: "m1", amount: "99,999,999,999.99", dateMs: Rig.t0))
    #expect(atBound.fields?.amountMinor == MailboxLimits.maxAmountMinor)
  }

  @Test func aNonTwoDecimalCurrencyNextToTheAmountGoesToReview() throws {
    for amount in ["JPY12,500.00", "KRW150,000.00", "OMR12.50", "jpy12,500.00"] {
      let from = "Emirates NBD <alerts@emiratesnbd.com>"
      let m = FakeGmail.Message(
        id: "m1",
        raw: SyntheticMail.rfc822(
          from: from, subject: "Transaction advice for your account ending with 8642",
          body: "\(amount) has been debited from your account 012XXX34XXX56.", dateMs: Rig.t0, authDomain: "emiratesnbd.com"),
        internalDateMs: Rig.t0, from: from)
      let p = try mail(m)
      #expect(p.fields == nil, "\(amount)")
    }
  }

  @Test func nonBankMailIsSetAside() {
    let m = SyntheticMail.lookAlike(id: "m5", dateMs: Rig.t0, listedAs: "emiratesnbd.com")
    let r = MessageDisposer.parse(
      raw: m.raw, messageID: m.id, internalDateMs: m.internalDateMs, topLevelFrom: "Offers <offers@emiratesnbd.com.promo.example>",
      templates: templates, bankDomains: trusted, trusted: trusted, provider: .gmail, linkedAddress: SyntheticMail.defaultTo, spam: false, analyze: AuthResults.analyze)
    #expect(r == .setAside(domain: "promo.example"))
  }

  func nestedDIB(depth: Int) -> FakeGmail.Message {
    var m = SyntheticMail.dibCard(id: "m7", dateMs: Rig.t0)
    let text = String(decoding: m.raw, as: UTF8.self)
    let split = text.range(of: "\r\n\r\n")!
    var head = String(text[..<split.lowerBound])
    let leafBody = String(text[split.upperBound...])
    head = head.replacingOccurrences(
      of: "Content-Type: text/plain; charset=\"utf-8\"", with: "Content-Type: multipart/mixed; boundary=\"n-0-x\"")
    var body = ""
    for i in 0..<(depth - 1) {
      body += "--n-\(i)-x\r\nContent-Type: multipart/mixed; boundary=\"n-\(i + 1)-x\"\r\n\r\n"
    }
    body += "--n-\(depth - 1)-x\r\nContent-Type: text/plain; charset=\"utf-8\"\r\nContent-Transfer-Encoding: 8bit\r\n\r\n"
    body += leafBody + "--n-\(depth - 1)-x--"
    for i in (0..<(depth - 1)).reversed() { body += "\r\n--n-\(i)-x--" }
    m.raw = Array((head + "\r\n\r\n" + body + "\r\n").utf8)
    return m
  }

  @Test func nestedMailReadsWithinTheDepthCap() throws {
    let p = try mail(nestedDIB(depth: 8))
    #expect(p.fields?.amountMinor == 25000)
  }

  @Test func overDeepMailGoesToReview() throws {
    let p = try mail(nestedDIB(depth: 3000))
    #expect(p.fields == nil)
    let d = MessageDisposer.finalize(p, provider: .gmail, grantID: "g", categorizer: NoCategorizer())
    #expect(d.needsReview)
  }

  @Test func zeroAmountIsAMissNotAFiling() throws {
    let p = try mail(SyntheticMail.dibCard(id: "m6", amount: "0.00", dateMs: Rig.t0))
    #expect(p.fields == nil)
  }
}

@Suite struct MailRecipientsTests {
  @Test func gmailFoldsDotsAndPlusOnlyForGmail() {
    #expect(MailRecipients.canonical("First.Last+bank@GoogleMail.com", provider: .gmail) == "firstlast@gmail.com")
    #expect(MailRecipients.canonical(" firstlast@gmail.com. ", provider: .gmail) == "firstlast@gmail.com")
    #expect(MailRecipients.canonical("First.Last+bank@Work.Example", provider: .gmail) == "first.last@work.example")
    #expect(MailRecipients.canonical("First.Last+bank@Outlook.Example", provider: .outlook) == "first.last+bank@outlook.example")
    #expect(MailRecipients.canonical("First.Last@GMail.com", provider: .outlook) == "first.last@gmail.com")
    #expect(MailRecipients.canonical("nobody", provider: .gmail) == nil)
    #expect(MailRecipients.canonical("@example.com", provider: .gmail) == nil)
    #expect(MailRecipients.canonical("+x@example.com", provider: .gmail) == nil)
  }

  @Test func readsSignedToAndCcOnly() {
    let sig = "DKIM-Signature: v=1; d=bank.example; s=s1;\r\n h=From : To : Cc; b=QUJD\r\n DEF"
    func check(_ linked: String?, _ lines: [String], provider: MailProviderID = .gmail, signature: String? = nil) -> RecipientCheck {
      MailRecipients.check(
        linked: linked, headers: lines.joined(separator: "\r\n"), provider: provider, signingDomain: "bank.example",
        signature: signature)
    }
    let lines = [
      "Delivered-To: me@example.com", "Reply-To: me@example.com", sig, "From: Bank <alerts@bank.example>",
      "To: \"Me, Myself\" <me+alerts@example.com>,", "\tother@example.net (note @ here)", "CC: group: a@example.org; ",
      "Subject: me@example.com",
    ]
    #expect(check("ME@example.com", lines) == .confirmed)
    #expect(check("a@example.org", lines, signature: "QUJDDE") == .confirmed)
    #expect(check("a@example.org", lines, signature: "WFla") == .unconfirmed)
    #expect(check("me@example.com", lines, provider: .outlook) == .mismatch)
    #expect(check("someone@example.com", lines) == .mismatch)
    #expect(check(nil, lines) == .mismatch)
    #expect(check("me@example.com", ["Delivered-To: me@example.com", sig, "To: you@example.com"]) == .mismatch)
    #expect(check("me@example.com", ["Delivered-To: me@example.com", "X-Original-To: me@example.com", sig]) == .unconfirmed)
    #expect(check("me@example.com", ["DKIM-Signature: d=other.example; h=to; b=x", "To: me@example.com"]) == .unconfirmed)
    let both = ["DKIM-Signature: d=bank.example; h=from:to; b=x", "DKIM-Signature: d=bank.example; h=from; b=y", "To: me@example.com"]
    #expect(check("me@example.com", both) == .unconfirmed)
  }
}

@Suite struct URLSessionExchangeTests {
  @Test func gmailClientWorksOverARealURLSession() async throws {
    let g = FakeGmail()
    g.add(SyntheticMail.enbdAlert(id: "u1", dateMs: Rig.t0))
    let c = GmailClient(http: FakeGmailURLProtocol.exchange(for: g), accessToken: "tok")
    let page = try await c.messagesList(query: GmailClient.senderQuery(["emiratesnbd.com"], sinceSec: 0), pageToken: nil)
    #expect(page.ids == ["u1"])
    #expect(g.requests.last?.authorization == "Bearer tok")
    let raw = try await c.messageRaw(id: "u1")
    #expect(try Base64.decodeURL(raw.rawBase64URL) == Data(SyntheticMail.enbdAlert(id: "u1", dateMs: Rig.t0).raw))
    #expect(!raw.spam)
    var junk = SyntheticMail.enbdAlert(id: "u2", dateMs: Rig.t0)
    junk.spam = true
    g.add(junk)
    #expect(try await c.messageRaw(id: "u2").spam)
    await #expect(throws: GmailAPIError.status(404, op: "raw")) { try await c.messageRaw(id: "missing") }
  }

  @Test func tokenExchangeFormSurvivesURLSession() async throws {
    let g = FakeGmail()
    let oauth = GoogleOAuthClient(
      config: GmailOAuthConfig(clientID: "synthetic-client", redirectScheme: "com.googleusercontent.apps.synthetic"),
      http: FakeGmailURLProtocol.exchange(for: g))
    let grant = try await oauth.refresh(refreshToken: "fake-refresh-token")
    #expect(grant.accessToken == "fake-access-token" && grant.refreshToken == nil)
    #expect(g.requests.last?.form.first { $0.0 == "client_id" }?.1 == "synthetic-client")
  }
}
