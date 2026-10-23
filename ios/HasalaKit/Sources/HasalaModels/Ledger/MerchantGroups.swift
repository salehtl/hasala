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

  public static func patterns(filed: Txn?, members: [Txn]) -> [String] {
    var counts: [String: Int] = [:]
    var order: [String] = []
    for t in members {
      guard let p = pattern(t.spelling) else { continue }
      if counts[p] == nil { order.append(p) }
      counts[p, default: 0] += 1
    }
    let ranked = order.enumerated().sorted { a, b in
      let ca = counts[a.element] ?? 0, cb = counts[b.element] ?? 0
      return ca == cb ? a.offset < b.offset : ca > cb
    }.map(\.element)
    var out: [String] = []
    if let filed, let p = pattern(filed.spelling) { out.append(p) }
    for p in ranked where out.count < maxPatterns && !out.contains(p) { out.append(p) }
    return out
  }
}
