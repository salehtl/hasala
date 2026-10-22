import CoreDomain
import CoreMailbox
import CoreSync
import Foundation
import Observation

@MainActor
@Observable
final class LiveCloudSortController: CloudSortControlling {
  private(set) var status: CloudSortStatus = .off
  @ObservationIgnored private let sorter: BacklogSorter
  @ObservationIgnored private let view: @Sendable ([String: Int64]) async -> ModelSuggestionStage.BacklogView?
  @ObservationIgnored private let undo: @MainActor () async -> Int
  @ObservationIgnored private let sendBack: @MainActor () async -> Int
  @ObservationIgnored private let enabled: () -> Bool
  @ObservationIgnored private let nowMs: () -> Int64
  @ObservationIgnored private var snapshot: BacklogSnapshot?
  @ObservationIgnored private var counts: ModelSuggestionStage.BacklogView?
  @ObservationIgnored private var listener: Task<Void, Never>?
  @ObservationIgnored private var recounting = false
  @ObservationIgnored private var recountAgain = false
  @ObservationIgnored private let load: @MainActor () async -> RunOffer.Load
  @ObservationIgnored private let offers: RunOffer.Store
  @ObservationIgnored private var memory: RunOffer.Memory
  @ObservationIgnored private var loaded: RunOffer.Load?
  @ObservationIgnored private var facts: RunOffer.Facts?
  @ObservationIgnored private var openPending = false
  @ObservationIgnored private let watch: (@MainActor () -> RunOffer.Mailbox)?
  @ObservationIgnored private var watched: RunOffer.Mailbox?
  @ObservationIgnored private var readSeq = 0

  init(
    sorter: BacklogSorter, view: @escaping @Sendable ([String: Int64]) async -> ModelSuggestionStage.BacklogView?,
    undo: @escaping @MainActor () async -> Int, sendBack: @escaping @MainActor () async -> Int,
    enabled: @escaping () -> Bool = { MerchantSuggestionsSetting.isEnabled() },
    nowMs: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
    load: @escaping @MainActor () async -> RunOffer.Load = { RunOffer.Load() },
    offers: RunOffer.Store = .inMemory(),
    watch: (@MainActor () -> RunOffer.Mailbox)? = nil
  ) {
    self.sorter = sorter
    self.load = load
    self.watch = watch
    self.offers = offers
    memory = offers.load()
    self.view = view
    self.undo = undo
    self.sendBack = sendBack
    self.enabled = enabled
    self.nowMs = nowMs
    let (stream, continuation) = AsyncStream<BacklogSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
    listener = Task { [weak self] in
      await sorter.observe { _ = continuation.yield($0) }
      for await s in stream {
        guard let self else { return }
        self.take(s)
      }
    }
    follow()
  }

  convenience init(runtime: AccountRuntime) {
    let stage = runtime.suggestions
    self.init(
      sorter: runtime.backlog, view: { await stage.backlogView(filedHere: $0) },
      undo: { [weak runtime] in await runtime?.undoLastRun() ?? 0 },
      sendBack: { [weak runtime] in await runtime?.sendAllBack() ?? 0 },
      load: { [weak runtime] in
        guard let runtime else { return RunOffer.Load() }
        let phase = runtime.store.mailboxPhase
        let sync = await runtime.engine.status
        return Self.load(phase: phase, sync: sync)
      },
      offers: .live(),
      watch: { [weak runtime] in Self.mailbox(runtime?.store.mailboxPhase) })
  }

  nonisolated static func load(phase: MailboxPhase?, sync: CoreSync.SyncStatus) -> RunOffer.Load {
    RunOffer.Load(mailbox: mailbox(phase), caughtUp: sync.phase == .idle && sync.lastSuccessAt != nil)
  }

  nonisolated static func mailbox(_ phase: MailboxPhase?) -> RunOffer.Mailbox {
    switch phase {
    case .active?: .active
    case .otherDevice?: .elsewhere
    case .scanning?, .authoringBackfill?: .importing
    case .awaitingCards?: .awaitingCards
    case .unlinked?, .halted?, .reconnectRequired?, nil: RunOffer.Mailbox.none
    }
  }

  isolated deinit {
    listener?.cancel()
  }

  func refresh() async {
    snapshot = await sorter.snapshot
    await reread()
    compose()
  }

  func countsChanged() {
    recount()
  }

  private func reread() async {
    readSeq += 1
    let seq = readSeq
    let filed = snapshot?.record.filedHere ?? [:]
    let view = self.view
    let nextLoad = await load()
    let next = await Task.detached(priority: .userInitiated) { await view(filed) }.value
    guard seq == readSeq else { return }
    loaded = nextLoad
    counts = next
  }

