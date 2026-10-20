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
    let defs = BundledTemplates.load().templates.map(\.definition)
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
  let templates = BundledTemplates.load().templates
  let trusted = ["dib.ae", "emiratesnbd.com"]

  func parse(_ m: FakeGmail.Message) -> MessageDisposer.Parse {
    MessageDisposer.parse(
      raw: m.raw, messageID: m.id, internalDateMs: m.internalDateMs, topLevelFrom: m.from, templates: templates,
      bankDomains: trusted, trusted: trusted, recipient: SyntheticMail.defaultTo, spam: false, analyze: AuthResults.analyze)
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

  @Test func enbdAlertIsDatedByGmail() throws {
    let p = try mail(SyntheticMail.enbdAlert(id: "m2", dateMs: Rig.t0))
    let f = try #require(p.fields)
    #expect(f.amountMinor == 1234 && f.direction == "debit")
    #expect(p.last4 == "8642" && p.bank == "enbd")
    #expect(f.postedAt == "2026-05-28T20:26:40.000Z" && f.precision == "time")
  }

  @Test func filedOnlyWithEveryGate() throws {
    let p = try mail(SyntheticMail.dibCard(id: "m1", dateMs: Rig.t0))
    let known = MessageDisposer.finalize(p, provider: .gmail, grantID: "g", cards: [CardKey(bank: "dib", last4: "1234"): .mine], categorizer: GroceryCategorizer())
    #expect(!known.needsReview)
    #expect(known.payload["needs_review"] == .bool(false))
    #expect(known.payload["category"] == .string("groceries"))
    #expect(known.payload["gates"]?["card"] == .string("known"))
    #expect(known.payload.keys == [
      "amount_minor", "currency", "direction", "posted_at", "posted_precision", "merchant_raw", "last4", "category",
      "category_source", "needs_review", "unparsed", "tier", "entry_method", "provenance", "bank", "gates", "dedupe",
    ])
    #expect(known.payload["amount_minor"] == .string("25000"))
    #expect(known.payload["provenance"] == .object(JSONObject([("provider", .string("gmail")), ("grant_id", .string("g")), ("message_id", .string("m1"))])))

    // A card the ledger doesn't know files like a known one (there is no cards step).
    let unknown = MessageDisposer.finalize(p, provider: .gmail, grantID: "g", cards: [:], categorizer: NoCategorizer())
    #expect(!unknown.needsReview && unknown.payload["gates"]?["card"] == .string("unknown"))
    #expect(unknown.payload["category"] == nil)

    let notMine = MessageDisposer.finalize(p, provider: .gmail, grantID: "g", cards: [CardKey(bank: "dib", last4: "1234"): .notMine], categorizer: NoCategorizer())
    #expect(notMine.needsReview && notMine.payload["gates"]?["card"] == .string("not_mine"))
  }

  @Test func untrustedOrForeignVerdictStaysInReview() throws {
    // A foreign A-R above Gmail's: not_topmost, so the sender is not verified.
    let p = try mail(SyntheticMail.dibCard(id: "m1", dateMs: Rig.t0, arTopmost: false))
    #expect(p.gates.ar == "not_topmost" && !p.gates.senderTrusted)
    let d = MessageDisposer.finalize(p, provider: .gmail, grantID: "g", cards: [CardKey(bank: "dib", last4: "1234"): .mine], categorizer: NoCategorizer())
    #expect(d.needsReview)
    #expect(d.payload["gates"]?["sender"] == .string("untrusted"))
    #expect(d.payload["amount_minor"] == .string("25000"))  // prefilled
    // Verified, but for a domain outside T.
    let q = try mail(SyntheticMail.dibCard(id: "m3", dateMs: Rig.t0, authDomain: "mailer.example"))
    #expect(q.gates.ar == "fail" && !q.gates.senderTrusted)
  }

  @Test func mailAddressedToAnotherMailboxStaysInReview() throws {
    let cards = [CardKey(bank: "dib", last4: "1234"): CardState.mine]
    let other = try mail(SyntheticMail.dibCard(id: "r1", dateMs: Rig.t0, to: "Someone Else <someone.else@example.net>"))
    #expect(other.gates.ar == "pass" && other.gates.senderTrusted && other.recipientMatched == false)
    let d = MessageDisposer.finalize(other, provider: .gmail, grantID: "g", cards: cards, categorizer: NoCategorizer())
    #expect(d.needsReview && d.payload["amount_minor"] == .string("25000"))
    #expect(d.payload["gates"] == MessageDisposer.finalize(try mail(SyntheticMail.dibCard(id: "r0", dateMs: Rig.t0)), provider: .gmail, grantID: "g", cards: cards, categorizer: NoCategorizer()).payload["gates"])

    let named = "\"\(SyntheticMail.defaultTo)\" <someone.else@example.net>, (\(SyntheticMail.defaultTo)) x@example.net"
    let display = try mail(SyntheticMail.dibCard(id: "r2", dateMs: Rig.t0, to: named))
    #expect(display.recipientMatched == false)

    let cc = SyntheticMail.dibCard(id: "r3", dateMs: Rig.t0, to: "someone.else@example.net\r\nCc: Me <\(SyntheticMail.defaultTo)>")
    #expect(try mail(cc).recipientMatched == true)

    guard case .mail(let unlinked) = MessageDisposer.parse(
      raw: SyntheticMail.dibCard(id: "r4", dateMs: Rig.t0).raw, messageID: "r4", internalDateMs: Rig.t0,
      topLevelFrom: "DIB Alerts <alerts@dib.ae>", templates: templates, bankDomains: trusted, trusted: trusted,
      recipient: nil, spam: false, analyze: AuthResults.analyze)
    else { throw CancellationError() }
    #expect(MessageDisposer.finalize(unlinked, provider: .gmail, grantID: "g", cards: cards, categorizer: NoCategorizer()).needsReview)
  }

  @Test func spamStaysInReview() throws {
    let m = SyntheticMail.dibCard(id: "s1", dateMs: Rig.t0)
    guard case .mail(let p) = MessageDisposer.parse(
      raw: m.raw, messageID: m.id, internalDateMs: m.internalDateMs, topLevelFrom: m.from, templates: templates,
      bankDomains: trusted, trusted: trusted, recipient: SyntheticMail.defaultTo, spam: true, analyze: AuthResults.analyze)
    else { throw CancellationError() }
    let d = MessageDisposer.finalize(p, provider: .gmail, grantID: "g", cards: [CardKey(bank: "dib", last4: "1234"): .mine], categorizer: NoCategorizer())
    #expect(d.needsReview && d.payload["amount_minor"] == .string("25000"))
  }

  @Test func stagedMailWithoutRecipientFactsStaysInReview() throws {
    let p = try mail(SyntheticMail.dibCard(id: "o1", dateMs: Rig.t0))
    let cards = [CardKey(bank: "dib", last4: "1234"): CardState.mine]
    #expect(!MessageDisposer.finalize(p, provider: .gmail, grantID: "g", cards: cards, categorizer: NoCategorizer()).needsReview)
    var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(p)) as! [String: Any]
    json.removeValue(forKey: "recipientMatched")
    json.removeValue(forKey: "spam")
    let old = try JSONDecoder().decode(ParsedMail.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(MessageDisposer.finalize(old, provider: .gmail, grantID: "g", cards: cards, categorizer: NoCategorizer()).needsReview)
  }

  @Test func unparsedBankMailIsTheEmptyReviewShape() throws {
    let p = try mail(SyntheticMail.bankNotice(id: "m4", dateMs: Rig.t0))
    #expect(p.fields == nil)
    let d = MessageDisposer.finalize(p, provider: .gmail, grantID: "g", cards: [:], categorizer: GroceryCategorizer())
    #expect(d.needsReview)
    let mid = MessageIDEvidence.hash(headers: "Message-ID: <\(Rig.t0).synthetic@example.invalid>") ?? ""
    #expect(d.payload.canonical == #"{"unparsed":true,"needs_review":true,"posted_at":"2026-05-28T20:00:00.000Z","posted_precision":"day","merchant_raw":"","last4":"","category":null,"entry_method":"mailbox","provenance":{"provider":"gmail","grant_id":"g","message_id":"m4"},"gates":{"ar":"pass","sender":"trusted","template":"none","card":"none","forwarded":false},"dedupe":{"message_id":"\#(mid)"}}"#)
  }

  @Test func nonBankMailIsSetAside() {
    let m = SyntheticMail.lookAlike(id: "m5", dateMs: Rig.t0, listedAs: "emiratesnbd.com")
    let r = MessageDisposer.parse(
      raw: m.raw, messageID: m.id, internalDateMs: m.internalDateMs, topLevelFrom: "Offers <offers@emiratesnbd.com.promo.example>",
      templates: templates, bankDomains: trusted, trusted: trusted, recipient: SyntheticMail.defaultTo, spam: false, analyze: AuthResults.analyze)
    #expect(r == .setAside(domain: "promo.example"))
  }

  @Test func zeroAmountIsAMissNotAFiling() throws {
    let p = try mail(SyntheticMail.dibCard(id: "m6", amount: "0.00", dateMs: Rig.t0))
    #expect(p.fields == nil)
  }
}

