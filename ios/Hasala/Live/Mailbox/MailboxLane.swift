import CoreMailbox
import CorePrimitives
import CoreStore
import CoreTemplate
import CoreTime
import Foundation

/// One mail provider's lane for one bound account (Gmail or Outlook): the MailboxEngine
/// wired to its platform halves (Keychain, ASWebAuthenticationSession, BGTaskScheduler) and
/// to the account's ports. The account has at most one link at a time; `AccountRuntime`
/// keeps a lane per configured provider and runs the linked one.
///
/// The ports come from the account runtime (spec 04 §3): `persistence` (CoreStore's
/// mailbox tables in ledger.sqlite, shared by both lanes), `ledger` (`RuntimeMailboxLedger`
/// over the account's sync engine, observer and outbox), `server` (`HTTPMailboxServer` over
/// the session transport) and `stepUp` (`LiveStepUp`). The refresh token is the account's
/// `SecretItem.mailRefresh(provider:)` in `Secrets` (Outlook's clientState and subscription
/// id are `outlookClientState`), so every account wipe takes them.
///
/// `WorkCoordinator` owns the triggers (§3 "one entry point"): it calls
/// `cycle(trigger:deadlineMs:)` as its mailbox stage. Push settings are the server's (`GET
/// /meta`); with none, the watch or subscription is skipped and new mail is caught by the
/// foreground, background-refresh and silent-push runs.
nonisolated final class MailboxLane: Sendable {
  let provider: MailboxProvider
  let engine: MailboxEngine
  let tokens: RefreshingMailTokenProvider
  let presenter: any MailAuthSessionPresenter
  let events = LaneEvents()
  let work = LaneWork()

  /// nil when the build carries no client for `provider` (the `unset` placeholders, spec 06
  /// §15.2): that provider is then not offered.
  init?(
    provider: MailboxProvider, build: BuildInfo, secrets: Secrets, userID: UserID, persistence: any MailboxPersistence,
    ledger: any MailboxLedger, server: any MailboxServer, stepUp: any MailboxStepUp, categorizer: any IngestCategorizer,
    presenter: any MailAuthSessionPresenter
  ) {
    let http = URLSessionHTTPExchange.ephemeral(maxResponseBytes: MailboxLimits.maxResponseBytes)
    let clock = SystemClock()
    let mail: any MailProvider
    switch provider {
    case .gmail:
      let config = GmailOAuthConfig(clientID: build.googleClientID, redirectScheme: build.googleRedirectScheme)
      guard config.isConfigured else { return nil }
      mail = GmailProvider(oauth: GoogleOAuthClient(config: config, http: http), http: http)
    case .outlook:
      let config = MicrosoftOAuthConfig(clientID: build.outlookClientID, redirectScheme: build.outlookRedirectScheme)
      guard config.isConfigured else { return nil }
      mail = OutlookProvider(
        oauth: MicrosoftOAuthClient(config: config, http: http), http: http,
        link: SecretsOutlookLinkStore(secrets: secrets, userID: userID), clock: clock)
    }
    self.provider = provider
    tokens = RefreshingMailTokenProvider(
      oauth: mail.oauth, store: SecretsMailRefreshTokenStore(secrets: secrets, userID: userID, provider: provider.providerID),
      clock: clock)
    // No build topic: the server's `meta` names the push settings (nil skips the watch).
    engine = MailboxEngine(
      config: MailboxEngineConfig(grantID: userID.string, buildTopic: nil), provider: mail, tokens: tokens,
      store: persistence, ledger: ledger, server: server, stepUp: stepUp, categorizer: categorizer,
      templates: Self.mailTemplates, clock: clock, random: SystemRandom(), readerKeys: SecretsMailReaderKeyStore(secrets: secrets))
    self.presenter = presenter
  }

  func relayEvents() async {
    let events = self.events
    await engine.setProgressHandler { events.send(.progress($0)) }
    await engine.setCommitHandler { events.send(.committed) }
  }

  /// Whether this iPhone keeps a refresh token for the provider (nil: unreadable now).
  func hasGrant() async -> Bool? { await tokens.hasRefreshToken() }

  /// Bank alerts › Connect (after the window choice sheet, spec 04 §7.7 step 1).
  /// `replacing`: the mailbox tables hold the other provider's lane, cleared only once this
  /// link is made.
  ///
  /// An account that left this iPhone (deleted, removed, erased) may still be ending its
  /// grant at the provider (`MailGrantEnds`). That ending acts on the provider account and
  /// this app's client id, not on one Hasala account, so this connect waits for it first:
  /// its revoke and `users.stop` must reach Google before this link's grant and watch exist.
  /// The wait is bounded, and every ending is bounded inside it (`MailGrantEnds.http`), so it
  /// ends first in practice. If it hasn't, the connect is refused ("Try again"): signing in
  /// regardless could let that ending reach Google after this link and end its grant.
  func connect(
    backfillDays: Int, pastMail: MailboxPastMail = .read, replacing: Bool = false, confirm: MailboxSwitchConfirm? = nil
  ) async -> ConnectResult {
    if let refused = await MailGrantEnds.shared.connectGate() { return refused }
    let r = await engine.connect(
      presenter: presenter, backfillDays: backfillDays, pastMail: pastMail, replacing: replacing, confirm: confirm)
    if case .connected = r {
      // The scan itself runs from `firstScan()` (foreground) or the processing task.
      BackgroundScheduler.shared.scheduleProcessing()
    }
    return r
  }

  /// What the first scan's foreground runs authored, for "264 transactions, sorted." and
  /// where the lane stopped (`.active` when the whole window is in).
  struct FirstScanTotals: Sendable, Equatable {
    var ops = 0
    var byRules = 0
    var byDictionary = 0
    var byModel = 0
    var toReview = 0
    var phase: MailboxPhase = .scanning
    var haltedOn: MailboxHaltCode?

    mutating func add(_ r: CycleReport) {
      ops += r.ops
      byRules += r.sortedBy["rule"] ?? 0
      byDictionary += r.sortedBy["dictionary"] ?? 0
      byModel += r.sortedBy["model"] ?? 0
      toReview += r.toReview
      phase = r.phase
      haltedOn = r.haltedOn
    }

    var pause: MailboxProgress? {
      guard phase == .scanning || phase == .authoringBackfill, let code = haltedOn, code != .stagingFull else {
        return nil
      }
      return MailboxProgress(stage: .failed(code), done: 0, total: 0)
    }
  }

  enum FirstScanEvent: Sendable {
    case progress(MailboxProgress)
    case ended(FirstScanTotals)
  }

  /// The first scan (Setup 2 of 4, Paper FR2-0): runs cycles until the window is listed and
  /// authored (`MailboxEngine.runFirstScan`, which rides out Gmail's rate limit and a dropped
  /// connection), yielding their progress, then the totals. There is no cards step: the scan
  /// authors what it finds. Ending the stream (setup finished, the sheet closed) does not stop
  /// the import: it runs to the end here, and whatever is left after 50 cycles runs in
  /// `app.hasala.ios.processing` and the next foreground runs (§7.7 step 3).
  func firstScan() -> AsyncStream<FirstScanEvent> {
    let engine = self.engine
    let events = self.events
    let work = self.work
    return AsyncStream { continuation in
      // Not cancelled with the stream: the import outlives the setup screens.
      let started = work.start {
        await self.relayEvents()
        let id = events.add { if case .progress(let p) = $0 { continuation.yield(.progress(p)) } }
        var totals = FirstScanTotals()
        for r in await engine.runFirstScan(maxCycles: 50) { totals.add(r) }
        events.remove(id)
        if let pause = totals.pause { events.send(.progress(pause)) }
        continuation.yield(.ended(totals))
        continuation.finish()
      }
      if !started { continuation.finish() }
    }
  }

  func backfill(senders: [String]) {
    let engine = self.engine
    work.start { _ = await engine.backfill(senders: senders) }
  }

  func importPastMail() async -> CycleReport { await engine.importPastMail() }

  func stop() async {
    await engine.stop()
    await work.cancelAll()
  }

  func resume() async { await engine.resume() }

  func close() async {
    work.close()
    await engine.stop()
    await work.cancelAll()
  }

  static let mailTemplates: [CompiledTemplate] = BundledTemplates.load(channel: .mail).templates

  static let mailDefinitions: [TemplateDefinition] = mailTemplates.map(\.definition)

  /// The sender domains Setup's bank step trusts for a bank (03c §7.2), e.g. "dib" → dib.ae.
  static func senderDomains(bank: String) -> [String] {
    BankDomains.templateDomains(bank: bank, templates: mailDefinitions)
  }

  /// Bank alerts (spec 04 §7.10).
  func status() async -> MailboxStatus { await engine.status() }
  func retirePlan() async -> MailboxRetirePlan? { await engine.retirePlan() }
  func disconnect(removing plan: MailboxRetirePlan?) async -> MailboxDisconnectOutcome {
    await engine.disconnect(removing: plan)
  }
  func retire(_ plan: MailboxRetirePlan) async -> MailboxRetireOutcome { await engine.retire(plan) }
  /// The other provider's link replaced this one: end this provider's grant here.
  func endGrant() async { await engine.endGrant() }
  func addSender(_ typed: String) async -> Result<CycleReport, BankDomains.TypedDomainError> {
    await engine.importSender(typed)
  }
  func probeSenders(_ domains: [String]) async -> SenderProbeResult { await engine.probeSenders(domains) }

  func cycle(trigger: MailboxTrigger, deadlineMs: Int64? = nil) async -> CycleReport {
    await engine.runCycle(trigger: trigger, deadlineMs: deadlineMs)
  }
}

