public struct RefundFiling: Sendable, Hashable {
  public var categoryID: CategoryID?
  public var needsReview: Bool
  public var refundOf: TxnID?
  public var isRefund: Bool
  public var title: String

  public func apply(to t: inout Txn) {
    t.categoryID = categoryID
    t.categorySource = categoryID == nil ? nil : .user
    t.ruleID = nil
    t.needsReview = needsReview
    t.refundOf = refundOf
    t.isRefund = isRefund
    t.isTransfer = t.isMatchedTransfer
    t.priorFiling = nil
  }
}

public enum RefundEdit {
  public static let refusedOut = "Only money in can be a refund."
  public static let refusedTarget = "Choose a payment out to match this refund."
  public static let refusedMatchedTransfer = "This is one side of a matched transfer."

  public static func mark(_ t: Txn, in s: LedgerState) throws(ActionError) -> RefundFiling {
    if t.isRefund {
      return RefundFiling(categoryID: nil, needsReview: true, refundOf: nil, isRefund: false, title: "No longer a refund")
    }
    guard t.direction == .in else { throw .refused(refusedOut) }
    guard !t.isMatchedTransfer else { throw .refused(refusedMatchedTransfer) }
    let keep = t.splits.isEmpty && Spending.counts(s.category(t.categoryID))
    return RefundFiling(
      categoryID: keep ? t.categoryID : Spending.refundsID, needsReview: false, refundOf: nil, isRefund: true,
      title: "Marked as a refund")
  }

  public static func file(_ t: Txn, into c: CategoryID, of target: TxnID?, in s: LedgerState) throws(ActionError)
    -> RefundFiling
  {
    guard t.direction == .in else { throw .refused(refusedOut) }
    guard !t.isMatchedTransfer else { throw .refused(refusedMatchedTransfer) }
    guard Spending.counts(s.category(c)) else { throw .notFound }
    if let target {
      guard target != t.id, let p = s.txn(target), p.direction == .out, !p.archived else { throw .refused(refusedTarget) }
    }
    let name = s.category(c)?.name ?? "Uncategorized"
    return RefundFiling(categoryID: c, needsReview: false, refundOf: target, isRefund: true, title: "Refund · \(name)")
  }

  public static let reversalWindowDays = 30

  public static func reversal(of id: TxnID, in s: LedgerState) -> Txn? {
    s.txns.first { $0.isReversal && $0.refundOf == id && !$0.archived }
  }

  public static func reversalCandidates(for t: Txn, in s: LedgerState) -> [Txn] {
    guard t.direction == .in, let home = t.homeMinor, let group = t.merchantGroup ?? t.merchantKey else { return [] }
    let from = t.postedAt.date.adding(days: -reversalWindowDays)
    return s.txns.filter { p in
      p.id != t.id && p.direction == .out && !p.archived && !p.isTransfer && !p.isHeldCopy && p.splits.isEmpty
        && p.homeMinor == home && (p.merchantGroup ?? p.merchantKey) == group
        && p.postedAt.date >= from && p.postedAt <= t.postedAt && reversal(of: p.id, in: s) == nil
    }
  }

  public static func label(_ t: Txn, in s: LedgerState) -> String? {
    guard t.splits.isEmpty else { return nil }
    if t.isReversal {
      let c = Spending.refundTarget(t, in: s) ?? s.category(t.categoryID).flatMap { Spending.counts($0) ? $0 : nil }
      return c.map { "Reversal · \($0.name)" } ?? "Reversal"
    }
    if t.direction == .in, isRefund(t, in: s) {
      let c = Spending.refundTarget(t, in: s) ?? s.category(t.categoryID).flatMap { Spending.counts($0) ? $0 : nil }
      return c.map { "Refund · \($0.name)" } ?? "Refund"
    }
    if t.direction == .out, reversal(of: t.id, in: s) != nil {
      return s.category(t.categoryID).map { "Reversed · \($0.name)" } ?? "Reversed"
    }
    return nil
  }

  public static func filedAsRefund(_ t: Txn, in s: LedgerState) -> Bool {
    t.categoryID == Spending.refundsID || t.refundOf != nil
      || (t.direction == .in && t.splits.isEmpty && Spending.counts(s.category(t.categoryID)))
  }

  public static func refundByBrokenLink(_ t: Txn, in s: LedgerState) -> Bool {
    t.isRefund && !filedAsRefund(t, in: s)
  }

  public static func filedAsTransfer(_ t: Txn) -> Bool {
    t.categoryID == "transfer" || t.isMatchedTransfer
  }

  public static func isRefund(_ t: Txn, in s: LedgerState) -> Bool {
    t.isRefund || (t.direction == .in && t.splits.isEmpty && Spending.counts(s.category(t.categoryID)))
  }
}
