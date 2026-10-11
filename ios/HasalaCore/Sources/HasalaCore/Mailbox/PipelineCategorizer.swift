// The at-ingest categorization of the Gmail lane (03c §8.2-§8.3, spec 04 §8.1):
// CoreCategorize's `Categorizer` over the projection's rules and category table
// and the bundled merchant dictionary. Rules first, then the dictionary; a
// spending category on a credit is only a suggestion and files nothing. The
// model tier (Foundation Models) is a later sweep, never at ingest.
//
// The prepared categorizer is cached and rebuilt after every projection (the
// projection's `generation`), so a rule made in Review applies to the very next
// message.
import CoreCategorize
import CoreDomain
import CoreProjection
import Foundation
import Synchronization

public final class PipelineCategorizer: IngestCategorizer {
  let projection: ProjectionStore
  let dictionary: MerchantDictionary
  private let cache = Mutex<(key: UInt64, categorizer: Categorizer)?>(nil)

  public init(projection: ProjectionStore, dictionary: MerchantDictionary) {
    self.projection = projection
    self.dictionary = dictionary
  }

  public func decide(merchantRaw: String, direction: String) -> IngestDecision {
    guard let dir = Direction(rawValue: direction), let c = current() else { return .none }
    let d = c.decide(merchantRaw: merchantRaw, direction: dir)
    guard let category = d.category else { return .none }
    return IngestDecision(category: category, source: OpAuthor.sourceJSON(OpAuthor.categorySource(d.source)))
  }

  /// Drops the cached rules (the next decision reads the projection again).
  public func invalidate() { cache.withLock { $0 = nil } }

  func current() -> Categorizer? {
    let key = projection.generation
    if let hit = cache.withLock({ $0 }), hit.key == key { return hit.categorizer }
    let reader = projection.reader
    guard let rules = try? reader.rules(), let taxonomy = try? reader.taxonomy() else { return nil }
    let inputs = rules.map {
      RuleInput(
        id: $0.id, patterns: $0.patterns, match: $0.match, category: $0.category, priority: $0.priority, enabled: $0.enabled,
        removed: $0.removed)
    }
    let c = Categorizer(rules: inputs, dictionary: dictionary, categories: taxonomy)
    cache.withLock { $0 = (key, c) }
    return c
  }
}
