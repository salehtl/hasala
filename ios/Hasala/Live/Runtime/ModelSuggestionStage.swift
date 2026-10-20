import CoreCategorize
import CoreDomain
import CoreOutbox
import CoreStore
import CoreSync
import Foundation

struct ModelSuggestionStage: Sendable {
  let observer: LedgerPageObserver
  let outbox: Outbox
  let cache: FMCache
  let dictionary: MerchantDictionary
  let onDevice: any CategoryModel
  let cloud: (any CategoryModel)?
  let nowMs: @Sendable () -> Int64

  static func runs(_ trigger: WorkCoordinator.Trigger) -> Bool {
    trigger == .launch || trigger == .foreground || trigger == .refresh
  }

  static func stages(onDevice: any CategoryModel, cloud: (any CategoryModel)?) -> [ModelStage] {
    guard let cloud, cloud.availability() == .available else { return [.onDevice(onDevice)] }
    return [.cloud(cloud), .onDevice(onDevice)]
  }

  func run(_ trigger: WorkCoordinator.Trigger) async -> Bool {
    guard Self.runs(trigger) else { return false }
    let observer = self.observer
    let reader = observer.reader
    _ = try? cache.purgeExpired(now: nowMs())
    do {
      let taxonomy = try reader.taxonomy()
      let rules = try reader.rules().map {
        RuleInput(
          id: $0.id, patterns: $0.patterns, match: $0.match, category: $0.category, priority: $0.priority, enabled: $0.enabled,
          removed: $0.removed)
      }
      let stages = Self.stages(onDevice: onDevice, cloud: cloud)
      let blobs = try await ModelSuggestionSweep.run(
        rows: try reader.sweepRows(), categorizer: Categorizer(rules: rules, dictionary: dictionary, categories: taxonomy),
        allowed: ModelTier.allowed(taxonomy.ordered), stages: stages, context: .foreground, cache: cache, now: nowMs,
        stamps: observer.stamps,
        reread: { (try observer.reader.sweepRows(), try await observer.authorContext()) })
      guard !blobs.isEmpty else { return false }
      for b in blobs { try await outbox.enqueue(b.ops) }
      try await observer.reproject()
      return true
    } catch {
      return false
    }
  }
}
