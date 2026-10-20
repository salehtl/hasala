import CoreDomain
import Foundation
import Synchronization
import UIKit

actor FirstImportSorter {
  struct Store: Sendable {
    var state: @Sendable () -> (startedMs: Int64, requests: Int)?
    var record: @Sendable (_ requests: Int) -> Void
    var end: @Sendable () -> Void

    static let live = Store(
      state: { MerchantSuggestionsSetting.firstImport() },
      record: { MerchantSuggestionsSetting.recordFirstImport(requests: $0) },
      end: { MerchantSuggestionsSetting.endFirstImport() })
  }

  typealias PassRunner = @Sendable (FirstImportSort.Memo) async -> FirstImportSort.Pass?

  static let idleWait: Duration = .seconds(30)
  static let maxFailures = 3

  private let pass: PassRunner
  private let store: Store
  private let nowMs: @Sendable () -> Int64
  private let appActive: @Sendable () async -> Bool
  private let importRunning: @Sendable () async -> Bool
  private let sleep: @Sendable (Duration) async -> Void
  private let wake = WakeSignal()
  private var task: Task<Void, Never>?
  private var generation = 0
  private(set) var passes = 0

  init(
    pass: @escaping PassRunner, store: Store = .live, nowMs: @escaping @Sendable () -> Int64,
    appActive: @escaping @Sendable () async -> Bool = FirstImportSorter.foreground,
    importRunning: @escaping @Sendable () async -> Bool,
    sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
  ) {
    self.pass = pass
    self.store = store
    self.nowMs = nowMs
    self.appActive = appActive
    self.importRunning = importRunning
    self.sleep = sleep
  }

  @Sendable static func foreground() async -> Bool {
    await MainActor.run { UIApplication.shared.applicationState != .background }
  }

  var isRunning: Bool { task != nil }

  func start() {
    guard task == nil, store.state() != nil else { return }
    generation += 1
    let id = generation
    task = Task { await self.loop(id) }
  }

  func nudge() {
    if task == nil {
      start()
    } else {
      wake.fire()
    }
  }

  func stop() {
    task?.cancel()
    task = nil
    wake.fire()
  }

  func finished() async {
    await task?.value
  }

  private func loop(_ id: Int) async {
    defer { if generation == id { task = nil } }
    guard let saved = store.state() else { return }
    var memo = FirstImportSort.Memo(requests: saved.requests)
    var backoffs = 0
    var failures = 0
    while !Task.isCancelled {
      guard let s = store.state() else { return }
      if FirstImportSort.expired(startedMs: s.startedMs, nowMs: nowMs()) { return store.end() }
      guard await appActive() else {
        await wake.wait(Self.idleWait, sleep: sleep)
        continue
      }
      let started = ContinuousClock.now
      guard let p = await pass(memo) else {
        failures += 1
        if failures >= Self.maxFailures { return store.end() }
        await wake.wait(Self.idleWait, sleep: sleep)
        continue
      }
      passes += 1
      failures = 0
      memo = p.memo
      store.record(memo.requests)
      if Task.isCancelled { return }
      let decided = FirstImportSort.next(after: p, importRunning: await importRunning(), backoffs: backoffs)
      backoffs = decided.backoffs
      switch decided.next {
      case .pass(let afterMs):
        let left = Duration.milliseconds(afterMs) - (ContinuousClock.now - started)
        if left > .zero { await sleep(left) }
      case .waitForRows:
        await wake.wait(Self.idleWait, sleep: sleep)
      case .done:
        return store.end()
      }
    }
  }
}

nonisolated final class WakeSignal: Sendable {
  private let state = Mutex<(pending: Bool, waiter: CheckedContinuation<Void, Never>?)>((false, nil))

  func fire() {
    let k = state.withLock { s -> CheckedContinuation<Void, Never>? in
      guard let k = s.waiter else {
        s.pending = true
        return nil
      }
      s.waiter = nil
      return k
    }
    k?.resume()
  }

  func wait(_ limit: Duration, sleep: @escaping @Sendable (Duration) async -> Void) async {
    let timer = Task { [weak self] in
      await sleep(limit)
      if !Task.isCancelled { self?.fire() }
    }
    defer { timer.cancel() }
    await withTaskCancellationHandler {
      await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
        let now = state.withLock { s -> Bool in
          if s.pending {
            s.pending = false
            return true
          }
          s.waiter = k
          return false
        }
        if now { k.resume() }
      }
    } onCancel: {
      fire()
    }
  }
}

@MainActor
final class LiveCloudSort: CloudSortOffering {
  private let runtime: @MainActor () -> AccountRuntime?
  private let defaults: UserDefaults

  init(runtime: @escaping @MainActor () -> AccountRuntime?, defaults: UserDefaults = .standard) {
    self.runtime = runtime
    self.defaults = defaults
  }

  var isOffered: Bool { BuildSurface.showsCloudSuggestions }

  var isOn: Bool { MerchantSuggestionsSetting.isAutoSortEnabled(defaults) }

  func turnOn() {
    MerchantSuggestionsSetting.turnOnForFirstImport(nowMs: Int64(Date().timeIntervalSince1970 * 1000), defaults)
    guard let sorter = runtime()?.firstImport else { return }
    Task { await sorter.start() }
  }
}
