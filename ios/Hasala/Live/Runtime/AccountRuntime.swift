import CoreAuth
import CoreCategorize
import CoreDomain
import CoreMailbox
import CoreOutbox
import CoreProjection
import CoreSync
import Foundation
import HasalaModels
import Observation

/// One bound account, open (spec 04 §3, §2.1 step 6): its ledger store and projection,
/// the fold observer, the sync engine, the outbox, the Gmail lane, the screens' ledger,
/// and the coordinator that runs them. Built by `BootController` once the account has
/// keys on this iPhone (after signup, after unlock, or at launch from the binding), and
/// closed on sign-out or a wipe.
@MainActor
@Observable
final class AccountRuntime {
  @ObservationIgnored let env: AccountEnvironment
  @ObservationIgnored let binding: AccountBinding
  @ObservationIgnored let context: SyncContext
  @ObservationIgnored let projection: ProjectionStore
  @ObservationIgnored let observer: LedgerPageObserver
  @ObservationIgnored let engine: SyncEngine
  @ObservationIgnored let outbox: Outbox
  @ObservationIgnored let coordinator: WorkCoordinator
  @ObservationIgnored let lane: GmailLane?
  @ObservationIgnored let mailboxLedger: RuntimeMailboxLedger
  /// The server's mailbox routes (the Gmail lane's, and the link check below).
  @ObservationIgnored let mailboxServer: any MailboxServer
  let store: LiveLedgerStore

  /// The account's Gmail link on the server (#37), asked while this iPhone has none: a
  /// link held by another iPhone means Gmail is read there (spec 04 §6.6's second iPhone,
  /// §7.4 `other_device`). nil until the server answers.
  private(set) var serverLink: MailboxLinkStatus?

  /// `GET /account`'s `review_account` (#40), read live when the account opens: the App
  /// Review demo account, whose ledger is sample data. Until an answer arrives, every
  /// run asks again (an offline launch must not hide "Use sample data" for good).
  private(set) var reviewAccount = false
  /// The last `GET /account` answer, when one arrived.
  @ObservationIgnored private(set) var account: AccountInfo?
  /// Told each `GET /account` answer (the gate updates the profile and the review flag).
  @ObservationIgnored var onAccount: (@MainActor (AccountInfo) async -> Void)?

  /// The bundled merchant dictionary (`.empty` when its tier is off).
  nonisolated static let dictionary = (try? MerchantDictionary.bundled().get()) ?? .empty

  private init(
    env: AccountEnvironment, binding: AccountBinding, context: SyncContext, projection: ProjectionStore,
    observer: LedgerPageObserver, engine: SyncEngine, outbox: Outbox, coordinator: WorkCoordinator, lane: GmailLane?,
    mailboxLedger: RuntimeMailboxLedger, mailboxServer: any MailboxServer, store: LiveLedgerStore
  ) {
    self.env = env
    self.binding = binding
    self.context = context
    self.projection = projection
    self.observer = observer
    self.engine = engine
    self.outbox = outbox
    self.coordinator = coordinator
    self.lane = lane
    self.mailboxLedger = mailboxLedger
    self.mailboxServer = mailboxServer
    self.store = store
  }

  var userID: UserID { context.userID }

  /// "Use sample data" is offered on a review account whose ledger holds no
  /// transaction (spec 04 §6.13; plan §2.5). The loader checks both again, live.
  var offersSampleData: Bool { reviewAccount && store.loaded && store.state.txns.isEmpty }

  /// Home's "Connect Gmail" card and the Profile card's action (spec 04 §6.6 row 4, §7.4):
  /// nothing until the lane's phase and the ledger have been read, and nothing in a build
  /// without a Google client.
  var gmailOffer: GmailOffer? {
    guard lane != nil, store.loaded, let phase = store.mailboxPhase else { return nil }
    return LiveMailboxConnecting.offer(phase: phase, sampleLoaded: store.holdsSample, serverLink: serverLink)
  }

  /// Reads the Gmail lane's state again (after a connect, the first scan or the cards
  /// step), so Home and Profile follow it before the next run.
  func refreshMailbox() async {
    guard let lane else { return }
    store.noteMailbox(await lane.status(), nowMs: context.clock.nowMs())
    await store.reload()
    await checkServerLinkIfUnknown()
  }

