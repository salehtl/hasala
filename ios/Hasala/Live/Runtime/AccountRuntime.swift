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
  let store: LiveLedgerStore

  /// `GET /account`'s `review_account` (#40), read live when the account opens: the App
  /// Review demo account, whose ledger is sample data.
  private(set) var reviewAccount = false
  /// The last `GET /account` answer, when one arrived.
  @ObservationIgnored private(set) var account: AccountInfo?

  /// The bundled merchant dictionary (`.empty` when its tier is off).
  nonisolated static let dictionary = (try? MerchantDictionary.bundled().get()) ?? .empty

  private init(
    env: AccountEnvironment, binding: AccountBinding, context: SyncContext, projection: ProjectionStore,
    observer: LedgerPageObserver, engine: SyncEngine, outbox: Outbox, coordinator: WorkCoordinator, lane: GmailLane?,
    mailboxLedger: RuntimeMailboxLedger, store: LiveLedgerStore
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
    self.store = store
  }

  var userID: UserID { context.userID }

  /// "Use sample data" is offered on a review account whose ledger holds no
  /// transaction (spec 04 §6.13; plan §2.5). The loader checks both again, live.
  var offersSampleData: Bool { reviewAccount && store.loaded && store.state.txns.isEmpty }

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
    let authoring = MailboxAuthoring(observer: observer)
    let mailboxLedger = RuntimeMailboxLedger(engine: engine, observer: observer, outbox: outbox, authoring: authoring)
    let lane = GmailLane(
      build: build, secrets: env.secrets, userID: context.userID,
      persistence: LedgerMailboxPersistence(store: context.store, authoring: authoring, nowMs: { context.clock.nowMs() }),
      ledger: mailboxLedger,
      server: HTTPMailboxServer(
        http: SessionHTTPExchange(transport: env.client.api.transport, secrets: env.secrets), base: env.apiBase),
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
        committed: { await store.reload() },
        stopped: stopped))
    box.set(coordinator)
    try await observer.open()
    await store.reload()
    return AccountRuntime(
      env: env, binding: binding, context: context, projection: projection, observer: observer, engine: engine,
      outbox: outbox, coordinator: coordinator, lane: lane, mailboxLedger: mailboxLedger, store: store)
  }

  /// The launch run (spec 04 §6.5): `GET /meta` and `GET /auth/session` first, then
  /// `GET /account` (the review flag), a full run, and the account's opening ops when the
  /// ledger has none yet (home currency AED and the USD peg, §6.2).
  func start(buildNumber: Int, stopped: @escaping @Sendable (SyncStop) async -> Void) async {
    let probe = await LaunchProbe.run(context, build: buildNumber)
    switch probe {
    case .frozen:
      await stopped(.frozen)
    case .unbound:
      await stopped(.needsRebind)
      return
    case .stop(let stop) where WorkCoordinator.endsTheAccount(stop):
      await stopped(stop)
      return
    case .ok, .updateRequired, .stop:
      break
    }
    await refreshAccount()
    await coordinator.run(.launch)
    await authorOpeningOpsIfNeeded()
  }

  /// `GET /account` (#40), read live: the review flag and the account's own name.
  func refreshAccount() async {
    guard let token = try? env.secrets.session()?.token else { return }
    guard let info = try? await env.client.account(bearer: token), info.user_id == binding.user_id else { return }
    account = info
    reviewAccount = info.review_account == true
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

/// The outbox is built before the coordinator it triggers; this holds the reference.
nonisolated final class CoordinatorBox: @unchecked Sendable {
  private let lock = NSLock()
  private var coordinator: WorkCoordinator?

  func set(_ c: WorkCoordinator) { lock.withLock { coordinator = c } }
  func get() -> WorkCoordinator? { lock.withLock { coordinator } }
}
