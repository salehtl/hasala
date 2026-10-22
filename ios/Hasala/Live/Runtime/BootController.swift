import CoreAuth
import CoreMailbox
import CoreStore
import CoreSync
import Foundation
import HasalaModels
import Observation
import UIKit

/// The live account gate (spec 04 §6.5, §3): decides the first screen from what is on
/// this iPhone (`InstallCheck`, then `Boot.gather` / `Boot.decide`), opens the account's
/// runtime whenever the gate reaches setup or the app, closes it when the account leaves
/// this iPhone, and acts on what only the gate can act on (deleted elsewhere, signed out
/// by the server, frozen, an update required).
///
///   signedOut, signedOutBound   → Welcome (a bound iPhone signs in again, C2b/C2b-P)
///   foreignData, unenrolled     → a wall: "Remove this iPhone's data"
///   restoring                   → a wall: "Remove this iPhone's data" (this build can't
///                                  rebuild the store under the writer's verified head)
///   onboardingKeys, needsUnlock → "Opening Hasala" (the server's has_keys decides)
///   opening                     → the app, or setup where it left off
///   waitingForUnlock            → nothing yet; retried when protected data is available
///
/// One account per iPhone: a signup, or a sign-in to another address, while this iPhone
/// holds an account's data opens the "Remove this iPhone's data" wall first.
@MainActor
@Observable
final class BootController {
  enum State: Equatable {
    /// Before first unlock (or while the fresh-install purge can't finish): the Keychain
    /// can't be read yet.
    case waiting
    case decided
  }

  /// A wall in front of the account gate (spec 04 §6.5's walls this build carries out).
  enum Wall: Equatable {
    /// A signup, or a sign-in to another address, while this iPhone holds the data of the
    /// account at `email`.
    case otherAccount(email: String?)
    /// The binding, the store and the session disagree about the account (§4.4).
    case foreignData
    /// The account's key is here but this iPhone's writer key is gone.
    case unenrolled
    /// The binding and keys are here but the store is not (a restore to this iPhone).
    case restoring
    /// The account's store could not be opened.
    case openFailed
    /// The server needs a newer build (`min_ios_build`, or `426`; RD-1).
    case updateRequired
  }

  @ObservationIgnored let env: AppEnvironment
  /// The account gate's state. Replaced once, when the first phase is decided.
  private(set) var session: AccountSession
  /// Everything onboarding remembers, for the life of the process (plan B3): it outlives
  /// the gate's rebuild for a new session, the launch view and the walls.
  @ObservationIgnored let onboarding: OnboardingStore
  private(set) var state: State = .waiting
  /// The open account, while the gate is at setup or the app.
  private(set) var runtime: AccountRuntime?
  /// The screens' app model over the runtime's ledger (one per opened runtime).
  private(set) var app: AppModel?
  @ObservationIgnored private var widgets: WidgetPublisher?
  /// Bumped per opened runtime, so the tab shell is rebuilt for a new account.
  private(set) var generation = 0
  /// Where setup resumes after a relaunch mid-setup.
  private(set) var setupFacts = OnboardingStep.Facts(hasSession: true, keysReady: true)
  /// The wall on screen, if any.
  private(set) var wall: Wall?
  /// "Remove this iPhone's data" is running.
  private(set) var erasing = false
  private(set) var syncHalt: HaltKind?
  private(set) var retryingSync = false

  @ObservationIgnored private let account: LiveAccountService
  @ObservationIgnored private let services: AccountServices
  /// The runtime being opened; its value is the runtime once it is open (before its
  /// launch run).
  @ObservationIgnored private var opening: Task<AccountRuntime?, Never>?
  @ObservationIgnored private var closing: Task<Void, Never>?
  /// Bumped by every open and close, so an older opening can't publish or clear a newer one.
  @ObservationIgnored private var openingID = 0
  @ObservationIgnored private var lastPhase: AccountSession.Phase?
  @ObservationIgnored private var observingProtectedData = false
  @ObservationIgnored private var startRetry: Task<Void, Never>?
  @ObservationIgnored private var startRetryDelay: Duration = .seconds(1)

