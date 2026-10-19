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
    parts(t, in: s).reduce(Int64(0)) { $0 + $1.minor }
  }

  public static func parts(_ t: Txn, in s: LedgerState) -> [(category: Category?, minor: Int64)] {
    carvedOut(t, in: s) == nil ? measured(t, in: s) : []
  }

  public static func carvedOut(_ t: Txn, in s: LedgerState) -> Project? {
    s.project(t.projectID).flatMap { $0.countInPlan ? nil : $0 }
  }

  public static func notCounted(_ s: LedgerState, in period: Period) -> [(project: Project, minor: Int64)] {
    var byProject: [ProjectID: Int64] = [:]
    for t in s.txns where period.contains(t.postedAt.date) {
      guard let p = carvedOut(t, in: s) else { continue }
      byProject[p.id, default: 0] += measured(t, in: s).reduce(Int64(0)) { $0 + $1.minor }
    }
    return s.projects.compactMap { p in byProject[p.id].flatMap { $0 == 0 ? nil : (p, $0) } }
  }

  static func measured(_ t: Txn, in s: LedgerState) -> [(category: Category?, minor: Int64)] {
    if t.archived || t.isTransfer || t.isHeldCopy { return [] }
    if !t.splits.isEmpty {
      return t.splits.compactMap { sp in
        let c = s.category(sp.categoryID)
        return counts(c) ? (c, sp.amount.minor) : nil
      }
    }
    let signed = t.direction == .out ? t.amount.minor : -t.amount.minor
    guard let c = s.category(t.categoryID) else {
      return t.direction == .out || t.isRefund ? [(nil, signed)] : []
    }
    return counts(c) ? [(c, signed)] : []
  }

  public static func counts(_ c: Category?) -> Bool {
    guard let c else { return false }
    return c.kind == .spending && c.bucket != .savings && c.role != .saving
  }
}
