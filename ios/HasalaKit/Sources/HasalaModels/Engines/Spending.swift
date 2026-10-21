public enum Spending {
  public static func total(_ s: LedgerState, in period: Period) -> Int64 {
    Fils.sum(s.txns.filter { period.contains($0.postedAt.date) }) { spent($0, in: s) }
  }

  public static func total(_ s: LedgerState, in month: YearMonth) -> Int64 {
    total(s, in: .month(month))
  }

  public static func spent(_ t: Txn, in s: LedgerState) -> Int64 {
    Fils.sum(parts(t, in: s).map(\.minor))
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
      byProject[p.id, default: 0].add(Fils.sum(measured(t, in: s).map(\.minor)))
    }
    return s.projects.compactMap { p in byProject[p.id].flatMap { $0 == 0 ? nil : (p, $0) } }
  }

  public static func spent(_ s: LedgerState, category c: CategoryID, in period: Period) -> Int64 {
    Fils.sum(s.txns.filter { period.contains($0.postedAt.date) && includes($0, in: s) }) { t in
      Fils.sum(t.lines.filter { $0.category == c }.map(\.minor))
    }
  }

  public static func spent(_ s: LedgerState, category c: CategoryID, in month: YearMonth) -> Int64 {
    spent(s, category: c, in: .month(month))
  }

  public static func includes(_ t: Txn, in s: LedgerState) -> Bool {
    t.countsInPlan && carvedOut(t, in: s) == nil
  }

  static func measured(_ t: Txn, in s: LedgerState) -> [(category: Category?, minor: Int64)] {
    if t.archived || t.isTransfer || t.isHeldCopy { return [] }
    if !t.splits.isEmpty {
      return t.splits.compactMap { sp in
        let c = s.category(sp.categoryID)
        guard counts(c), let home = sp.homeMinor else { return nil }
        return (c, t.direction == .out ? home : home.negated)
      }
    }
    guard let signed = t.homeSigned else { return [] }
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
