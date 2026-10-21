import CoreDomain
import CoreStore
import Foundation
import Network
import Synchronization
import UIKit

nonisolated struct BacklogRunRecord: Codable, Equatable, Sendable {
  enum Phase: String, Codable, Sendable { case running, paused, done }
  enum Reason: String, Codable, Sendable { case off, refused, rateLimited, busy, runCap, dayCap, stopped }

  struct Run: Codable, Equatable, Sendable {
    var id: String
    var startedMs: Int64
    var requests = 0
    var asked = 0
    var totalNames = 0
    var filed = 0
    var suggested = 0
    var phase: Phase = .running
    var reason: Reason?
    var untilMs: Int64?
    var endedMs: Int64?
    var manifest: [String: Int64] = [:]
  }

  var run: Run?
  var day: [Int64] = []

  var isActive: Bool {
    guard let run else { return false }
    switch run.phase {
    case .running: return true
    case .paused: return run.reason == .busy || run.reason == .rateLimited
    case .done: return false
    }
  }

  var canUndo: Bool {
    guard let run else { return false }
    return run.phase != .running && !run.manifest.isEmpty
  }

  static func reason(_ stop: BacklogSort.Stop) -> Reason {
    switch stop {
    case .off: .off
    case .refused: .refused
    case .rateLimited: .rateLimited
    case .busy: .busy
    case .runCap: .runCap
    case .dayCap: .dayCap
    }
  }
}

nonisolated struct BacklogSnapshot: Equatable, Sendable {
  enum Hold: Equatable, Sendable {
    case offline, background
    case waiting(untilMs: Int64)
  }

  var record: BacklogRunRecord
  var hold: Hold?
  var looping: Bool
}

nonisolated protocol NetworkWatching: Sendable {
  var isOnline: Bool { get }
  func start(_ changed: @escaping @Sendable () -> Void)
  func cancel()
}

nonisolated final class PathWatcher: NetworkWatching {
  private let monitor = NWPathMonitor()
  private let online = Mutex(true)

  var isOnline: Bool { online.withLock { $0 } }

  func start(_ changed: @escaping @Sendable () -> Void) {
    monitor.pathUpdateHandler = { [weak self] path in
      guard let self else { return }
      let now = path.status == .satisfied
      let moved = self.online.withLock { o in
        defer { o = now }
        return o != now
      }
      if moved { changed() }
    }
    monitor.start(queue: DispatchQueue(label: "app.hasala.backlog.path"))
  }

  func cancel() { monitor.cancel() }
}

nonisolated final class BacklogActivity: Sendable {
  private let active = Mutex(false)

  var isActive: Bool { active.withLock { $0 } }
  func set(_ on: Bool) { active.withLock { $0 = on } }
}

