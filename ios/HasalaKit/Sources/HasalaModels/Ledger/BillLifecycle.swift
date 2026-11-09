public enum BillLifecycle {
  @discardableResult
  public static func markPaid(_ b: inout Bill) throws(ActionError) -> LocalDate {
    guard !b.isIncome, b.state != .dismissed else { throw .notFound }
    guard b.state == .tracked else { throw .invalidBill }
    let due = b.nextDue
    b.history.insert(due, at: 0)
    b.payments.removeAll { $0.due == due }
    b.payments.insert(BillPayment(due: due, amount: b.amount, link: .marked), at: 0)
    b.nextDue = BillDueDates.shift(b, from: due, by: 1)
    return due
  }

  public static func dismissNotice(_ b: inout Bill, id: String) throws(ActionError) {
    guard let notice = b.notices.first(where: { $0.id == id }) else { throw .notFound }
    b.notices.removeAll { $0.id == id }
    guard notice.isPriceChange, let usual = b.priceChangeFrom else { return }
    b.amount = usual
    b.priceChangeFrom = nil
  }

  public static func link(_ s: inout LedgerState, bill i: Int, _ ids: [TxnID]) throws(ActionError) {
    guard !ids.isEmpty, Set(ids).count == ids.count else { throw .invalidBill }
    let b = s.bills[i]
    var dues = Set<LocalDate>()
    var planned: [(id: TxnID, due: LocalDate, amount: Money, day: LocalDate)] = []
    for id in ids {
      guard let t = s.txn(id) else { throw .notFound }
      if t.archived || t.isTransfer || t.isHeldCopy || t.isRefund { throw .invalidBill }
      if t.direction != (b.isIncome ? .in : .out) { throw .invalidBill }
      if let other = t.billID, other != b.id { throw .invalidBill }
      let due = BillDueDates.nearest(b, to: t.postedAt.date)
      if let end = b.endedOn, due > end { throw .invalidBill }
      if !dues.insert(due).inserted { throw .invalidBill }
      if b.payments.contains(where: { $0.due == due && $0.link == .linked && $0.txnID != id }) { throw .invalidBill }
      planned.append((id, due, t.amount, t.postedAt.date))
    }
    for p in planned {
      if let k = s.txns.firstIndex(where: { $0.id == p.id }) { s.txns[k].billID = b.id }
      s.bills[i].payments.removeAll { $0.due == p.due || $0.txnID == p.id }
      s.bills[i].payments.append(BillPayment(due: p.due, txnID: p.id, amount: p.amount, link: .linked))
      if !s.bills[i].history.contains(p.day) { s.bills[i].history.append(p.day) }
      if p.due >= s.bills[i].nextDue { s.bills[i].nextDue = BillDueDates.shift(s.bills[i], from: p.due, by: 1) }
    }
    s.bills[i].payments.sort { $0.due > $1.due }
    s.bills[i].history.sort(by: >)
  }

  public static func editIncome(
    _ s: inout LedgerState, _ id: BillID, amount: Money, payday: Int, active: Bool, today: LocalDate
  ) throws(ActionError) {
    guard let i = s.bills.firstIndex(where: { $0.id == id && $0.isIncome }) else { throw .notFound }
    guard amount.minor > 0, amount.minor <= ManualEntryDraft.maxMinor else { throw .invalidAmount }
    guard (1...31).contains(payday) else { throw .invalidBill }
    let old = s.bills[i]
    s.bills[i].amount = amount
    s.bills[i].usualDay = payday
    s.bills[i].state = active ? .tracked : .ended
    s.bills[i].endedOn = active ? nil : today
    let ym = today.yearMonth
    let thisMonth = ym.date(clampedDay: payday)
    s.bills[i].nextDue = thisMonth >= today ? thisMonth : ym.next.date(clampedDay: payday)
    let removed = old.state == .tracked ? old.amount.minor : 0
    s.plan.income = .aed(max(0, s.plan.income.minor - removed + (active ? amount.minor : 0)))
    s.plan.payday = payday
    for m in s.plan.incomeByMonth.keys where m >= ym { s.plan.incomeByMonth[m] = nil }
    for m in s.plan.incomeExpectedByMonth.keys where m >= ym { s.plan.incomeExpectedByMonth[m] = nil }
  }
}