nonisolated final class LaneWork: @unchecked Sendable {
  private let lock = NSLock()
  private var tasks: [UUID: Task<Void, Never>] = [:]
  private var closed = false

  @discardableResult
  func start(_ body: @escaping @Sendable () async -> Void) -> Bool {
    let id = UUID()
    return lock.withLock {
      guard !closed else { return false }
      tasks[id] = Task {
        await body()
        self.finished(id)
      }
      return true
    }
  }

  private func finished(_ id: UUID) {
    _ = lock.withLock { tasks.removeValue(forKey: id) }
  }

  func close() { lock.withLock { closed = true } }

  var isClosed: Bool { lock.withLock { closed } }

  var running: Int { lock.withLock { tasks.count } }

  func cancelAll() async {
    let all = lock.withLock { Array(tasks.values) }
    for t in all { t.cancel() }
    for t in all { await t.value }
  }
}

nonisolated final class LaneEvents: @unchecked Sendable {
  enum Event: Sendable {
    case progress(MailboxProgress)
    case committed
  }

  private let lock = NSLock()
  private var listeners: [UUID: @Sendable (Event) -> Void] = [:]

  @discardableResult
  func add(_ listener: @escaping @Sendable (Event) -> Void) -> UUID {
    let id = UUID()
    lock.withLock { listeners[id] = listener }
    return id
  }

  func remove(_ id: UUID) {
    _ = lock.withLock { listeners.removeValue(forKey: id) }
  }

  func send(_ event: Event) {
    for listener in lock.withLock({ Array(listeners.values) }) { listener(event) }
  }
}