  init(env: AppEnvironment) {
    self.env = env
    let account = LiveAccountService(env: env.account, build: env.build)
    self.account = account
    let holder = RuntimeHolder()
    let unseenPhrase = StoredUnseenPhrase()
    services = AccountServices(
      account: account, mailbox: LiveMailboxConnecting(
        runtime: { holder.boot?.runtime }, buildProviders: LiveMailboxConnecting.providers(build: env.build)),
      setup: LiveSetupAuthoring(runtime: { holder.boot?.runtime }), notifications: SystemNotificationPermission(),
      hasPasscode: env.hasPasscode, cloudSort: LiveCloudSort(runtime: { holder.boot?.runtime }),
      unseenPhrase: unseenPhrase)
    let first = AccountSession(services: services, phase: .signedOut)
    session = first
    onboarding = OnboardingStore(services: services, session: { [weak holder] in holder?.boot?.session ?? first })
    holder.boot = self
    account.hooks = LiveAccountHooks(
      engine: { [weak self] in self?.runtime?.engine },
      context: { [weak self] in self?.runtime?.context },
      pause: { [weak self] in await self?.runtime?.coordinator.pause() },
      resume: { [weak self] in await self?.runtime?.coordinator.resume() },
      left: { [weak self] in await self?.left() },
      otherAccountHere: { [weak self] email in self?.wall = .otherAccount(email: email) })
    // The BGTaskScheduler tasks run the open account's coordinator (spec 04 §7.9). A task
    // can launch the app cold, before the account has opened: it waits for the opening.
    BackgroundScheduler.shared.install { kind, _ in
      guard let rt = await AppGraph.boot?.openedRuntime() else { return false }
      return await rt.backgroundWork(kind)
    }
  }

  /// Setup and the root view wait for the runtime: setup authors into it, and resumes
  /// from what it holds.
  var waitingForRuntime: Bool {
    guard state == .decided, runtime == nil, wall == nil else { return false }
    switch session.phase {
    case .onboarding, .ready: return true
    default: return false
    }
  }

  // MARK: Launch

  /// Decides the first screen. Called when the process starts (`AppDelegate`) and when
  /// the window appears; only the first call that can read the Keychain decides.
  func start() {
    guard state == .waiting else { return }
    guard case .done = env.retryInstallCheck() else { return waitForProtectedData() }
    // The Keychain may be read from here on (§4.4, R-03).
    let facts = Boot.gather(env.account)
    let boot = Boot.decide(facts)
    if boot == .waitingForUnlock { return waitForProtectedData() }
    startRetry?.cancel()
    startRetry = nil
    account.loadProfile()
    LocalAccountData.migrate(boundUserID: facts.binding?.user_id)
    MerchantSuggestionsSetting.migrateReviewAsk(setupFinished: LocalAccountData.setupFinished())
    let (phase, wall) = Self.initialPhase(boot, finished: LocalAccountData.setupFinished())
    self.wall = wall
    session = AccountSession(services: services, phase: phase)
    state = .decided
    phaseChanged(session.phase)
    let env = self.env.account
    Task { await LiveAccountService.retryPendingLogout(env) }
  }

