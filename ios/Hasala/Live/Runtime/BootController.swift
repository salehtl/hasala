import CoreAuth
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
/// by the server, frozen).
///
///   signedOut, foreignData, signedOutBound, unenrolled → Welcome (sign in again; a bound
///                                                         iPhone re-binds, C2b/C2b-P)
///   onboardingKeys, needsUnlock → "Opening Hasala" (the server's has_keys decides)
///   opening, restoring          → the app, or setup where it left off
///   waitingForUnlock            → nothing yet; retried when protected data is available
@MainActor
@Observable
final class BootController {
  enum State: Equatable {
    /// Before first unlock: the Keychain can't be read yet.
    case waiting
    case decided
  }

  @ObservationIgnored let env: AppEnvironment
  /// The account gate's state. Replaced once, when the first phase is decided.
  private(set) var session: AccountSession
  private(set) var state: State = .waiting
  /// The open account, while the gate is at setup or the app.
  private(set) var runtime: AccountRuntime?
  /// The screens' app model over the runtime's ledger (one per opened runtime).
  private(set) var app: AppModel?
  /// Bumped per opened runtime, so the tab shell is rebuilt for a new account.
  private(set) var generation = 0
  /// Where setup resumes after a relaunch mid-setup.
  private(set) var setupFacts = OnboardingStep.Facts(hasSession: true, keysReady: true)

  @ObservationIgnored private let account: LiveAccountService
  @ObservationIgnored private let services: AccountServices
  @ObservationIgnored private var opening: Task<Void, Never>?
  @ObservationIgnored private var lastPhase: AccountSession.Phase?

  init(env: AppEnvironment) {
    self.env = env
    let account = LiveAccountService(env: env.account)
    self.account = account
    let holder = RuntimeHolder()
    services = AccountServices(
      account: account, mailbox: LiveMailboxConnecting(runtime: { holder.boot?.runtime }),
      setup: LiveSetupAuthoring(runtime: { holder.boot?.runtime }), notifications: SystemNotificationPermission(),
      hasPasscode: env.hasPasscode)
    session = AccountSession(services: services, phase: .signedOut)
    holder.boot = self
    account.hooks = LiveAccountHooks(
      engine: { [weak self] in self?.runtime?.engine },
      left: { [weak self] in await self?.left() })
  }

  /// Setup and the root view wait for the runtime: setup authors into it, and resumes
  /// from what it holds.
  var waitingForRuntime: Bool {
    guard state == .decided, runtime == nil else { return false }
    switch session.phase {
    case .onboarding, .ready: return true
    default: return false
    }
  }

  // MARK: Launch

