import CoreAuth
import CoreCategorize
import CoreDomain
import CoreMailbox
import CoreOutbox
import CoreProjection
import CoreSync
import CoreStore
import Foundation
import HasalaCloud
import HasalaModel
import HasalaModels
import Observation

/// One bound account, open (spec 04 §3, §2.1 step 6): its ledger store and projection,
/// the fold observer, the sync engine, the outbox, the mailbox lanes, the screens' ledger,
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
  /// A lane per provider this build has a client for. They share the mailbox tables; one
  /// runs at a time (`lane`), the provider of the account's link on this iPhone.
  @ObservationIgnored let lanes: [MailboxProvider: MailboxLane]
  @ObservationIgnored private let active: ActiveLane
  @ObservationIgnored let mailboxLedger: RuntimeMailboxLedger
  /// The server's mailbox routes (the lanes', and the link check below).
  @ObservationIgnored let mailboxServer: HTTPMailboxServer
  @ObservationIgnored let backlog: BacklogSorter
  @ObservationIgnored let suggestions: ModelSuggestionStage
  @ObservationIgnored private var switchOff: NSObjectProtocol?
  @ObservationIgnored private var switchOn: NSObjectProtocol?
  let store: LiveLedgerStore

  /// The provider the running lane reads (observed: Profile names it).
  private(set) var activeProvider: MailboxProvider?

  /// The account's mailbox link on the server (#37), asked while this iPhone has none: a
  /// link held by another iPhone means the mail is read there (spec 04 §6.6's second iPhone,
  /// §7.4 `other_device`). nil until the server answers; the last answer while offline.
  private(set) var serverLink: MailboxLinkStatus?

  /// `GET /account`'s `review_account` (#40), read live when the account opens: the App
  /// Review demo account, whose ledger is sample data. Until an answer arrives, every
  /// run asks again (an offline launch must not hide "Use sample data" for good).
  private(set) var reviewAccount = false
  @ObservationIgnored private(set) var closed = false
  /// The last `GET /account` answer, when one arrived.
  @ObservationIgnored private(set) var account: AccountInfo?
  /// Told each `GET /account` answer (the gate updates the profile and the review flag).
  @ObservationIgnored var onAccount: (@MainActor (AccountInfo) async -> Void)?
  @ObservationIgnored private var importFollower: ImportFollower?

  /// The bundled merchant dictionary (`.empty` when its tier is off).
  nonisolated static let dictionary = (try? MerchantDictionary.bundled().get()) ?? .empty

  private init(
    env: AccountEnvironment, binding: AccountBinding, context: SyncContext, projection: ProjectionStore,
    observer: LedgerPageObserver, engine: SyncEngine, outbox: Outbox, coordinator: WorkCoordinator,
    lanes: [MailboxProvider: MailboxLane], active: ActiveLane, mailboxLedger: RuntimeMailboxLedger,
    mailboxServer: HTTPMailboxServer, backlog: BacklogSorter, suggestions: ModelSuggestionStage, store: LiveLedgerStore
  ) {
    self.env = env
    self.binding = binding
    self.context = context
    self.projection = projection
    self.observer = observer
    self.engine = engine
    self.outbox = outbox
    self.coordinator = coordinator
    self.lanes = lanes
    self.active = active
    activeProvider = active.lane?.provider
    self.mailboxLedger = mailboxLedger
    self.mailboxServer = mailboxServer
    self.backlog = backlog
    self.suggestions = suggestions
    self.store = store
  }

  var userID: UserID { context.userID }

  /// The running lane: the provider of the account's link on this iPhone; nil in a build that
  /// connects no mailbox.
  var lane: MailboxLane? { active.lane }

  /// The providers this build connects, Gmail first.
  var providers: [MailboxProvider] { MailboxProvider.allCases.filter { lanes[$0] != nil } }

  /// The provider of the account's link on this iPhone; nil while there is none.
  var linkedProvider: MailboxProvider? {
    guard let p = activeProvider, let phase = store.mailboxPhase, phase != .unlinked else { return nil }
    return p
  }

  /// Runs `provider`'s lane from now on (after its link was made here, or to follow the
  /// server's link), and remembers it for the next launch.
  func activate(_ provider: MailboxProvider) {
    guard let lane = lanes[provider] else { return }
    active.set(lane)
    if activeProvider != provider { activeProvider = provider }
    LocalAccountData.setMailboxProvider(provider)
  }

  /// The lane to run when the account opens: the provider this iPhone ran last, else the one
  /// it keeps a grant for, else Gmail (else Outlook, in a build with only that client).
  nonisolated static func initialLane(_ lanes: [MailboxProvider: MailboxLane], remembered: MailboxProvider?) async
    -> MailboxLane?
  {
    if let r = remembered, let lane = lanes[r] { return lane }
    for p in [MailboxProvider.outlook, .gmail] {
      if let lane = lanes[p], await lane.hasGrant() == true { return lane }
    }
    return lanes[.gmail] ?? lanes[.outlook]
  }

  /// Plain-language words for a halt a reconnect alone doesn't fix.
  var haltMessage: String? {
    guard store.mailboxHalt == .noMailbox, let provider = activeProvider else { return nil }
    return LiveMailboxConnecting.message(.noMailbox, provider: provider)
  }

  /// "Use sample data" is offered on a review account whose ledger holds no
  /// transaction (spec 04 §6.13; plan §2.5). The loader checks both again, live.
  var offersSampleData: Bool { reviewAccount && store.loaded && store.state.txns.isEmpty }

  /// What the bell, the Profile card and Bank alerts offer for mail (spec 04 §6.6 row 4,
  /// §7.4): nothing until the lane's phase and the ledger have been read, and nothing in a
  /// build that connects no mailbox.
  var mailOffer: MailOffer? {
    guard let lane, store.loaded, let phase = store.mailboxPhase else { return nil }
    return LiveMailboxConnecting.offer(
      phase: phase, halt: store.mailboxHalt, sampleLoaded: store.holdsSample || reviewAccount, serverLink: serverLink,
      provider: lane.provider)
  }

  func retryMailbox() async {
    _ = await coordinator.run(.retryMail, budget: .seconds(20))
  }

  /// Reads the mailbox lane's state again (after a connect, the first scan or the cards
  /// step), so Home and Profile follow it before the next run.
  func refreshMailbox() async {
    guard !closed, let lane else { return }
    store.noteMailbox(await lane.status(), nowMs: context.clock.nowMs())
    await store.reload()
    await checkServerLink()
  }

  /// Asks the server for the account's mailbox link after every run while this iPhone has
  /// none or another iPhone holds it: another iPhone can take the link at any time, or
  /// move it to the other provider, whose lane then runs here. Offline, the last answer
  /// stays until the next run.
  func checkServerLink() async {
    guard lane != nil, store.mailboxPhase == .unlinked || store.mailboxPhase == .otherDevice else { return }
    _ = await askServerLink()
  }

  /// `GET /mailbox/link` now: the answer (kept in `serverLink`), or nil when the server
  /// couldn't be asked.
  func askServerLink() async -> MailboxLinkStatus? {
    guard let (link, provider) = try? await mailboxServer.linkStatusAndProvider() else { return nil }
    if serverLink != link { serverLink = link }
    // Another iPhone's link names the provider this one reads it through, if it reads it
    // here instead ("Read them here instead").
    if case .holder(false, _) = link, store.mailboxPhase == .unlinked || store.mailboxPhase == .otherDevice,
      let p = provider.flatMap({ MailboxProvider(rawValue: $0.rawValue) }), p != activeProvider
    {
      activate(p)
    }
    return link
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
    let persistence = LedgerMailboxPersistence(
      store: context.store, authoring: authoring, nowMs: { context.clock.nowMs() })
    let stepUp = LiveStepUp(env: env, usesPasskey: usesPasskey, askPassword: { await StepUpPrompt.password($0) })
    let categorizer = PipelineCategorizer(projection: projection, dictionary: dictionary)
    var lanes: [MailboxProvider: MailboxLane] = [:]
    for p in MailboxProvider.allCases {
      lanes[p] = MailboxLane(
        provider: p, build: build, secrets: env.secrets, userID: context.userID, persistence: persistence,
        ledger: mailboxLedger, server: mailboxServer, stepUp: stepUp, categorizer: categorizer,
        presenter: WebAuthenticationPresenter(for: p))
    }
    let active = ActiveLane(await initialLane(lanes, remembered: LocalAccountData.mailboxProvider()))
    let editor = LedgerEditAuthor(observer: observer, outbox: outbox)
    let store = LiveLedgerStore(
      reader: projection.reader, author: editor, profile: profile, prefs: DevicePrefsStore(), clock: LiveLedgerStore.runClock())
    // The running lane's cycle (nil in a build that connects no mailbox). Typed apart: the
    // coordinator's initializer is too much for the type checker with it inline.
    var mailboxStage: WorkCoordinator.MailboxStage?
    if !lanes.isEmpty {
      mailboxStage = { @Sendable (trigger: MailboxTrigger, deadlineMs: Int64?) async -> CycleReport in
        await active.cycle(trigger, deadlineMs)
      }
    }
    let activity = BacklogActivity()
    let link = BacklogLink()
    let suggestions = ModelSuggestionStage(
      observer: observer, outbox: outbox, cache: FMCache(context.store), dictionary: dictionary,
      onDevice: HasalaModelFactory.make(),
      cloud: HasalaCloudFactory.makeCategoryModel(
        baseURL: build.assistBaseURL, clientVersion: build.marketingVersion,
        isEnabled: MerchantSuggestionsSetting.isEnabledReader,
        isAutoFileEnabled: MerchantSuggestionsSetting.isAutoSortEnabledReader,
        refusal: MerchantSuggestionsSetting.refusal(
          version: MerchantSuggestionsSetting.appVersion(marketing: build.marketingVersion, build: build.buildNumber))),
      onDeviceAlone: BuildSurface.showsUnfinished,
      nowMs: { context.clock.nowMs() },
      backlogActive: { activity.isActive },
      autoFileEnabled: MerchantSuggestionsSetting.isAutoSortEnabledReader,
      cloudBudget: { await link.budget() },
      cloudSpent: { await link.spent($0) },
      trusts: TrustCounts.shared.autoFile)
    let backlog = BacklogSorter(
      pass: { await suggestions.backlogPass($0, dayLeft: $1) }, waiting: { await suggestions.backlogWaiting($0) },
      store: .live(BacklogRunStore(context.store)),
      nowMs: { Int64(Date().timeIntervalSince1970 * 1000) },
      importRunning: {
        guard let lane = active.lane else { return false }
        let phase = await lane.status().phase
        return phase == .scanning || phase == .authoringBackfill
      }, enabled: MerchantSuggestionsSetting.isEnabledReader, activity: activity)
    link.set(backlog)
    let coordinator = WorkCoordinator(
      stages: WorkCoordinator.Stages(
        sync: { trigger, deadline in
          let out = await engine.run(trigger, deadline: deadline)
          if let seen = try? await observer.seenStamps() { authoring.updateSeen(seen) }
          let phase = await engine.status.phase
          return (out.newData, Self.shownStop(out.stop, phase: phase))
        },
        mailbox: mailboxStage,
        categorize: { trigger in
          let followed = await editor.followUp()
          let suggested = await suggestions.run(trigger)
          return followed || suggested
        },
        committed: {
          if let lane = active.lane {
            let status = await lane.status()
            await MainActor.run { store.noteMailbox(status, nowMs: context.clock.nowMs()) }
          }
          await store.reload()
          await afterRun.run()
          Task { await backlog.ensure() }
        },
        stopped: stopped))
    box.set(coordinator)
    try await observer.open()
    if let lane = active.lane { store.noteMailbox(await lane.status(), nowMs: context.clock.nowMs()) }
    await store.reload()
    let rt = AccountRuntime(
      env: env, binding: binding, context: context, projection: projection, observer: observer, engine: engine,
      outbox: outbox, coordinator: coordinator, lanes: lanes, active: active, mailboxLedger: mailboxLedger,
      mailboxServer: mailboxServer, backlog: backlog, suggestions: suggestions, store: store)
    afterRun.set { [weak rt] in
      await rt?.refreshAccountIfUnknown()
      await rt?.checkServerLink()
    }
    await rt.followImports()
    rt.followSwitch()
    await backlog.watchNetwork()
    Task { await backlog.ensure(retry: true) }
    return rt
  }

  nonisolated static func shownStop(_ stop: SyncStop?, phase: SyncPhase) -> SyncStop? {
    guard case .halted = stop, case .halted(let kind) = phase else { return stop }
    return .halted(kind)
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
    closed = true
    stopFollowingImports()
    for token in [switchOff, switchOn].compactMap({ $0 }) { NotificationCenter.default.removeObserver(token) }
    switchOff = nil
    switchOn = nil
    await backlog.suspend()
    await coordinator.close()
    for lane in lanes.values { await lane.close() }
  }

  func followSwitch() {
    let sorter = backlog
    let center = NotificationCenter.default
    let defaults = UserDefaults.standard
    switchOff = center.addObserver(forName: MerchantSuggestionsSetting.turnedOff, object: defaults, queue: nil) { _ in
      Task { await sorter.switchedOff() }
    }
    switchOn = center.addObserver(forName: MerchantSuggestionsSetting.turnedOn, object: defaults, queue: nil) { _ in
      Task { await sorter.ensure(retry: true) }
    }
  }

  func sendAllBack() async -> Int {
    let stage = suggestions
    return await backlog.sendAllBack { await stage.sendBack(filed: $0) }
  }

  func followImports() async {
    let sorter = backlog
    let follower = ImportFollower(
      store: store,
      refreshStatus: { [weak self] in
        guard let self, let lane = self.lane else { return }
        self.store.noteMailbox(await lane.status(), nowMs: self.context.clock.nowMs())
      },
      imported: { Task { await sorter.ensure() } })
    follower.follow(lanes.values.map(\.events))
    for lane in lanes.values { await lane.relayEvents() }
    importFollower = follower
  }

  private func stopFollowingImports() {
    importFollower?.stop()
    importFollower = nil
  }
}