  private func follow() {
    guard let watch else { return }
    let mailbox = withObservationTracking { watch() } onChange: { [weak self] in
      Task { @MainActor [weak self] in self?.follow() }
    }
    let first = watched == nil
    guard mailbox != watched else { return }
    watched = mailbox
    remember(RunOffer.noted(memory, mailbox))
    if !first { recount() }
  }

  func reviewOpened() {
    openPending = true
  }

  func offerShown() {
    guard let facts else { return }
    remember(RunOffer.shown(memory, facts))
  }

  private func remember(_ next: RunOffer.Memory) {
    guard next != memory else { return }
    memory = next
    offers.save(next)
  }

  func start() {
    let sorter = self.sorter
    Task { await sorter.start() }
  }

  func stop() {
    let sorter = self.sorter
    Task { await sorter.stop() }
  }

  func undoLastRun() async -> Int {
    let n = await undo()
    await refresh()
    return n
  }

  func sendAllBack() async -> Int {
    let n = await sendBack()
    await refresh()
    return n
  }

  private func take(_ s: BacklogSnapshot) {
    let moved = snapshot?.record != s.record
    snapshot = s
    compose()
    guard moved else { return }
    recount()
  }

  private func recount() {
    guard !recounting else {
      recountAgain = true
      return
    }
    recounting = true
    recountAgain = false
    Task {
      await reread()
      recounting = false
      compose()
      if recountAgain { recount() }
    }
  }

  private func compose() {
    var next = Self.status(snapshot: snapshot, view: counts, enabled: enabled(), nowMs: nowMs())
    if counts != nil, let loaded {
      let f = Self.facts(next, run: snapshot?.record.run, load: loaded)
      facts = f
      var m = RunOffer.observe(memory, f)
      if openPending {
        openPending = false
        m = RunOffer.opened(m, f)
      }
      remember(m)
      next.offerDue = RunOffer.due(memory, f)
    }
    if next != status { status = next }
  }

  nonisolated static func facts(_ status: CloudSortStatus, run: BacklogRunRecord.Run?, load: RunOffer.Load) -> RunOffer.Facts {
    let active: Bool
    switch status.phase {
    case .running, .paused: active = true
    case .off, .idle, .done: active = false
    }
    return RunOffer.Facts(
      enabled: status.phase != .off, load: load, waitingNames: status.waitingNames, runActive: active,
      runStartedMs: run?.startedMs)
  }

  nonisolated static func status(
    snapshot: BacklogSnapshot?, view: ModelSuggestionStage.BacklogView?, enabled: Bool, nowMs: Int64
  ) -> CloudSortStatus {
    let record = snapshot?.record ?? BacklogRunRecord()
    let run = record.run
    let c = view?.counts ?? BacklogSort.Counts()
    let today = BacklogSort.dayLeft(record.day, nowMs: nowMs)
    let shown: CloudSortStatus.Phase = enabled ? phase(run, hold: snapshot?.hold) : .off
    let holding: Bool
    switch shown {
    case .running, .paused: holding = true
    case .off, .idle, .done: holding = false
    }
    return CloudSortStatus(
      phase: shown, waitingNames: c.waitingNames, waitingPayments: c.waitingPayments,
      askedNames: run?.asked ?? 0, totalNames: run?.totalNames ?? 0, filed: run?.filed ?? 0, suggested: run?.suggested ?? 0,
      leftForYou: c.leftForYou, staysOnDevice: c.staysOnDevice, pendingTxnIDs: holding ? c.pendingTxnIDs : [], lastRunEndedMs: run?.endedMs,
      canUndoLastRun: record.canUndo, cloudSortedCount: view?.cloudSorted ?? 0, remainingToday: today,
      nextRunNames: min(c.waitingNames, BacklogSort.runNames, today))
  }

  nonisolated static func phase(_ run: BacklogRunRecord.Run?, hold: BacklogSnapshot.Hold?) -> CloudSortStatus.Phase {
    guard let run else { return .idle }
    switch run.phase {
    case .running:
      switch hold {
      case .offline?: return .paused(.offline)
      case .background?: return .paused(.background)
      case .waiting(let until)?: return .paused(.rateLimited(untilMs: until))
      case nil: return .running
      }
    case .paused:
      switch run.reason {
      case .busy?: return .paused(.busy(untilMs: run.untilMs ?? 0))
      case .rateLimited?: return .paused(.rateLimited(untilMs: run.untilMs ?? 0))
      case .dayCap?: return .paused(.dayCap)
      default: return .paused(.runCap)
      }
    case .done:
      return .done
    }
  }
}
