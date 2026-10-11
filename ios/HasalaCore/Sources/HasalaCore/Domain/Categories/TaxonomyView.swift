// `TaxonomyView` (spec 03c §4.4): taxonomy v1 overlaid with the account's
// `category_defined` records. Built-ins keep their taxonomy `ord`; a user
// category's ord is 100 + its first-definition index (fold order, which the
// snapshot preserves). Applied at read time, never in the fold (03c §1.11).
import CoreCategorize
import CoreReplay
import HasalaText

public struct TaxonomyView: Sendable, CategoryLookup {
  public let ordered: [CategoryInfo]
  private let byID: [String: CategoryInfo]

  public init(_ infos: [CategoryInfo]) {
    ordered = infos.sorted { $0.sortKey != $1.sortKey ? $0.sortKey < $1.sortKey : compareUTF8($0.id, $1.id) < 0 }
    var m: [String: CategoryInfo] = [:]
    for i in infos { m[i.id] = i }
    byID = m
  }

  /// The effective table of a folded state.
  public init(state: State) {
    var infos: [CategoryInfo] = []
    for b in TaxonomyV1.builtins {
      guard let d = state.categories[b.id] else {
        infos.append(b)
        continue
      }
      infos.append(Self.info(d, sortKey: b.sortKey, builtin: true, defaultIcon: b.icon))
    }
    var userIndex = 0
    for (id, d) in state.categories where TaxonomyV1.builtin(id) == nil {
      infos.append(Self.info(d, sortKey: 100 + userIndex, builtin: false, defaultIcon: TaxonomyV1.userIcon))
      userIndex += 1
    }
    self.init(infos)
  }

  private static func info(_ d: CategoryDef, sortKey: Int, builtin: Bool, defaultIcon: String) -> CategoryInfo {
    CategoryInfo(
      id: d.id, name: d.name, kind: CategoryKind(rawValue: d.kind) ?? .excluded, bucket: d.bucket.flatMap(Bucket.init(rawValue:)),
      icon: d.shape >= 4 ? (d.icon ?? defaultIcon) : defaultIcon, active: d.active, builtin: builtin, sortKey: sortKey)
  }

  public func info(_ id: String) -> CategoryInfo? { byID[id] }

  /// Spending at read time (03a §2): defined, kind spending.
  public func isSpending(_ id: String) -> Bool { byID[id]?.kind == .spending }
}
