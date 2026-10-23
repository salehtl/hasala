import CoreCategorize
import CoreDomain
import CoreOutbox
import CorePrimitives
import CoreStore
import CoreSync
import Foundation
import HasalaCloud
import Synchronization

struct ModelSuggestionStage: Sendable {
  let observer: LedgerPageObserver
  let outbox: Outbox
  let cache: FMCache
  let dictionary: MerchantDictionary
  let onDevice: any CategoryModel
  let cloud: (any CategoryModel)?
  let onDeviceAlone: Bool
  let nowMs: @Sendable () -> Int64
  var backlogActive: @Sendable () -> Bool = { false }
  var autoFileEnabled: @Sendable () -> Bool = { false }
  var cloudBudget: @Sendable () async -> Int = { BacklogSort.dayNames }
  var cloudSpent: @Sendable (Int) async -> Void = { _ in }
  var trusts: @Sendable (String) -> Bool = { _ in true }
  let gate = SweepGate()

  static func runs(_ trigger: WorkCoordinator.Trigger) -> Bool {
    trigger == .launch || trigger == .foreground || trigger == .refresh
  }

  static func stages(onDevice: any CategoryModel, cloud: (any CategoryModel)?, onDeviceAlone: Bool) -> [ModelStage] {
    switch cloud?.availability() {
    case .available?:
      guard let cloud else { return [] }
      return [.cloud(cloud), .onDevice(onDevice)]
    case .notEnabled?, nil:
      return onDeviceAlone ? [.onDevice(onDevice)] : []
    case .notEligible?, .notReady?, .unsupportedLanguage?:
      return [.onDevice(onDevice)]
    }
  }

  func run(_ trigger: WorkCoordinator.Trigger) async -> Bool {
    guard Self.runs(trigger), !backlogActive() else { return false }
    return await gate.run { await sweep() }
  }

  private func sweep() async -> Bool {
    let observer = self.observer
    let reader = observer.reader
    _ = try? cache.purgeExpired(now: nowMs())
    let tally = CallTally()
    let done: Bool
    do {
      let taxonomy = try reader.taxonomy()
      let all = Self.stages(onDevice: onDevice, cloud: cloud, onDeviceAlone: onDeviceAlone)
      let budget = all.contains(where: \.leavesDevice) ? max(0, await cloudBudget()) : 0
      let stages = budget > 0 ? all : all.filter { !$0.leavesDevice }
      if stages.isEmpty {
        done = false
      } else {
        let outbox = self.outbox
        let blobs = try await ModelSuggestionSweep.run(
          rows: try reader.sweepRows(), categorizer: try categorizer(taxonomy), allowed: ModelTier.allowed(taxonomy.ordered),
          stages: stages, context: .foreground, cache: cache, now: nowMs, autoFile: autoFileEnabled(), maxCloudCalls: budget,
          spent: { tally.add($0) }, trusts: trusts, stamps: observer.stamps, serial: observer.writes,
          reread: { (try observer.reader.sweepRows(), try await observer.authorContext()) },
          commit: { blobs in
            try await outbox.enqueue(blobs.flatMap(\.ops))
            try await observer.reproject()
          })
        done = !blobs.isEmpty
      }
    } catch {
      done = false
    }
    let calls = tally.value
    if calls > 0 { await cloudSpent(calls) }
    return done
  }

