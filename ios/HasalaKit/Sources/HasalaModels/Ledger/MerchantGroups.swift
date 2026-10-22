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

  public var autoFiledByCloudflare: Bool {
    guard !needsReview, categoryID != nil, case .model(let tag) = categorySource else { return false }
    return tag?.hasPrefix(CategorySource.cloudflareModelPrefix) == true
  }

  public var filedByRule: Bool {
    guard !needsReview, categoryID != nil, case .rule = categorySource else { return false }
    return true
  }

  public func inGroup(_ key: String) -> Bool { (merchantGroup ?? merchantKey) == key }
}

extension LedgerState {
  public func rule(_ id: RuleID?) -> Rule? {
    guard let id else { return nil }
    return rules.first { $0.id == id }
  }
}