actor BacklogSorter {
  struct Store: Sendable {
    var load: @Sendable () -> BacklogRunRecord
    var save: @Sendable (BacklogRunRecord) -> Void

    static func live(_ store: BacklogRunStore) -> Store {
      Store(
        load: {
          guard let data = try? store.load(), let r = try? JSONDecoder().decode(BacklogRunRecord.self, from: data) else {
            return BacklogRunRecord()
          }
          return r
        },
        save: { r in
          guard let data = try? JSONEncoder().encode(r) else { return }
          try? store.save(data)
        })
    }
  }

  struct PassResult: Sendable {
    var pass: BacklogSort.Pass
    var filing: BacklogSort.Filing

    init(pass: BacklogSort.Pass, filing: BacklogSort.Filing = .init()) {
      self.pass = pass
      self.filing = filing
    }
  }

  typealias PassRunner = @Sendable (_ memo: BacklogSort.Memo, _ dayLeft: Int) async -> PassResult?

  static let idleWait: Duration = .seconds(30)
  static let maxFailures = 3

  private let pass: PassRunner
  private let store: Store
  private let nowMs: @Sendable () -> Int64
  private let appActive: @Sendable () async -> Bool
  private let importRunning: @Sendable () async -> Bool
  private let enabled: @Sendable () -> Bool
  private let network: any NetworkWatching
  private let sleep: @Sendable (Duration) async -> Void
  private let newID: @Sendable () -> String
  nonisolated let activity: BacklogActivity
  private let wake = WakeSignal()
  private var record: BacklogRunRecord
  private var hold: BacklogSnapshot.Hold?
  private var observer: (@Sendable (BacklogSnapshot) -> Void)?
  private var task: Task<Void, Never>?
  private var generation = 0
  private var watching = false
  private(set) var passes = 0

  init(
    pass: @escaping PassRunner, store: Store, nowMs: @escaping @Sendable () -> Int64,
    appActive: @escaping @Sendable () async -> Bool = BacklogSorter.foreground,
    importRunning: @escaping @Sendable () async -> Bool, enabled: @escaping @Sendable () -> Bool,
    network: any NetworkWatching = PathWatcher(), activity: BacklogActivity = BacklogActivity(),
    sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
    newID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }
  ) {
    self.pass = pass
    self.store = store
    self.nowMs = nowMs
    self.appActive = appActive
    self.importRunning = importRunning
    self.enabled = enabled
    self.network = network
    self.activity = activity
    self.sleep = sleep
    self.newID = newID
    record = store.load()
    activity.set(record.isActive)
  }

  @Sendable static func foreground() async -> Bool {
    await MainActor.run { UIApplication.shared.applicationState != .background }
  }

  var isRunning: Bool { task != nil }

  var snapshot: BacklogSnapshot { BacklogSnapshot(record: record, hold: hold, looping: task != nil) }

  func observe(_ f: @escaping @Sendable (BacklogSnapshot) -> Void) {
    observer = f
    f(snapshot)
  }

  func watchNetwork() {
    guard !watching else { return }
    watching = true
    network.start { [weak self] in Task { await self?.resume() } }
  }

  func start() {
    guard enabled() else { return }
    let now = nowMs()
    if var run = record.run, run.phase != .done, run.reason != .runCap {
      run.phase = .running
      run.reason = nil
      run.untilMs = nil
      record.run = run
    } else {
      record.run = BacklogRunRecord.Run(id: newID(), startedMs: now)
    }
    save()
    launch()
  }

  func resume() {
    guard var run = record.run else { return }
    guard enabled() else {
      if run.phase != .done { end(.off) }
      return
    }
    switch run.phase {
    case .running:
      if task == nil { launch() } else { wake.fire() }
    case .paused:
      let now = nowMs()
      switch run.reason {
      case .busy?, .rateLimited?:
        guard now >= run.untilMs ?? 0 else { return }
      case .dayCap?:
        guard BacklogSort.dayLeft(record.day, nowMs: now) > 0 else { return }
      default:
        return
      }
      run.phase = .running
      run.reason = nil
      run.untilMs = nil
      record.run = run
      save()
      launch()
    case .done:
      return
    }
  }

  func stop() {
    halt()
    if let run = record.run, run.phase != .done { end(.stopped) }
  }

  func switchedOff() {
    halt()
    if let run = record.run, run.phase != .done { end(.off) }
  }

  func suspend() {
    halt()
    if watching {
      network.cancel()
      watching = false
    }
  }

  func finished() async {
    await task?.value
  }

  func undoLastRun(_ author: @Sendable ([String: Int64]) async -> Int?) async -> Int {
    stop()
    guard let run = record.run, !run.manifest.isEmpty else { return 0 }
    guard let n = await author(run.manifest) else { return 0 }
    if record.run?.id == run.id {
      record.run?.manifest = [:]
      save()
    }
    return n
  }

  func sendAllBack(_ author: @Sendable () async -> Int?) async -> Int {
    stop()
    guard let n = await author() else { return 0 }
    if record.run?.manifest.isEmpty == false {
      record.run?.manifest = [:]
      save()
    }
    return n
  }

  private func halt() {
    task?.cancel()
    task = nil
    hold = nil
    wake.fire()
  }

  private func launch() {
    guard task == nil else { return wake.fire() }
    generation += 1
    let id = generation
    task = Task { await self.loop(id) }
    publish()
  }

  private func save() {
    activity.set(record.isActive)
    store.save(record)
    publish()
  }

  private func publish() {
    observer?(snapshot)
  }

  private func setHold(_ h: BacklogSnapshot.Hold?) {
    guard hold != h else { return }
    hold = h
    publish()
  }

  private func end(_ reason: BacklogRunRecord.Reason?) {
    guard var run = record.run else { return }
    run.phase = .done
    run.reason = reason
    run.untilMs = nil
    run.endedMs = nowMs()
    record.run = run
    hold = nil
    save()
  }

  private func pause(_ reason: BacklogRunRecord.Reason, untilMs: Int64?) {
    guard var run = record.run else { return }
    run.phase = .paused
    run.reason = reason
    run.untilMs = untilMs
    record.run = run
    hold = nil
    save()
  }

  private func apply(_ r: PassResult, to runID: String) {
    let now = nowMs()
    record.day = record.day.filter { $0 > now - BacklogSort.dayWindowMs } + Array(repeating: now, count: r.pass.calls)
    guard var run = record.run, run.id == runID else { return save() }
    run.requests = r.pass.memo.requests
    run.asked += r.pass.settled
    run.filed += r.filing.filed.count
    run.suggested += r.filing.suggested.count
    run.manifest.merge(r.filing.filed) { _, new in new }
    run.totalNames = run.asked + min(r.pass.pending, max(0, BacklogSort.runNames - run.requests))
    record.run = run
    save()
  }

  private func loop(_ id: Int) async {
    defer {
      if generation == id {
        task = nil
        hold = nil
        publish()
      }
    }
    var memo = BacklogSort.Memo(requests: record.run?.requests ?? 0)
    var backoffs = 0
    var failures = 0
    var last: ContinuousClock.Instant?
    while !Task.isCancelled {
      guard let run = record.run, run.phase == .running else { return }
      guard enabled() else { return end(.off) }
      guard await appActive() else {
        setHold(.background)
        await idle(since: last)
        continue
      }
      guard network.isOnline else {
        setHold(.offline)
        await idle(since: last)
        continue
      }
      if Task.isCancelled { return }
      setHold(nil)
      let now = nowMs()
      let dayLeft = BacklogSort.dayLeft(record.day, nowMs: now)
      guard dayLeft > 0 else { return pause(.dayCap, untilMs: BacklogSort.dayReopensMs(record.day, nowMs: now)) }
      let started = ContinuousClock.now
      last = started
      let result = await pass(memo, dayLeft)
      if let result {
        memo = result.pass.memo
        apply(result, to: run.id)
      }
      if Task.isCancelled || generation != id { return }
      guard let r = result, !r.pass.failed else {
        failures += 1
        if failures >= Self.maxFailures { return }
        await idle(since: started)
        continue
      }
      passes += 1
      failures = 0
      let decided = BacklogSort.next(after: r.pass, importRunning: await importRunning(), backoffs: backoffs, nowMs: nowMs())
      if Task.isCancelled || generation != id { return }
      backoffs = decided.backoffs
      switch decided.next {
      case .pass(let afterMs):
        let left = Duration.milliseconds(afterMs) - (ContinuousClock.now - started)
        if afterMs > BacklogSort.passSpacingMs { setHold(.waiting(untilMs: nowMs() + afterMs)) }
        if left > .zero { await sleep(left) }
      case .waitForRows:
        await idle(since: started)
      case .pause(let stop, let untilMs):
        let until = stop == .dayCap ? BacklogSort.dayReopensMs(record.day, nowMs: nowMs()) : untilMs
        return pause(BacklogRunRecord.reason(stop), untilMs: until)
      case .done(let stop):
        return end(stop.map(BacklogRunRecord.reason))
      }
    }
  }

  private func idle(since last: ContinuousClock.Instant?) async {
    await wake.wait(Self.idleWait, sleep: sleep)
    guard let last, !Task.isCancelled else { return }
    let left = Duration.milliseconds(BacklogSort.passSpacingMs) - (ContinuousClock.now - last)
    if left > .zero { await sleep(left) }
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
    MerchantSuggestionsSetting.turnOnForFirstImport(defaults)
    guard let sorter = runtime()?.backlog else { return }
    MerchantSuggestionsSetting.takeRunRequest(defaults)
    Task { await sorter.start() }
  }
}
