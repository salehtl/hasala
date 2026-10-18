public enum Spending {
  public static func total(_ s: LedgerState, in period: Period) -> Int64 {
    s.txns.reduce(Int64(0)) { sum, t in
      period.contains(t.postedAt.date) ? sum + spent(t, in: s) : sum
    }
  }

  public static func total(_ s: LedgerState, in month: YearMonth) -> Int64 {
    total(s, in: .month(month))
  }

  public static func spent(_ t: Txn, in s: LedgerState) -> Int64 {
    if t.archived || t.isTransfer { return 0 }
    if let p = s.project(t.projectID), !p.countInPlan { return 0 }
    if !t.splits.isEmpty {
      return t.splits.reduce(Int64(0)) { $0 + (counts(s.category($1.categoryID)) ? $1.amount.minor : 0) }
    }
    let signed = t.direction == .out ? t.amount.minor : -t.amount.minor
    guard let c = s.category(t.categoryID) else {
      return t.direction == .out || t.isRefund ? signed : 0
    }
    return counts(c) ? signed : 0
  }

  public static func counts(_ c: Category?) -> Bool {
    guard let c else { return false }
    return c.kind == .spending && c.bucket != .savings && c.role != .saving
  }
}
