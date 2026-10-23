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

  func accepted(_ category: String, modelTag: String?) {
    guard Self.cloud(modelTag), builtins.contains(category) else { return }
    change { $0.accepts[category, default: 0] += 1 }
  }

  func corrected(_ category: String, modelTag: String?) {
    guard Self.cloud(modelTag), builtins.contains(category) else { return }
    change { $0.corrections[category, default: 0] += 1 }
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

  func reset() {
    cache.withLock { c in
      c = Counts()
      defaults().removeObject(forKey: Self.key)
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
