import CoreMailbox
import CorePrimitives
import CoreStore
import CoreTemplate
import CoreTime
import Foundation

/// The Gmail lane for one bound account: the MailboxEngine wired to its platform halves
/// (Keychain, ASWebAuthenticationSession, BGTaskScheduler) and to the account's ports.
///
/// The ports come from the account runtime (spec 04 §3): `persistence` (CoreStore's
/// mailbox tables in ledger.sqlite), `ledger` (`RuntimeMailboxLedger` over the account's
/// sync engine, observer and outbox), `server` (`HTTPMailboxServer` over the session
/// transport) and `stepUp` (`LiveStepUp`). The refresh token is the account's
/// `SecretItem.gmailRefresh` in `Secrets`, so every account wipe takes it.
///
/// `WorkCoordinator` owns the triggers (§3 "one entry point"): it calls
/// `cycle(trigger:deadlineMs:)` as its mailbox stage. The watch topic is the server's
/// (`GET /meta` `gmail_watch_topic`); with none, `users.watch` is skipped and new mail is
/// caught by the foreground, background-refresh and silent-push runs.
nonisolated final class GmailLane: Sendable {
  let engine: MailboxEngine
  let tokens: RefreshingGmailTokenProvider
  let presenter: any GmailAuthSessionPresenter

  /// nil when the build carries no Google client (the `unset` placeholders, spec 06 §15.2):
  /// "Connect Gmail" is then not offered.
  init?(
    build: BuildInfo, secrets: Secrets, userID: UserID, persistence: any MailboxPersistence, ledger: any MailboxLedger,
    server: any MailboxServer, stepUp: any MailboxStepUp, categorizer: any IngestCategorizer,
    presenter: any GmailAuthSessionPresenter
  ) {
    let config = GmailOAuthConfig(clientID: build.googleClientID, redirectScheme: build.googleRedirectScheme)
    guard config.isConfigured else { return nil }
    let google = URLSessionHTTPExchange.ephemeral()
    let oauth = GoogleOAuthClient(config: config, http: google)
    let clock = SystemClock()
    tokens = RefreshingGmailTokenProvider(
      oauth: oauth, store: SecretsGmailRefreshTokenStore(secrets: secrets, userID: userID), clock: clock)
    let templates = BundledTemplates.load().templates
    // No build topic: the server's `meta.gmail_watch_topic` is the only one (nil skips the watch).
    engine = MailboxEngine(
      config: MailboxEngineConfig(grantID: userID.string, buildTopic: nil),
      oauth: oauth, tokens: tokens, gmailHTTP: google, store: persistence, ledger: ledger, server: server,
      stepUp: stepUp, categorizer: categorizer, templates: templates, clock: clock, random: SystemRandom())
    self.presenter = presenter
  }

  /// Bank alerts › Connect Gmail (after the window choice sheet, spec 04 §7.7 step 1).
  func connect(backfillDays: Int) async -> ConnectResult {
    let r = await engine.connect(presenter: presenter, backfillDays: backfillDays)
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
  }

  enum FirstScanEvent: Sendable {
    case progress(MailboxProgress)
    case ended(FirstScanTotals)
  }

  /// The first scan (Setup 2 of 4, Paper FR2-0): runs cycles until the window is listed and
  /// authored, yielding their progress, then the totals. There is no cards step: the scan
  /// authors what it finds. Ending the stream (setup finished, the sheet closed) does not stop
  /// the import: it runs to the end here, and whatever is left after 50 cycles runs in
  /// `app.hasala.ios.processing` and the next foreground runs (§7.7 step 3).
  func firstScan() -> AsyncStream<FirstScanEvent> {
    let engine = self.engine
    return AsyncStream { continuation in
      // Not cancelled with the stream: the import outlives the setup screens.
      Task {
        await engine.setProgressHandler { continuation.yield(.progress($0)) }
        var totals = FirstScanTotals()
        for _ in 0..<50 {
          let r = await engine.runCycle(trigger: .refresh)
          totals.add(r)
          if r.phase != .scanning && r.phase != .authoringBackfill { break }
          if r.haltedOn != nil && r.haltedOn != .stagingFull { break }
          // Nothing listed and not finished: no trusted sender yet (or offline). Stop rather
          // than spin; the next trigger resumes it.
          if r.listed == 0 && r.ops == 0 && !r.completed { break }
        }
        await engine.setProgressHandler(nil)
        continuation.yield(.ended(totals))
        continuation.finish()
      }
    }
  }

  /// The sender domains Setup's bank step trusts for a bank (03c §7.2), e.g. "dib" → dib.ae.
  static func senderDomains(bank: String) -> [String] {
    BankDomains.templateDomains(bank: bank, templates: BundledTemplates.load().templates.map(\.definition))
  }

  /// Bank alerts (spec 04 §7.10).
  func status() async -> MailboxStatus { await engine.status() }
  func disconnect() async -> Bool { await engine.disconnect() }
  func addSender(_ typed: String) async -> Result<CycleReport, BankDomains.TypedDomainError> {
    await engine.importSender(typed)
  }
  func viewEmail(messageID: String) async -> EmailView { await engine.viewEmail(messageID: messageID) }

  func cycle(trigger: MailboxTrigger, deadlineMs: Int64? = nil) async -> CycleReport {
    await engine.runCycle(trigger: trigger, deadlineMs: deadlineMs)
  }
}

// MARK: Leaving the account

extension GmailLane {
  /// The account's Google refresh token on this iPhone, read before the account's secrets
  /// are wiped; nil when there is none (another iPhone holds Gmail) or it can't be read.
  static func heldGrant(secrets: Secrets, userID: UserID) -> String? {
    guard let token = try? SecretsGmailRefreshTokenStore(secrets: secrets, userID: userID).read(), !token.isEmpty else {
      return nil
    }
    return token
  }

  /// Ends this iPhone's Google grant as the account leaves it (spec 04 §4.7 rows 2–4):
  /// `users.stop` first when the account itself is going (`stopWatch`), then the refresh
  /// token is revoked at Google. Best effort, and nothing when the build has no Google
  /// client. It needs only the token, so it runs after the local wipe as well.
  static func endGrant(_ refreshToken: String, build: BuildInfo, stopWatch: Bool) async {
    let config = GmailOAuthConfig(clientID: build.googleClientID, redirectScheme: build.googleRedirectScheme)
    guard config.isConfigured else { return }
    let google = URLSessionHTTPExchange.ephemeral()
    let oauth = GoogleOAuthClient(config: config, http: google)
    if stopWatch, let grant = try? await oauth.refresh(refreshToken: refreshToken) {
      try? await GmailClient(http: google, accessToken: grant.accessToken).stop()
    }
    try? await oauth.revoke(token: refreshToken)
  }
}
