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

  /// The first scan (Setup 2 of 5, Paper FR2-0): runs scan cycles in the foreground and yields
  /// their progress; the stream ends at "Are these your cards?" (or a halt). The scan continues
  /// in `app.hasala.ios.processing` if the user leaves the screen (§7.7 step 3).
  func firstScan() -> AsyncStream<MailboxProgress> {
    let engine = self.engine
    return AsyncStream { continuation in
      let job = Task {
        await engine.setProgressHandler { continuation.yield($0) }
        for _ in 0..<50 where !Task.isCancelled {
          let r = await engine.runCycle(trigger: .refresh)
          if r.phase != .scanning || (r.haltedOn != nil && r.haltedOn != .stagingFull) { break }
          // Nothing listed and not finished: no trusted sender yet (or offline). Stop rather
          // than spin; the board shows the scan as waiting and the next trigger resumes it.
          if r.listed == 0 && !r.completed { break }
        }
        await engine.setProgressHandler(nil)
        continuation.finish()
      }
      continuation.onTermination = { _ in job.cancel() }
    }
  }

  /// "Are these your cards?" (Setup 5 of 5, Paper G9Q-0).
  func discoveredCards() async -> ScanSummary { await engine.scanSummary() }

  /// "Continue with {k} cards": `card_linked` for each card (mine or not mine), then the backfill.
  func confirmCards(_ decisions: [CardDecision]) async -> CycleReport {
    await engine.confirmCards(decisions)
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