  /// Decides the first screen. Call once, when the window appears.
  func start() {
    guard state == .waiting else { return }
    guard case .done = env.retryInstallCheck() else {
      // Launched before first unlock: decide once protected data is available.
      NotificationCenter.default.addObserver(
        forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.start() }
      }
      return
    }
    let phase = Self.initialPhase(Boot.decide(Boot.gather(env.account)), finished: setupFinished)
    session = AccountSession(services: services, phase: phase)
    state = .decided
    phaseChanged(session.phase)
  }

  /// The gate's first phase from what is on this iPhone (§6.5, no network).
  static func initialPhase(_ boot: BootState, finished: (String) -> Bool) -> AccountSession.Phase {
    switch boot {
    case .signedOut, .foreignData, .signedOutBound, .unenrolled, .waitingForUnlock: .signedOut
    // A session without keys here: a sign-in killed before unlock, or C1 killed before
    // its bootstrap. The server's `has_keys` tells them apart (`AccountSession.resume`).
    case .onboardingKeys, .needsUnlock: .checking
    case .restoring: .ready
    case .opening(let binding): finished(binding.user_id) ? .ready : .onboarding(.bank)
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
      if case .onboarding? = previous, phase == .ready, let b = try? env.account.secrets.binding() {
        markSetupFinished(b.user_id)
      }
      if case .needsUnlock? = previous, phase == .ready, let b = try? env.account.secrets.binding() {
        // A new iPhone unlocked: the account's setup was done on the first one.
        markSetupFinished(b.user_id)
      }
      openRuntimeIfNeeded()
    case .signedOut:
      Task { await closeRuntime() }
    case .checking, .needsUnlock, .needsKeys:
      break
    }
  }

  /// The open runtime, waiting for one that is opening (a silent push or a background
  /// task that launched the app).
  func openedRuntime() async -> AccountRuntime? {
    if let runtime { return runtime }
    await opening?.value
    return runtime
  }

  /// The app came to the foreground: catch up (at most once a minute).
  func foreground() {
    guard let rt = runtime else { return }
    Task { await rt.coordinator.run(.foreground) }
  }

  private func openRuntimeIfNeeded() {
    guard runtime == nil, opening == nil, let binding = try? env.account.secrets.binding() else { return }
    let env = self.env
    let account = self.account
    let profile = Self.profileInfo(account.profile, binding: binding)
    let stopped: @Sendable (SyncStop) async -> Void = { [weak self] stop in await self?.stopped(stop) }
    opening = Task { [weak self] in
      defer { self?.opening = nil }
      do {
        let rt = try await AccountRuntime.open(
          env: env.account, binding: binding, enrolled: account.enrolled, build: env.build, profile: profile,
          usesPasskey: { await MainActor.run { account.profile?.method == .passkey } },
          stopped: stopped)
        guard let self, self.session.phase != .signedOut else {
          await rt.close()
          return
        }
        self.runtime = rt
        self.app = AppModel(store: rt.store)
        self.generation += 1
        self.setupFacts = Self.facts(rt)
        self.installBackgroundWork(rt)
        await rt.start(buildNumber: env.buildNumber, stopped: stopped)
        if let info = rt.account {
          account.noteAccount(info)
          rt.store.profile = Self.profileInfo(account.profile, binding: binding)
          await rt.store.reload()
        }
        self.session.reviewAccount = rt.reviewAccount
        PushRegistrar.shared.register(env: env.account, userID: binding.user_id)
      } catch {
        // The store or projection could not open (a disk or protection failure): the
        // gate stays where it is, and the next phase change or launch tries again.
      }
    }
  }

  /// This iPhone left the account (signed out, removed, the account deleted): the
  /// runtime closes and the gate goes back to Welcome, whichever screen asked.
  private func left() async {
    await closeRuntime()
    if session.phase != .signedOut { session.signedOut() }
  }

  /// Closes the open account's runtime (sign-out, removal, deletion, a wipe).
  func closeRuntime() async {
    opening?.cancel()
    opening = nil
    BackgroundScheduler.shared.install(nil)
    BackgroundScheduler.shared.cancelAll()
    guard let rt = runtime else { return }
    runtime = nil
    app = nil
    session.reviewAccount = false
    PushRegistrar.shared.forget()
    await rt.close()
  }

  /// Hands the BGTaskScheduler tasks to this account's coordinator (spec 04 §7.9).
  private func installBackgroundWork(_ rt: AccountRuntime) {
    let coordinator = rt.coordinator
    let lane = rt.lane
    BackgroundScheduler.shared.install { kind, _ in
      switch kind {
      case .refresh:
        _ = await coordinator.run(.bgRefresh, budget: .seconds(25))
        return false
      case .processing:
        _ = await coordinator.run(.bgProcessing)
        guard let lane else { return false }
        let phase = await lane.status().phase
        return phase == .scanning || phase == .authoringBackfill
      }
    }
    BackgroundScheduler.shared.scheduleRefresh()
  }

  // MARK: Stops only the gate can act on

  private func stopped(_ stop: SyncStop) async {
    switch stop {
    case .wipe:
      // `410 account_deleted`: the account was deleted on another device (§4.7 row 4).
      let binding = try? env.account.secrets.binding()
      await closeRuntime()
      if let b = binding, let u = b.userID { AccountWipe.wipe(env.account, userID: u, writerID: b.writerID) }
      try? env.account.secrets.deleteSession()
      session.signedOut()
    case .needsSignIn, .needsRebind:
      // The session is gone (expired, signed out everywhere): sign in again. The data and
      // keys stay; the next sign-in re-binds this iPhone's writer (C2b, C2b-P).
      await closeRuntime()
      try? env.account.secrets.deleteSession()
      session.signedOut()
    case .frozen:
      session.froze(FreezeInfo(by: .holder, when: nil))
    case .needsUnlock, .keysRequired:
      await closeRuntime()
      session.signedOut()
    default:
      break
    }
  }

  // MARK: Setup

  private static let finishedKey = "setup.finished.v1"

  private func setupFinished(_ userID: String) -> Bool {
    (UserDefaults.standard.stringArray(forKey: Self.finishedKey) ?? []).contains(userID)
  }

  private func markSetupFinished(_ userID: String) {
    var ids = UserDefaults.standard.stringArray(forKey: Self.finishedKey) ?? []
    if !ids.contains(userID) {
      ids.append(userID)
      UserDefaults.standard.set(ids, forKey: Self.finishedKey)
    }
  }

  /// Where setup resumes, from what the account's ledger already holds (§6.6: derived
  /// from facts, never stored).
  static func facts(_ rt: AccountRuntime) -> OnboardingStep.Facts {
    var f = OnboardingStep.Facts(hasSession: true, keysReady: true)
    let r = rt.projection.reader
    f.banksChosen = !((try? r.senderTrust()) ?? [:]).isEmpty
    f.sampleLoaded = ((try? r.activity(limit: 1_000)) ?? []).contains { $0.mailboxMessageID?.hasPrefix("sample-") == true }
    f.incomeSet = !((try? r.incomeSources()) ?? []).isEmpty
    f.planSet = (try? r.budgetTemplate()) != nil
    f.notificationsAsked = UserDefaults.standard.bool(forKey: "prefs.setup.notificationsAsked")
    return f
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
