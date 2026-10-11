import CoreMailbox
import CorePrimitives
import CoreTemplate
import CoreTime
import Foundation
import Synchronization

/// The Gmail lane for one bound account: the MailboxEngine wired to its platform halves
/// (Keychain, ASWebAuthenticationSession, BGTaskScheduler) and to the account's ports.
///
/// The ports come from the account runtime (spec 04 §3): `persistence` (CoreStore's
/// mailbox tables in ledger.sqlite), `ledger` (CoreSync/CoreOutbox/CoreDomain), `server`
/// (`HTTPMailboxServer` over the session transport) and `stepUp` (the auth lane's step-up).
///
/// TODO(WS-13): the WorkCoordinator should own the triggers (§3 "one entry point") and call
/// `cycle(trigger:deadlineMs:)` as its mailbox stage; until it lands, `installBackgroundWork`
/// and `foreground()` drive the lane directly.
nonisolated final class GmailLane: Sendable {
  let engine: MailboxEngine
  let tokens: RefreshingGmailTokenProvider
  let presenter: any GmailAuthSessionPresenter

  /// Minimum spacing of foreground catch-ups (spec 04 §7.9: 5-min timer while active).
  static let foregroundSpacingMs: Int64 = 5 * 60_000
  private let lastForeground = Mutex<Int64>(0)

  /// nil when the build carries no Google client (the `unset` placeholders, spec 06 §15.2):
  /// "Connect Gmail" is then not offered.
  init?(
    build: BuildInfo, userID: String, persistence: any MailboxPersistence, ledger: any MailboxLedger,
    server: any MailboxServer, stepUp: any MailboxStepUp, categorizer: any IngestCategorizer,
    presenter: any GmailAuthSessionPresenter
  ) {
    let config = GmailOAuthConfig(clientID: build.googleClientID, redirectScheme: build.googleRedirectScheme)
    guard config.isConfigured else { return nil }
    let google = URLSessionHTTPExchange.ephemeral()
    let oauth = GoogleOAuthClient(config: config, http: google)
    let clock = SystemClock()
    tokens = RefreshingGmailTokenProvider(
      oauth: oauth, store: KeychainGmailRefreshTokenStore(userID: userID), clock: clock)
    let templates = BundledTemplates.load().templates
    engine = MailboxEngine(
      config: MailboxEngineConfig(
        grantID: userID, buildTopic: build.gmailPubSubTopic == "unset" ? nil : build.gmailPubSubTopic),
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

  /// Catch-up on open (spec 04 §7.9 "Foreground"), at most once per 5 minutes.
  func foreground() async {
    let now = SystemClock().nowMs()
    let due = lastForeground.withLock { last -> Bool in
      guard now - last >= Self.foregroundSpacingMs else { return false }
      last = now
      return true
    }
    guard due else { return }
    _ = await engine.runCycle(trigger: .foreground)
  }

  /// Hands BGAppRefreshTask / BGProcessingTask runs to this lane.
  func installBackgroundWork() {
    let engine = self.engine
    BackgroundScheduler.shared.install { kind, deadlineMs in
      switch kind {
      case .refresh:
        _ = await engine.runCycle(trigger: .appRefresh, deadlineMs: deadlineMs)
      case .processing:
        // Scan or backfill pages until iOS expires the task (the engine checks cancellation at
        // each message boundary via its deadline; a cancelled task stops at the next commit).
        for _ in 0..<50 where !Task.isCancelled {
          let r = await engine.runCycle(trigger: .processing)
          if r.completed || r.haltedOn != nil || r.phase == .awaitingCards { break }
        }
      }
      let phase = await engine.status().phase
      return phase == .scanning || phase == .authoringBackfill
    }
    BackgroundScheduler.shared.scheduleRefresh()
  }
}
