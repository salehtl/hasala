import CoreCategorize
import Foundation
import Synchronization

nonisolated final class TrustCounts: Sendable {
  static let key = "app.hasala.prefs.trust.counts.v1"
  static let correctionsToStop = 2

  struct Counts: Codable, Equatable, Sendable {
    var accepts: [String: Int] = [:]
    var corrections: [String: Int] = [:]
  }

  private let defaults: @Sendable () -> UserDefaults
  private let builtins: Set<String>
  private let cache = Mutex<Counts?>(nil)

  init(defaults: @escaping @Sendable () -> UserDefaults = { .standard }, builtins: Set<String> = TrustCounts.builtinIDs) {
    self.defaults = defaults
    self.builtins = builtins
  }

  static let builtinIDs = Set(TaxonomyV1.builtins.map(\.id))

  static func cloud(_ tag: String?) -> Bool { tag.map(ModelTier.mayAutoFile(modelTag:)) == true }

  var counts: Counts {
    cache.withLock { c in
      if let c { return c }
      let loaded = Self.read(defaults()) ?? Counts()
      c = loaded
      return loaded
    }
  }

  @discardableResult
  func corrected(_ category: String, modelTag: String?) -> Bool {
    guard Self.cloud(modelTag), builtins.contains(category) else { return false }
    change { $0.corrections[category, default: 0] += 1 }
    return true
  }

  func uncorrected(_ category: String, modelTag: String?, by n: Int = 1) {
    guard n > 0, Self.cloud(modelTag), builtins.contains(category) else { return }
    change { c in
      let left = max(0, (c.corrections[category] ?? 0) - n)
      c.corrections[category] = left == 0 ? nil : left
    }
  }

  func autoFiles(_ category: String) -> Bool {
    (counts.corrections[category] ?? 0) < Self.correctionsToStop
  }

  var autoFile: @Sendable (String) -> Bool { { [self] in autoFiles($0) } }

  private func change(_ edit: (inout Counts) -> Void) {
    cache.withLock { c in
      var next = c ?? Self.read(defaults()) ?? Counts()
      edit(&next)
      c = next
      if let data = try? JSONEncoder().encode(next) { defaults().set(data, forKey: Self.key) }
    }
  }

  private static func read(_ d: UserDefaults) -> Counts? {
    guard let data = d.data(forKey: key) else { return nil }
    return try? JSONDecoder().decode(Counts.self, from: data)
  }

  static func forget(_ defaults: UserDefaults) {
    defaults.removeObject(forKey: key)
    shared.dropCache()
  }

  func dropCache() { cache.withLock { $0 = nil } }

  static let shared = TrustCounts()
}