@Suite struct MailRecipientsTests {
  @Test func canonicalFormsMatch() {
    #expect(MailRecipients.canonical("First.Last+bank@GoogleMail.com") == "firstlast@gmail.com")
    #expect(MailRecipients.canonical(" firstlast@gmail.com. ") == "firstlast@gmail.com")
    #expect(MailRecipients.canonical("First.Last+bank@Outlook.Example") == "first.last@outlook.example")
    #expect(MailRecipients.canonical("nobody") == nil)
    #expect(MailRecipients.canonical("@example.com") == nil)
    #expect(MailRecipients.canonical("+x@example.com") == nil)
  }

  @Test func readsToAndCcOnly() {
    let headers = [
      "Delivered-To: me@example.com", "Reply-To: me@example.com", "From: Bank <alerts@bank.example>",
      "To: \"Me, Myself\" <me+alerts@example.com>,", "\tother@example.net (note @ here)", "CC: group: a@example.org; ",
      "Subject: me@example.com",
    ].joined(separator: "\r\n")
    #expect(MailRecipients.addresses(headers: headers) == ["me+alerts@example.com", "other@example.net", "a@example.org"])
    #expect(MailRecipients.names("ME@example.com", headers: headers))
    #expect(!MailRecipients.names("someone@example.com", headers: headers))
    #expect(!MailRecipients.names(nil, headers: headers))
    #expect(!MailRecipients.names("me@example.com", headers: "Delivered-To: me@example.com\r\nTo: you@example.com"))
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
