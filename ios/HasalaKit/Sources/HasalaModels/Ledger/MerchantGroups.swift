public struct MerchantGroupRef: Sendable, Hashable, Codable, Identifiable {
  public var key: String
  public var direction: Direction

  public init(key: String, direction: Direction) {
    self.key = key
    self.direction = direction
  }

  public var id: String { "\(direction.rawValue).\(key)" }
}

public struct SortReceipt: Sendable, Hashable, Codable, Identifiable {
  public var id: Int
  public var group: MerchantGroupRef?
  public var merchant: String
  public var categoryID: CategoryID
  public var txnIDs: [TxnID]
  public var ruleID: RuleID?
  public var undo: UndoToken?

  public init(
    id: Int, group: MerchantGroupRef?, merchant: String, categoryID: CategoryID, txnIDs: [TxnID],
    ruleID: RuleID? = nil, undo: UndoToken? = nil
  ) {
    self.id = id
    self.group = group
    self.merchant = merchant
    self.categoryID = categoryID
    self.txnIDs = txnIDs
    self.ruleID = ruleID
    self.undo = undo
  }

  public var count: Int { txnIDs.count }
}

extension Txn {
  public var groupRef: MerchantGroupRef? { merchantGroup.map { MerchantGroupRef(key: $0, direction: direction) } }

  public var rejectionRef: MerchantGroupRef? {
    (merchantGroup ?? merchantKey).map { MerchantGroupRef(key: $0, direction: direction) }
  }

  public var spelling: String { provenance?.rawMerchant ?? merchant }

  public var isModelSourced: Bool {
    if case .model = categorySource { return true }
    return false
  }

  public var modelGuessRejected: Bool {
    isModelSourced && categoryID.map(rejectedCategories.contains) == true
  }

  public var autoFiledByCloudflare: Bool {
    guard !needsReview, !modelGuessRejected, categoryID != nil, case .model(let tag) = categorySource else { return false }
    return tag?.hasPrefix(CategorySource.cloudflareModelPrefix) == true
  }

  public var filedByRule: Bool {
    guard !needsReview, categoryID != nil, case .rule = categorySource else { return false }
    return true
  }

  public var filedByPerson: Bool {
    switch categorySource {
    case .user, .manual, .rule: true
    case .dictionary, .model, nil: false
    }
  }

  public func inGroup(_ key: String) -> Bool { (merchantGroup ?? merchantKey) == key }

  public var canAlwaysUse: Bool { merchantGroup != nil && splits.isEmpty && GroupRule.pattern(spelling) != nil }

  public func settled(in c: CategoryID) -> Bool { !needsReview && categoryID == c }

  public var filing: PriorFiling {
    PriorFiling(
      categoryID: categoryID, categorySource: categorySource, ruleID: ruleID, needsReview: needsReview, categorizedAt: categorizedAt)
  }

  public mutating func restore(_ p: PriorFiling) {
    categoryID = p.categoryID
    categorySource = p.categorySource
    ruleID = p.ruleID
    needsReview = p.needsReview
    isTransfer = p.categoryID == "transfer"
    categorizedAt = p.categorizedAt
    priorFiling = nil
  }
}

extension LedgerState {
  public func rule(_ id: RuleID?) -> Rule? {
    guard let id else { return nil }
    return rules.first { $0.id == id }
  }
}

public enum GroupRule {
  public static let maxPatterns = 8
  public static let maxScalars = 128

  public static func pattern(_ spelling: String) -> String? {
    let words = spelling.lowercased().split(whereSeparator: { $0.isWhitespace })
    let p = words.joined(separator: " ")
    guard (2...maxScalars).contains(p.unicodeScalars.count) else { return nil }
    return p
  }

  static func ranked(_ rows: [Txn]) -> [String] {
    var counts: [String: Int] = [:]
    var order: [String] = []
    for t in rows {
      guard let p = pattern(t.spelling) else { continue }
      if counts[p] == nil { order.append(p) }
      counts[p, default: 0] += 1
    }
    return order.enumerated().sorted { a, b in
      let ca = counts[a.element] ?? 0, cb = counts[b.element] ?? 0
      return ca == cb ? a.offset < b.offset : ca > cb
    }.map(\.element)
  }

  public static func patterns(filed: Txn?, members: [Txn], then rest: [Txn] = []) -> [String] {
    var out: [String] = []
    if let filed, let p = pattern(filed.spelling) { out.append(p) }
    for p in ranked(members) + ranked(rest) where out.count < maxPatterns && !out.contains(p) { out.append(p) }
    return out
  }

  public static func patterns(filed: Txn, members: [Txn], filing c: CategoryID) -> [String] {
    patterns(filed: filed, members: members.filter { !$0.settled(in: c) }, then: members.filter { $0.settled(in: c) })
  }

  public static func reaches(_ t: Txn, _ patterns: [String]) -> Bool {
    pattern(t.spelling).map(patterns.contains) == true
  }
}