// MARK: Leaving the account

extension MailboxProvider {
  /// The core's provider id (the same strings).
  nonisolated var providerID: MailProviderID { self == .gmail ? .gmail : .outlook }
}

/// What this iPhone holds of the account's mailbox grants, read before the account's secrets
/// are wiped: each provider's refresh token, and Outlook's subscription id.
nonisolated struct HeldMailGrants: Sendable, Equatable {
  struct Grant: Sendable, Equatable {
    var provider: MailboxProvider
    var refreshToken: String
    var subscriptionID: String?
  }
  var grants: [Grant]
}

/// The grant endings of the accounts that left this iPhone (deleted, removed, erased, wiped),
/// run one after another, and what a new connect waits for.
///
/// An ending is not scoped to the Hasala account that left: Google's revoke ends this app's
/// whole grant for the Google account (every Hasala account shares the iOS client id), and
/// `users.stop` ends the mailbox's watch for the whole project. Run as a detached task, it
/// could reach Google after the next account on this iPhone linked the same mailbox, and end
/// that account's grant and watch too: its first scan then stops on `reconnect_required` and
/// nothing is imported. So the departure waits for its ending (bounded), and
/// `MailboxLane.connect` waits for any still running.
nonisolated final class MailGrantEnds: @unchecked Sendable {
  static let shared = MailGrantEnds()
  /// How long a departure waits for its grant ending before it carries on regardless.
  static let departureWait: Duration = .seconds(10)
  /// How long a connect waits for earlier endings; past it the connect is refused.
  static let connectWait: Duration = .seconds(20)
  /// The longest one request of an ending may take, start to end. `endGrant` sends at most
  /// five, one after another (Gmail's refresh, `users.stop` and revoke; Outlook's refresh
  /// and subscription delete), so one ending is over inside `connectWait`.
  static let requestLimit: TimeInterval = 3
  /// The most requests one ending sends.
  static let requestsPerEnding = 5

  /// The HTTP every ending uses: the shared ephemeral configuration, with each request
  /// limited from start to end (`timeoutIntervalForResource`), not only between bytes.
  nonisolated static func http() -> URLSessionHTTPExchange {
    let c = URLSessionConfiguration.ephemeral
    c.httpCookieStorage = nil
    c.httpShouldSetCookies = false
    c.urlCache = nil
    c.urlCredentialStorage = nil
    c.requestCachePolicy = .reloadIgnoringLocalCacheData
    c.timeoutIntervalForRequest = requestLimit
    c.timeoutIntervalForResource = requestLimit
    c.waitsForConnectivity = false
    return URLSessionHTTPExchange(configuration: c)
  }

  private let lock = NSLock()
  private var last: Task<Void, Never>?

  /// Runs `end` once every ending handed in before it is done.
  func enqueue(_ end: @escaping @Sendable () async -> Void) {
    lock.withLock {
      let before = last
      last = Task {
        await before?.value
        await end()
      }
    }
  }

  /// Before a connect signs in: nil once every earlier ending is done (waiting at most
  /// `limit`), else the refusal ("Couldn't connect … Try again."). An ending still running
  /// could reach the provider after the new link and end its grant and watch.
  func connectGate(within limit: Duration = MailGrantEnds.connectWait) async -> ConnectResult? {
    await settled(within: limit) ? nil : .failed(.google)
  }

  /// Waits until every ending handed in so far is done, at most `limit`. False when the
  /// limit came first (the ending carries on).
  @discardableResult
  func settled(within limit: Duration) async -> Bool {
    guard let pending = lock.withLock({ last }) else { return true }
    let done = Task { () -> Bool in
      await pending.value
      return true
    }
    return await WorkCoordinator.wait(
      for: done, until: ContinuousClock.now + limit, timedOut: false, cancelled: false)
  }
}

