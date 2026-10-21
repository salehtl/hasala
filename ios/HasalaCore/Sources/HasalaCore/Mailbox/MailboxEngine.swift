// MailboxEngine: the mailbox lane on the holder iPhone (spec 04 §7.4-§7.9; port of fetch.ts
// `runFetchCycle`, rebuilt on a sender-filtered listing, PO G). The mail service is a
// `MailProvider` (Gmail: `GmailProvider`); everything below it is the provider's wire.
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
//   - 404/410 is `gone` (accounted, the cycle moves past it); 5xx/transport retry 400 ms then
//     1200 ms, a 429 retries after 1, 2, 4 and 8 s, and a 429 narrows the download width to 1
//     (a 403 whose reason is a rate or quota limit counts as a 429, the provider's MailSource);
//     a 429 or 503 that names
//     its `Retry-After` stops the run at once and no cycle starts before it has passed; 401/403
//     is fatal; any other 4xx halts;
//   - 413 on flush halts `account_full` with the watermark intact;
//   - no token is `reconnect_required`, an unreadable Keychain is "not now";
//   - a deadline or background-processing run lists page by page, downloading each page before
//     listing the next, so a short run always makes progress;
//   - an interruption of the first-connect setup (reconnect, takeover, halt) resumes the phase it
//     cut short (`halted_detail` "resume:<phase>"), so a backfill is never restarted as a scan;
//   - there is no cards step: a finished scan authors what it staged in the same run, and a card
//     the ledger doesn't know files like a known one (`awaiting_cards` survives only as a state
//     an older build may have stored; the next cycle authors it).
import CoreJSON
import CoreMail
import CoreNorm
import CorePrimitives
import CoreTemplate
import CoreTime
import Foundation

public enum MailboxDisconnectOutcome: Sendable, Equatable {
  case failed
  case disconnected
  case removed(Int)
  case disconnectedRemoveFailed
  case otherDevice
}

public struct MailboxEngineConfig: Sendable {
  /// `provenance.grant_id`: the account's user id (one link per account).
  public var grantID: String
  /// `BuildInfo.gmailPubSubTopic`; the server's `meta.gmail_watch_topic` wins on a mismatch.
  public var buildTopic: String?
  public var maxMessageBytes = MailboxLimits.maxMessageBytes
  public var stagingCap = 5_000
  public var holderCheckIntervalMs: Int64 = 10 * 60_000
  public var accountFullRetryMs: Int64 = 15 * 60_000
  /// Authoring stops this long before the deadline (§3).
  public var authoringMarginMs: Int64 = 5_000
  public var backfillBatch = 200
  public var firstScanCommitEvery = 25
  /// Downloads in flight at once. Each message is two `messages.get` calls (5 quota units each)
  /// against Gmail's 250 units per user per second; 6 at once on a fast link went over it.
  public var downloadWidth = 4
  public var retryBackoffMs: [Int64] = [400, 1_200]
  /// The waits before each retry of a rate-limited (429) download: Google's limit is a moving
  /// average, so the 400 ms / 1.2 s blip retries above only meet it again (exponential, 15 s).
  public var rateLimitBackoffMs: [Int64] = [1_000, 2_000, 4_000, 8_000]
  /// The first scan's waits after a cycle that stopped on a passing condition without reading
  /// anything (`runFirstScan`); it gives up after the last one.
  public var firstScanStallWaitsMs: [Int64] = [2_000, 5_000, 15_000, 30_000]
  /// Renew the watch when it expires within this window (§7.5 step 5).
  public var watchRenewWindowMs: Int64 = 3 * 86_400_000
  public var maxListPages = 100
  public var messageStrikeLimit = 3
  /// The Gmail API base of the `oauth:gmailHTTP:` initializer's `GmailProvider`.
  public var gmailBase = GmailClient.defaultBase

  public init(grantID: String, buildTopic: String? = nil) {
    self.grantID = grantID
    self.buildTopic = buildTopic
  }

  public func grantID(provider: MailProviderID, address: String?) -> String {
    guard let address, !address.isEmpty else { return grantID }
    var key = Data(grantID.utf8)
    key.append(0)
    key.append(contentsOf: provider.rawValue.utf8)
    key.append(0)
    key.append(contentsOf: Self.normalized(address).utf8)
    return "\(grantID)/mbx-\(Hex.encode(sha256(key).prefix(16)))"
  }

  static func normalized(_ address: String) -> String {
    let bytes = Array(address.utf8)
    let blank: Set<UInt8> = [0x20, 0x09, 0x0d, 0x0a]
    guard let first = bytes.firstIndex(where: { !blank.contains($0) }),
      let last = bytes.lastIndex(where: { !blank.contains($0) })
    else { return "" }
    let folded = bytes[first...last].map { (0x41...0x5a).contains($0) ? $0 + 0x20 : $0 }
    return String(decoding: folded, as: UTF8.self)
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
  /// Authored rows by `category_source.kind` ("rule", "dictionary", "none", ... ; unparsed rows
  /// count as "unparsed"), for "264 transactions, sorted." summaries.
  public var sortedBy: [String: Int] = [:]
  /// Authored rows that land in the review deck: needs review, or no category.
  public var toReview = 0
  public var haltedOn: MailboxHaltCode?
  /// The checkpoint advanced (or the scan / backfill phase finished).
  public var completed = false
  public var phase: MailboxPhase = .unlinked
  public init() {}

  mutating func count(_ d: MailboxIngestDraft) {
    ops += 1
    if d.needsReview { review += 1 }
    if d.needsReview || d.payload["category"] == nil { toReview += 1 }
    let kind =
      d.payload["unparsed"] == .bool(true) ? "unparsed" : (d.payload["category_source"]?["kind"]?.stringValue ?? "none")
    sortedBy[kind, default: 0] += 1
  }
}

/// Progress of a scan or backfill, for the first-scan board (Paper FR2-0: "182 of 268 alerts").
public struct MailboxProgress: Sendable, Equatable {
  public enum Stage: Sendable, Equatable {
    case listing, downloading, authoring, done
    case failed(MailboxHaltCode)
  }
  public var stage: Stage
  public var done: Int
  public var total: Int
  public init(stage: Stage, done: Int, total: Int) {
    self.stage = stage
    self.done = done
    self.total = total
  }
}

public enum ConnectResult: Sendable, Equatable {
  case connected(address: String?, anotherAddress: Bool = false, retired: MailboxRetireOutcome? = nil)
  case cancelled
  case declined
  case failed(ConnectFailure)
}

public enum MailboxRetireOutcome: Sendable, Equatable {
  case removed(Int?)
  case failed
}

public struct MailboxSwitchQuestion: Sendable, Equatable {
  public var oldAddress: String
  public var newAddress: String
  public var transactions: Int?
  public var edited: Int
  public var oldHasNoMailbox: Bool

