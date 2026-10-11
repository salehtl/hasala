// MailboxEngine: the Gmail lane on the holder iPhone (spec 04 §7.4-§7.9; port of fetch.ts
// `runFetchCycle`, rebuilt on a sender-filtered listing, PO G).
//
// One actor per bound account. Every entry point is serialized (single flight): a cycle that is
// asked for while one runs waits for it and returns its report rather than running twice. A
// cycle never throws; every failure it can name ends as `haltedOn` in its report and, where it
// changes what the user must do, in the persisted phase.
//
// The invariants carried over from fetch.ts, each pinned by a test in CoreMailboxTests:
//   - every listed message ends ACCOUNTED (an op, set aside, unreadable, dup or gone) in the
//     same transaction as its op's enqueue, so a cut cycle never re-downloads;
//   - the checkpoint (watermark) moves only after every group's listing is exhausted, every id
//     accounted AND the outbox flushed; a cut run keeps the old watermark and re-lists;
//   - 404/410 is `gone` (accounted, the cycle moves past it); 429/5xx/transport retry
//     400 ms then 1200 ms and a 429 narrows the download width to 1; 401/403 is fatal;
//   - 413 on flush halts `account_full` with the watermark intact;
//   - no token is `reconnect_required`, an unreadable Keychain is "not now".
import CoreJSON
import CoreMail
import CoreNorm
import CorePrimitives
import CoreTemplate
import CoreTime
import Foundation

public struct MailboxEngineConfig: Sendable {
  /// `provenance.grant_id`: the account's user id (one link per account).
  public var grantID: String
  /// `BuildInfo.gmailPubSubTopic`; the server's `meta.gmail_watch_topic` wins on a mismatch.
  public var buildTopic: String?
  public var maxMessageBytes = MailboxLimits.maxMessageBytes
  public var stagingCap = 5_000
  public var holderCheckIntervalMs: Int64 = 10 * 60_000
  /// Authoring stops this long before the deadline (§3).
  public var authoringMarginMs: Int64 = 5_000
  public var backfillBatch = 200
  public var downloadWidth = 6
  public var retryBackoffMs: [Int64] = [400, 1_200]
  /// Renew the watch when it expires within this window (§7.5 step 5).
  public var watchRenewWindowMs: Int64 = 3 * 86_400_000
  public var maxListPages = 100
  public var importMaxPages = 5
  public var gmailBase = GmailClient.defaultBase

  public init(grantID: String, buildTopic: String? = nil) {
    self.grantID = grantID
    self.buildTopic = buildTopic
  }
}

public struct CycleReport: Sendable, Equatable {
  public var listed = 0
  public var fetched = 0
  public var ops = 0
  public var review = 0
  public var unreadable = 0
  public var setAside = 0
  public var staged = 0
  public var dup = 0
  public var haltedOn: MailboxHaltCode?
  /// The checkpoint advanced (or the scan / backfill phase finished).
  public var completed = false
  public var phase: MailboxPhase = .unlinked
  public init() {}
}

public enum ConnectResult: Sendable, Equatable {
  case connected(address: String?)
  case cancelled
  case failed(ConnectFailure)
}

public enum ConnectFailure: String, Sendable, Equatable {
  case notConfigured = "not_configured"
  case offline
  /// The token response lacked the gmail.readonly scope or a refresh token.
  case permissionMissing = "permission_missing"
  case stateMismatch = "state_mismatch"
  case nonceMismatch = "nonce_mismatch"
  case stepUpFailed = "step_up_failed"
  case serverRefused = "server_refused"
  case keychain
  case google
}

public enum EmailView: Sendable, Equatable {
  case ready(subject: String, text: String)
  case nonHolder
  case reconnectRequired
  case gone
  case offline
}

public struct ScanSummary: Sendable, Equatable {
  public struct Card: Sendable, Equatable {
    public let card: CardKey
    public let count: Int
  }
  public var phase: MailboxPhase
  /// Staged rows grouped by (bank, last4), newest-count first.
  public var cards: [Card]
  /// Staged rows with no card (no template hit, or a template without a card field).
  public var withoutCard: Int
  public var stagedTotal: Int
  public var stagingFull: Bool
}

public struct MailboxStatus: Sendable, Equatable {
  public enum Hero: String, Sendable, Equatable {
    case working, catchingUp = "catching_up", needsYou = "needs_you", otherDevice = "other_device"
    case notConnected = "not_connected"
  }
  public struct SetAsideGroup: Sendable, Equatable {
    public let domain: String
    public let count: Int
    public let newestMs: Int64
  }
  public var hero: Hero
  public var phase: MailboxPhase
  public var address: String?
  public var lastSuccessAtMs: Int64?
  public var haltedOn: MailboxHaltCode?
  public var setAside: [SetAsideGroup]
  public var unreadable: Int
  public var health: [BankHealthRow]
  /// False when the server relays no wakes ("Updates when you open Hasala").
  public var watchActive: Bool
}

