import HasalaModels

public enum MockReach {
  public static func waiting(_ t: Txn, pairs: Set<TxnID>) -> Bool {
    guard !t.archived, !t.isTransfer, !t.isHeldCopy, t.samePurchase == nil, !pairs.contains(t.id) else { return false }
    guard t.reviewReason == nil else { return false }
    switch t.categorySource {
    case .user?, .manual?: return false
    default: return t.needsReview || (t.categoryID == nil && t.splits.isEmpty)
    }
  }

  public static func refresh(_ s: inout LedgerState) {
    let pairs = Set(s.txns.compactMap { $0.samePurchase?.of })
    for i in s.txns.indices {
      let reach = waiting(s.txns[i], pairs: pairs)
      if s.txns[i].reachable != reach { s.txns[i].reachable = reach }
    }
  }

  public static func refreshed(_ s: LedgerState) -> LedgerState {
    var s = s
    refresh(&s)
    return s
  }
}