  public init(oldAddress: String, newAddress: String, transactions: Int?, edited: Int, oldHasNoMailbox: Bool) {
    self.oldAddress = oldAddress
    self.newAddress = newAddress
    self.transactions = transactions
    self.edited = edited
    self.oldHasNoMailbox = oldHasNoMailbox
  }
}

public enum MailboxSwitchChoice: Sendable, Equatable {
  case keep, remove, cancel
}

public typealias MailboxSwitchConfirm = @Sendable (MailboxSwitchQuestion) async -> MailboxSwitchChoice

public enum ConnectFailure: String, Sendable, Equatable {
  case notConfigured = "not_configured"
  case offline
  /// The token response lacked the mail-read scope (gmail.readonly) or a refresh token.
  case permissionMissing = "permission_missing"
  /// The signed-in account has no mailbox the provider's API reads (Outlook's
  /// `MailboxNotEnabledForRESTAPI`). Nothing was linked.
  case noMailbox = "no_mailbox"
  case stateMismatch = "state_mismatch"
  case nonceMismatch = "nonce_mismatch"
  case stepUpFailed = "step_up_failed"
  case serverRefused = "server_refused"
  case mailboxInUse = "mailbox_in_use"
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
  public var unlisted: [String] = []
  public var unparsedSenders: [String: String] = [:]
}

public actor MailboxEngine {
  public let config: MailboxEngineConfig
  public let provider: any MailProvider
  let tokens: RefreshingMailTokenProvider
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
  private var onProgress: (@Sendable (MailboxProgress) -> Void)?
  private var onCommit: (@Sendable () -> Void)?
  private var scanTotal = 0
  /// Consecutive cycles that ended on a 429 (`quota` after 3); process-local.
  private var quotaStrikes = 0
  private var waiters: [CheckedContinuation<Void, Never>] = []
  /// The server's push settings for this provider (`meta`): nil until read; `.none` when the
  /// server relays no wakes.
  private var push: MailboxPushConfig?
  /// When `push` was last read (engine clock).
  private var pushReadAtMs: Int64 = 0
  /// Set when the last cycle saw the server's topic differ from the build's (diagnostics).
  public private(set) var topicMismatch = false
  /// No cycle starts before this (engine clock): the provider's last `Retry-After`. Process-local.
  private var notBeforeMs: Int64 = 0
  /// `runFirstScan` is driving: its passing stops are not `.failed` progress.
  private var firstScanRunning = false
  public private(set) var stopped = false
  private var strikes: [String: Int] = [:]

  /// `tokens` must refresh through `provider.oauth` and keep the provider's Keychain item.
  public init(
    config: MailboxEngineConfig, provider: any MailProvider, tokens: RefreshingMailTokenProvider,
    store: any MailboxPersistence, ledger: any MailboxLedger,
    server: any MailboxServer, stepUp: any MailboxStepUp, categorizer: any IngestCategorizer,
    templates: [CompiledTemplate], clock: any Clock, random: any RandomSource,
    sleep: @escaping @Sendable (Int64) async -> Void = { ms in try? await Task.sleep(for: .milliseconds(ms)) }
  ) {
    self.config = config
    self.provider = provider
    self.tokens = tokens
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

  /// The Gmail lane: a `GmailProvider` over `oauth` and `gmailHTTP` (at `config.gmailBase`).
  public init(
    config: MailboxEngineConfig, oauth: GoogleOAuthClient, tokens: RefreshingMailTokenProvider,
    gmailHTTP: any HTTPExchange, store: any MailboxPersistence, ledger: any MailboxLedger,
    server: any MailboxServer, stepUp: any MailboxStepUp, categorizer: any IngestCategorizer,
    templates: [CompiledTemplate], clock: any Clock, random: any RandomSource,
    sleep: @escaping @Sendable (Int64) async -> Void = { ms in try? await Task.sleep(for: .milliseconds(ms)) }
  ) {
    self.init(
      config: config, provider: GmailProvider(oauth: oauth, http: gmailHTTP, base: config.gmailBase), tokens: tokens,
      store: store, ledger: ledger, server: server, stepUp: stepUp, categorizer: categorizer, templates: templates,
      clock: clock, random: random, sleep: sleep)
  }

  /// Receives scan and backfill progress (called on the engine's executor; hop to the UI).
  public func setProgressHandler(_ h: (@Sendable (MailboxProgress) -> Void)?) { onProgress = h }

  public func setCommitHandler(_ h: (@Sendable () -> Void)?) { onCommit = h }

  func emit(_ stage: MailboxProgress.Stage, _ done: Int, _ total: Int) {
    onProgress?(MailboxProgress(stage: stage, done: done, total: total))
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

  public func stop() async {
    stopped = true
    await acquire()
    release()
  }

  public func resume() {
    stopped = false
  }

  // MARK: - Connect, disconnect

  /// Connect the provider's mailbox (spec 04 §7.4): link challenge → OAuth with that nonce → code exchange →
  /// step-up `mailbox.link` over SHA-256(id_token) → `PUT /mailbox/link` → Keychain. A first
  /// connect then starts the scan over `backfillDays` (30, 90 or 365; §7.7); a reconnect or a
  /// takeover of the same address resumes the normal cycle from the kept watermark, and another
  /// address is a first connect, as `replacing` is.
  ///
  /// `replacing`: the mailbox tables hold another provider's lane (the account switches
  /// provider). Only once the new link is made are they cleared, in the same commit as the new
  /// state, so this is a first connect; a cancelled or failed switch leaves them as they were.
  public static func backfillDays(newestImportMs: Int64?, nowMs: Int64) -> Int {
    guard let newest = newestImportMs else { return 90 }
    let gapDays = (nowMs - newest) / 86_400_000 + 2
    return gapDays <= 90 ? 90 : 365
  }

  public func connect(
    presenter: any MailAuthSessionPresenter, backfillDays: Int, replacing: Bool = false,
    confirm: MailboxSwitchConfirm? = nil
  ) async -> ConnectResult {
    stopped = false
    let (result, plan) = await exclusive { () -> (ConnectResult, MailboxRetirePlan?) in
      var plan: MailboxRetirePlan?
      let r = await connectLocked(
        presenter: presenter, backfillDays: backfillDays, replacing: replacing, confirm: confirm, retiring: &plan)
      return (r, plan)
    }
    guard let plan, case .connected(let address, true, _) = result else { return result }
    return .connected(address: address, anotherAddress: true, retired: await retire(plan))
  }

  private func connectLocked(
    presenter: any MailAuthSessionPresenter, backfillDays: Int, replacing: Bool, confirm: MailboxSwitchConfirm?,
    retiring: inout MailboxRetirePlan?
  ) async -> ConnectResult {
    let oauth = provider.oauth
    guard oauth.isConfigured else { return .failed(.notConfigured) }
    let nonce: String
    do { nonce = try await server.linkChallenge() } catch .offline { return .failed(.offline) } catch {
      return .failed(.serverRefused)
    }
    let auth: MailAuthorization
    let grant: MailTokenGrant
    do throws(MailOAuthError) {
      auth = try oauth.begin(nonce: nonce, random: random)
      let callback = try await presenter.authorize(url: auth.url, callbackScheme: oauth.redirectScheme)
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
    guard let idToken = grant.idToken, let claims = oauth.identity(idToken: idToken) else {
      return .failed(.google)
    }
    // The server checks the nonce for real (spec 02 §13.2); checking here too means a sheet that
    // came back from a different attempt fails before any step-up prompt.
    guard let n = claims.nonce, constantTimeEquals(Data(n.utf8), Data(nonce.utf8)) else {
      return .failed(.nonceMismatch)
    }
    // An account with no mailbox is refused before the step-up: linking it would replace a
    // working link to the other provider with one that can read nothing.
    let probe = AccessToken(value: grant.accessToken, expiresAtMs: clock.nowMs() + grant.expiresIn * 1000)
    do throws(MailAPIError) { try await source(probe).checkMailbox() } catch .noMailbox {
      return .failed(.noMailbox)
    } catch .offline {
      return .failed(.offline)
    } catch where error.status == 401 || error.status == 403 {
      return .failed(.permissionMissing)
    } catch {}
    let stored = replacing ? nil : ((try? await store.loadState()) ?? MailboxState())
    if let stored, Self.identityUnknown(linked: stored.address, signedIn: claims.email) {
      return .failed(.permissionMissing)
    }
    let otherMailbox = stored.map { Self.isAnotherMailbox(linked: $0.address, signedIn: claims.email) } ?? false
    let fresh = replacing || otherMailbox
    if otherMailbox, let old = stored {
      let plan = await ledger.retirePlan(grantID: self.grant(old), provider: provider.id.rawValue)
      let noMailbox = old.phase == .halted && old.haltedOn == .noMailbox
      let imported = plan.countKnown ? plan.total : nil
      if !noMailbox || imported != 0 {
        let question = MailboxSwitchQuestion(
          oldAddress: old.address ?? "", newAddress: claims.email ?? "", transactions: imported, edited: plan.edited,
          oldHasNoMailbox: noMailbox)
        switch await confirm?(question) ?? .cancel {
        case .cancel: return .declined
        case .keep: break
        case .remove: retiring = imported == 0 ? nil : plan
        }
      }
    }
    let proof: JSONValue
    do { proof = try await stepUp.proof(kind: "mailbox.link", payloadHash: sha256(Data(idToken.utf8))) } catch {
      return .failed(.stepUpFailed)
    }
    let link: MailboxLinkResult
    do {
      link = try await server.putLink(provider: provider.id, idToken: idToken, stepUp: proof)
    } catch .offline {
      return .failed(.offline)
    } catch .refused(409, "mailbox_in_use") {
      return .failed(.mailboxInUse)
    } catch {
      return .failed(.serverRefused)
    }
    if otherMailbox {
      var cleared = commitState(MailboxState())
      cleared.clearAll = true
      do { try await store.commit(cleared) } catch { return .failed(.keychain) }
      if let token = try? await tokens.accessToken(forceRefresh: false) {
        try? await source(token).stop()
      }
      _ = await tokens.revokeAndForget(keepOnFailure: false)
      provider.forgetLink()
      notBeforeMs = 0
      quotaStrikes = 0
      strikes = [:]
    }
    do {
      try await tokens.install(grant: grant)
      try provider.installLink(link)
    } catch {
      if otherMailbox { await abandonSwitch() }
      return .failed(.keychain)
    }

    var s = fresh ? MailboxState() : (stored ?? MailboxState())
    switch s.phase {
    case .scanning, .awaitingCards, .authoringBackfill, .active:
      break  // a re-link mid-setup (or while active) keeps its place
    case .unlinked:
      s.phase = .scanning
      s.scanStartedMs = nil
    case .reconnectRequired, .otherDevice, .halted:
      // Reconnect / "Read them here instead": back to the phase the interruption cut short, never
      // a fresh scan once the backfill has started.
      s.phase = resumePhase(s)
    }
    s.address = claims.email
    s.haltedOn = nil
    s.haltedDetail = nil
    s.lastHolderCheckAtMs = clock.nowMs()
    s.watchExpiresAtMs = nil  // a new link starts with no watch (spec 02 §13.2 step 3)
    if s.phase == .scanning && s.scanStartedMs == nil {
      // First connect. A resumed scan keeps its window: what it staged and accounted still counts.
      s.backfillDays = [30, 90, 365].contains(backfillDays) ? backfillDays : 90
      s.scanStartedMs = clock.nowMs()
      // h0 is captured before any listing (§7.7 step 2); best effort here, re-read by the scan.
      if let token = try? await tokens.accessToken(forceRefresh: false) {
        s.profileHistoryID = try? await source(token).changeToken()
      }
    }
    var c = commitState(s)
    c.clearAll = fresh
    do { try await store.commit(c) } catch {
      if otherMailbox { await abandonSwitch() }
      return .failed(.keychain)
    }
    return .connected(address: claims.email, anotherAddress: otherMailbox)
  }

  private func abandonSwitch() async {
    await tokens.forget()
    provider.forgetLink()
  }

  static func isAnotherMailbox(linked: String?, signedIn: String?) -> Bool {
    let old = MailboxEngineConfig.normalized(linked ?? "")
    let new = MailboxEngineConfig.normalized(signedIn ?? "")
    return !old.isEmpty && !new.isEmpty && old != new
  }

  static func identityUnknown(linked: String?, signedIn: String?) -> Bool {
    !MailboxEngineConfig.normalized(linked ?? "").isEmpty && MailboxEngineConfig.normalized(signedIn ?? "").isEmpty
  }

  /// Ends this provider's grant on this iPhone after another provider's link replaced it: stops
  /// push, revokes the refresh token where the provider can (best effort) and forgets it and the
  /// link's items. The mailbox tables are the new provider's and are not touched.
  public func endGrant() async {
    await exclusive {
      if let token = try? await tokens.accessToken(forceRefresh: false) {
        try? await source(token).stop()
      }
      await tokens.revokeAndForget(keepOnFailure: false)
      provider.forgetLink()
    }
  }

  /// Disconnect (Bank alerts › Disconnect): step-up `mailbox.unlink` → stop push (users.stop) →
  /// revoke and delete the Keychain item → `DELETE /mailbox/link` → clear the mailbox tables.
  /// A revoke that did not go through stops the disconnect there (false): the token is kept, so
  /// the retry can still end the grant, and nothing says it ended when it didn't.
  public func retirePlan() async -> MailboxRetirePlan? {
    guard let state = try? await store.loadState(), state.phase != .unlinked, state.phase != .otherDevice else { return nil }
    return await ledger.retirePlan(grantID: grant(state), provider: provider.id.rawValue)
  }

  public func disconnect(removing plan: MailboxRetirePlan?) async -> MailboxDisconnectOutcome {
    let outcome = await unlink()
    guard outcome == .disconnected, let plan else { return outcome }
    switch await retire(plan) {
    case .removed(let n): return .removed(n ?? 0)
    case .failed: return .disconnectedRemoveFailed
    }
  }

  public func retire(_ plan: MailboxRetirePlan) async -> MailboxRetireOutcome {
    do throws(MailboxLedgerError) {
      try await ledger.authorRetire(plan)
    } catch {
      return .failed
    }
    _ = await ledger.flush()
    return .removed(plan.countKnown ? plan.total : nil)
  }

  public func disconnect() async -> Bool { await unlink() == .disconnected }

  private func unlink() async -> MailboxDisconnectOutcome {
    await exclusive {
      guard var state = try? await store.loadState() else { return .failed }
      do throws(MailboxServerError) {
        switch try await server.linkStatus(provider: provider.id) {
        case .holder(isThisDevice: false, _):
          return await leaveLink(&state)
        case .noLink, .holder(isThisDevice: true, _):
          break
        }
      } catch .otherProvider {
        if case .holder(isThisDevice: true, _)? = try? await server.linkStatus() { return .failed }
        return await leaveLink(&state)
      } catch {
        return .failed
      }
      let proof: JSONValue
      do { proof = try await stepUp.proof(kind: "mailbox.unlink", payloadHash: nil) } catch { return .failed }
      if let token = try? await tokens.accessToken(forceRefresh: false) {
        try? await source(token).stop()
      }
      guard await tokens.revokeAndForget() else { return .failed }
      provider.forgetLink()
      do throws(MailboxServerError) {
        try await server.deleteLink(stepUp: proof)
      } catch .noLink {
        // Already gone server-side.
      } catch {
        return .failed
      }
      var c = MailboxCommit()
      c.clearAll = true
      c.state = MailboxState()
      do { try await store.commit(c) } catch { return .failed }
      return .disconnected
    }
  }

  private func leaveLink(_ state: inout MailboxState) async -> MailboxDisconnectOutcome {
    await endLocalPush()
    await tokens.forget()
    state.lastHolderCheckAtMs = clock.nowMs()
    _ = await setPhase(&state, .otherDevice, halt: .notHolder, CycleReport())
    return .otherDevice
  }

  // MARK: - The cycle

  /// One cycle (spec 04 §7.5). `deadlineMs` is in the engine clock's epoch ms; nil = foreground
  /// (no deadline). Never throws.
  public func runCycle(trigger: MailboxTrigger, deadlineMs: Int64? = nil) async -> CycleReport {
    await exclusive { await cycleLocked(trigger: trigger, deadlineMs: deadlineMs) }
  }

  private func cycleLocked(trigger: MailboxTrigger, deadlineMs: Int64?) async -> CycleReport {
    var report = CycleReport()
    if stopped { return report }
    guard var state = try? await store.loadState() else {
      report.haltedOn = .offline
      return report
    }
    report.phase = state.phase
    if clock.nowMs() < notBeforeMs {
      // The provider asked for a pause (`Retry-After`): every request now would count against
      // the same limit. Nothing changes; a later trigger runs.
      report.haltedOn = .gmail
      return report
    }
    if state.phase == .halted {
      guard trigger == .retry || resumesAfterAccountFull(state, trigger) else {
        report.haltedOn = state.haltedOn
        return report
      }
      // Resume where the halt interrupted: the normal cycle once a watermark exists, else the
      // first-connect phase it cut short.
      state.phase = resumePhase(state)
      state.haltedOn = nil
      state.haltedDetail = nil
    }
    switch state.phase {
    case .unlinked:
      return report
    case .otherDevice:
      guard holderCheckDue(state, trigger) else { return report }
      let now = clock.nowMs()
      do {
        switch try await server.linkStatus(provider: provider.id) {
        case .noLink:
          var c = MailboxCommit()
          c.clearAll = true
          c.state = MailboxState()
          try? await store.commit(c)
          report.phase = .unlinked
          return report
        case .holder(isThisDevice: false, _):
          state.lastHolderCheckAtMs = now
          return await finish(&state, report)
        case .holder(isThisDevice: true, _):
          state.phase = resumePhase(state)
          state.haltedOn = nil
          state.haltedDetail = nil
        }
      } catch .otherProvider {
        state.lastHolderCheckAtMs = now
        return await finish(&state, report)
      } catch {
        report.haltedOn = .offline
        return report
      }
    case .awaitingCards:
      // A scan staged by a build that still asked "Are these your cards?": author it now, as a
      // finished scan does.
      state.phase = .authoringBackfill
    case .reconnectRequired:
      guard trigger == .retry else { return report }
      state.phase = resumePhase(state)
      state.haltedOn = nil
      state.haltedDetail = nil
    default: break
    }
    if templates.isEmpty { return await halt(&state, .templatesUnavailable, report) }

    let now = clock.nowMs()
    // 1. Holder check.
    if holderCheckDue(state, trigger) {
      do {
        switch try await server.linkStatus(provider: provider.id) {
        case .noLink:
          await endLocalPush()
          return await setPhase(&state, .reconnectRequired, halt: .reconnectRequired, report)
        case .holder(isThisDevice: false, _):
          // Delete this phone's refresh token but do NOT revoke it at the provider: both iPhones
          // share the iOS client id, and Google's revoke ends the whole grant for that client and
          // Google account, which would sign the new holder out too (deviation from §7.4's
          // "revoke OWN refresh token"; to confirm with an AT-GMAIL run on a real account).
          await endLocalPush()
          await tokens.forget()
          return await setPhase(&state, .otherDevice, halt: .notHolder, report)
        case .holder(isThisDevice: true, let watch):
          state.lastHolderCheckAtMs = now
          if let watch, state.watchExpiresAtMs == nil { state.watchExpiresAtMs = watch }
        }
      } catch .otherProvider {
        if case .holder(isThisDevice: true, _)? = try? await server.linkStatus() {
          stopped = true
          return report
        }
        await endLocalPush()
        await tokens.forget()
        var elsewhere = MailboxState()
        elsewhere.phase = .otherDevice
        elsewhere.haltedOn = .notHolder
        elsewhere.lastHolderCheckAtMs = now
        var c = commitState(elsewhere)
        c.clearAll = true
        try? await store.commit(c)
        report.haltedOn = .notHolder
        report.phase = .otherDevice
        emit(.failed(.notHolder), 0, 0)
        return report
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
    let source = await listingSource(token)
    // Short runs list a page, download it, then list the next (§7.5 "one scan page per cycle in a
    // deadline run"); the foreground lists everything first so the first-scan board has a total.
    let paged = deadlineMs != nil || trigger == .processing

    // 4. Load.
    let trusted = BankDomains.effectiveTrusted(await ledger.senderTrust())
    state.lastCycleAtMs = now

    // 5. Watch renewal (scan and active phases).
    await renewWatch(source, &state, now: now)

    switch state.phase {
    case .scanning:
      return await scan(source, &state, trusted: trusted, deadlineMs: deadlineMs, paged: paged, report)
    case .authoringBackfill:
      return await authorBackfill(source, &state, trusted: trusted, deadlineMs: deadlineMs, paged: paged, report)
    default: break
    }

    // 6. Change detector (nil: the provider has none, so every cycle lists).
    let h0: String?
    do { h0 = try await source.changeToken() } catch let e {
      return await mailFailure(e, &state, report)
    }
    if trusted.isEmpty {
      // Nothing is listed when no sender is trusted (03c §7.2); not an error.
      state.profileHistoryID = h0
      state.lastSuccessAtMs = now
      if state.watermarkMs == nil { state.watermarkMs = now }
      report.completed = true
      return await finish(&state, report)
    }
    if let h0, h0 == state.profileHistoryID, state.watermarkMs != nil,
      ![.refresh, .launch, .retry].contains(trigger)
    {
      state.lastSuccessAtMs = now
      report.completed = true
      let unchanged = await finish(&state, report)
      return await runImports(source, &state, deadlineMs: deadlineMs, paged: paged, unchanged).report
    }
    let t0 = now

    // 7. List and account.
    let since = BankDomains.sinceSec(watermarkMs: state.watermarkMs ?? (now - 30 * 86_400_000))
    var run = Run(trusted: trusted, cards: await ledger.knownCards(), grant: grant(state), address: state.address)
    let cut: Bool
    do {
      cut = try await listAndProcess(
        source, domains: trusted, sinceSec: since, maxPages: config.maxListPages, mode: .author, paged: paged,
        run: &run, report: &report, deadlineMs: deadlineMs)
    } catch let e as MailAPIError {
      return await mailFailure(e, &state, report)
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
      quotaStrikes = 0
      c.pruneAccountedBelowMs = (state.watermarkMs ?? 0) - BankDomains.overlapMs - 86_400_000
      report.completed = true
    }
    c.state = state
    try? await store.commit(c)
    report.phase = state.phase
    if cut || state.phase != .active { return report }
    return await runImports(source, &state, deadlineMs: deadlineMs, paged: paged, report).report
  }

  func holderCheckDue(_ state: MailboxState, _ trigger: MailboxTrigger) -> Bool {
    let now = clock.nowMs()
    return trigger == .launch || trigger == .retry || state.lastHolderCheckAtMs == nil
      || now - (state.lastHolderCheckAtMs ?? 0) >= config.holderCheckIntervalMs
  }

  // MARK: - First connect (§7.7)

  private func scan(
    _ source: any MailSource, _ state: inout MailboxState, trusted: [String], deadlineMs: Int64?, paged: Bool,
    _ report: CycleReport
  ) async -> CycleReport {
    var report = report
    // No trusted sender yet (the Setup bank step's sender_trust_set ops have not folded): list
    // nothing and stay scanning, rather than finish an empty scan (03c §7.2: T empty lists nothing).
    if trusted.isEmpty { return await finish(&state, report) }
    let started = state.scanStartedMs ?? clock.nowMs()
    if state.scanStartedMs == nil {
      state.scanStartedMs = started
      scanTotal = 0
    }
    if state.profileHistoryID == nil {
      do { state.profileHistoryID = try await source.changeToken() } catch let e {
        return await mailFailure(e, &state, report)
      }
    }
    let days = Int64(state.backfillDays ?? 90)
    let since = max(0, (started - days * 86_400_000) / 1000)
    var run = Run(trusted: trusted, cards: [:], grant: grant(state), address: state.address)
    run.commitEvery = max(1, config.firstScanCommitEvery)
    var cut: Bool
    do {
      cut = try await listAndProcess(
        source, domains: trusted, sinceSec: since, firstSinceSec: Self.monthStartSec(clock.nowMs()),
        maxPages: config.maxListPages, mode: .stage, paged: paged, run: &run, report: &report, deadlineMs: deadlineMs)
    } catch let e as MailAPIError {
      _ = await commitStaged(&run, &report)
      if run.stop == .accountFull { return await halt(&state, .accountFull, report) }
      return await mailFailure(e, &state, report)
    } catch {
      _ = await commitStaged(&run, &report)
      report.haltedOn = .offline
      return await finish(&state, report)
    }
    switch run.stop {
    case .accountFull?: return await halt(&state, .accountFull, report)
    case let code?:
      report.haltedOn = code
      return await finish(&state, report)
    case nil: break
    }
    if run.stagingFull {
      report.haltedOn = .stagingFull
      cut = false  // the cap ends the listing; the backfill lists and authors the remainder
    }
    guard !cut else { return await finish(&state, report) }
    // The scan is complete: author what it staged in the same run. There is no cards step; a
    // card the ledger doesn't know files like a known one (`MessageDisposer.finalize`).
    state.phase = .authoringBackfill
    try? await store.commit(commitState(state))
    return await authorBackfill(source, &state, trusted: trusted, deadlineMs: deadlineMs, paged: paged, report)
  }

  private func authorBackfill(
    _ source: any MailSource, _ state: inout MailboxState, trusted: [String], deadlineMs: Int64?, paged: Bool,
    _ report: CycleReport
  ) async -> CycleReport {
    var report = report
    let cards = await ledger.knownCards()
    let total = (try? await store.stagedCount()) ?? 0
    var authored = 0
    if total > 0 {
      emit(.authoring, 0, total)
    } else if scanTotal > 0 {
      emit(.authoring, scanTotal, scanTotal)
    }
    while !Task.isCancelled {
      if let d = deadlineMs, clock.nowMs() >= d - config.authoringMarginMs { break }
      guard let n = await authorStagedBatch(cards: cards, grant: grant(state), report: &report) else {
        report.haltedOn = .offline
        return await finish(&state, report)
      }
      if n == 0 { break }
      authored += n
      emit(.authoring, authored, total)
    }
    switch await ledger.flush() {
    case .accountFull: return await halt(&state, .accountFull, report)
    case .failed:
      report.haltedOn = .offline
      return await finish(&state, report)
    case .flushed: break
    }
    var remainderDone = false
    if ((try? await store.stagedCount()) ?? 1) == 0 {
      // §7.7 step 7: when the scan stopped at the staging cap, the rest of its window is listed
      // again and authored directly. Run unconditionally (no state
      // column records the cap): ids only, and the accounted set skips everything already done.
      let days = Int64(state.backfillDays ?? 90)
      let since = max(0, ((state.scanStartedMs ?? clock.nowMs()) - days * 86_400_000) / 1000)
      var run = Run(trusted: trusted, cards: cards, grant: grant(state), address: state.address)
      do {
        let cut = try await listAndProcess(
          source, domains: trusted, sinceSec: since, maxPages: config.maxListPages, mode: .author, paged: paged,
          run: &run, report: &report, deadlineMs: deadlineMs)
        remainderDone = !cut
      } catch let e as MailAPIError {
        return await mailFailure(e, &state, report)
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
    let stagingEmpty = ((try? await store.stagedCount()) ?? 1) == 0
    if remainderDone && stagingEmpty {
      // §7.7 step 6: the normal cycle's 2-day overlap catches up what arrived during the scan.
      state.watermarkMs = state.scanStartedMs ?? clock.nowMs()
      state.phase = .active
      state.lastSuccessAtMs = clock.nowMs()
      report.completed = true
      let all = max(total, scanTotal)
      emit(.done, all, all)
    }
    return await finish(&state, report)
  }

  func grant(_ state: MailboxState) -> String { config.grantID(provider: provider.id, address: state.address) }

  func authorStagedBatch(cards: [CardKey: CardState], grant: String, report: inout CycleReport) async -> Int? {
    guard let batch = try? await store.staged(limit: config.backfillBatch) else { return nil }
    if batch.isEmpty { return 0 }
    var c = MailboxCommit()
    var counted = report
    let at = clock.nowMs()
    for m in batch {
      c.unstage.append(m.messageID)
      if await ledger.isIngested(m.ingestID) {
        c.accounted.append(AccountedRecord(messageID: m.messageID, outcome: .dup, internalDateMs: m.internalDateMs, atMs: at))
        counted.dup += 1
        continue
      }
      let draft = MessageDisposer.finalize(
        m, provider: provider.id, grantID: grant, cards: cards, categorizer: categorizer)
      c.drafts.append(draft)
      c.accounted.append(AccountedRecord(messageID: m.messageID, outcome: .op, internalDateMs: m.internalDateMs, atMs: at))
      if let u = Self.unparsedSender(m, at: at) { c.unparsedSenders.append(u) }
      counted.count(draft)
    }
    do { try await store.commit(c) } catch { return nil }
    report = counted
    return batch.count
  }

  func commitStaged(_ run: inout Run, _ report: inout CycleReport) async -> Bool {
    run.sinceCommit = 0
    let cards = await ledger.knownCards()
    var authored = 0
    while true {
      guard let n = await authorStagedBatch(cards: cards, grant: run.grant, report: &report) else {
        run.stop = .offline
        return false
      }
      if n == 0 { break }
      authored += n
    }
    guard authored > 0 else { return true }
    switch await ledger.flush() {
    case .accountFull:
      run.stop = .accountFull
      return false
    case .failed, .flushed: break
    }
    onCommit?()
    return true
  }

  static func monthStartSec(_ nowMs: Int64) -> Int64? {
    guard let d = LocalClock.localDate(nowMs), let first = CivilDate(year: d.year, month: d.month, day: 1) else {
      return nil
    }
    return max(0, LocalClock.startOfDay(first) / 1000)
  }

  // MARK: - The first scan's foreground run (Setup 2 of 4)

  /// Runs cycles until the connect window is listed and authored (`.active`), a stop the user
  /// must act on, or `maxCycles`. Returns every cycle's report, in order.
  ///
  /// A 90-day backfill is a thousand or more mail API calls. A cycle stops at the first one that
  /// outlives its retries (Gmail's per-user rate limit, a dropped connection, an access token
  /// that expired mid-run), with its work so far committed, and the next cycle carries on. So a
  /// passing stop (`gmail`, `offline`, `quota`) does not end the first scan: the next cycle runs
  /// at once when the last one read something, and after `firstScanStallWaitsMs` (or the
  /// provider's `Retry-After`) when it read nothing, giving up after the last wait. While this
  /// runs, a passing stop is not reported as `.failed` progress, since the scan goes on.
  public func runFirstScan(maxCycles: Int = 50) async -> [CycleReport] {
    firstScanRunning = true
    defer { firstScanRunning = false }
    var reports: [CycleReport] = []
    var stalls = 0
    for _ in 0..<maxCycles {
      if Task.isCancelled || stopped { break }
      let r = await runCycle(trigger: .refresh)
      reports.append(r)
      guard r.phase == .scanning || r.phase == .authoringBackfill else { break }
      let read = r.fetched + r.ops + r.staged + r.setAside + r.unreadable + r.dup > 0
      switch r.haltedOn {
      case nil, .stagingFull?:
        // Nothing listed and not finished: no trusted sender yet. Stop rather than spin; the
        // next trigger resumes it.
        if r.listed == 0 && r.ops == 0 && !r.completed { return reports }
        stalls = 0
      case let code? where Self.passing(code):
        if read {
          stalls = 0
          continue
        }
        guard stalls < config.firstScanStallWaitsMs.count else { return reports }
        let wait = max(config.firstScanStallWaitsMs[stalls], notBeforeMs - clock.nowMs())
        stalls += 1
        // A pause longer than the longest stall wait (a long Retry-After) is left to the later
        // triggers: the setup board says the import goes on in the background.
        guard wait <= config.firstScanStallWaitsMs.last ?? 0 else { return reports }
        await sleep(wait)
        if Task.isCancelled || stopped { return reports }
      default:
        return reports
      }
    }
    return reports
  }

  /// A stop that passes by itself: the next cycle may read on.
  static func passing(_ code: MailboxHaltCode) -> Bool {
    code == .gmail || code == .offline || code == .quota
  }

  // MARK: - Add a sender (§7.8)

  /// Trusts a typed sender domain (`sender_trust_set`) and imports its mail in the connect
  /// window through the normal gates, without moving the watermark.
  public func importSender(_ typed: String) async -> Result<CycleReport, BankDomains.TypedDomainError> {
    let domain: String
    var address: String?
    do {
      if provider.listsByAddress {
        let a = try BankDomains.normalizeTypedAddress(typed)
        address = a
        domain = BankDomains.domainOf(a)
      } else {
        domain = try BankDomains.normalizeTyped(typed)
      }
    } catch { return .failure(error) }
    return .success(
      await exclusive {
        var report = CycleReport()
        guard var state = try? await store.loadState() else { return report }
        report.phase = state.phase
        if let address {
          do { try await store.addSenderAddress(address) } catch {
            report.haltedOn = .offline
            return report
          }
        }
        do { try await ledger.authorSenderTrust(domain: domain, trusted: true) } catch {
          report.haltedOn = .offline
          return report
        }
        return await importLocked([domain], &state, report)
      })
  }

  public func backfill(senders: [String]) async -> CycleReport {
    let domains = senders.map { $0.lowercased() }.filter(BankDomains.isQuerySafe)
    return await exclusive {
      var report = CycleReport()
      guard !stopped, !domains.isEmpty, var state = try? await store.loadState() else { return report }
      report.phase = state.phase
      return await importLocked(domains, &state, report)
    }
  }

  /// Records the senders' window as pending, then imports it now when the lane is active. A
  /// scan in progress lists every trusted sender itself; anything left pending is finished by
  /// later cycles, and `completed` says the whole window was listed and read.
  private func importLocked(_ domains: [String], _ state: inout MailboxState, _ report: CycleReport) async
    -> CycleReport
  {
    var report = report
    guard state.watermarkMs != nil else { return report }
    let days = Int64(state.backfillDays ?? 90)
    let sinceMs = max(0, clock.nowMs() - days * 86_400_000)
    var c = MailboxCommit()
    c.addImports = domains.map { PendingImport(domain: $0, sinceMs: sinceMs) }
    do { try await store.commit(c) } catch {
      report.haltedOn = .offline
      return report
    }
    guard state.phase == .active, !stopped else { return report }
    let token: AccessToken
    do { token = try await tokens.accessToken(forceRefresh: false) } catch {
      report.haltedOn = .reconnectRequired
      return report
    }
    let (out, done) = await runImports(await listingSource(token), &state, deadlineMs: nil, paged: false, report)
    report = out
    report.completed = done && report.haltedOn == nil
    return report
  }

  /// Lists and authors every pending import's window, sender group by sender group, and ends
  /// each one whose listing was exhausted. A sender the ledger no longer trusts is dropped.
  func runImports(
    _ source: any MailSource, _ state: inout MailboxState, deadlineMs: Int64?, paged: Bool, _ report: CycleReport
  ) async -> (report: CycleReport, done: Bool) {
    var report = report
    guard let pending = try? await store.pendingImports() else {
      report.haltedOn = .offline
      return (report, false)
    }
    if pending.isEmpty { return (report, true) }
    let trust = await ledger.senderTrust()
    var trusted = BankDomains.effectiveTrusted(trust)
    let wanted = pending.filter { trust[$0.domain] != false && BankDomains.isQuerySafe($0.domain) }
    for p in wanted where !trusted.contains(p.domain) { trusted.append(p.domain) }
    var done = pending.filter { p in !wanted.contains(p) }.map(\.domain)
    var run = Run(trusted: trusted, cards: await ledger.knownCards(), grant: grant(state), address: state.address)
    var failure: MailAPIError?
    var offline = false
    for (sinceMs, group) in Dictionary(grouping: wanted, by: \.sinceMs).sorted(by: { $0.key < $1.key }) {
      if shouldStop(deadlineMs) { break }
      let domains = group.map(\.domain)
      do {
        let cut = try await listAndProcess(
          source, domains: domains, sinceSec: sinceMs / 1000, maxPages: config.maxListPages, mode: .author,
          paged: paged, run: &run, report: &report, deadlineMs: deadlineMs)
        if cut { break }
        done += domains
      } catch let e as MailAPIError {
        failure = e
        break
      } catch {
        offline = true
        break
      }
    }
    switch await ledger.flush() {
    case .accountFull:
      await endImports(done)
      return (await halt(&state, .accountFull, report), false)
    case .failed, .flushed: break
    }
    await endImports(done)
    if let failure { return (await mailFailure(failure, &state, report), false) }
    if offline { report.haltedOn = .offline }
    return (report, !offline && done.count == pending.count)
  }

  func endImports(_ domains: [String]) async {
    guard !domains.isEmpty else { return }
    var c = MailboxCommit()
    c.doneImports = domains
    try? await store.commit(c)
  }

  public func probeSenders(_ domains: [String], days: Int = 180) async -> SenderProbeResult {
    let wanted = domains.map { $0.lowercased() }.filter(BankDomains.isQuerySafe)
    return await exclusive {
      let state = (try? await store.loadState()) ?? MailboxState()
      switch state.phase {
      case .otherDevice, .unlinked: return .notReading
      case .reconnectRequired: return .reconnectRequired
      default: break
      }
      let token: AccessToken
      do throws(MailAuthError) { token = try await tokens.accessToken(forceRefresh: false) } catch .reconnectRequired {
        return .reconnectRequired
      } catch {
        return .offline
      }
      let source = await listingSource(token)
      let since = max(0, (clock.nowMs() - Int64(days) * 86_400_000) / 1000)
      var found: [String] = []
      for domain in wanted where !found.contains(domain) {
        do throws(MailAPIError) {
          if !(try await source.list(senders: [domain], since: since, pageToken: nil)).ids.isEmpty { found.append(domain) }
        } catch let e {
          if let s = e.status, s == 401 || s == 403 { return .reconnectRequired }
          return .offline
        }
      }
      return .found(found)
    }
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
      do throws(MailAuthError) { token = try await tokens.accessToken(forceRefresh: false) } catch .reconnectRequired {
        return .reconnectRequired
      } catch {
        return .offline
      }
      let raw: MailRawMessage
      do throws(MailAPIError) { raw = try await source(token).raw(id: messageID) } catch let e {
        if let s = e.status, s == 404 || s == 410 { return .gone }
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
      health: (try? await store.bankHealth()) ?? [], watchActive: state.watchExpiresAtMs != nil,
      unlisted: await unlisted(state), unparsedSenders: (try? await store.unparsedSenders()) ?? [:])
  }

  static func unparsedSender(_ m: ParsedMail, from: String = "", at: Int64) -> UnparsedSenderRecord? {
    guard m.fields == nil else { return nil }
    let domain = m.senderDomain ?? BankDomains.domainOf(from)
    return domain.isEmpty ? nil : UnparsedSenderRecord(messageID: m.messageID, domain: domain, atMs: at)
  }

  func unlisted(_ state: MailboxState) async -> [String] {
    guard provider.listsByAddress, state.phase != .unlinked, state.phase != .otherDevice else { return [] }
    let trusted = BankDomains.effectiveTrusted(await ledger.senderTrust())
    return provider.unlisted(trusted, senderAddresses: (try? await store.senderAddresses()) ?? [])
  }

  public func senderAddresses() async -> [String] { (try? await store.senderAddresses()) ?? [] }

  // MARK: - Internals

  func source(_ token: AccessToken) -> any MailSource { provider.source(accessToken: token) }

  func listingSource(_ token: AccessToken) async -> any MailSource {
    guard provider.listsByAddress else { return source(token) }
    return provider.source(accessToken: token, senderAddresses: (try? await store.senderAddresses()) ?? [])
  }

  /// This iPhone no longer holds the link (another took it over, or it was deleted): end this
  /// iPhone's own push where that cannot touch the new holder's (best effort), and forget what
  /// the link kept. The new holder's subscription replaces a leftover one in any case.
  func endLocalPush() async {
    if provider.stopIsDeviceScoped, let token = try? await tokens.accessToken(forceRefresh: false) {
      try? await source(token).stop()
    }
    provider.forgetLink()
  }

  struct Run {
    var trusted: [String]
    var cards: [CardKey: CardState]
    var grant: String
    var address: String?
    var width = 6
    var stagingFull = false
    var saw429 = false
    var commitEvery: Int?
    var firstPass: Set<String> = []
    var sinceCommit = 0
    var stop: MailboxHaltCode?
    var pagedBase: Int?
    var senderAddresses: [String]?
  }

  enum Mode { case author, stage }

  enum Fetched: Sendable {
    case setAside(id: String, domain: String, internalDateMs: Int64)
    case raw(id: String, from: String, raw: MailRawMessage)
    case gone(id: String)
    case failed(id: String, error: MailAPIError)
  }

  /// Whether a run must stop at this boundary: the BGTask expired (cancellation) or the
  /// deadline's authoring margin is reached.
  func shouldStop(_ deadlineMs: Int64?) -> Bool {
    if Task.isCancelled || stopped { return true }
    if let d = deadlineMs, clock.nowMs() >= d - config.authoringMarginMs { return true }
    return false
  }

  /// Steps 7 over every sender group. Returns whether the run was cut (a listing not exhausted,
  /// the deadline, cancellation or the staging cap); adds the listed count to the report.
  ///
  /// `paged == false` (foreground): every page is listed first, then downloaded, so progress has
  /// a total ("182 of 268"). `paged == true` (a deadline or processing run): each page is
  /// downloaded and accounted before the next is listed, with the deadline checked before every
  /// listing call; the page token lives only within this run (§7.5 step 7g), and a later run
  /// re-lists the accounted pages cheaply (ids only, no downloads).
  func listAndProcess(
    _ source: any MailSource, domains: [String], sinceSec: Int64, firstSinceSec: Int64? = nil, maxPages: Int,
    mode: Mode, paged: Bool, run: inout Run, report: inout CycleReport, deadlineMs: Int64?
  ) async throws -> Bool {
    let passes = firstSinceSec.map { $0 > sinceSec ? [$0, sinceSec] : [sinceSec] } ?? [sinceSec]
    if !paged {
      var ids: [String] = []
      var seen = Set<String>()
      var exhausted = true
      for (pass, since) in passes.enumerated() {
        let (listed, done) = try await list(source, domains: domains, sinceSec: since, maxPages: maxPages)
        for id in listed where seen.insert(id).inserted { ids.append(id) }
        if pass == 0 && passes.count > 1 { run.firstPass = seen }
        exhausted = done
      }
      report.listed += ids.count
      let cut = try await process(source, ids: ids, mode: mode, run: &run, report: &report, deadlineMs: deadlineMs)
      return cut || !exhausted
    }
    var seen = Set<String>()
    var cut = false
    run.pagedBase = 0
    for (pass, since) in passes.enumerated() {
      for group in BankDomains.groups(domains, size: source.maxSendersPerList) {
        var token: String?
        var pages = 0
        repeat {
          if shouldStop(deadlineMs) { return true }
          let page = try await source.list(senders: group, since: since, pageToken: token)
          let ids = page.ids.filter { seen.insert($0).inserted }
          report.listed += ids.count
          token = page.nextPageToken
          pages += 1
          if !ids.isEmpty,
            try await process(source, ids: ids, mode: mode, run: &run, report: &report, deadlineMs: deadlineMs)
          {
            return true
          }
        } while token != nil && pages < maxPages
        if token != nil && pass == passes.count - 1 { cut = true }
      }
    }
    return cut
  }

  /// Lists every group, page by page. Returns the ids (deduplicated, in listing order) and
  /// whether every group's listing was exhausted (false when cancelled between pages).
  func list(_ source: any MailSource, domains: [String], sinceSec: Int64, maxPages: Int) async throws(MailAPIError)
    -> ([String], Bool)
  {
    var ids: [String] = []
    var seen = Set<String>()
    var exhausted = true
    for group in BankDomains.groups(domains, size: source.maxSendersPerList) {
      var token: String?
      var pages = 0
      repeat {
        if Task.isCancelled || stopped { return (ids, false) }
        let page = try await source.list(senders: group, since: sinceSec, pageToken: token)
        for id in page.ids where seen.insert(id).inserted { ids.append(id) }
        token = page.nextPageToken
        pages += 1
      } while token != nil && pages < maxPages
      if token != nil { exhausted = false }
    }
    return (ids, exhausted)
  }

  /// Steps 7a-7g over `ids`. Returns whether the run was cut short (deadline or staging cap).
  /// Throws only a fatal mail API error (401/403 or a transient one that outlived its retries).
  func process(
    _ source: any MailSource, ids all: [String], mode: Mode, run: inout Run, report: inout CycleReport,
    deadlineMs: Int64?
  ) async throws -> Bool {
    let accounted = (try? await store.accounted(among: all)) ?? []
    let projected = await ledger.projectedMessageIDs(among: all)
    let todo = all.filter { !accounted.contains($0) && !projected.contains($0) }
    var i = 0
    let split = run.firstPass.isEmpty ? todo.count : (todo.firstIndex { !run.firstPass.contains($0) } ?? todo.count)
    if !run.saw429 { run.width = max(1, min(config.downloadWidth, provider.maxDownloadWidth)) }
    let skipped = all.count - todo.count
    let base = run.pagedBase ?? 0
    defer { if run.pagedBase != nil { run.pagedBase = base + all.count } }
    if todo.isEmpty && mode == .author { return false }
    var shown = base + all.count
    if mode == .stage {
      if run.pagedBase != nil { shown = max(shown, scanTotal) }
      scanTotal = shown
    }
    emit(.downloading, base + skipped, shown)
    while i < todo.count {
      // A BGTask expiration cancels the task: stop at this boundary, everything so far committed.
      if shouldStop(deadlineMs) {
        if mode == .stage, run.commitEvery != nil, run.sinceCommit > 0 { _ = await commitStaged(&run, &report) }
        return true
      }
      var width = run.width
      if mode == .stage {
        let room = config.stagingCap - ((try? await store.stagedCount()) ?? 0)
        if room <= 0 {
          run.stagingFull = true
          return true
        }
        width = min(width, room)
      }
      let chunk = Array(todo[i..<min(i + width, i < split ? split : todo.count)])
      i += chunk.count
      let results = await fetchChunk(source, chunk, bank: run.trusted)
      // A 429 anywhere narrows the pipe to one request for the rest of the run (fetch.ts).
      if results.contains(where: \.rateLimited) {
        run.width = 1
        run.saw429 = true
      }
      for r in results {
        try await account(r.fetched, mode: mode, run: &run, report: &report)
      }
      if mode == .stage, let every = run.commitEvery {
        run.sinceCommit += chunk.count
        if run.sinceCommit >= every || i >= todo.count || i == split {
          if !(await commitStaged(&run, &report)) { return true }
        }
      }
      emit(.downloading, base + skipped + i, shown)
    }
    return false
  }

  struct FetchResult: Sendable {
    let fetched: Fetched
    let rateLimited: Bool
  }

  /// Downloads a chunk concurrently; the results come back in listing order, so accounting
  /// stays strictly sequential (fetch.ts: only the network is overlapped).
  func fetchChunk(_ source: any MailSource, _ ids: [String], bank: [String]) async -> [FetchResult] {
    let backoff = config.retryBackoffMs
    let rateBackoff = config.rateLimitBackoffMs
    let sleep = self.sleep
    let provider = self.provider
    return await withTaskGroup(of: (Int, FetchResult).self) { group in
      for (n, id) in ids.enumerated() {
        group.addTask {
          (
            n,
            await Self.fetchOne(
              source, provider, id, bank: bank, backoff: backoff, rateBackoff: rateBackoff, sleep: sleep)
          )
        }
      }
      var out: [(Int, FetchResult)] = []
      for await r in group { out.append(r) }
      return out.sorted { $0.0 < $1.0 }.map(\.1)
    }
  }

  /// 7a-7c for one id, with the retry classes of fetch.ts; a 429 waits `rateBackoff` instead.
  static func fetchOne(
    _ source: any MailSource, _ provider: any MailProvider, _ id: String, bank: [String], backoff: [Int64],
    rateBackoff: [Int64], sleep: @Sendable (Int64) async -> Void
  ) async -> FetchResult {
    var rateLimited = false
    func attempt<T: Sendable>(_ op: () async throws(MailAPIError) -> T) async -> Result<T, MailAPIError> {
      var n = 0
      while true {
        do { return .success(try await op()) } catch let e {
          let s = e.status
          if s == 429 { rateLimited = true }
          // The provider named its pause: a quick retry would only count against it again.
          if case .throttled = e { return .failure(e) }
          let transient = e == .offline || s == 429 || (s ?? 0) >= 500 || (s ?? 400) < 400
          let waits = s == 429 ? rateBackoff : backoff
          if !transient || n >= waits.count { return .failure(e) }
          await sleep(waits[n])
          n += 1
        }
      }
    }
    func gone(_ e: MailAPIError) -> Bool {
      guard let s = e.status else { return false }
      return s == 404 || s == 410
    }

    func done(_ f: Fetched) -> FetchResult { FetchResult(fetched: f, rateLimited: rateLimited) }
    let meta: MailMessageMetadata
    switch await attempt({ () async throws(MailAPIError) in try await source.metadata(id: id) }) {
    case .success(let m): meta = m
    case .failure(let e): return done(gone(e) ? .gone(id: id) : .failed(id: id, error: e))
    }
    // 7b: neither the claimed nor the verified domain is a bank domain: set aside, no body.
    let claimed = BankDomains.domainOf(meta.from)
    let analysis = provider.analyzeAuthResults(meta.headerBlock)
    let verified = analysis.verdict.trusted ? (analysis.domain ?? "") : ""
    if !BankDomains.isMember(claimed, of: bank) && !BankDomains.isMember(verified, of: bank) {
      return done(
        .setAside(id: id, domain: verified.isEmpty ? claimed : verified, internalDateMs: Int64(meta.internalDate) ?? 0))
    }
    switch await attempt({ () async throws(MailAPIError) in try await source.raw(id: id) }) {
    case .success(let raw): return done(.raw(id: id, from: meta.from, raw: raw))
    case .failure(let e): return done(gone(e) ? .gone(id: id) : .failed(id: id, error: e))
    }
  }

  /// 7d-7f for one fetched message: one commit (op + accounting, or the accounting alone).
  func account(_ f: Fetched, mode: Mode, run: inout Run, report: inout CycleReport) async throws {
    let at = clock.nowMs()
    var c = MailboxCommit()
    var interrupted: String?
    switch f {
    case .failed(let id, let error):
      guard let reason = Self.unreadableAfterStrikes(error) else { throw error }
      let n = (strikes[id] ?? 0) + 1
      if n < config.messageStrikeLimit {
        strikes[id] = n
        throw error
      }
      strikes[id] = nil
      report.unreadable += 1
      c.unreadable.append(UnreadableRecord(messageID: id, reason: reason, domain: nil, internalDateMs: nil, atMs: at))
      c.accounted.append(AccountedRecord(messageID: id, outcome: .unreadable, internalDateMs: at, atMs: at))
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
      let parsed: MessageDisposer.Parse
      if try await store.isParsing(id) {
        Self.log.notice("mailbox.parse_interrupted", .state("provider", provider.id == .outlook ? "outlook" : "gmail"))
        parsed = .mail(MessageDisposer.unparsed(raw: [UInt8](bytes), messageID: id, internalDateMs: date, spam: raw.spam))
        interrupted = id
      } else {
        try await store.markParsing(id)
        if run.senderAddresses == nil { run.senderAddresses = (try? await store.senderAddresses()) ?? [] }
        let senders = run.senderAddresses ?? []
        parsed = MessageDisposer.parse(
          raw: [UInt8](bytes), messageID: id, internalDateMs: date, topLevelFrom: from, templates: templates,
          bankDomains: run.trusted, trusted: run.trusted, provider: provider.id, linkedAddress: run.address, spam: raw.spam,
          analyze: { provider.analyzeAuthResults($0, inInbox: raw.inInbox, senderAddresses: senders) })
        try await store.clearParsing(id)
      }
      switch parsed {
      case .interrupted:
        return
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
          var staged = m
          if staged.senderDomain == nil { staged.senderDomain = Self.unparsedSender(m, from: from, at: at)?.domain }
          c.stage.append(staged)
        case .author:
          let draft = MessageDisposer.finalize(
            m, provider: provider.id, grantID: run.grant, cards: run.cards, categorizer: categorizer)
          report.count(draft)
          c.drafts.append(draft)
          c.accounted.append(AccountedRecord(messageID: id, outcome: .op, internalDateMs: date, atMs: at))
          if let u = Self.unparsedSender(m, from: from, at: at) { c.unparsedSenders.append(u) }
        }
      }
    }
    try await store.commit(c)
    if let interrupted { try? await store.clearParsing(interrupted) }
  }

  static func unreadableAfterStrikes(_ e: MailAPIError) -> UnreadableReason? {
    guard case .status(let s, _) = e else { return nil }
    if s < 400 { return .undecodable }
    if s == 401 || s == 404 || s == 410 || s == 429 || s >= 500 { return nil }
    return .refused
  }

  func renewWatch(_ source: any MailSource, _ state: inout MailboxState, now: Int64) async {
    // Read once; a null setting again every holder-check interval, so a server whose push is
    // turned on later is watched without a relaunch. A clock that went back since the last read
    // counts as due, so a backwards jump never postpones the re-read.
    let readPush = push.map {
      $0 == .none && (now < pushReadAtMs || now - pushReadAtMs >= config.holderCheckIntervalMs)
    } ?? true
    if readPush {
      do {
        let p = try await server.pushConfig(provider: provider.id)
        push = p
        pushReadAtMs = now
        if case .gmail(let t) = p {
          topicMismatch = config.buildTopic != nil && config.buildTopic != "unset" && t != config.buildTopic
        } else {
          topicMismatch = false
        }
      } catch {
        return  // offline: renewed on a later cycle
      }
    }
    guard let p = push, p != .none else { return }
    if let exp = state.watchExpiresAtMs, exp > now + config.watchRenewWindowMs { return }
    let live = state.watchExpiresAtMs != nil
    guard let w = try? await (live ? source.renew(p) : source.subscribe(p)) else { return }
    do throws(MailboxServerError) {
      try await server.putWatch(expiresAtMs: w.expiresAtMs)
      state.watchExpiresAtMs = w.expiresAtMs
    } catch .noWatchTopic {
      // The server turned its push off after the settings were read: nothing relays this
      // watch. Stop it, show no live watch, and read the settings again on the next cycle.
      try? await source.stop()
      state.watchExpiresAtMs = nil
      push = nil
    } catch {
      // Reported next cycle; the watch itself is live at the provider.
    }
  }

  static let log = CoreLog(category: "CoreMailbox")

  static func kind(_ e: MailAPIError) -> StaticString {
    switch e {
    case .status: "status"
    case .offline: "offline"
    case .unfilteredListing: "unfiltered_listing"
    case .throttled: "throttled"
    case .noMailbox: "no_mailbox"
    case .filterNotApplied: "filter_not_applied"
    }
  }

  func mailFailure(_ e: MailAPIError, _ state: inout MailboxState, _ report: CycleReport) async -> CycleReport {
    var report = report
    Self.log.notice(
      "mailbox.api_failure", .state("provider", provider.id == .outlook ? "outlook" : "gmail"),
      .state("kind", Self.kind(e)), .count("status", e.status ?? 0))
    switch e {
    case .throttled(let sec, _):
      notBeforeMs = clock.nowMs() + min(max(sec, 1), 600) * 1000
    case .noMailbox:
      return await halt(&state, .noMailbox, report)
    case .filterNotApplied:
      // The provider listed mail outside the trusted senders. The page was dropped unread; halt
      // loudly (shown with "Try again") rather than list on as if nothing happened.
      return await halt(&state, .gmail, report)
    default: break
    }
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
      quotaStrikes += 1
      report.haltedOn = quotaStrikes >= 3 ? .quota : .gmail
    case let s? where (400..<500).contains(s):
      // Any other 4xx is unrecoverable by retrying (§7.4): halt, shown on Bank alerts with "Try
      // again", rather than silently stopping every cycle at the same message.
      return await halt(&state, .gmail, report)
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
    markResume(&state)
    state.phase = phase
    state.haltedOn = code
    report.haltedOn = code
    return await finish(&state, report)
  }

  func resumesAfterAccountFull(_ state: MailboxState, _ trigger: MailboxTrigger) -> Bool {
    guard state.haltedOn == .accountFull else { return false }
    if trigger == .launch || trigger == .foreground || trigger == .refresh { return true }
    return clock.nowMs() - (state.lastCycleAtMs ?? 0) >= config.accountFullRetryMs
  }

  func halt(_ state: inout MailboxState, _ code: MailboxHaltCode, _ report: CycleReport) async -> CycleReport {
    var report = report
    markResume(&state)
    state.phase = .halted
    state.haltedOn = code
    report.haltedOn = code
    return await finish(&state, report)
  }

  func finish(_ state: inout MailboxState, _ report: CycleReport) async -> CycleReport {
    var report = report
    if let h = report.haltedOn, h != .stagingFull, !(firstScanRunning && Self.passing(h)) { emit(.failed(h), 0, 0) }
    try? await store.commit(commitState(state))
    report.phase = state.phase
    return report
  }

  /// `halted_detail` for an interrupted first-connect phase (a content-free code).
  static let resumePrefix = "resume:"

  /// Records which setup phase an interruption is cutting short.
  func markResume(_ state: inout MailboxState) {
    if state.phase == .scanning || state.phase == .authoringBackfill {
      state.haltedDetail = Self.resumePrefix + state.phase.rawValue
    }
  }

  /// The phase to resume after a reconnect, a takeover or a retried halt: the normal cycle once a
  /// watermark exists, else the setup phase the interruption recorded (a scan when none was).
  func resumePhase(_ state: MailboxState) -> MailboxPhase {
    if state.watermarkMs != nil { return .active }
    if let d = state.haltedDetail, d.hasPrefix(Self.resumePrefix),
      let p = MailboxPhase(rawValue: String(d.dropFirst(Self.resumePrefix.count))),
      p == .scanning || p == .authoringBackfill
    {
      return p
    }
    return .scanning
  }

  func commitState(_ s: MailboxState) -> MailboxCommit {
    var c = MailboxCommit()
    c.state = s
    return c
  }
}
