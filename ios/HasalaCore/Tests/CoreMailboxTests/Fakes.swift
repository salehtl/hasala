// Test doubles for the engine's ports. FakeGmail (CoreTestSupport) stands in for Google.
import CoreJSON
import CoreMailbox
import CoreStore
import CorePrimitives
import CoreTemplate
import CoreTestSupport
import CoreTime
import Foundation

final class ManualClock: Clock, @unchecked Sendable {
  private let lock = NSLock()
  private var now: Int64
  init(_ ms: Int64) { now = ms }
  func nowMs() -> Int64 { lock.withLock { now } }
  func advance(_ ms: Int64) { lock.withLock { now += ms } }
  func set(_ ms: Int64) { lock.withLock { now = ms } }
}

/// Deterministic bytes (a counter), never a real random source.
final class CountingRandom: RandomSource, @unchecked Sendable {
  private let lock = NSLock()
  private var n: UInt8 = 0
  func fill(_ buffer: UnsafeMutableRawBufferPointer) throws(PrimitivesError) {
    lock.withLock {
      for i in 0..<buffer.count {
        n &+= 1
        buffer[i] = n
      }
    }
  }
}

actor FakeLedger: MailboxLedger {
  var trust: [String: Bool] = ["dib.ae": true, "emiratesnbd.com": true]
  var cards: [CardKey: CardState] = [:]
  var projected: Set<String> = []
  var ingested: Set<String> = []
  var syncs = 0
  var syncFails = false
  var flushes = 0
  var flushResult: FlushOutcome = .flushed
  var accountFullAfter: Int?
  var authoredCards: [CardDecision] = []
  var authoredTrust: [(String, Bool)] = []

  func setTrust(_ t: [String: Bool]) { trust = t }
  func setCards(_ c: [CardKey: CardState]) { cards = c }
  func setProjected(_ p: Set<String>) { projected = p }
  func setIngested(_ i: Set<String>) { ingested = i }
  func setFlush(_ r: FlushOutcome) { flushResult = r }
  func setAccountFull(after flushes: Int?) { accountFullAfter = flushes }
  func setSyncFails(_ v: Bool) { syncFails = v }

  func syncToHead() async throws(MailboxLedgerError) {
    syncs += 1
    if syncFails { throw MailboxLedgerError("offline") }
  }
  func senderTrust() async -> [String: Bool] { trust }
  func knownCards() async -> [CardKey: CardState] { cards }
  func projectedMessageIDs(among ids: [String]) async -> Set<String> { projected.intersection(ids) }
  func isIngested(_ ingestID: String) async -> Bool { ingested.contains(ingestID) }
  func authorCards(_ decisions: [CardDecision]) async throws(MailboxLedgerError) {
    authoredCards += decisions
    for d in decisions { cards[d.card] = d.state }
  }
  func authorSenderTrust(domain: String, trusted: Bool) async throws(MailboxLedgerError) {
    authoredTrust.append((domain, trusted))
    trust[domain] = trusted
  }
  var plans: [String: MailboxRetirePlan] = [:]
  var retired: [MailboxRetirePlan] = []
  func setPlan(_ p: MailboxRetirePlan) { plans[p.grantID] = p }
  func retirePlan(grantID: String, provider: String) async -> MailboxRetirePlan {
    plans[grantID] ?? MailboxRetirePlan(grantID: grantID, provider: provider, legacy: true, total: 0, edited: 0)
  }
  var retireFails = false
  func setRetireFails(_ v: Bool) { retireFails = v }
  func authorRetire(_ plan: MailboxRetirePlan) async throws(MailboxLedgerError) {
    if retireFails { throw MailboxLedgerError("enqueue") }
    retired.append(plan)
  }
  func flush() async -> FlushOutcome {
    flushes += 1
    if let n = accountFullAfter, flushes > n { return .accountFull }
    return flushResult
  }
}

