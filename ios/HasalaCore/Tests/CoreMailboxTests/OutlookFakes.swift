// The Outlook lane's test rig: the real MailboxEngine over an OutlookProvider whose Graph and
// Microsoft token endpoint are FakeGraph (CoreTestSupport). Every message is synthetic.
import CoreJSON
import CoreMailbox
import CorePrimitives
import CoreStore
import CoreTemplate
import CoreTestSupport
import CoreTime
import Foundation

/// hasalad's link routes for an Outlook link: the link answer carries a clientState, and `meta`
/// names the two Graph hook URLs.
actor OutlookServer: MailboxServer {
  static let clientState = "c3ludGhldGljLWNsaWVudC1zdGF0ZS0wMDAwMDAwMDAwMDA"
  static let notificationURL = "https://hasala.example/hooks/outlook/graph"
  static let lifecycleURL = "https://hasala.example/hooks/outlook/graph/lifecycle"

  var link: MailboxLinkStatus = .noLink
  var nonce = "bm9uY2Utc3ludGhldGljLTAwMDAwMDAwMDAwMDAwMDA"
  var linkedProviders: [MailProviderID] = []
  var watches: [Int64] = []
  var deletes = 0
  var pushOn = true
  var returnsClientState = true

  func setLink(_ l: MailboxLinkStatus) { link = l }
  func setPushOn(_ v: Bool) { pushOn = v }
  func setReturnsClientState(_ v: Bool) { returnsClientState = v }

  func linkStatus() async throws(MailboxServerError) -> MailboxLinkStatus { link }
  func linkChallenge() async throws(MailboxServerError) -> String { nonce }
  func putLink(provider: MailProviderID, idToken: String, stepUp: JSONValue) async throws(MailboxServerError)
    -> MailboxLinkResult
  {
    linkedProviders.append(provider)
    link = .holder(isThisDevice: true, watchExpiresAtMs: nil)
    return MailboxLinkResult(status: link, clientState: returnsClientState ? Self.clientState : nil)
  }
  func putWatch(expiresAtMs: Int64) async throws(MailboxServerError) { watches.append(expiresAtMs) }
  func deleteLink(stepUp: JSONValue) async throws(MailboxServerError) {
    deletes += 1
    link = .noLink
  }
  func pushConfig(provider: MailProviderID) async throws(MailboxServerError) -> MailboxPushConfig {
    guard provider == .outlook, pushOn else { return .none }
    return .outlook(notificationURL: Self.notificationURL, lifecycleURL: Self.lifecycleURL)
  }
}

/// The ASWebAuthenticationSession stand-in: Microsoft's consent page auto-approves.
struct OutlookPresenter: MailAuthSessionPresenter {
  let graph: FakeGraph
  var cancel = false
  func authorize(url: URL, callbackScheme: String) async throws(MailOAuthError) -> URL {
    if cancel { throw .cancelled }
    return graph.consent(authorizeURL: url)
  }
}

struct OutlookRig {
  static let t0 = Rig.t0
  static let config = MicrosoftOAuthConfig(clientID: "00000000-0000-4000-8000-00000000c11e", redirectScheme: "msauth.app.hasala.ios")
  let graph = FakeGraph()
  let tables = try! MailboxTableStore.inMemory()
  let authored = AuthoredDrafts()
  let store: any MailboxPersistence
  let ledger = FakeLedger()
  let server = OutlookServer()
  let clock = ManualClock(OutlookRig.t0)
  let keychain = MemoryMailRefreshTokenStore()
  let link = MemoryOutlookLinkStore()
  let provider: OutlookProvider
  let tokens: RefreshingMailTokenProvider
  let engine: MailboxEngine

  /// `viaURLSession` serves FakeGraph through a real URLSession (`URLSessionHTTPExchange`).
  init(trustProven: Bool = false, viaURLSession: Bool = false, categorizer: any IngestCategorizer = NoCategorizer()) {
    let authored = self.authored
    let clock = self.clock
    store = LedgerMailboxPersistence(
      tables: tables,
      author: { drafts, at in
        authored.append(drafts)
        return drafts.map {
          MailboxPendingOpRow(
            opID: "op-\($0.messageID)", opJSON: Data(JSONWriter().bytes(.object($0.payload))), opType: "txn_ingested",
            entityKind: "txn", entityID: "e-\($0.messageID)", enqueuedAt: at)
        }
      }, nowMs: { clock.nowMs() })
    let http: any HTTPExchange = viaURLSession ? FakeGmailURLProtocol.exchange(for: graph) : graph
    let oauth = MicrosoftOAuthClient(config: Self.config, http: http)
    provider = OutlookProvider(oauth: oauth, http: http, link: link, clock: clock, trustProven: trustProven)
    tokens = RefreshingMailTokenProvider(oauth: oauth, store: keychain, clock: clock)
    engine = MailboxEngine(
      config: MailboxEngineConfig(grantID: "00000000-0000-4000-8000-000000000001"), provider: provider, tokens: tokens,
      store: store, ledger: ledger, server: server, stepUp: FakeStepUp(), categorizer: categorizer,
      templates: BundledTemplates.load().templates, clock: clock, random: CountingRandom(),
      sleep: { ms in clock.advance(ms) })
    graph.nowMs = { clock.nowMs() }
  }

  func connect(days: Int = 90) async -> ConnectResult {
    await engine.connect(presenter: OutlookPresenter(graph: graph), backfillDays: days)
  }

  /// Connect, then the first scan authors what it finds: the engine ends `active`.
  func connectAndActivate(days: Int = 90) async {
    _ = await connect(days: days)
    _ = await engine.runCycle(trigger: .launch)
  }

  func enqueued() -> [MailboxIngestDraft] { authored.all }
  func byID() -> [String: MailboxIngestDraft] { Dictionary(uniqueKeysWithValues: enqueued().map { ($0.messageID, $0) }) }
  func state() async -> MailboxState { (try? await store.loadState()) ?? MailboxState() }
  func accounted(_ id: String) -> AccountedOutcome? {
    (try? tables.accountedRowsForTests()[id]).flatMap { AccountedOutcome(rawValue: $0) }
  }
  func unreadableReasons() async -> [UnreadableReason] { ((try? await store.unreadableRecords()) ?? []).map(\.reason) }

  var listRequests: [FakeGraph.Recorded] { graph.graphRequests.filter { $0.path == "/v1.0/me/messages" } }
  var rawRequests: [FakeGraph.Recorded] { graph.graphRequests.filter { $0.path.hasSuffix("/$value") } }
  /// Single-message metadata reads (`GET /me/messages/{id}` without `$value`).
  var metadataRequests: [FakeGraph.Recorded] {
    graph.graphRequests.filter { $0.path.hasPrefix("/v1.0/me/messages/") && !$0.path.hasSuffix("/$value") }
  }
  func subscriptionRequests(_ method: String) -> [FakeGraph.Recorded] {
    graph.graphRequests.filter { $0.method == method && $0.path.hasPrefix("/v1.0/subscriptions") }
  }
}