  /// Asks the server for the account's Gmail link once, while this iPhone has none (the
  /// lane's cycle never asks then); offline, the next run asks again.
  func checkServerLinkIfUnknown() async {
    guard lane != nil, serverLink == nil, store.mailboxPhase == .unlinked else { return }
    serverLink = try? await mailboxServer.linkStatus()
  }

  /// Opens the account. `enrolled` is the ceremony's freshly enrolled account (its store
  /// is already open); otherwise the store opens from the binding.
  static func open(
    env: AccountEnvironment, binding: AccountBinding, enrolled: EnrolledAccount?, build: BuildInfo,
    profile: ProfileInfo, usesPasskey: @escaping @Sendable () async -> Bool,
    stopped: @escaping @Sendable (SyncStop) async -> Void
  ) async throws -> AccountRuntime {
    let context: SyncContext
    if let enrolled, enrolled.userID.string == binding.user_id {
      context = Enrolment.context(env, account: enrolled)
    } else {
      context = try Enrolment.context(env, binding: binding)
    }
    let projection: ProjectionStore
    if let dir = env.storeDirectory(for: context.userID) {
      projection = try ProjectionStore.open(directory: dir)
    } else {
      projection = try ProjectionStore.inMemory()
    }
    let observer = LedgerPageObserver(context: context, projection: projection, dictionary: dictionary)
    let engine = SyncEngine(context: context, observer: observer)
    let box = CoordinatorBox()
    let outbox = Outbox(store: context.store, clock: context.clock) {
      await box.get()?.run(.authored)
    }
    let afterRun = AfterRun()
    let authoring = MailboxAuthoring(observer: observer)
    let mailboxLedger = RuntimeMailboxLedger(engine: engine, observer: observer, outbox: outbox, authoring: authoring)
    let mailboxServer = HTTPMailboxServer(
      http: SessionHTTPExchange(transport: env.client.api.transport, secrets: env.secrets), base: env.apiBase)
    let lane = GmailLane(
      build: build, secrets: env.secrets, userID: context.userID,
      persistence: LedgerMailboxPersistence(store: context.store, authoring: authoring, nowMs: { context.clock.nowMs() }),
      ledger: mailboxLedger, server: mailboxServer,
      stepUp: LiveStepUp(env: env, usesPasskey: usesPasskey, askPassword: { await PasswordPrompt.ask($0) }),
      categorizer: PipelineCategorizer(projection: projection, dictionary: dictionary),
      presenter: WebAuthenticationPresenter())
    let store = LiveLedgerStore(
      reader: projection.reader, author: LedgerEditAuthor(observer: observer, outbox: outbox), profile: profile,
      prefs: DevicePrefsStore())
    let coordinator = WorkCoordinator(
      stages: WorkCoordinator.Stages(
        sync: { trigger, deadline in
          let out = await engine.run(trigger, deadline: deadline)
          if let seen = try? await observer.seenStamps() { authoring.updateSeen(seen) }
          return (out.newData, out.stop)
        },
        mailbox: lane.map { lane -> @Sendable (MailboxTrigger, Int64?) async -> CycleReport in
          { @Sendable trigger, deadlineMs in await lane.cycle(trigger: trigger, deadlineMs: deadlineMs) }
        },
        committed: {
          if let lane {
            let status = await lane.status()
            await MainActor.run { store.noteMailbox(status, nowMs: context.clock.nowMs()) }
          }
          await store.reload()
          await afterRun.run()
        },
        stopped: stopped))
    box.set(coordinator)
    try await observer.open()
    if let lane { store.noteMailbox(await lane.status(), nowMs: context.clock.nowMs()) }
    await store.reload()
    let rt = AccountRuntime(
      env: env, binding: binding, context: context, projection: projection, observer: observer, engine: engine,
      outbox: outbox, coordinator: coordinator, lane: lane, mailboxLedger: mailboxLedger, mailboxServer: mailboxServer,
      store: store)
    afterRun.set { [weak rt] in
      await rt?.refreshAccountIfUnknown()
      await rt?.checkServerLinkIfUnknown()
    }
    return rt
  }