actor FakeServer: MailboxServer {
  var link: MailboxLinkStatus = .holder(isThisDevice: true, watchExpiresAtMs: nil)
  var topic: String? = "projects/synthetic/topics/hasala-gmail-test"
  var nonce = "bm9uY2Utc3ludGhldGljLTAwMDAwMDAwMDAwMDAwMDA"
  var puts: [(String, JSONValue)] = []
  var linkedProviders: [MailProviderID] = []
  var watches: [Int64] = []
  var deletes = 0
  var offline = false
  /// Route 36's refusal, when set (e.g. `.noWatchTopic`: a server without the Pub/Sub push).
  var watchRefusal: MailboxServerError?
  var linkRefusal: MailboxServerError?
  var topicReads = 0

  func setLink(_ l: MailboxLinkStatus) { link = l }
  func setTopic(_ t: String?) { topic = t }
  func setWatchRefusal(_ e: MailboxServerError?) { watchRefusal = e }
  func setLinkRefusal(_ e: MailboxServerError?) { linkRefusal = e }

  func linkStatus() async throws(MailboxServerError) -> MailboxLinkStatus {
    if offline { throw .offline }
    return link
  }
  var linkProvider: MailProviderID?
  func setLinkProvider(_ p: MailProviderID?) { linkProvider = p }
  func linkStatus(provider: MailProviderID) async throws(MailboxServerError) -> MailboxLinkStatus {
    if let linkProvider, linkProvider != provider { throw .otherProvider }
    return try await linkStatus()
  }
  func linkChallenge() async throws(MailboxServerError) -> String { nonce }
  func putLink(provider: MailProviderID, idToken: String, stepUp: JSONValue) async throws(MailboxServerError)
    -> MailboxLinkResult
  {
    puts.append((idToken, stepUp))
    if let linkRefusal { throw linkRefusal }
    linkedProviders.append(provider)
    link = .holder(isThisDevice: true, watchExpiresAtMs: nil)
    return MailboxLinkResult(status: link)
  }
  func putWatch(expiresAtMs: Int64) async throws(MailboxServerError) {
    if let watchRefusal { throw watchRefusal }
    watches.append(expiresAtMs)
  }
  func deleteLink(stepUp: JSONValue) async throws(MailboxServerError) {
    deletes += 1
    link = .noLink
  }
  func pushConfig(provider: MailProviderID) async throws(MailboxServerError) -> MailboxPushConfig {
    topicReads += 1
    guard provider == .gmail, let topic else { return .none }
    return .gmail(topic: topic)
  }
}

final class StepUpLog: @unchecked Sendable {
  private let lock = NSLock()
  private var seen: [String] = []
  func record(_ kind: String) { lock.withLock { seen.append(kind) } }
  var kinds: [String] { lock.withLock { seen } }
}

struct FakeStepUp: MailboxStepUp {
  var fail = false
  var log: StepUpLog?
  func proof(kind: String, payloadHash: Data?) async throws(MailboxStepUpError) -> JSONValue {
    log?.record(kind)
    if fail { throw .cancelled }
    return .object(JSONObject([("kind", .string(kind)), ("p", .string(payloadHash.map { Hex.encode($0) } ?? ""))]))
  }
}

/// The ASWebAuthenticationSession stand-in: Google's consent page auto-approves.
struct FakePresenter: GmailAuthSessionPresenter {
  let gmail: FakeGmail
  var cancel = false
  func authorize(url: URL, callbackScheme: String) async throws(GmailOAuthError) -> URL {
    if cancel { throw .cancelled }
    return gmail.consent(authorizeURL: url)
  }
}

/// Files merchants containing GROCER under groceries (a stand-in for 03c §8.2's decide).
struct GroceryCategorizer: IngestCategorizer {
  func decide(merchantRaw: String, direction: String) -> IngestDecision {
    guard merchantRaw.contains("GROCER") else { return .none }
    return IngestDecision(
      category: "groceries",
      source: .object(JSONObject([("kind", .string("dictionary")), ("bundle", .string("2026.10.01-1")), ("entry", .string("contains:GROCER"))])))
  }
}

/// The ops the persistence authored (the tests' view of `pending_ops`).
final class AuthoredDrafts: @unchecked Sendable {
  private let lock = NSLock()
  private var drafts: [MailboxIngestDraft] = []
  private var sizes: [Int] = []
  func append(_ d: [MailboxIngestDraft]) {
    lock.withLock {
      drafts += d
      sizes.append(d.count)
    }
  }
  var all: [MailboxIngestDraft] { lock.withLock { drafts } }
  var batches: [Int] { lock.withLock { sizes } }
}

enum Backend { case sqlite, memory }