extension MailboxLane {
  /// The account's mailbox grants on this iPhone; nil when there is none (another iPhone
  /// holds the link) or none can be read.
  nonisolated static func heldGrant(secrets: Secrets, userID: UserID) -> HeldMailGrants? {
    var grants: [HeldMailGrants.Grant] = []
    for p in MailboxProvider.allCases {
      guard let token = try? SecretsMailRefreshTokenStore(secrets: secrets, userID: userID, provider: p.providerID).read(),
        !token.isEmpty
      else { continue }
      let sub = p == .outlook ? (try? SecretsOutlookLinkStore(secrets: secrets, userID: userID).read())??.subscriptionID : nil
      grants.append(.init(provider: p, refreshToken: token, subscriptionID: sub))
    }
    return grants.isEmpty ? nil : HeldMailGrants(grants: grants)
  }

  nonisolated static func endGrantLater(_ held: HeldMailGrants?, build: BuildInfo) {
    guard let held else { return }
    MailGrantEnds.shared.enqueue { await endGrant(held, build: build, stopWatch: false) }
  }

  /// Ends this iPhone's grants as the account leaves it (spec 04 §4.7 rows 2–4), best effort,
  /// and nothing for a provider the build has no client for. It needs only what `heldGrant`
  /// read, so it runs after the local wipe as well.
  ///
  /// - Gmail: `users.stop` first when the account itself is going (`stopWatch`), then the
  ///   refresh token is revoked at Google.
  /// - Outlook: Microsoft has no revoke endpoint; this iPhone's Graph subscription is deleted
  ///   when the account is going, and the tokens are simply forgotten (consent is ended at
  ///   account.live.com/consent/Manage).
  nonisolated static func endGrant(_ held: HeldMailGrants, build: BuildInfo, stopWatch: Bool) async {
    let http = MailGrantEnds.http()
    for g in held.grants {
      switch g.provider {
      case .gmail:
        let config = GmailOAuthConfig(clientID: build.googleClientID, redirectScheme: build.googleRedirectScheme)
        guard config.isConfigured else { continue }
        let oauth = GoogleOAuthClient(config: config, http: http)
        if stopWatch, let grant = try? await oauth.refresh(refreshToken: g.refreshToken) {
          try? await GmailClient(http: http, accessToken: grant.accessToken).stop()
        }
        try? await oauth.revoke(token: g.refreshToken)
      case .outlook:
        let config = MicrosoftOAuthConfig(clientID: build.outlookClientID, redirectScheme: build.outlookRedirectScheme)
        guard config.isConfigured, stopWatch, let id = g.subscriptionID else { continue }
        let oauth = MicrosoftOAuthClient(config: config, http: http)
        if let grant = try? await oauth.refresh(refreshToken: g.refreshToken) {
          let graph = GraphClient(
            http: http, accessToken: grant.accessToken, link: MemoryOutlookLinkStore(), nowMs: { SystemClock().nowMs() })
          try? await graph.deleteSubscription(id: id)
        }
      }
    }
  }
}