  /// Launched before first unlock, or the purge couldn't finish: decide once protected
  /// data is available. A purge that failed while protected data IS available gets no
  /// such notification, so it is retried on a backing-off timer too.
  private func waitForProtectedData() {
    if !observingProtectedData {
      observingProtectedData = true
      NotificationCenter.default.addObserver(
        forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.start() }
      }
    }
    guard UIApplication.shared.isProtectedDataAvailable, startRetry == nil else { return }
    let delay = startRetryDelay
    startRetryDelay = min(startRetryDelay * 2, .seconds(30))
    startRetry = Task { [weak self] in
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled else { return }
      self?.startRetry = nil
      self?.start()
    }
  }

  /// The gate's first phase and wall from what is on this iPhone (§6.5, no network).
  static func initialPhase(_ boot: BootState, finished: Bool) -> (AccountSession.Phase, Wall?) {
    switch boot {
    case .signedOut, .signedOutBound, .waitingForUnlock: (.signedOut, nil)
    case .foreignData: (.signedOut, .foreignData)
    case .unenrolled: (.signedOut, .unenrolled)
    case .restoring: (.signedOut, .restoring)
    // A session without keys here: a sign-in killed before unlock, or C1 killed before
    // its bootstrap. The server's `has_keys` tells them apart (`AccountSession.resume`).
    case .onboardingKeys, .needsUnlock: (.checking, nil)
    case .opening: (finished ? .ready : .onboarding(.bank), nil)
    }
  }

  // MARK: Phase changes

  /// The gate moved: open the account when it reaches setup or the app, close it when
  /// it leaves. Called by the root view on every phase change.
  func phaseChanged(_ phase: AccountSession.Phase) {
    let previous = lastPhase
    lastPhase = phase
    switch phase {
    case .onboarding, .ready, .frozen:
      if case .onboarding? = previous, phase == .ready { LocalAccountData.markSetupFinished() }
      // A new iPhone unlocked: the account's setup was done on the first one.
      if case .needsUnlock? = previous, phase == .ready { LocalAccountData.markSetupFinished() }
      openRuntimeIfNeeded()
    case .signedOut:
      app?.forgetHomeLayout()
      HomeLayoutStore.forgetAll()
      Task { await closeRuntime() }
    case .checking, .needsUnlock, .needsKeys:
      break
    }
  }

  /// The open runtime, waiting for one that is opening (a silent push or a background
  /// task that launched the app). Returns once the account is open, without waiting for
  /// its launch run (a caller's run coalesces with it).
  func openedRuntime() async -> AccountRuntime? {
    if let runtime { return runtime }
    if let opening { return await opening.value }
    return runtime
  }

  /// The app came to the foreground: catch up (at most once a minute), and finish a
  /// sign-out that couldn't reach the server.
  func foreground() {
    if state == .waiting { start() }
    let env = self.env.account
    Task { await LiveAccountService.retryPendingLogout(env) }
    guard let rt = runtime else { return }
    if syncHalt != nil { return retrySync() }
    Task { await rt.coordinator.run(.foreground) }
    Task { await rt.backlog.resume() }
  }

  private func openRuntimeIfNeeded() {
    guard runtime == nil, opening == nil, wall == nil, let binding = try? env.account.secrets.binding() else { return }
    // The binding and keys are here but the store isn't (a restore to this iPhone, §4.7
    // row 8). A fresh store would restart this writer's chain at zero; this build can't
    // set it from the verified server head, so it asks to start this iPhone again.
    if account.enrolled?.userID.string != binding.user_id, !Self.storeExists(env.account, binding) {
      wall = .restoring
      return
    }
    let env = self.env
    let account = self.account
    let profile = Self.profileInfo(account.profile, binding: binding)
    let stopped: @Sendable (SyncStop) async -> Void = { [weak self] stop in await self?.stopped(stop) }
    openingID += 1
    let id = openingID
    let closing = self.closing
    opening = Task { [weak self] in
      await closing?.value
      let rt: AccountRuntime
      do {
        rt = try await AccountRuntime.open(
          env: env.account, binding: binding, enrolled: account.enrolled, build: env.build, profile: profile,
          usesPasskey: { await account.usesPasskey() }, stopped: stopped)
      } catch {
        // The store or projection could not open (a disk or protection failure, or a
        // store left half-made): a wall offers Try again and starting this iPhone over.
        guard let self, self.openingID == id else { return nil }
        self.opening = nil
        if self.session.phase != .signedOut { self.wall = .openFailed }
        return nil
      }
      guard let self, self.openingID == id, self.session.phase != .signedOut else {
        await rt.close()
        return nil
      }
      var facts = Self.facts(rt)
      if let phase = rt.store.mailboxPhase { facts.mailbox = Self.mailboxFact(phase) }
      self.opening = nil
      self.runtime = rt
      let layouts = HomeLayoutStore(account: LocalAccountData.digest(binding.user_id, salt: LocalAccountData.salt()))
      let app = AppModel(store: rt.store, mailbox: self.services.mailbox, layouts: layouts)
      if BuildSurface.showsCloudSuggestions { app.cloudSort = LiveCloudSortController(runtime: rt) }
      rt.store.onWriteFailed = { [weak app] in app?.writeFailed() }
      // Pull to refresh waits at most 20 s; the run carries on without it.
      app.refreshWork = { [weak rt] in _ = await rt?.coordinator.run(.refresh, budget: .seconds(20)) }
      self.app = app
      self.widgets = WidgetPublisher(app: app, locked: { [weak app] in app?.store.state.prefs.faceIDLock ?? false })
      self.generation += 1
      self.setupFacts = facts
      rt.onAccount = { [weak self, weak rt] info in
        guard let self, let rt, self.runtime === rt else { return }
        account.noteAccount(info)
        if info.has_keys == true {
          await self.services.unseenPhrase.adopt(serverUnseenSince: LiveAccountService.instant(info.phrase_unseen_since))
        }
        rt.store.profile = Self.profileInfo(account.profile, binding: binding)
        self.session.reviewAccount = rt.reviewAccount
        await rt.store.reload()
      }
      BackgroundScheduler.shared.scheduleRefresh()
      Task { [weak self] in await self?.launch(rt, binding: binding) }
      return rt
    }
  }

  /// The launch run, then APNs registration for the account that is still open.
  private func launch(_ rt: AccountRuntime, binding: AccountBinding) async {
    await rt.start(buildNumber: env.buildNumber, stopped: { [weak self] stop in await self?.stopped(stop) })
    guard runtime === rt else { return }
    PushRegistrar.shared.register(env: env.account, userID: binding.user_id)
  }

  /// This iPhone left the account (signed out, removed, the account deleted): the
  /// runtime closes and the gate goes back to Welcome, whichever screen asked.
  private func left() async {
    await closeRuntime()
    wall = nil
    if session.phase != .signedOut { session.signedOut() }
  }

  /// Closes the open account's runtime (sign-out, removal, deletion, a wipe).
  func closeRuntime() async {
    // What was searched belongs to the account that is closing (merchant names): the next
    // account opened in this process starts with none.
    SearchHistory.shared.clear()
    WidgetLinkInbox.shared.pending = nil
    widgets?.stop()
    widgets = nil
    WidgetPublisher.clear()
    openingID += 1
    opening?.cancel()
    opening = nil
    BackgroundScheduler.shared.cancelAll()
    syncHalt = nil
    setupFacts = OnboardingStep.Facts(hasSession: true, keysReady: true)
    guard let rt = runtime else { return }
    runtime = nil
    app = nil
    session.reviewAccount = false
    PushRegistrar.shared.forget()
    let previous = closing
    let task = Task {
      await previous?.value
      await rt.close()
    }
    closing = task
    await task.value
  }

  // MARK: Walls

  /// "Try again" on a wall that offers it.
  func tryAgain() {
    switch wall {
    case .openFailed:
      wall = nil
      openRuntimeIfNeeded()
    case .updateRequired:
      wall = nil
      if let rt = runtime, let binding = try? env.account.secrets.binding() {
        Task { await launch(rt, binding: binding) }
      }
    default:
      break
    }
  }

  func retrySync() {
    guard syncHalt != nil, !retryingSync, let rt = runtime else { return }
    retryingSync = true
    Task {
      let out = await rt.coordinator.run(.refresh)
      retryingSync = false
      guard runtime === rt else { return }
      if Self.clearsSyncHalt(out.stop) { syncHalt = nil }
    }
  }

  static func clearsSyncHalt(_ stop: SyncStop?) -> Bool {
    stop.map(WorkCoordinator.tolerable) ?? true
  }

  static func syncHalt(for stop: SyncStop) -> HaltKind? {
    guard case .halted(let kind) = stop, kind != .updateRequired else { return nil }
    return kind
  }

  /// "Back" on the other-account wall: Welcome, as it was.
  func dismissWall() {
    if case .otherAccount = wall { wall = nil }
  }

  /// "Remove this iPhone's data" (spec 04 §4.7 row 2 without the server's revocation,
  /// which needs a store this iPhone can't open or a session for that account): sign the
  /// session out, wipe every account's items and files here, then Welcome. The old
  /// writer stays in Devices, for removal from another iPhone.
  func eraseThisIPhone() async {
    guard !erasing else { return }
    erasing = true
    await closeRuntime()
    await env.eraseLocalData()
    account.forgetAll()
    wall = nil
    erasing = false
    if session.phase != .signedOut { session.signedOut() }
  }

  // MARK: Stops only the gate can act on

  private func stopped(_ stop: SyncStop) async {
    switch stop {
    case .wipe:
      // `410 account_deleted` or `403 writer_revoked`: the account was deleted, or this
      // iPhone removed, on another device (§4.7 row 3). The Google grant is read before
      // the wipe and revoked after it.
      let binding = try? env.account.secrets.binding()
      let grant = binding?.userID.flatMap { MailboxLane.heldGrant(secrets: env.account.secrets, userID: $0) }
      await closeRuntime()
      if let b = binding, let u = b.userID { AccountWipe.wipe(env.account, userID: u, writerID: b.writerID) }
      try? env.account.secrets.deleteSession()
      LocalAccountData.forget()
      account.forgetAll()
      if let grant {
        // Through the queue a later connect waits for (`MailGrantEnds`).
        let build = env.build
        MailGrantEnds.shared.enqueue { await MailboxLane.endGrant(grant, build: build, stopWatch: false) }
      }
      session.signedOut()
    case .needsSignIn, .needsRebind:
      // The session is gone (expired, signed out everywhere): sign in again. The data and
      // keys stay; the next sign-in re-binds this iPhone's writer (C2b, C2b-P).
      await closeRuntime()
      try? env.account.secrets.deleteSession()
      session.signedOut()
    case .frozen:
      // Who froze it decides whether the wall offers Unfreeze (spec 04 §6.11), so it is
      // read from `GET /account` first. Unknown (offline) keeps what the app knew, else
      // shows the holder's wall; its Unfreeze reads `frozen_by` again before any #66.
      // After "Leave it frozen" the banner stays.
      let info = await account.freezeInfo()
      guard session.phase != .signedOut else { return }
      session.runFoundFrozen(info)
    case .needsUnlock, .keysRequired:
      await closeRuntime()
      session.signedOut()
    case .halted(.updateRequired):
      wall = .updateRequired
    case .halted:
      guard runtime != nil, let kind = Self.syncHalt(for: stop) else { return }
      syncHalt = kind
    default:
      break
    }
  }

  // MARK: Setup

  /// Where setup resumes, from what the account's ledger already holds (§6.6: derived
  /// from facts, never stored).
  static func facts(_ rt: AccountRuntime) -> OnboardingStep.Facts {
    var f = OnboardingStep.Facts(hasSession: true, keysReady: true)
    let r = rt.projection.reader
    f.banksChosen = !((try? r.senderTrust()) ?? [:]).isEmpty
    f.sampleLoaded = ((try? r.activity(limit: 1_000)) ?? []).contains { $0.mailboxMessageID?.hasPrefix("sample-") == true }
    return f
  }

  /// The mailbox step's fact from the lane's own state: a relaunch mid-scan resumes at the
  /// scan or the cards, and a linked mailbox skips the mailbox step.
  static func mailboxFact(_ phase: MailboxPhase) -> OnboardingStep.Facts.Mailbox {
    switch phase {
    case .unlinked: .unlinked
    // A scan left at the retired cards step is filed on the lane's next run.
    case .scanning, .awaitingCards: .scanning
    case .otherDevice: .otherDevice
    case .authoringBackfill, .active, .reconnectRequired, .halted: .linked
    }
  }

  /// Whether the account's store file is on this iPhone.
  static func storeExists(_ env: AccountEnvironment, _ binding: AccountBinding) -> Bool {
    guard let u = binding.userID, let dir = env.storeDirectory(for: u) else { return true }
    return FileManager.default.fileExists(atPath: dir.appendingPathComponent("ledger.sqlite").path)
  }

  /// The profile row's identity from the account service's profile (or the binding).
  static func profileInfo(_ p: AccountProfile?, binding: AccountBinding) -> ProfileInfo {
    ProfileInfo(
      displayName: p?.displayName.isEmpty == false ? p!.displayName : (binding.display_name ?? ""),
      email: p?.email.isEmpty == false ? p!.email : binding.email_norm,
      signIn: p?.method == .password ? .password : .passkey)
  }
}

/// The setup services are built before the controller that owns the runtime they use.
@MainActor
private final class RuntimeHolder {
  weak var boot: BootController?
}

/// The live graph, once per process, and its entry point for UIKit callbacks
/// (`AppDelegate`).
@MainActor
enum AppGraph {
  private(set) static var boot: BootController?

  /// The process's live graph, built on first use.
  static func live() -> BootController {
    if let boot { return boot }
    let made = BootController(env: .live())
    boot = made
    return made
  }
}
