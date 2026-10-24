import HasalaText

public enum LastPick {
  public struct Key: Sendable, Hashable {
    public let group: String
    public let direction: String

    public init(group: String, direction: String) {
      self.group = group
      self.direction = direction
    }
  }

  public struct Row: Sendable, Equatable {
    public let id: String
    public let group: String?
    public let direction: String
    public let category: String?
    public let sourceKind: SweepRow.SourceKind
    public let split: Bool
    public let needsReview: Bool
    public let categorizedMs: Int64?
    public let postedMs: Int64

    public init(
      id: String, group: String?, direction: String, category: String?, sourceKind: SweepRow.SourceKind, split: Bool = false,
      needsReview: Bool = false, categorizedMs: Int64?, postedMs: Int64
    ) {
      self.id = id
      self.group = group
      self.direction = direction
      self.category = category
      self.sourceKind = sourceKind
      self.split = split
      self.needsReview = needsReview
      self.categorizedMs = categorizedMs
      self.postedMs = postedMs
    }

    public var key: Key? {
      guard let group, !group.isEmpty else { return nil }
      return Key(group: group, direction: direction)
    }

    public var at: Int64 { categorizedMs ?? postedMs }
  }

  public static func counts(_ r: Row) -> Bool {
    r.key != nil && r.category != nil && !r.split && !r.needsReview && r.sourceKind == .user
  }

  public static func newer(_ a: Row, than b: Row) -> Bool {
    if a.at != b.at { return a.at > b.at }
    if a.postedMs != b.postedMs { return a.postedMs > b.postedMs }
    return compareUTF8(a.id, b.id) > 0
  }

  public static func picks(_ rows: [Row]) -> [Key: String] {
    var newest: [Key: Row] = [:]
    for r in rows where counts(r) {
      guard let k = r.key else { continue }
      if let n = newest[k], !newer(r, than: n) { continue }
      newest[k] = r
    }
    return newest.compactMapValues(\.category)
  }
}
