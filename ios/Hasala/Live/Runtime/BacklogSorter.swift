import CoreDomain
import CoreStore
import Foundation
import Network
import Synchronization
import UIKit

nonisolated struct BacklogRunRecord: Codable, Equatable, Sendable {
  enum Phase: String, Codable, Sendable { case running, paused, done }
  enum Reason: String, Codable, Sendable { case off, refused, rateLimited, busy, dayCap, failed }

  struct Run: Codable, Equatable, Sendable {
    var phase: Phase
    var reason: Reason?
    var untilMs: Int64?

    private enum CodingKeys: String, CodingKey {
      case phase, reason, untilMs, id, startedMs, requests, asked, totalNames, filed, suggested, manifest
    }

    init(phase: Phase = .running, reason: Reason? = nil, untilMs: Int64? = nil) {
      self.phase = phase
      self.reason = reason
      self.untilMs = untilMs
    }

    init(from decoder: any Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      phase = try c.decodeIfPresent(Phase.self, forKey: .phase) ?? .done
      untilMs = try c.decodeIfPresent(Int64.self, forKey: .untilMs)
      let raw = try c.decodeIfPresent(String.self, forKey: .reason)
      reason = raw.flatMap(Reason.init(rawValue:))
      if raw != nil, reason == nil {
        phase = .done
        untilMs = nil
      }
    }

    func encode(to encoder: any Encoder) throws {
      var c = encoder.container(keyedBy: CodingKeys.self)
      try c.encode(phase, forKey: .phase)
      try c.encodeIfPresent(reason, forKey: .reason)
      try c.encodeIfPresent(untilMs, forKey: .untilMs)
      try c.encode("", forKey: .id)
      for k in [CodingKeys.startedMs, .requests, .asked, .totalNames, .filed, .suggested] { try c.encode(0, forKey: k) }
      try c.encode([String: Int64](), forKey: .manifest)
    }

    var retriesOnlyAtOpen: Bool {
      guard phase == .done else { return false }
      switch reason {
      case .failed?, .refused?, .off?: return true
      default: return false
      }
    }
  }

  var run: Run?
  var day: [Int64] = []
  var filedHere: [String: Int64] = [:]
  var lastPassMs: Int64?

  init(run: Run? = nil, day: [Int64] = [], filedHere: [String: Int64] = [:], lastPassMs: Int64? = nil) {
    self.run = run
    self.day = day
    self.filedHere = filedHere
    self.lastPassMs = lastPassMs
  }

  init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    run = try c.decodeIfPresent(Run.self, forKey: .run)
    day = try c.decodeIfPresent([Int64].self, forKey: .day) ?? []
    filedHere = try c.decodeIfPresent([String: Int64].self, forKey: .filedHere) ?? [:]
    lastPassMs = try c.decodeIfPresent(Int64.self, forKey: .lastPassMs)
  }

  var isActive: Bool {
    guard let run else { return false }
    switch run.phase {
    case .running: return true
    case .paused: return run.reason == .busy || run.reason == .rateLimited
    case .done: return false
    }
  }

  var capped: Bool {
    guard let run, run.phase == .paused else { return false }
    return run.reason == .dayCap
  }

  mutating func spend(_ calls: Int, nowMs: Int64) {
    day = day.filter { $0 > nowMs - BacklogSort.dayWindowMs } + Array(repeating: nowMs, count: max(0, calls))
  }

  static func reason(_ stop: BacklogSort.Stop) -> Reason {
    switch stop {
    case .off: .off
    case .refused: .refused
    case .rateLimited: .rateLimited
    case .busy: .busy
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

nonisolated final class BacklogLink: Sendable {
  private let sorter = Mutex<BacklogSorter?>(nil)

  func set(_ s: BacklogSorter) { sorter.withLock { $0 = s } }

  func budget() async -> Int {
    guard let s = sorter.withLock({ $0 }) else { return 0 }
    return await s.cloudBudget()
  }

  func spent(_ calls: Int) async {
    guard let s = sorter.withLock({ $0 }) else { return }
    await s.spent(calls)
  }
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
  typealias Waiting = @Sendable (_ memo: BacklogSort.Memo) async -> Bool

  static let idleWait: Duration = .seconds(30)
  static let maxFailures = 3

  private let pass: PassRunner
  private let waiting: Waiting
  private let store: Store
  private let nowMs: @Sendable () -> Int64
  private let appActive: @Sendable () async -> Bool
  private let importRunning: @Sendable () async -> Bool
  private let enabled: @Sendable () -> Bool
  private let network: any NetworkWatching
  private let sleep: @Sendable (Duration) async -> Void
  nonisolated let activity: BacklogActivity
  private let wake = WakeSignal()
  private var record: BacklogRunRecord
  private var memo = BacklogSort.Memo()
  private var retryArmed = false
  private var checking = false
  private var checkAgain = false
  private var closed = false
  private var mayRun: Bool
  private var hold: BacklogSnapshot.Hold?
  private var observer: (@Sendable (BacklogSnapshot) -> Void)?
  private var task: Task<Void, Never>?
  private var generation = 0
  private var watching = false
  private(set) var passes = 0

  init(
    pass: @escaping PassRunner, waiting: @escaping Waiting = { _ in true }, store: Store, nowMs: @escaping @Sendable () -> Int64,
    appActive: @escaping @Sendable () async -> Bool = BacklogSorter.foreground,
    importRunning: @escaping @Sendable () async -> Bool, enabled: @escaping @Sendable () -> Bool,
    network: any NetworkWatching = PathWatcher(), activity: BacklogActivity = BacklogActivity(), mayRun: Bool = true,
    sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
  ) {
    self.pass = pass
    self.waiting = waiting
    self.store = store
    self.nowMs = nowMs
    self.appActive = appActive
    self.importRunning = importRunning
    self.enabled = enabled
    self.network = network
    self.activity = activity
    self.mayRun = mayRun
    self.sleep = sleep
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

  func ensure(retry: Bool = false) async {
    guard !closed else { return }
    if retry { retryArmed = true }
    guard mayRun else { return }
    guard enabled() else { return resume() }
    if let run = record.run, run.phase != .done { return resume() }
    if checking {
      checkAgain = true
      return
    }
    checking = true
    defer { checking = false }
    repeat {
      checkAgain = false
      if enabled(), mayStart, await appActive(), mayStart, await waiting(memo) {
        guard enabled(), mayStart else { return resume() }
        retryArmed = false
        record.run = BacklogRunRecord.Run()
        save()
        return launch()
      }
    } while checkAgain
  }

  private var mayStart: Bool {
    guard !closed, mayRun, task == nil else { return false }
    guard let run = record.run else { return true }
    return run.phase == .done && (retryArmed || !run.retriesOnlyAtOpen)
  }

  func resume() {
    guard !closed, var run = record.run else { return }
    guard enabled() else {
      if run.phase != .done { end(.off) }
      return
    }
    guard mayRun else { return }
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

  func allowRuns(_ ok: Bool) {
    guard ok != mayRun else { return }
    mayRun = ok
    if ok { resume() } else { halt() }
  }

  func switchedOff() {
    guard !enabled() else { return }
    halt()
    if let run = record.run, run.phase != .done { end(.off) }
  }

  func suspend() {
    closed = true
    halt()
    if watching {
      network.cancel()
      watching = false
    }
  }

  func finished() async {
    await task?.value
  }

  func sendAllBack(_ author: @Sendable ([String: Int64]) async -> Int?) async -> Int {
    let sent = record.filedHere
    guard !sent.isEmpty else { return 0 }
    guard let n = await author(sent) else { return 0 }
    for (id, v) in sent where record.filedHere[id] == v { record.filedHere[id] = nil }
    save()
    return n
  }

  func cloudBudget() -> Int {
    guard !record.capped else { return 0 }
    return BacklogSort.dayLeft(record.day, nowMs: nowMs())
  }

  func spent(_ calls: Int) {
    guard calls > 0 else { return }
    record.spend(calls, nowMs: nowMs())
    save()
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
    record.run = run
    retryArmed = false
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

  private func apply(_ r: PassResult) {
    record.spend(r.pass.calls, nowMs: nowMs())
    record.filedHere.merge(r.filing.filed) { _, new in new }
    save()
  }

  nonisolated static func left(_ ms: Int64, since: Int64, nowMs: Int64) -> Duration {
    .milliseconds(min(ms, max(0, since + ms - nowMs)))
  }

  private func spacingLeft() -> Duration? {
    guard let last = record.lastPassMs else { return nil }
    let left = Self.left(BacklogSort.passSpacingMs, since: last, nowMs: nowMs())
    return left > .zero ? left : nil
  }

  private func loop(_ id: Int) async {
    defer {
      if generation == id {
        task = nil
        hold = nil
        publish()
      }
    }
    var backoffs = 0
    var failures = 0
    var rested = false
    while !Task.isCancelled {
      guard let run = record.run, run.phase == .running else { return }
      guard enabled() else { return end(.off) }
      guard await appActive() else {
        setHold(.background)
        await wake.wait(Self.idleWait, sleep: sleep)
        continue
      }
      guard network.isOnline else {
        setHold(.offline)
        await wake.wait(Self.idleWait, sleep: sleep)
        continue
      }
      if Task.isCancelled || generation != id { return }
      setHold(nil)
      if !rested, let left = spacingLeft() {
        rested = true
        await sleep(left)
        continue
      }
      rested = false
      let now = nowMs()
      let dayLeft = BacklogSort.dayLeft(record.day, nowMs: now)
      guard dayLeft > 0 else { return pause(.dayCap, untilMs: BacklogSort.dayReopensMs(record.day, nowMs: now)) }
      record.lastPassMs = now
      store.save(record)
      let result = await pass(memo, dayLeft)
      if let result {
        memo = result.pass.memo
        apply(result)
      }
      if Task.isCancelled || generation != id { return }
      guard let r = result, !r.pass.failed else {
        failures += 1
        if failures >= Self.maxFailures { return end(.failed) }
        await wake.wait(Self.idleWait, sleep: sleep)
        continue
      }
      passes += 1
      failures = 0
      let decided = BacklogSort.next(after: r.pass, importRunning: await importRunning(), backoffs: backoffs, nowMs: nowMs())
      if Task.isCancelled || generation != id { return }
      backoffs = decided.backoffs
      switch decided.next {
      case .pass(let afterMs):
        if afterMs > BacklogSort.passSpacingMs { setHold(.waiting(untilMs: nowMs() + afterMs)) }
        let left = Self.left(afterMs, since: now, nowMs: nowMs())
        if left > .zero { await sleep(left) }
        rested = true
      case .waitForRows:
        await wake.wait(Self.idleWait, sleep: sleep)
      case .pause(let stop, let untilMs):
        let until = stop == .dayCap ? BacklogSort.dayReopensMs(record.day, nowMs: nowMs()) : untilMs
        return pause(BacklogRunRecord.reason(stop), untilMs: until)
      case .done(let stop):
        return end(stop.map(BacklogRunRecord.reason))
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
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  var isOffered: Bool { BuildSurface.showsCloudSuggestions }

  var isOn: Bool { MerchantSuggestionsSetting.isAutoSortEnabled(defaults) }

  var answered: Bool { MerchantSuggestionsSetting.reviewAskAnswered(defaults) }

  func notNow() {
    MerchantSuggestionsSetting.answerReviewAsk(defaults)
  }

  func turnOn() {
    MerchantSuggestionsSetting.turnOnBoth(defaults)
  }
}