public actor MailboxEngine {
  public let config: MailboxEngineConfig
  let oauth: GoogleOAuthClient
  let tokens: RefreshingGmailTokenProvider
  let gmailHTTP: any HTTPExchange
  let store: any MailboxPersistence
  let ledger: any MailboxLedger
  let server: any MailboxServer
  let stepUp: any MailboxStepUp
  let categorizer: any IngestCategorizer
  let templates: [CompiledTemplate]
  let clock: any Clock
  let random: any RandomSource
  let sleep: @Sendable (Int64) async -> Void

  private var busy = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private var topic: String??
  /// Set when the last cycle saw the server's topic differ from the build's (diagnostics).
  public private(set) var topicMismatch = false

  public init(
    config: MailboxEngineConfig, oauth: GoogleOAuthClient, tokens: RefreshingGmailTokenProvider,
    gmailHTTP: any HTTPExchange, store: any MailboxPersistence, ledger: any MailboxLedger,
    server: any MailboxServer, stepUp: any MailboxStepUp, categorizer: any IngestCategorizer,
    templates: [CompiledTemplate], clock: any Clock, random: any RandomSource,
    sleep: @escaping @Sendable (Int64) async -> Void = { ms in try? await Task.sleep(for: .milliseconds(ms)) }
  ) {
    self.config = config
    self.oauth = oauth
    self.tokens = tokens
    self.gmailHTTP = gmailHTTP
    self.store = store
    self.ledger = ledger
    self.server = server
    self.stepUp = stepUp
    self.categorizer = categorizer
    self.templates = templates
    self.clock = clock
    self.random = random
    self.sleep = sleep
  }

  // MARK: - Serialization

  private func acquire() async {
    if !busy {
      busy = true
      return
    }
    await withCheckedContinuation { waiters.append($0) }
  }

  private func release() {
    if waiters.isEmpty {
      busy = false
    } else {
      waiters.removeFirst().resume()
    }
  }

  private func exclusive<T: Sendable>(_ body: () async -> T) async -> T {
    await acquire()
    defer { release() }
    return await body()
  }

  // MARK: - Connect, disconnect

  /// Connect Gmail (spec 04 §7.4): link challenge → OAuth with that nonce → code exchange →
  /// step-up `mailbox.link` over SHA-256(id_token) → `PUT /mailbox/link` → Keychain. A first
  /// connect then starts the scan over `backfillDays` (30, 90 or 365; §7.7); a reconnect or a
  /// takeover resumes the normal cycle from the kept watermark.
  public func connect(presenter: any GmailAuthSessionPresenter, backfillDays: Int) async -> ConnectResult {
    await exclusive { await connectLocked(presenter: presenter, backfillDays: backfillDays) }
  }

  private func connectLocked(presenter: any GmailAuthSessionPresenter, backfillDays: Int) async -> ConnectResult {
    guard oauth.config.isConfigured else { return .failed(.notConfigured) }
    let nonce: String
    do { nonce = try await server.linkChallenge() } catch .offline { return .failed(.offline) } catch {
      return .failed(.serverRefused)
    }
    let auth: GmailAuthorization
    let grant: GmailTokenGrant
    do throws(GmailOAuthError) {
      auth = try oauth.begin(nonce: nonce, random: random)
      let callback = try await presenter.authorize(url: auth.url, callbackScheme: oauth.config.redirectScheme)
      let code = try oauth.code(fromCallback: callback, for: auth)
      grant = try await oauth.exchange(code: code, auth: auth)
    } catch .cancelled {
      return .cancelled
    } catch .stateMismatch {
      return .failed(.stateMismatch)
    } catch .missingGrant {
      return .failed(.permissionMissing)
    } catch .offline {
      return .failed(.offline)
    } catch .notConfigured {
      return .failed(.notConfigured)
    } catch {
      return .failed(.google)
    }
    guard let idToken = grant.idToken, let claims = GoogleIDTokenClaims(idToken: idToken) else {
      return .failed(.google)
    }
    // The server checks the nonce for real (spec 02 §13.2); checking here too means a sheet that
    // came back from a different attempt fails before any step-up prompt.
    guard let n = claims.nonce, constantTimeEquals(Data(n.utf8), Data(nonce.utf8)) else {
      return .failed(.nonceMismatch)
    }
    let proof: JSONValue
    do { proof = try await stepUp.proof(kind: "mailbox.link", payloadHash: sha256(Data(idToken.utf8))) } catch {
      return .failed(.stepUpFailed)
    }
    do {
      _ = try await server.putLink(idToken: idToken, stepUp: proof)
    } catch .offline {
      return .failed(.offline)
    } catch {
      return .failed(.serverRefused)
    }
    do { try await tokens.install(grant: grant) } catch { return .failed(.keychain) }

    var s = (try? await store.loadState()) ?? MailboxState()
    s.address = claims.email
    s.haltedOn = nil
    s.haltedDetail = nil
    s.phaseBeforeHalt = nil
    s.lastHolderCheckAtMs = clock.nowMs()
    s.watchExpiresAtMs = nil  // a new link starts with no watch (spec 02 §13.2 step 3)
    if s.watermarkMs != nil {
      s.phase = .active
    } else if s.phase == .awaitingCards || s.phase == .authoringBackfill || s.phase == .scanning {
      // A reconnect mid-setup keeps its place.
    } else {
      s.phase = .scanning
      s.backfillDays = [30, 90, 365].contains(backfillDays) ? backfillDays : 90
      s.scanStartedMs = clock.nowMs()
      // h0 is captured before any listing (§7.7 step 2); best effort here, re-read by the scan.
      if let token = try? await tokens.accessToken(forceRefresh: false) {
        s.profileHistoryID = try? await gmail(token).profileHistoryID()
      }
    }
    do { try await store.commit(commitState(s)) } catch { return .failed(.keychain) }
    return .connected(address: claims.email)
  }

  /// Disconnect Gmail (Bank alerts › Disconnect): step-up `mailbox.unlink` → users.stop →
  /// revoke → `DELETE /mailbox/link` → delete the Keychain item → clear the mailbox tables.
  public func disconnect() async -> Bool {
    await exclusive {
      let proof: JSONValue
      do { proof = try await stepUp.proof(kind: "mailbox.unlink", payloadHash: nil) } catch { return false }
      if let token = try? await tokens.accessToken(forceRefresh: false) {
        try? await gmail(token).stop()
      }
      await tokens.revokeAndForget()
      do throws(MailboxServerError) {
        try await server.deleteLink(stepUp: proof)
      } catch .noLink {
        // Already gone server-side.
      } catch {
        return false
      }
      var c = MailboxCommit()
      c.clearAll = true
      c.state = MailboxState()
      do { try await store.commit(c) } catch { return false }
      return true
    }
  }

  // MARK: - The cycle

  /// One cycle (spec 04 §7.5). `deadlineMs` is in the engine clock's epoch ms; nil = foreground
  /// (no deadline). Never throws.
  public func runCycle(trigger: MailboxTrigger, deadlineMs: Int64? = nil) async -> CycleReport {
    await exclusive { await cycleLocked(trigger: trigger, deadlineMs: deadlineMs) }
  }

  private func cycleLocked(trigger: MailboxTrigger, deadlineMs: Int64?) async -> CycleReport {
    var report = CycleReport()
    guard var state = try? await store.loadState() else {
      report.haltedOn = .offline
      return report
    }
    report.phase = state.phase
    if state.phase == .halted {
      guard trigger == .retry else {
        report.haltedOn = state.haltedOn
        return report
      }
      state.phase = state.phaseBeforeHalt ?? .active
      state.haltedOn = nil
      state.haltedDetail = nil
      state.phaseBeforeHalt = nil
    }
    switch state.phase {
    case .unlinked, .otherDevice, .awaitingCards:
      return report
    case .reconnectRequired:
      guard trigger == .retry else { return report }
      state.phase = state.watermarkMs != nil ? .active : .scanning
    default: break
    }
    if templates.isEmpty { return await halt(&state, .templatesUnavailable, report) }

    let now = clock.nowMs()
    // 1. Holder check.
    if trigger == .launch || trigger == .retry || state.lastHolderCheckAtMs == nil
      || now - (state.lastHolderCheckAtMs ?? 0) >= config.holderCheckIntervalMs
    {
      do {
        switch try await server.linkStatus() {
        case .noLink:
          return await setPhase(&state, .reconnectRequired, halt: .reconnectRequired, report)
        case .holder(isThisDevice: false, _):
          await tokens.revokeAndForget()
          return await setPhase(&state, .otherDevice, halt: .notHolder, report)
        case .holder(isThisDevice: true, let watch):
          state.lastHolderCheckAtMs = now
          if let watch, state.watchExpiresAtMs == nil { state.watchExpiresAtMs = watch }
        }
      } catch {
        report.haltedOn = .offline
        return report
      }
    }

    // 2. Pull to head, so peers' ops are visible to dedup.
    do { try await ledger.syncToHead() } catch {
      report.haltedOn = .offline
      return report
    }

    // 3. Token.
    let token: AccessToken
    do { token = try await tokens.accessToken(forceRefresh: false) } catch .reconnectRequired {
      return await setPhase(&state, .reconnectRequired, halt: .reconnectRequired, report)
    } catch .notNow {
      return report
    } catch {
      report.haltedOn = .offline
      return report
    }
    let gmail = gmail(token)

    // 4. Load.
    let trusted = BankDomains.effectiveTrusted(await ledger.senderTrust())
    state.lastCycleAtMs = now

    // 5. Watch renewal (scan and active phases).
    await renewWatch(gmail, &state, now: now)

    switch state.phase {
    case .scanning:
      return await scan(gmail, &state, trusted: trusted, deadlineMs: deadlineMs, report)
    case .authoringBackfill:
      return await authorBackfill(gmail, &state, trusted: trusted, deadlineMs: deadlineMs, report)
    default: break
    }

    // 6. Change detector.
    let h0: String
    do { h0 = try await gmail.profileHistoryID() } catch let e {
      return await gmailFailure(e, &state, report)
    }
    if trusted.isEmpty {
      // Nothing is listed when no sender is trusted (03c §7.2); not an error.
      state.profileHistoryID = h0
      state.lastSuccessAtMs = now
      if state.watermarkMs == nil { state.watermarkMs = now }
      report.completed = true
      return await finish(&state, report)
    }
    if h0 == state.profileHistoryID, state.watermarkMs != nil,
      ![.refresh, .launch, .retry].contains(trigger)
    {
      state.lastSuccessAtMs = now
      report.completed = true
      return await finish(&state, report)
    }
    let t0 = now

    // 7. List and account.
    let since = BankDomains.sinceSec(watermarkMs: state.watermarkMs ?? (now - 30 * 86_400_000))
    var run = Run(trusted: trusted, cards: (await ledger.knownCards()).merging(state.confirmedCards) { a, _ in a })
    let listed: [String]
    let exhausted: Bool
    do {
      (listed, exhausted) = try await list(gmail, domains: trusted, sinceSec: since, maxPages: config.maxListPages)
    } catch let e {
      return await gmailFailure(e, &state, report)
    }
    report.listed = listed.count
    var cut = !exhausted
    do {
      cut = try await process(
        gmail, ids: listed, mode: .author, run: &run, report: &report, deadlineMs: deadlineMs) || cut
    } catch let e as GmailAPIError {
      return await gmailFailure(e, &state, report)
    } catch {
      report.haltedOn = .offline
      return await finish(&state, report)
    }

    // 8. Flush.
    switch await ledger.flush() {
    case .accountFull:
      return await halt(&state, .accountFull, report)
    case .failed:
      report.haltedOn = .offline
      return await finish(&state, report)
    case .flushed: break
    }

    // 9. Advance only when complete.
    var c = MailboxCommit()
    if !cut {
      state.watermarkMs = max(state.watermarkMs ?? 0, t0)
      state.profileHistoryID = h0
      state.lastSuccessAtMs = clock.nowMs()
      state.quotaStrikes = 0
      c.pruneAccountedBelowMs = (state.watermarkMs ?? 0) - BankDomains.overlapMs - 86_400_000
      report.completed = true
    }
    c.state = state
    try? await store.commit(c)
    report.phase = state.phase
    return report
  }

  // MARK: - First connect (§7.7)

  private func scan(
    _ gmail: GmailClient, _ state: inout MailboxState, trusted: [String], deadlineMs: Int64?, _ report: CycleReport
  ) async -> CycleReport {
    var report = report
    let started = state.scanStartedMs ?? clock.nowMs()
    if state.scanStartedMs == nil { state.scanStartedMs = started }
    if state.profileHistoryID == nil {
      do { state.profileHistoryID = try await gmail.profileHistoryID() } catch let e {
        return await gmailFailure(e, &state, report)
      }
    }
    let days = Int64(state.backfillDays ?? 90)
    let since = max(0, (started - days * 86_400_000) / 1000)
    var run = Run(trusted: trusted, cards: [:])
    let listed: [String]
    let exhausted: Bool
    do {
      (listed, exhausted) = try await list(gmail, domains: trusted, sinceSec: since, maxPages: config.maxListPages)
    } catch let e {
      return await gmailFailure(e, &state, report)
    }
    report.listed = listed.count
    var cut = !exhausted
    do {
      cut = try await process(gmail, ids: listed, mode: .stage, run: &run, report: &report, deadlineMs: deadlineMs) || cut
    } catch let e as GmailAPIError {
      return await gmailFailure(e, &state, report)
    } catch {
      report.haltedOn = .offline
      return await finish(&state, report)
    }
    if run.stagingFull {
      report.haltedOn = .stagingFull
      state.scanRemainder = true
      cut = false  // the cap ends the listing; the remainder is authored after confirmation
    }
    if !cut {
      state.phase = .awaitingCards
      report.completed = true
    }
    return await finish(&state, report)
  }

  /// "Are these your cards?" (§7.7 step 4): the staged rows grouped by card.
  public func scanSummary() async -> ScanSummary {
    await exclusive {
      let state = (try? await store.loadState()) ?? MailboxState()
      let staged = (try? await store.staged(limit: Int.max)) ?? []
      var counts: [CardKey: Int] = [:]
      var without = 0
      for m in staged {
        if m.fields != nil && m.templateHasCardField && !m.last4.isEmpty {
          counts[CardKey(bank: m.bank, last4: m.last4), default: 0] += 1
        } else {
          without += 1
        }
      }
      let cards = counts.map { ScanSummary.Card(card: $0.key, count: $0.value) }
        .sorted { $0.count != $1.count ? $0.count > $1.count : $0.card < $1.card }
      return ScanSummary(
        phase: state.phase, cards: cards, withoutCard: without, stagedTotal: staged.count,
        stagingFull: staged.count >= config.stagingCap)
    }
  }

  /// "Continue with {k} cards" (§7.7 step 5): authors the card ops, then the staged transactions
  /// with the gate applied ("not mine" cards stay in review; nothing is dropped).
  public func confirmCards(_ decisions: [CardDecision], deadlineMs: Int64? = nil) async -> CycleReport {
    await exclusive {
      var report = CycleReport()
      guard var state = try? await store.loadState() else { return report }
      report.phase = state.phase
      guard state.phase == .awaitingCards else { return report }
      do { try await ledger.authorCards(decisions) } catch {
        report.haltedOn = .offline
        return report
      }
      for d in decisions { state.confirmedCards[d.card] = d.state }
      state.phase = .authoringBackfill
      try? await store.commit(commitState(state))
      return await cycleLocked(trigger: .refresh, deadlineMs: deadlineMs)
    }
  }

  private func authorBackfill(
    _ gmail: GmailClient, _ state: inout MailboxState, trusted: [String], deadlineMs: Int64?, _ report: CycleReport
  ) async -> CycleReport {
    var report = report
    let cards = (await ledger.knownCards()).merging(state.confirmedCards) { _, confirmed in confirmed }
    while true {
      if let d = deadlineMs, clock.nowMs() >= d - config.authoringMarginMs { break }
      guard let batch = try? await store.staged(limit: config.backfillBatch), !batch.isEmpty else { break }
      var c = MailboxCommit()
      let at = clock.nowMs()
      for m in batch {
        c.unstage.append(m.messageID)
        if await ledger.isIngested(m.ingestID) {
          c.accounted.append(AccountedRecord(messageID: m.messageID, outcome: .dup, internalDateMs: m.internalDateMs, atMs: at))
          report.dup += 1
          continue
        }
        let draft = MessageDisposer.finalize(m, grantID: config.grantID, cards: cards, categorizer: categorizer)
        c.drafts.append(draft)
        c.accounted.append(AccountedRecord(messageID: m.messageID, outcome: .op, internalDateMs: m.internalDateMs, atMs: at))
        report.ops += 1
        if draft.needsReview { report.review += 1 }
      }
      do { try await store.commit(c) } catch {
        report.haltedOn = .offline
        return await finish(&state, report)
      }
    }
    switch await ledger.flush() {
    case .accountFull: return await halt(&state, .accountFull, report)
    case .failed:
      report.haltedOn = .offline
      return await finish(&state, report)
    case .flushed: break
    }
    if ((try? await store.stagedCount()) ?? 1) == 0 && state.scanRemainder {
      // §7.7 step 7: the scan stopped at the staging cap; list the rest of its window and author
      // it directly with the now-known cards (the accounted set skips what is already done).
      let days = Int64(state.backfillDays ?? 90)
      let since = max(0, ((state.scanStartedMs ?? clock.nowMs()) - days * 86_400_000) / 1000)
      var run = Run(trusted: trusted, cards: cards)
      do {
        let (ids, exhausted) = try await list(gmail, domains: trusted, sinceSec: since, maxPages: config.maxListPages)
        report.listed += ids.count
        let cut = try await process(gmail, ids: ids, mode: .author, run: &run, report: &report, deadlineMs: deadlineMs)
        if exhausted && !cut { state.scanRemainder = false }
      } catch let e as GmailAPIError {
        return await gmailFailure(e, &state, report)
      } catch {
        report.haltedOn = .offline
        return await finish(&state, report)
      }
      switch await ledger.flush() {
      case .accountFull: return await halt(&state, .accountFull, report)
      case .failed:
        report.haltedOn = .offline
        return await finish(&state, report)
      case .flushed: break
      }
    }
    if ((try? await store.stagedCount()) ?? 1) == 0 && !state.scanRemainder {
      // §7.7 step 6: the normal cycle's 2-day overlap catches up what arrived during the scan.
      state.watermarkMs = state.scanStartedMs ?? clock.nowMs()
      state.phase = .active
      state.lastSuccessAtMs = clock.nowMs()
      report.completed = true
    }
    return await finish(&state, report)
  }

  // MARK: - Add a sender (§7.8)

  /// Trusts a typed sender domain (`sender_trust_set`) and imports its mail in the connect
  /// window through the normal gates, without moving the watermark.
  public func importSender(_ typed: String) async -> Result<CycleReport, BankDomains.TypedDomainError> {
    let domain: String
    do { domain = try BankDomains.normalizeTyped(typed) } catch { return .failure(error) }
    return .success(
      await exclusive {
        var report = CycleReport()
        guard var state = try? await store.loadState() else { return report }
        report.phase = state.phase
        do { try await ledger.authorSenderTrust(domain: domain, trusted: true) } catch {
          report.haltedOn = .offline
          return report
        }
        guard state.phase == .active else { return report }  // the scan or next cycle lists it
        let token: AccessToken
        do { token = try await tokens.accessToken(forceRefresh: false) } catch {
          report.haltedOn = .reconnectRequired
          return report
        }
        let gmail = gmail(token)
        var trusted = BankDomains.effectiveTrusted(await ledger.senderTrust())
        if !trusted.contains(domain) { trusted.append(domain) }
        let days = Int64(state.backfillDays ?? 90)
        let since = max(0, (clock.nowMs() - days * 86_400_000) / 1000)
        var run = Run(trusted: trusted, cards: (await ledger.knownCards()).merging(state.confirmedCards) { a, _ in a })
        do {
          let (ids, _) = try await list(gmail, domains: [domain], sinceSec: since, maxPages: config.importMaxPages)
          report.listed = ids.count
          _ = try await process(gmail, ids: ids, mode: .author, run: &run, report: &report, deadlineMs: nil)
        } catch let e as GmailAPIError {
          return await gmailFailure(e, &state, report)
        } catch {
          report.haltedOn = .offline
          return report
        }
        if await ledger.flush() == .accountFull { return await halt(&state, .accountFull, report) }
        report.completed = true
        return report
      })
  }

  // MARK: - View the email (§7.8)

  /// Re-fetches one message by id and returns its normalized text (never HTML; raw mail is
  /// never persisted). Holder only.
  public func viewEmail(messageID: String) async -> EmailView {
    await exclusive {
      let state = (try? await store.loadState()) ?? MailboxState()
      switch state.phase {
      case .otherDevice, .unlinked: return .nonHolder
      case .reconnectRequired: return .reconnectRequired
      default: break
      }
      let token: AccessToken
      do throws(GmailAuthError) { token = try await tokens.accessToken(forceRefresh: false) } catch .reconnectRequired {
        return .reconnectRequired
      } catch {
        return .offline
      }
      let raw: GmailRawMessage
      do throws(GmailAPIError) { raw = try await gmail(token).messageRaw(id: messageID) } catch let e {
        if let s = e.status, s == 404 || s == 410 || s < 400 { return .gone }
        if let s = e.status, s == 401 || s == 403 { return .reconnectRequired }
        return .offline
      }
      guard let bytes = try? Base64.decodeURL(raw.rawBase64URL) else { return .gone }
      let ms = Int64(raw.internalDate) ?? 0
      guard let n = try? Normalizer.normalize(version: Normalizer.currentVersion, raw: [UInt8](bytes), receivedAtMs: ms)
      else { return .ready(subject: "", text: "") }
      return .ready(subject: n.subject, text: n.text)
    }
  }

  // MARK: - Status (§7.10)

  public func status() async -> MailboxStatus {
    let state = (try? await store.loadState()) ?? MailboxState()
    let setAside = (try? await store.setAsideRecords()) ?? []
    var groups: [String: (Int, Int64)] = [:]
    for r in setAside {
      let g = groups[r.domain] ?? (0, 0)
      groups[r.domain] = (g.0 + 1, max(g.1, r.internalDateMs))
    }
    let hero: MailboxStatus.Hero
    switch state.phase {
    case .unlinked: hero = .notConnected
    case .otherDevice: hero = .otherDevice
    case .reconnectRequired, .halted: hero = .needsYou
    case .scanning, .awaitingCards, .authoringBackfill: hero = .catchingUp
    case .active:
      let recent = state.lastSuccessAtMs.map { clock.nowMs() - $0 < 6 * 3_600_000 } ?? false
      hero = recent ? .working : .catchingUp
    }
    return MailboxStatus(
      hero: hero, phase: state.phase, address: state.address, lastSuccessAtMs: state.lastSuccessAtMs,
      haltedOn: state.haltedOn,
      setAside: groups.map { .init(domain: $0.key, count: $0.value.0, newestMs: $0.value.1) }.sorted {
        $0.newestMs > $1.newestMs
      }, unreadable: ((try? await store.unreadableRecords()) ?? []).count,
      health: (try? await store.bankHealth()) ?? [], watchActive: state.watchExpiresAtMs != nil)
  }

  // MARK: - Internals

  func gmail(_ token: AccessToken) -> GmailClient {
    GmailClient(http: gmailHTTP, accessToken: token.value, base: config.gmailBase)
  }

  struct Run {
    var trusted: [String]
    var cards: [CardKey: CardState]
    var width = 6
    var stagingFull = false
    var saw429 = false
  }

  enum Mode { case author, stage }

  enum Fetched: Sendable {
    case setAside(id: String, domain: String, internalDateMs: Int64)
    case raw(id: String, from: String, raw: GmailRawMessage)
    case gone(id: String)
    case failed(id: String, error: GmailAPIError)
  }

  /// Lists every group, page by page. Returns the ids (deduplicated, in listing order) and
  /// whether every group's listing was exhausted.
  func list(_ gmail: GmailClient, domains: [String], sinceSec: Int64, maxPages: Int) async throws(GmailAPIError)
    -> ([String], Bool)
  {
    var ids: [String] = []
    var seen = Set<String>()
    var exhausted = true
    for group in BankDomains.groups(domains) {
      let q = BankDomains.query(group, sinceSec: sinceSec)
      var token: String?
      var pages = 0
      repeat {
        let page = try await gmail.messagesList(query: q, pageToken: token)
        for id in page.ids where seen.insert(id).inserted { ids.append(id) }
        token = page.nextPageToken
        pages += 1
      } while token != nil && pages < maxPages
      if token != nil { exhausted = false }
    }
    return (ids, exhausted)
  }

  /// Steps 7a-7g over `ids`. Returns whether the run was cut short (deadline or staging cap).
  /// Throws only a fatal Gmail error (401/403 or a transient one that outlived its retries).
  func process(
    _ gmail: GmailClient, ids all: [String], mode: Mode, run: inout Run, report: inout CycleReport,
    deadlineMs: Int64?
  ) async throws -> Bool {
    let accounted = (try? await store.accounted(among: all)) ?? []
    let projected = await ledger.projectedMessageIDs(among: all)
    let todo = all.filter { !accounted.contains($0) && !projected.contains($0) }
    var i = 0
    run.width = config.downloadWidth
    while i < todo.count {
      if let d = deadlineMs, clock.nowMs() >= d - config.authoringMarginMs { return true }
      var width = run.width
      if mode == .stage {
        let room = config.stagingCap - ((try? await store.stagedCount()) ?? 0)
        if room <= 0 {
          run.stagingFull = true
          return true
        }
        width = min(width, room)
      }
      let chunk = Array(todo[i..<min(i + width, todo.count)])
      i += chunk.count
      let results = await fetchChunk(gmail, chunk, bank: run.trusted)
      // A 429 anywhere narrows the pipe to one request for the rest of the run (fetch.ts).
      if results.contains(where: \.rateLimited) {
        run.width = 1
        run.saw429 = true
      }
      for r in results {
        try await account(r.fetched, mode: mode, run: &run, report: &report)
      }
    }
    return false
  }

  struct FetchResult: Sendable {
    let fetched: Fetched
    let rateLimited: Bool
  }

  /// Downloads a chunk concurrently; the results come back in listing order, so accounting
  /// stays strictly sequential (fetch.ts: only the network is overlapped).
  func fetchChunk(_ gmail: GmailClient, _ ids: [String], bank: [String]) async -> [FetchResult] {
    let backoff = config.retryBackoffMs
    let sleep = self.sleep
    return await withTaskGroup(of: (Int, FetchResult).self) { group in
      for (n, id) in ids.enumerated() {
        group.addTask {
          (n, await Self.fetchOne(gmail, id, bank: bank, backoff: backoff, sleep: sleep))
        }
      }
      var out: [(Int, FetchResult)] = []
      for await r in group { out.append(r) }
      return out.sorted { $0.0 < $1.0 }.map(\.1)
    }
  }

  /// 7a-7c for one id, with the retry classes of fetch.ts.
  static func fetchOne(
    _ gmail: GmailClient, _ id: String, bank: [String], backoff: [Int64], sleep: @Sendable (Int64) async -> Void
  ) async -> FetchResult {
    var rateLimited = false
    func attempt<T: Sendable>(_ op: () async throws(GmailAPIError) -> T) async -> Result<T, GmailAPIError> {
      var n = 0
      while true {
        do { return .success(try await op()) } catch let e {
          let s = e.status
          if s == 429 { rateLimited = true }
          let transient = e == .offline || s == 429 || (s ?? 0) >= 500
          if !transient || n >= backoff.count { return .failure(e) }
          await sleep(backoff[n])
          n += 1
        }
      }
    }
    func gone(_ e: GmailAPIError) -> Bool {
      guard let s = e.status else { return false }
      return s == 404 || s == 410 || s < 400
    }

    func done(_ f: Fetched) -> FetchResult { FetchResult(fetched: f, rateLimited: rateLimited) }
    let meta: GmailMessageMetadata
    switch await attempt({ () async throws(GmailAPIError) in try await gmail.messageMetadata(id: id) }) {
    case .success(let m): meta = m
    case .failure(let e): return done(gone(e) ? .gone(id: id) : .failed(id: id, error: e))
    }
    // 7b: neither the claimed nor the verified domain is a bank domain: set aside, no body.
    let claimed = BankDomains.domainOf(meta.from)
    let analysis = AuthResults.analyze(meta.headerBlock)
    let verified = analysis.verdict.trusted ? (analysis.domain ?? "") : ""
    if !BankDomains.isMember(claimed, of: bank) && !BankDomains.isMember(verified, of: bank) {
      return done(
        .setAside(id: id, domain: verified.isEmpty ? claimed : verified, internalDateMs: Int64(meta.internalDate) ?? 0))
    }
    switch await attempt({ () async throws(GmailAPIError) in try await gmail.messageRaw(id: id) }) {
    case .success(let raw): return done(.raw(id: id, from: meta.from, raw: raw))
    case .failure(let e): return done(gone(e) ? .gone(id: id) : .failed(id: id, error: e))
    }
  }

  /// 7d-7f for one fetched message: one commit (op + accounting, or the accounting alone).
  func account(_ f: Fetched, mode: Mode, run: inout Run, report: inout CycleReport) async throws {
    let at = clock.nowMs()
    var c = MailboxCommit()
    switch f {
    case .failed(_, let error):
      throw error
    case .gone(let id):
      report.unreadable += 1
      c.unreadable.append(UnreadableRecord(messageID: id, reason: .gone, domain: nil, internalDateMs: nil, atMs: at))
      c.accounted.append(AccountedRecord(messageID: id, outcome: .gone, internalDateMs: at, atMs: at))
    case .setAside(let id, let domain, let date):
      report.setAside += 1
      c.setAside.append(SetAsideRecord(messageID: id, domain: domain, internalDateMs: date, atMs: at))
      c.accounted.append(AccountedRecord(messageID: id, outcome: .setAside, internalDateMs: date, atMs: at))
    case .raw(let id, let from, let raw):
      report.fetched += 1
      let dateMs = Int64(raw.internalDate)
      func unreadable(_ r: UnreadableReason) {
        report.unreadable += 1
        c.unreadable.append(
          UnreadableRecord(messageID: id, reason: r, domain: BankDomains.domainOf(from), internalDateMs: dateMs, atMs: at))
        c.accounted.append(AccountedRecord(messageID: id, outcome: .unreadable, internalDateMs: dateMs ?? at, atMs: at))
      }
      guard let bytes = try? Base64.decodeURL(raw.rawBase64URL) else {
        unreadable(.undecodable)
        break
      }
      if bytes.count >= config.maxMessageBytes {
        unreadable(.overCap)
        break
      }
      guard let date = dateMs, date > 0, Instant.iso(date) != nil else {
        unreadable(.badDate)
        break
      }
      let parsed = MessageDisposer.parse(
        raw: [UInt8](bytes), messageID: id, internalDateMs: date, topLevelFrom: from, templates: templates,
        bankDomains: run.trusted, trusted: run.trusted)
      switch parsed {
      case .setAside(let domain):
        report.setAside += 1
        c.setAside.append(SetAsideRecord(messageID: id, domain: domain, internalDateMs: date, atMs: at))
        c.accounted.append(AccountedRecord(messageID: id, outcome: .setAside, internalDateMs: date, atMs: at))
      case .mail(let m):
        if await ledger.isIngested(m.ingestID) {
          report.dup += 1
          c.accounted.append(AccountedRecord(messageID: id, outcome: .dup, internalDateMs: date, atMs: at))
          break
        }
        c.healthBumps.append((BankDomains.domainOf(from), date))
        switch mode {
        case .stage:
          report.staged += 1
          c.stage.append(m)
        case .author:
          let draft = MessageDisposer.finalize(m, grantID: config.grantID, cards: run.cards, categorizer: categorizer)
          report.ops += 1
          if draft.needsReview { report.review += 1 }
          c.drafts.append(draft)
          c.accounted.append(AccountedRecord(messageID: id, outcome: .op, internalDateMs: date, atMs: at))
        }
      }
    }
    try await store.commit(c)
  }

  func renewWatch(_ gmail: GmailClient, _ state: inout MailboxState, now: Int64) async {
    if topic == nil {
      do {
        let t = try await server.watchTopic()
        topic = .some(t)
        topicMismatch = t != nil && config.buildTopic != nil && config.buildTopic != "unset" && t != config.buildTopic
      } catch {
        return  // offline: renewed on a later cycle
      }
    }
    guard let t = topic ?? nil else { return }
    if let exp = state.watchExpiresAtMs, exp > now + config.watchRenewWindowMs { return }
    guard let w = try? await gmail.watch(topicName: t) else { return }
    do {
      try await server.putWatch(expiresAtMs: w.expirationMs)
      state.watchExpiresAtMs = w.expirationMs
    } catch {
      // Reported next cycle; the watch itself is live at Google.
    }
  }

  func gmailFailure(_ e: GmailAPIError, _ state: inout MailboxState, _ report: CycleReport) async -> CycleReport {
    var report = report
    switch e.status {
    case 401?:
      // A stale access token: one forced refresh decides between a blip and a dead grant.
      await tokens.invalidate()
      do { _ = try await tokens.accessToken(forceRefresh: true) } catch .reconnectRequired {
        return await setPhase(&state, .reconnectRequired, halt: .reconnectRequired, report)
      } catch {}
      report.haltedOn = .gmail
    case 403?:
      return await setPhase(&state, .reconnectRequired, halt: .reconnectRequired, report)
    case 429?:
      state.quotaStrikes += 1
      report.haltedOn = state.quotaStrikes >= 3 ? .quota : .gmail
    case nil:
      report.haltedOn = .offline
    default:
      report.haltedOn = .gmail
    }
    return await finish(&state, report)
  }

  func setPhase(_ state: inout MailboxState, _ phase: MailboxPhase, halt code: MailboxHaltCode, _ report: CycleReport)
    async -> CycleReport
  {
    var report = report
    state.phase = phase
    state.haltedOn = code
    report.haltedOn = code
    return await finish(&state, report)
  }

  func halt(_ state: inout MailboxState, _ code: MailboxHaltCode, _ report: CycleReport) async -> CycleReport {
    var report = report
    if state.phase != .halted { state.phaseBeforeHalt = state.phase }
    state.phase = .halted
    state.haltedOn = code
    report.haltedOn = code
    return await finish(&state, report)
  }

  func finish(_ state: inout MailboxState, _ report: CycleReport) async -> CycleReport {
    var report = report
    try? await store.commit(commitState(state))
    report.phase = state.phase
    return report
  }

  func commitState(_ s: MailboxState) -> MailboxCommit {
    var c = MailboxCommit()
    c.state = s
    return c
  }
}
