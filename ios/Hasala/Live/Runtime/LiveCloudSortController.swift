import CoreDomain
import Foundation
import Observation

@MainActor
@Observable
final class LiveCloudSortController: CloudSortControlling {
  private(set) var status: CloudSortStatus = .off
  @ObservationIgnored private let sorter: BacklogSorter
  @ObservationIgnored private let view: @Sendable ([String: Int64]) async -> ModelSuggestionStage.BacklogView?
  @ObservationIgnored private let sendBack: @MainActor () async -> Int
  @ObservationIgnored private let enabled: () -> Bool
  @ObservationIgnored private var snapshot: BacklogSnapshot?
  @ObservationIgnored private var counts: ModelSuggestionStage.BacklogView?
  @ObservationIgnored private var listener: Task<Void, Never>?
  @ObservationIgnored private var recounting = false
  @ObservationIgnored private var recountAgain = false
  @ObservationIgnored private var readSeq = 0

  init(
    sorter: BacklogSorter, view: @escaping @Sendable ([String: Int64]) async -> ModelSuggestionStage.BacklogView?,
    sendBack: @escaping @MainActor () async -> Int, enabled: @escaping () -> Bool = { MerchantSuggestionsSetting.isEnabled() }
  ) {
    self.sorter = sorter
    self.view = view
    self.sendBack = sendBack
    self.enabled = enabled
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
      sendBack: { [weak runtime] in await runtime?.sendAllBack() ?? 0 })
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

  func sendAllBack() async -> Int {
    let n = await sendBack()
    await refresh()
    return n
  }

  private func reread() async {
    readSeq += 1
    let seq = readSeq
    let filed = snapshot?.record.filedHere ?? [:]
    let view = self.view
    let next = await Task.detached(priority: .userInitiated) { await view(filed) }.value
    guard seq == readSeq else { return }
    counts = next
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
    let next = Self.status(snapshot: snapshot, view: counts, enabled: enabled())
    if next != status { status = next }
  }

  nonisolated static func status(
    snapshot: BacklogSnapshot?, view: ModelSuggestionStage.BacklogView?, enabled: Bool
  ) -> CloudSortStatus {
    let shown: CloudSortStatus.Phase = enabled ? phase(snapshot?.record.run, hold: snapshot?.hold) : .off
    let holding: Bool
    switch shown {
    case .running, .paused: holding = true
    case .off, .idle, .done: holding = false
    }
    return CloudSortStatus(
      phase: shown, pendingTxnIDs: holding ? view?.pendingTxnIDs ?? [] : [], cloudSortedCount: view?.cloudSorted ?? 0)
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
      default: return .paused(.dayCap)
      }
    case .done:
      return .done
    }
  }
}
