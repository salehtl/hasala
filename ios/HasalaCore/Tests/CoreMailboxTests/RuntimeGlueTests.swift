// The production glue around the engine (spec 04 §7): the session exchange to
// hasalad's mailbox routes, the refresh token's custody in `Secrets`, the op
// author the persistence calls, and the at-ingest categorizer over the
// projection. RuntimeMailboxLedger runs end to end in HasalaCoreE2ETests.
import CoreAuth
import CoreCategorize
import CoreDomain
import CoreJSON
import CorePrimitives
import CoreProjection
import CoreReplay
import CoreStore
import CoreTestSupport
import CoreTime
import CoreWire
import Foundation
import Synchronization
import Testing

@testable import CoreMailbox

@Suite("CoreMailbox: runtime glue")
struct RuntimeGlueTests {
  static let user = UserID("6f1c2b9e-4d3a-4f5b-8c7d-0e1f2a3b4c5d")!
  static let writer = WriterID("ios-0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d")!
  static let now: Int64 = 1_791_625_200_000

  final class Recorder: Transport {
    let requests = Mutex<[APIRequest]>([])
    let result: Result<APIResponse, TransportError>
    init(_ result: Result<APIResponse, TransportError> = .success(APIResponse(status: 200, body: Data(#"{"nonce":"bm9uY2U"}"#.utf8)))) {
      self.result = result
    }
    func send(_ request: APIRequest) async throws(TransportError) -> APIResponse {
      requests.withLock { $0.append(request) }
      return try result.get()
    }
    var last: APIRequest? { requests.withLock { $0.last } }
  }

  static func secrets(token: String? = "session-token", pendingLogout: Bool = false) throws -> (Secrets, MemorySecretStore) {
    let store = MemorySecretStore()
    let s = Secrets(store: store, apiHost: "api.hasala.app")
    if let token {
      try s.writeSession(SessionRecord(token: token, userID: user.string, expiresAt: 4_000_000_000, tag: "00", pendingLogout: pendingLogout))
    }
    return (s, store)
  }

  // MARK: SessionHTTPExchange

  @Test("the session exchange sends path and query to the transport with the bearer from Secrets")
  func sessionExchange() async throws {
    let t = Recorder()
    let (s, _) = try Self.secrets()
    let x = SessionHTTPExchange(transport: t, secrets: s)
    let r = try await x.send(
      HTTPRequest(
        method: .put, url: URL(string: "https://elsewhere.example/api/v1/mailbox/link?a=1%202")!, headers: [("X", "y")],
        body: Data("{}".utf8)))
    #expect(r.status == 200 && r.body == Data(#"{"nonce":"bm9uY2U"}"#.utf8))
    #expect(t.last == APIRequest(method: .put, path: "/api/v1/mailbox/link?a=1%202", body: Data("{}".utf8), bearer: "session-token"))
    // HTTPMailboxServer over it.
    let server = HTTPMailboxServer(http: x, base: "https://api.hasala.app")
    #expect(try await server.linkChallenge() == "bm9uY2U")
    #expect(t.last?.method == .post && t.last?.path == "/api/v1/mailbox/link/challenge")
  }

  @Test("no session or a pending logout sends no bearer; a locked Keychain and a dead network are offline")
  func sessionExchangeEdges() async throws {
    for (token, pending) in [(nil, false), ("t", true)] as [(String?, Bool)] {
      let t = Recorder()
      let (s, _) = try Self.secrets(token: token, pendingLogout: pending)
      _ = try await SessionHTTPExchange(transport: t, secrets: s).send(HTTPRequest(method: .get, url: URL(string: "https://api.hasala.app/api/v1/meta")!))
      #expect(t.last?.bearer == nil && t.last?.path == "/api/v1/meta")
    }
    let (s, store) = try Self.secrets()
    store.locked = true
    await #expect(throws: HTTPExchangeError.offline) {
      try await SessionHTTPExchange(transport: Recorder(), secrets: s).send(HTTPRequest(method: .get, url: URL(string: "https://api.hasala.app/x")!))
    }
    store.locked = false
    await #expect(throws: HTTPExchangeError.offline) {
      try await SessionHTTPExchange(transport: Recorder(.failure(.offline(.timedOut))), secrets: s)
        .send(HTTPRequest(method: .get, url: URL(string: "https://api.hasala.app/x")!))
    }
    await #expect(throws: HTTPExchangeError.cancelled) {
      try await SessionHTTPExchange(transport: Recorder(.failure(.cancelled)), secrets: s)
        .send(HTTPRequest(method: .get, url: URL(string: "https://api.hasala.app/x")!))
    }
    let refused = Recorder(.success(APIResponse(status: 409, body: Data(#"{"error":"not_holder"}"#.utf8))))
    let server = HTTPMailboxServer(http: SessionHTTPExchange(transport: refused, secrets: s), base: "https://api.hasala.app")
    await #expect(throws: MailboxServerError.notHolder) { try await server.putWatch(expiresAtMs: Self.now) }
    // hasalad without the Pub/Sub push: route 36 is refused with its own code.
    let noTopic = Recorder(.success(APIResponse(status: 409, body: Data(#"{"error":"no_watch_topic","detail":"x"}"#.utf8))))
    let quiet = HTTPMailboxServer(http: SessionHTTPExchange(transport: noTopic, secrets: s), base: "https://api.hasala.app")
    await #expect(throws: MailboxServerError.noWatchTopic) { try await quiet.putWatch(expiresAtMs: Self.now) }
  }

  @Test("a path the transport would resolve to another host is refused before any bearer is read")
  func sessionExchangeOriginOnly() async throws {
    let t = Recorder()
    let (s, store) = try Self.secrets()
    let x = SessionHTTPExchange(transport: t, secrets: s)
    for url in ["https://api.hasala.app//api/v1/mailbox/link", "https://api.hasala.app//evil.example/x"] {
      store.locked = true  // a read of the session would throw: the refusal comes first
      await #expect(throws: HTTPExchangeError.offline) { try await x.send(HTTPRequest(method: .put, url: URL(string: url)!)) }
      store.locked = false
    }
    #expect(t.requests.withLock { $0.isEmpty })
    #expect(SessionHTTPExchange.isOriginPath("/") && SessionHTTPExchange.isOriginPath("/api/v1/x"))
    #expect(!SessionHTTPExchange.isOriginPath("//x") && !SessionHTTPExchange.isOriginPath("x") && !SessionHTTPExchange.isOriginPath(""))
    // A trailing-slash base still builds single-slash paths.
    let server = HTTPMailboxServer(http: x, base: "https://api.hasala.app/")
    #expect(try await server.linkChallenge() == "bm9uY2U")
    #expect(t.last?.path == "/api/v1/mailbox/link/challenge" && t.last?.bearer == "session-token")
  }

  @Test("route 35 names the provider only when it is not Gmail and returns Outlook's client_state")
  func putLinkProvider() async throws {
    let (s, _) = try Self.secrets()
    let linked = #"{"provider":"gmail","holder":{"writer_id":"w","is_this_device":true},"watch_expires_at":null}"#
    let t = Recorder(.success(APIResponse(status: 200, body: Data(linked.utf8))))
    let server = HTTPMailboxServer(http: SessionHTTPExchange(transport: t, secrets: s), base: "https://api.hasala.app")
    let step = JSONValue.object(JSONObject([("kind", .string("device"))]))
    let gmail = try await server.putLink(provider: .gmail, idToken: "id", stepUp: step)
    #expect(gmail == MailboxLinkResult(status: .holder(isThisDevice: true, watchExpiresAtMs: nil), clientState: nil))
    // A server from before the Outlook link refuses unknown fields: a Gmail body is unchanged.
    #expect(String(decoding: t.last?.body ?? Data(), as: UTF8.self) == #"{"id_token":"id","step_up":{"kind":"device"}}"#)

    let outlookLinked = #"{"provider":"outlook","holder":{"is_this_device":true},"client_state":"Y2xpZW50LXN0YXRl"}"#
    let o = Recorder(.success(APIResponse(status: 200, body: Data(outlookLinked.utf8))))
    let outlookServer = HTTPMailboxServer(http: SessionHTTPExchange(transport: o, secrets: s), base: "https://api.hasala.app")
    let outlook = try await outlookServer.putLink(provider: .outlook, idToken: "id", stepUp: step)
    #expect(outlook.clientState == "Y2xpZW50LXN0YXRl")
    #expect(
      String(decoding: o.last?.body ?? Data(), as: UTF8.self)
        == #"{"provider":"outlook","id_token":"id","step_up":{"kind":"device"}}"#)
  }

  @Test("route 37 names the link's provider; an older server's link is Gmail; no link has none")
  func linkProvider() async throws {
    let (s, _) = try Self.secrets()
    func server(_ status: Int, _ body: String) -> HTTPMailboxServer {
      let t = Recorder(.success(APIResponse(status: status, body: Data(body.utf8))))
      return HTTPMailboxServer(http: SessionHTTPExchange(transport: t, secrets: s), base: "https://api.hasala.app")
    }
    let outlook = try await server(200, #"{"provider":"outlook","holder":{"is_this_device":false}}"#).linkStatusAndProvider()
    #expect(outlook.0 == .holder(isThisDevice: false, watchExpiresAtMs: nil) && outlook.1 == .outlook)
    let older = try await server(200, #"{"holder":{"is_this_device":true}}"#).linkStatusAndProvider()
    #expect(older.1 == .gmail)
    let none = try await server(404, #"{"error":"no_link"}"#).linkStatusAndProvider()
    #expect(none.0 == .noLink && none.1 == nil)
  }

  @Test("meta's push settings, per provider: a topic, both Outlook URLs, or none")
  func pushConfig() async throws {
    let (s, _) = try Self.secrets()
    func server(_ meta: String) -> HTTPMailboxServer {
      let t = Recorder(.success(APIResponse(status: 200, body: Data(meta.utf8))))
      return HTTPMailboxServer(http: SessionHTTPExchange(transport: t, secrets: s), base: "https://api.hasala.app")
    }
    let both = server(
      #"{"gmail_watch_topic":"projects/p/topics/t","outlook_notification_url":"https://h/hooks/outlook/graph","outlook_lifecycle_url":"https://h/hooks/outlook/graph/lifecycle"}"#
    )
    #expect(try await both.pushConfig(provider: .gmail) == .gmail(topic: "projects/p/topics/t"))
    #expect(
      try await both.pushConfig(provider: .outlook)
        == .outlook(notificationURL: "https://h/hooks/outlook/graph", lifecycleURL: "https://h/hooks/outlook/graph/lifecycle"))
    let off = server(#"{"gmail_watch_topic":null,"outlook_notification_url":"https://h/hooks/outlook/graph","outlook_lifecycle_url":null}"#)
    #expect(try await off.pushConfig(provider: .gmail) == MailboxPushConfig.none)
    #expect(try await off.pushConfig(provider: .outlook) == MailboxPushConfig.none)
    // An older server's meta has no Outlook fields at all.
    let meta = try JSONDecoder().decode(MetaResponse.self, from: Data(#"{"rp_id":"hasala.app","gmail_watch_topic":null}"#.utf8))
    #expect(meta.outlook_notification_url == nil && meta.outlook_lifecycle_url == nil)
  }

  @Test("each provider's refresh token is its own Keychain item; Outlook's is wiped with the account")
  func outlookRefreshTokenStore() throws {
    let (s, store) = try Self.secrets()
    let gmail = SecretsMailRefreshTokenStore(secrets: s, userID: Self.user, provider: .gmail)
    let outlook = SecretsMailRefreshTokenStore(secrets: s, userID: Self.user, provider: .outlook)
    try outlook.write("M.outlook-refresh")
    #expect(try gmail.read() == nil)
    #expect(try store.read(.mailRefresh(provider: .outlook, userID: Self.user)) == Data("M.outlook-refresh".utf8))
    try store.write(.outlookClientState(userID: Self.user), Data("cs".utf8))
    try s.wipeAccount(userID: Self.user, writerID: Self.writer)
    #expect(try outlook.read() == nil)
    #expect(try store.read(.outlookClientState(userID: Self.user)) == nil)
  }

  // MARK: SecretsGmailRefreshTokenStore

  @Test("the refresh token lives in .gmailRefresh(user): read nil, write, read back, locked throws, wiped with the account")
  func refreshTokenStore() throws {
    let (s, store) = try Self.secrets()
    let t = SecretsGmailRefreshTokenStore(secrets: s, userID: Self.user)
    #expect(try t.read() == nil)
    try t.write("1//refresh-token")
    #expect(try t.read() == "1//refresh-token")
    #expect(try store.read(.gmailRefresh(userID: Self.user)) == Data("1//refresh-token".utf8))
    store.locked = true
    #expect(throws: SecretUnavailable.self) { try t.read() }
    #expect(throws: SecretUnavailable.self) { try t.write("x") }
    store.locked = false
    try s.wipeAccount(userID: Self.user, writerID: Self.writer)
    #expect(try t.read() == nil)
    try t.write("again")
    try t.delete()
    #expect(try t.read() == nil)
    // An item that holds no token reads as absent (and is removed), never "not now" forever.
    for junk in [Data(), Data([0xFF, 0xFE])] {
      try store.write(.gmailRefresh(userID: Self.user), junk)
      #expect(try t.read() == nil)
      #expect(try store.read(.gmailRefresh(userID: Self.user)) == nil)
    }
  }

  // MARK: MailboxAuthoring

  static func ledger() throws -> LedgerStore {
    let s = try LedgerStore.inMemory()
    try s.create(StoreMeta(userID: user, writerID: writer, apiBase: "b", keyEpoch: 1, createdAt: 1))
    return s
  }

  static func draft(_ n: Int, amount: String = "4250") -> MailboxIngestDraft {
    let ingest = Hex.encode(sha256(Data("message-\(n)".utf8)))
    return MailboxIngestDraft(
      messageID: "m\(n)", ingestID: ingest, internalDateMs: now,
      payload: JSONObject([
        ("amount_minor", .string(amount)), ("currency", .string("AED")), ("direction", .string("debit")),
        ("posted_at", .string("2026-10-10T08:00:00.000Z")), ("posted_precision", .string("time")),
        ("merchant_raw", .string("CARREFOUR MOE")), ("last4", .string("4412")), ("needs_review", .bool(true)),
        ("unparsed", .bool(false)), ("tier", .string("template")), ("entry_method", .string("mailbox")),
        (
          "provenance",
          .object(JSONObject([("provider", .string("gmail")), ("grant_id", .string(user.string)), ("message_id", .string("m\(n)"))]))
        ),
        ("bank", .string("enbd")),
      ]), needsReview: true)
  }

  @Test("each draft becomes one validated txn_ingested row, committed with the message's accounting")
  func authoring() async throws {
    let store = try Self.ledger()
    let authoring = MailboxAuthoring(store: store, writerID: Self.writer.string, random: SeededRandom(), stamps: AuthorStamps())
    let persistence = LedgerMailboxPersistence(
      tables: MailboxTableStore(writer: store.db), author: authoring.opAuthor, nowMs: { Self.now })
    var c = MailboxCommit()
    c.drafts = [Self.draft(1), Self.draft(2)]
    c.accounted = [
      AccountedRecord(messageID: "m1", outcome: .op, internalDateMs: Self.now, atMs: Self.now),
      AccountedRecord(messageID: "m2", outcome: .op, internalDateMs: Self.now, atMs: Self.now),
    ]
    try await persistence.commit(c)
    let pending = try store.pendingOps()
    #expect(pending.count == 2 && pending.allSatisfy { $0.opType == "txn_ingested" && $0.entityKind == "txn" })
    #expect(try store.hasPendingIngest(Self.draft(1).ingestID) && store.hasPendingIngest(Self.draft(2).ingestID))
    #expect(try await persistence.accounted(among: ["m1", "m2", "m3"]) == ["m1", "m2"])
    // The stored bytes are the outbox's canonical op JSON, and they decode.
    let blob = Data(#"{"v":4,"kind":"ops","ops":["#.utf8) + pending[0].opJSON + Data(",".utf8) + pending[1].opJSON + Data("]}".utf8)
    let ops = try OpCodec.decodeBlobOps(blob)
    #expect(ops.map(\.ingestID) == [Self.draft(1).ingestID, Self.draft(2).ingestID])
    #expect(ops.map(\.payload) == [.object(Self.draft(1).payload), .object(Self.draft(2).payload)])
    // The next commit stamps after these, even with the clock standing still.
    let rows = try authoring.author([Self.draft(3)], atMs: Self.now)
    let next = try OpCodec.decodeBlobOps(Data(#"{"v":4,"kind":"ops","ops":["#.utf8) + rows[0].opJSON + Data("]}".utf8))
    #expect(try parseInstantMs(next[0].authoredAt) > parseInstantMs(ops[1].authoredAt))
    // Peers' newer stamps (within 24 h) push the base forward.
    authoring.updateSeen(["ios-1a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d": Self.now + 3_600_000])
    #expect(try authoring.context(nowMs: Self.now).baseMs == Self.now + 3_600_001)
  }

  @Test("Gmail blobs and screen blobs share one stamp memory: none repeats, the outbox not yet involved")
  func sharedStamps() throws {
    let store = try Self.ledger()
    let stamps = AuthorStamps()
    let authoring = MailboxAuthoring(store: store, writerID: Self.writer.string, random: SeededRandom(), stamps: stamps)
    // A screen context minted first, its blob built after a Gmail blob: neither enqueued.
    let screen = AuthorContext(writerID: Self.writer.string, nowMs: Self.now, ownLastMs: nil, maxAuthored: [:], random: SeededRandom(seed: "s"))
    let gmail = try authoring.author([Self.draft(1), Self.draft(2)], atMs: Self.now)
    let gmailLast = try parseInstantMs(
      try OpCodec.decodeBlobOps(Data(#"{"v":4,"kind":"ops","ops":["#.utf8) + gmail[1].opJSON + Data("]}".utf8))[0].authoredAt)
    #expect(stamps.lastMs == gmailLast)
    let blob = try #require(try stamps.build(screen) { a in a.setHomeCurrency("AED") })
    #expect(try parseInstantMs(blob.ops[0].authoredAt) == gmailLast + 1)
    #expect(stamps.lastMs == blob.lastAuthoredMs)
    // And the next Gmail blob stamps after the screen's.
    let next = try authoring.author([Self.draft(3)], atMs: Self.now)
    let nextAt = try parseInstantMs(
      try OpCodec.decodeBlobOps(Data(#"{"v":4,"kind":"ops","ops":["#.utf8) + next[0].opJSON + Data("]}".utf8))[0].authoredAt)
    #expect(nextAt == blob.lastAuthoredMs + 1)
    // A body that adds nothing builds nothing and records nothing.
    #expect(try stamps.build(screen) { _ in } == nil)
    #expect(stamps.lastMs == nextAt)
  }

  @Test("a draft outside the payload grammar throws and commits nothing")
  func authoringRefuses() async throws {
    let store = try Self.ledger()
    let authoring = MailboxAuthoring(store: store, writerID: Self.writer.string, random: SeededRandom(), stamps: AuthorStamps())
    let persistence = LedgerMailboxPersistence(
      tables: MailboxTableStore(writer: store.db), author: authoring.opAuthor, nowMs: { Self.now })
    var c = MailboxCommit()
    c.drafts = [Self.draft(1), Self.draft(2, amount: "-5")]
    c.accounted = [AccountedRecord(messageID: "m1", outcome: .op, internalDateMs: Self.now, atMs: Self.now)]
    await #expect(throws: MailboxPersistenceError.self) { try await persistence.commit(c) }
    #expect(try store.pendingCount() == 0)
    #expect(try await persistence.accounted(among: ["m1"]).isEmpty)
  }

  // MARK: PipelineCategorizer

  static func projection(rules: [OpAuthor.RuleDraft]) throws -> ProjectionStore {
    var s = State()
    var a = OpAuthor(AuthorContext(writerID: writer.string, nowMs: now, ownLastMs: nil, maxAuthored: [:], random: SeededRandom()))
    a.setHomeCurrency("AED")
    for r in rules { try a.rule(r) }
    try Replay.foldOps(try a.build().ops, seq: 1, writerID: writer.string, into: &s)
    let p = try ProjectionStore.inMemory()
    try p.project(s, pending: [], writerID: writer.string, dictionary: try MerchantDictionary.bundled().get(), projectedAtMs: now)
    return p
  }

  @Test("rules first, then the dictionary; a spending category on a credit files nothing; the cache follows the projection")
  func categorizer() throws {
    let dictionary = try MerchantDictionary.bundled().get()
    let p = try Self.projection(rules: [OpAuthor.RuleDraft(patterns: ["carrefour"], match: .contains, category: "shopping")])
    let c = PipelineCategorizer(projection: p, dictionary: dictionary)
    let rule = c.decide(merchantRaw: "CARREFOUR MOE", direction: "debit")
    #expect(rule.category == "shopping" && rule.source["kind"]?.stringValue == "rule")
    #expect(rule.source["rule_id"]?.stringValue == (try p.reader.rules().first?.id))
    let dict = c.decide(merchantRaw: "STARBUCKS DIFC", direction: "debit")
    #expect(dict.category == "dining" && dict.source["kind"]?.stringValue == "dictionary")
    #expect(dict.source["bundle"]?.stringValue == DictionaryManifest.bundle && dict.source["entry"]?.stringValue == "contains:starbucks")
    #expect(c.decide(merchantRaw: "STARBUCKS DIFC", direction: "credit") == .none)
    #expect(c.decide(merchantRaw: "UNKNOWN SHOP", direction: "debit") == .none)
    #expect(c.decide(merchantRaw: "STARBUCKS", direction: "sideways") == .none)

    // A new rule, projected later, applies to the next decision.
    var s = State()
    var a = OpAuthor(AuthorContext(writerID: Self.writer.string, nowMs: Self.now, ownLastMs: nil, maxAuthored: [:], random: SeededRandom(seed: "2")))
    a.setHomeCurrency("AED")
    try a.rule(OpAuthor.RuleDraft(patterns: ["starbucks"], match: .contains, category: "groceries"))
    try Replay.foldOps(try a.build().ops, seq: 1, writerID: Self.writer.string, into: &s)
    // Projected at the same millisecond: the projection's generation, not its clock, invalidates.
    try p.project(s, pending: [], writerID: Self.writer.string, dictionary: dictionary, projectedAtMs: Self.now)
    #expect(c.decide(merchantRaw: "STARBUCKS DIFC", direction: "debit").category == "groceries")
    #expect(c.decide(merchantRaw: "CARREFOUR MOE", direction: "debit").category != "shopping")
  }
}