  func backlogPass(_ memo: BacklogSort.Memo, dayLeft: Int) async -> BacklogSorter.PassResult? {
    guard let cloud else { return .init(pass: BacklogSort.Pass(suggestions: [], memo: memo, pending: 0, calls: 0, stop: .off)) }
    return await gate.run { () async -> BacklogSorter.PassResult? in
      let observer = self.observer
      let reader = observer.reader
      do {
        let taxonomy = try reader.taxonomy()
        let left = min(dayLeft, await cloudBudget())
        let outbox = self.outbox
        let r = try await BacklogSort.run(
          rows: try reader.sweepRows(), categorizer: try categorizer(taxonomy), allowed: ModelTier.allowed(taxonomy.ordered),
          cloud: cloud, memo: memo, cache: cache, now: nowMs, autoFile: autoFileEnabled(), dayLeft: left, random: SystemRandom(),
          trusts: trusts, stamps: observer.stamps, serial: observer.writes,
          reread: { (try observer.reader.sweepRows(), try await observer.authorContext()) },
          enqueue: { try await outbox.enqueue($0.ops) })
        var failed = r.failed
        if r.authored {
          do { try await observer.reproject() } catch { failed = true }
        }
        guard !failed else {
          return .init(pass: .failed(r.pass.memo, calls: r.pass.calls), filing: r.filing)
        }
        return .init(pass: r.pass, filing: r.filing)
      } catch let e as BacklogSort.Interrupted {
        return .init(pass: .failed(e.memo, calls: e.calls))
      } catch {
        return nil
      }
    }
  }

  struct BacklogView: Sendable, Equatable {
    var counts: BacklogSort.Counts
    var cloudSorted: Int
  }

  nonisolated func backlogView(filedHere: [String: Int64]) async -> BacklogView? {
    let reader = observer.reader
    do {
      let taxonomy = try reader.taxonomy()
      let rows = try reader.sweepRows()
      let counts = try BacklogSort.counts(
        rows: rows, categorizer: try categorizer(taxonomy), allowed: ModelTier.allowed(taxonomy.ordered),
        modelTag: cloud?.modelTag ?? CloudCategoryModel.defaultTag, cache: cache, now: nowMs())
      return BacklogView(counts: counts, cloudSorted: BacklogSort.undoItems(manifest: filedHere, current: rows).count)
    } catch {
      return nil
    }
  }

  func undo(manifest: [String: Int64]) async -> Int? {
    await gate.run { () async -> Int? in
      let observer = self.observer
      do {
        return try await observer.writes.run {
          let r = try await BacklogSort.undo(
            manifest: manifest, stamps: observer.stamps,
            reread: { (try observer.reader.sweepRows(), try await observer.authorContext()) })
          _ = try await commit(r.blobs)
          return r.rows
        }
      } catch {
        return nil
      }
    }
  }

  private nonisolated func categorizer(_ taxonomy: TaxonomyView) throws -> Categorizer {
    let rules = try observer.reader.rules().map {
      RuleInput(
        id: $0.id, patterns: $0.patterns, match: $0.match, category: $0.category, priority: $0.priority, enabled: $0.enabled,
        removed: $0.removed)
    }
    return Categorizer(rules: rules, dictionary: dictionary, categories: taxonomy)
  }

  private func commit(_ blobs: [AuthoredBlob]) async throws -> Bool {
    guard !blobs.isEmpty else { return false }
    try await outbox.enqueue(blobs.flatMap(\.ops))
    try await observer.reproject()
    return true
  }
}

nonisolated final class CallTally: Sendable {
  private let count = Mutex(0)

  var value: Int { count.withLock { $0 } }
  func add(_ n: Int) { count.withLock { $0 += n } }
}

nonisolated final class SweepGate: Sendable {
  private let state = Mutex<(busy: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))

  func run<T: Sendable>(_ body: @Sendable () async -> T) async -> T {
    await acquire()
    defer { release() }
    return await body()
  }

  private func acquire() async {
    await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
      let now = state.withLock { s -> Bool in
        if s.busy {
          s.waiters.append(k)
          return false
        }
        s.busy = true
        return true
      }
      if now { k.resume() }
    }
  }

  private func release() {
    let next = state.withLock { s -> CheckedContinuation<Void, Never>? in
      if s.waiters.isEmpty {
        s.busy = false
        return nil
      }
      return s.waiters.removeFirst()
    }
    next?.resume()
  }
}