/// A whole engine over fakes. The persistence is the production one (ledger.sqlite tables in an
/// in-memory SQLite database) unless a test asks for the in-memory reference.
struct Rig {
  static let t0: Int64 = 1_780_000_000_000  // 2026-05-28, synthetic
  let gmail: FakeGmail
  let memory = InMemoryMailboxPersistence()
  let tables = try! MailboxTableStore.inMemory()
  let authored = AuthoredDrafts()
  let store: any MailboxPersistence
  let backend: Backend
  let ledger = FakeLedger()
  let server = FakeServer()
  let clock = ManualClock(Rig.t0)
  let keychain = MemoryGmailRefreshTokenStore()
  let stepUps = StepUpLog()
  let engine: MailboxEngine
  let tokens: RefreshingGmailTokenProvider

  init(
    backend: Backend = .sqlite, categorizer: any IngestCategorizer = NoCategorizer(), stepUpFails: Bool = false,
    gmail: FakeGmail = FakeGmail(), config: ((inout MailboxEngineConfig) -> Void)? = nil,
    wrapStore: ((any MailboxPersistence) -> any MailboxPersistence)? = nil
  ) {
    self.gmail = gmail
    self.backend = backend
    let authored = self.authored
    let clockForStore = clock
    let base: any MailboxPersistence =
      backend == .memory
      ? memory
      : LedgerMailboxPersistence(
        tables: tables,
        author: { drafts, at in
          authored.append(drafts)
          return drafts.map {
            MailboxPendingOpRow(
              opID: "op-\($0.messageID)", opJSON: Data(JSONWriter().bytes(.object($0.payload))), opType: "txn_ingested",
              entityKind: "txn", entityID: "e-\($0.messageID)", enqueuedAt: at)
          }
        }, nowMs: { clockForStore.nowMs() })
    store = wrapStore?(base) ?? base
    let oauth = GoogleOAuthClient(
      config: GmailOAuthConfig(clientID: "synthetic-client.apps.googleusercontent.com", redirectScheme: "com.googleusercontent.apps.synthetic-client"),
      http: gmail)
    tokens = RefreshingGmailTokenProvider(oauth: oauth, store: keychain, clock: clock)
    var c = MailboxEngineConfig(grantID: "00000000-0000-4000-8000-000000000001", buildTopic: nil)
    config?(&c)
    let clock = self.clock
    engine = MailboxEngine(
      config: c, oauth: oauth, tokens: tokens, gmailHTTP: gmail, store: store, ledger: ledger, server: server,
      stepUp: FakeStepUp(fail: stepUpFails, log: stepUps), categorizer: categorizer, templates: BundledTemplates.load().templates,
      clock: clock, random: CountingRandom(), sleep: { ms in clock.advance(ms) })
    gmail.watchExpirationMs = Rig.t0 + 7 * 86_400_000
  }

  /// Connect, scan, confirm every card as mine: the engine ends `active`.
  func connectAndActivate(days: Int = 90) async {
    _ = await engine.connect(presenter: FakePresenter(gmail: gmail), backfillDays: days)
    _ = await engine.runCycle(trigger: .launch)  // the scan authors what it finds (no cards step)
  }

  func enqueued() async -> [MailboxIngestDraft] { backend == .memory ? await memory.enqueued : authored.all }
  func state() async -> MailboxState { (try? await store.loadState()) ?? MailboxState() }
  func stagedCount() async -> Int { (try? await store.stagedCount()) ?? -1 }
  func accounted(_ id: String) async -> AccountedOutcome? {
    if backend == .memory { return await memory.accountedRows[id]?.outcome }
    return (try? tables.accountedRowsForTests()[id]).flatMap { AccountedOutcome(rawValue: $0) }
  }
  func accountedCount() async -> Int {
    backend == .memory ? await memory.accountedRows.count : ((try? tables.accountedRowsForTests().count) ?? -1)
  }
  func unreadableReasons() async -> [UnreadableReason] {
    ((try? await store.unreadableRecords()) ?? []).map(\.reason)
  }

  var listRequests: [FakeGmail.Recorded] { gmail.requests.filter { $0.path.hasSuffix("/messages") } }
  var rawRequests: [FakeGmail.Recorded] {
    gmail.requests.filter { r in r.query.contains { $0 == ("format", "raw") } }
  }
}

extension JSONObject {
  var canonical: String { String(decoding: JSONWriter().bytes(.object(self)), as: UTF8.self) }
}
