import HasalaModels

public enum MockReach {
  public static func ruled(_ t: Txn, pairs: Set<TxnID>) -> Bool {
    guard !t.archived, !t.isTransfer, !t.isHeldCopy, t.samePurchase == nil, !pairs.contains(t.id) else { return false }
    guard t.reviewReason == nil, t.splits.isEmpty else { return false }
    switch t.categorySource {
    case .user?, .manual?: return false
    default: return true
    }
  }

  public static func refresh(_ s: inout LedgerState, sortOrder: [TxnID: Int] = [:]) {
    let pairs = Set(s.txns.compactMap { $0.samePurchase?.of })
    for i in s.txns.indices {
      let ruled = ruled(s.txns[i], pairs: pairs)
      if s.txns[i].ruled != ruled { s.txns[i].ruled = ruled }
      let reach = s.txns[i].waits
      if s.txns[i].reachable != reach { s.txns[i].reachable = reach }
    }
    ReviewEngine.fillLastPicks(&s, sortOrder: sortOrder)
  }

  public static func refreshed(_ s: LedgerState) -> LedgerState {
    var s = s
    refresh(&s)
    return s
  }
}