@MainActor
final class ImportFollower {
  private let store: LiveLedgerStore
  private let refreshStatus: @MainActor () async -> Void
  private let imported: @MainActor () -> Void
  private var task: Task<Void, Never>?
  private var listeners: [(LaneEvents, UUID)] = []

  init(
    store: LiveLedgerStore, refreshStatus: @escaping @MainActor () async -> Void, imported: @escaping @MainActor () -> Void = {}
  ) {
    self.store = store
    self.refreshStatus = refreshStatus
    self.imported = imported
  }

  func follow(_ sources: [LaneEvents]) {
    let (stream, continuation) = AsyncStream<LaneEvents.Event>.makeStream(bufferingPolicy: .bufferingNewest(64))
    for events in sources { listeners.append((events, events.add { continuation.yield($0) })) }
    task = Task { [weak self] in
      for await event in stream {
        guard let self else { return }
        await self.handle(event)
      }
    }
  }

  func stop() {
    for (events, id) in listeners { events.remove(id) }
    listeners = []
    task?.cancel()
    task = nil
  }

  func handle(_ event: LaneEvents.Event) async {
    switch event {
    case .committed:
      await store.reload()
      imported()
    case .progress(let p):
      store.noteImport(p)
      switch p.stage {
      case .done, .failed:
        await refreshStatus()
        await store.reload()
        imported()
      case .listing, .downloading, .authoring:
        break
      }
    }
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

/// The lane the coordinator's mailbox stage runs, swapped when the account's link changes
/// provider. Read from any task.
nonisolated final class ActiveLane: @unchecked Sendable {
  private let lock = NSLock()
  private var current: MailboxLane?

  init(_ lane: MailboxLane?) { current = lane }

  var lane: MailboxLane? { lock.withLock { current } }
  func set(_ lane: MailboxLane) { lock.withLock { current = lane } }

  /// One cycle of the running lane; an empty report when there is none.
  func cycle(_ trigger: MailboxTrigger, _ deadlineMs: Int64?) async -> CycleReport {
    guard let lane else { return CycleReport() }
    return await lane.cycle(trigger: trigger, deadlineMs: deadlineMs)
  }
}
