import CoreDomain
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

  init(
    sorter: BacklogSorter, view: @escaping @Sendable ([String: Int64]) async -> ModelSuggestionStage.BacklogView?,
    undo: @escaping @MainActor () async -> Int, sendBack: @escaping @MainActor () async -> Int,
    enabled: @escaping () -> Bool = { MerchantSuggestionsSetting.isEnabled() },
    nowMs: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
  ) {
    self.sorter = sorter
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
  }

  convenience init(runtime: AccountRuntime) {
    let stage = runtime.suggestions
    self.init(
      sorter: runtime.backlog, view: { await stage.backlogView(filedHere: $0) },
      undo: { [weak runtime] in await runtime?.undoLastRun() ?? 0 },
      sendBack: { [weak runtime] in await runtime?.sendAllBack() ?? 0 })
  }

  isolated deinit {
    listener?.cancel()
  }

  func refresh() async {
    snapshot = await sorter.snapshot
    counts = await view(snapshot?.record.filedHere ?? [:])
    compose()
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
    let filed = snapshot?.record.filedHere ?? [:]
    Task {
      counts = await view(filed)
      recounting = false
      compose()
      if recountAgain { recount() }
    }
  }

  private func compose() {
    let next = Self.status(snapshot: snapshot, view: counts, enabled: enabled(), nowMs: nowMs())
    if next != status { status = next }
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