  /// The launch run (spec 04 §6.5): `GET /meta` and `GET /auth/session` first, then
  /// `GET /account` (the review flag), a full run, and the account's opening ops when the
  /// ledger has none yet (home currency AED and the USD peg, §6.2).
  func start(buildNumber: Int, stopped: @escaping @Sendable (SyncStop) async -> Void) async {
    let probe = await LaunchProbe.run(context, build: buildNumber)
    switch probe {
    case .frozen:
      // Only `GET /account` and the unfreeze are allowed while frozen (§6.11).
      await stopped(.frozen)
      await refreshAccount()
      return
    case .updateRequired:
      await stopped(.halted(.updateRequired))
      return
    case .unbound:
      await stopped(.needsRebind)
      return
    case .stop(let stop) where WorkCoordinator.endsTheAccount(stop):
      await stopped(stop)
      return
    case .ok, .stop:
      break
    }
    await refreshAccount()
    let launched = await coordinator.run(.launch)
    // Only after a launch run that reached the server's head: an iPhone that couldn't
    // pull yet (offline) would author the account's opening ops a second time.
    if launched.stop == nil { await authorOpeningOpsIfNeeded() }
  }

  /// `GET /account` (#40), read live: the review flag and the account's own name.
  func refreshAccount() async {
    guard let token = try? env.secrets.session()?.token else { return }
    guard let info = try? await env.client.account(bearer: token), info.user_id == binding.user_id else { return }
    account = info
    reviewAccount = info.review_account == true
    await onAccount?(info)
  }

  /// After each run: `GET /account` again while no answer has arrived yet.
  func refreshAccountIfUnknown() async {
    if account == nil { await refreshAccount() }
  }

  /// One BGTaskScheduler task's work (spec 04 §7.9): a 25 s refresh run, or a processing
  /// run that lasts until iOS expires it. Returns whether a scan or backfill still has
  /// work for another processing window.
  func backgroundWork(_ kind: BackgroundScheduler.Kind) async -> Bool {
    switch kind {
    case .refresh:
      _ = await coordinator.run(.bgRefresh, budget: .seconds(25))
      return false
    case .processing:
      _ = await coordinator.run(.bgProcessing)
      guard let lane, !Task.isCancelled else { return false }
      let phase = await lane.status().phase
      return phase == .scanning || phase == .authoringBackfill
    }
  }

  /// Home currency AED and the USD peg (04 §6.2), once per account: authored only when
  /// the ledger (after the launch pull) has no home currency yet.
  func authorOpeningOpsIfNeeded() async {
    guard (try? projection.reader.homeCurrency()) == nil else { return }
    let observer = self.observer
    do {
      let ctx = try await observer.authorContext()
      guard
        let blob = try observer.stamps.build(
          ctx,
          { a throws(AuthorError) in
            a.setHomeCurrency("AED")
            try a.setRate(currency: "USD", rateMicro: 3_672_500)
          })
      else { return }
      try await outbox.enqueue(blob.ops)
      try await observer.reproject()
    } catch {
      // Retried on the next launch.
    }
  }

  /// "Use sample data" (spec 04 §6.13): a live `GET /account` for the gate, the bundled
  /// seed as blobs (the observer checks the review flag and the empty ledger again), each
  /// blob through the outbox, then one upload.
  func loadSample() async throws(SetupFailure) {
    guard let token = try? env.secrets.session()?.token else { throw .failed("You're signed out. Sign in again.") }
    let info: AccountInfo
    do {
      info = try await env.client.account(bearer: token)
    } catch {
      throw .offline
    }
    reviewAccount = info.review_account == true
    let blobs: [AuthoredBlob]
    do {
      blobs = try await observer.sampleBatches(account: info)
    } catch {
      throw .failed("Sample data isn't available for this account.")
    }
    do {
      for b in blobs { try await outbox.enqueue(b.ops) }
      try await observer.reproject()
    } catch {
      throw .failed("Couldn't save the sample data. Try again.")
    }
    await store.reload()
    Task { await coordinator.run(.authored) }
  }

  /// Stops the runtime's work: no more runs and no background work.
  func close() async {
    await coordinator.close()
  }
}

/// What runs after each run's screen reload, set once the runtime exists.
nonisolated final class AfterRun: @unchecked Sendable {
  private let lock = NSLock()
  private var action: (@Sendable () async -> Void)?

  func set(_ a: @escaping @Sendable () async -> Void) { lock.withLock { action = a } }
  func run() async {
    let a = lock.withLock { action }
    await a?()
  }
}

/// The outbox is built before the coordinator it triggers; this holds the reference.
nonisolated final class CoordinatorBox: @unchecked Sendable {
  private let lock = NSLock()
  private var coordinator: WorkCoordinator?

  func set(_ c: WorkCoordinator) { lock.withLock { coordinator = c } }
  func get() -> WorkCoordinator? { lock.withLock { coordinator } }
}
