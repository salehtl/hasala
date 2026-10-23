import CoreReplay
import CoreStore
import CoreWire
import Foundation
import HasalaModels
import Synchronization

nonisolated struct SortMemory: Codable, Sendable, Equatable {
  struct Receipt: Codable, Sendable, Equatable {
    var id: Int
    var group: String?
    var direction: String?
    var merchant: String
    var category: String
    var txnIDs: [String]
    var ruleID: String?
    var atMs: Int64
  }

  struct Prior: Codable, Sendable, Equatable {
    var category: String?
    var needsReview: Bool
    var source: CoreReplay.CategorySource
    var written: Int64
    var categorizedMs: Int64?
  }

  struct Batch: Codable, Sendable, Equatable {
    var id: String
    var ruleID: String?
    var group: String
    var direction: String
    var category: String
    var seen: Set<String>
    var prior: [String: Prior]
    var rerun: Bool
    var cursor: Int64
    var atMs: Int64
  }

  static let keptBatches = 40
  static let keptMs: Int64 = 30 * 86_400_000
  static let keptOps = 20_000

  var receipt: Receipt?
  var batches: [Batch] = []
  var repaired: Set<String> = []
  var autoOps: [String] = []

  mutating func noteAuto(_ ops: [Op]) {
    let ids = ops.filter { $0.type == .txnCategorized }.map(\.opID)
    guard !ids.isEmpty else { return }
    autoOps += ids
    if autoOps.count > Self.keptOps { autoOps.removeFirst(autoOps.count - Self.keptOps) }
  }

  mutating func add(_ b: Batch, nowMs: Int64) {
    batches.append(b)
    batches.removeAll { nowMs - $0.atMs > Self.keptMs }
    if batches.count > Self.keptBatches { batches.removeFirst(batches.count - Self.keptBatches) }
  }

  mutating func settle(_ ids: some Sequence<String>) {
    let all = Set(ids)
    guard !all.isEmpty else { return }
    for i in batches.indices { batches[i].seen.formUnion(all) }
  }

  func prior(of txn: String) -> Prior? {
    batches.reversed().lazy.compactMap { $0.prior[txn] }.first
  }

  var ownOps: Set<String> { Set(autoOps) }

  func kitReceipt(undo: UndoToken?) -> SortReceipt? {
    guard let r = receipt else { return nil }
    let ref = r.group.map { MerchantGroupRef(key: $0, direction: r.direction == "credit" ? .in : .out) }
    return SortReceipt(
      id: r.id, group: ref, merchant: r.merchant, categoryID: r.category, txnIDs: r.txnIDs, ruleID: r.ruleID, undo: undo)
  }
}

nonisolated final class SortKeeper: Sendable {
  private let store: SortMemoryStore?
  private let memory: Mutex<SortMemory?>

  init(store: SortMemoryStore?) {
    self.store = store
    memory = Mutex(nil)
  }

  static func inMemory() -> SortKeeper { SortKeeper(store: nil) }

  var value: SortMemory {
    memory.withLock { m in
      if let m { return m }
      let loaded = Self.decode(try? store?.load()) ?? SortMemory()
      m = loaded
      return loaded
    }
  }

  @discardableResult
  func update<T>(_ change: (inout SortMemory) -> T) -> T {
    memory.withLock { m in
      var current = m ?? Self.decode(try? store?.load()) ?? SortMemory()
      let out = change(&current)
      m = current
      if let data = try? JSONEncoder().encode(current) { try? store?.save(data) }
      return out
    }
  }

  func forget() {
    memory.withLock { m in
      m = SortMemory()
      try? store?.clear()
    }
  }

  private static func decode(_ data: Data?) -> SortMemory? {
    guard let data else { return nil }
    return try? JSONDecoder().decode(SortMemory.self, from: data)
  }
}
