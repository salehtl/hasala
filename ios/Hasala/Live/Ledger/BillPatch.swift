import Foundation
import HasalaModels

nonisolated enum BillPatch {
  static func shift(_ b: Bill, from base: LocalDate, by n: Int) -> LocalDate {
    switch b.cadence {
    case .weekly:
      return base.adding(days: 7 * b.every * n)
    case .monthly, .yearly:
      let months = (b.cadence == .yearly ? 12 : 1) * b.every * n
      let index = base.year * 12 + (base.month - 1) + months
      let year = index >= 0 ? index / 12 : (index - 11) / 12
      let ym = YearMonth(year, index - year * 12 + 1)
      return LocalDate(ym.year, ym.month, min(b.usualDay, ym.days))
    }
  }

  static func nearest(_ b: Bill, to date: LocalDate) -> LocalDate {
    var n = 0
    if date >= b.nextDue {
      while n < 2000, shift(b, from: b.nextDue, by: n + 1) <= date { n += 1 }
    } else {
      while n > -2000, shift(b, from: b.nextDue, by: n) > date { n -= 1 }
    }
    let d = shift(b, from: b.nextDue, by: n)
    let after = shift(b, from: b.nextDue, by: n + 1)
    return d.days(until: date) <= date.days(until: after) ? d : after
  }

  static func first(_ b: Bill, onOrAfter date: LocalDate) -> LocalDate {
    let d = nearest(b, to: date)
    return d >= date ? d : shift(b, from: d, by: 1)
  }

  static func start(_ b: Bill) -> LocalDate {
    ([b.trackingSince, b.payments.map(\.due).min(), b.history.min()].compactMap { $0 } + [b.nextDue]).min() ?? b.nextDue
  }

  static func index(_ s: LedgerState, _ id: BillID, expense: Bool = true) throws(ActionError) -> Int {
    guard let i = s.bills.firstIndex(where: { $0.id == id }), s.bills[i].state != .dismissed else { throw .notFound }
    if expense, s.bills[i].isIncome { throw .invalidBill }
    return i
  }

  static func link(_ s: inout LedgerState, _ i: Int, _ ids: [TxnID]) throws(ActionError) {
    guard !ids.isEmpty, Set(ids).count == ids.count else { throw .invalidBill }
    let b = s.bills[i]
    var dues = Set<LocalDate>()
    var planned: [(TxnID, LocalDate, Money, LocalDate)] = []
    for id in ids {
      guard let t = s.txn(id) else { throw .notFound }
      if t.archived || t.isTransfer || t.isHeldCopy || t.isRefund { throw .invalidBill }
      if t.direction != (b.isIncome ? .in : .out) { throw .invalidBill }
      if let other = t.billID, other != b.id { throw .invalidBill }
      let due = nearest(b, to: t.postedAt.date)
      if let end = b.endedOn, due > end { throw .invalidBill }
      if !dues.insert(due).inserted { throw .invalidBill }
      if b.payments.contains(where: { $0.due == due && $0.link == .linked && $0.txnID != id }) { throw .invalidBill }
      planned.append((id, due, t.amount, t.postedAt.date))
    }
    for (id, due, amount, day) in planned {
      if let k = s.txns.firstIndex(where: { $0.id == id }) { s.txns[k].billID = b.id }
      s.bills[i].payments.removeAll { $0.due == due || $0.txnID == id }
      s.bills[i].payments.append(BillPayment(due: due, txnID: id, amount: amount, link: .linked))
      if !s.bills[i].history.contains(day) { s.bills[i].history.append(day) }
      if due >= s.bills[i].nextDue { s.bills[i].nextDue = shift(s.bills[i], from: due, by: 1) }
    }
    s.bills[i].payments.sort { $0.due > $1.due }
    s.bills[i].history.sort(by: >)
  }

  static func end(_ b: inout Bill, lastPayment: LocalDate) throws(ActionError) {
    guard b.state == .tracked || b.state == .paused else { throw .invalidBill }
    guard lastPayment >= start(b) else { throw .invalidBill }
    b.state = .ended
    b.endedOn = lastPayment
    b.pausedSince = nil
    b.pausedUntil = nil
    if let from = b.nextAmountFrom, from > lastPayment {
      b.nextAmount = nil
      b.nextAmountFrom = nil
    }
  }

  static func apply(_ edit: LedgerEdit, _ s: inout LedgerState, today: LocalDate) throws(ActionError) -> String? {
    func categoryName(_ id: CategoryID) -> String { s.category(id)?.name ?? "Uncategorized" }
    switch edit {
    case .trackCandidate(let id):
      guard let c = s.billCandidates.first(where: { $0.id == id }) else { throw .notFound }
      s.billCandidates.removeAll { $0.id == id }
      let cadence: BillCadence = c.everyDays <= 10 ? .weekly : c.everyDays >= 300 ? .yearly : .monthly
      var b = Bill(
        id: id, name: c.name, kind: categoryName(c.categoryID), categoryID: c.categoryID, amount: c.amount,
        usualDay: c.last.day, nextDue: c.last, source: .detected, cadence: cadence,
        every: cadence == .weekly ? max(1, c.everyDays / 7) : 1, trackingSince: today)
      b.nextDue = shift(b, from: c.last, by: 1)
      s.bills.removeAll { $0.id == id }
      s.bills.append(b)
      return "Tracking \(c.name)"
    case .dismissCandidate(let id):
      guard s.billCandidates.contains(where: { $0.id == id }) else { throw .notFound }
      s.billCandidates.removeAll { $0.id == id }
      return "Dismissed"
    case .stopTrackingBill(let id):
      let i = try index(s, id)
      try end(&s.bills[i], lastPayment: today)
      return "Stopped tracking \(s.bills[i].name)"
    case .addBill(let d):
      if let refusal = d.refusal { throw refusal }
      guard s.category(d.categoryID) != nil else { throw .notFound }
      if let a = d.accountID, !s.accounts.contains(where: { $0.id == a }) { throw .notFound }
      let name = d.trimmedName
      s.bills.append(
        Bill(
          id: "pending-bill-\(UUID().uuidString.lowercased())", name: name, kind: categoryName(d.categoryID),
          categoryID: d.categoryID, amount: d.amount, approximate: d.approximate, usualDay: d.firstDue.day,
          nextDue: d.firstDue, accountID: d.accountID, source: .manual, cadence: d.cadence, every: d.every,
          trackingSince: max(d.firstDue, today), keys: BillEdits.keys(name: name, given: d.keys)))
      let i = s.bills.count - 1
      if !d.linkTxns.isEmpty { try link(&s, i, d.linkTxns) }
      let first = min(d.firstDue, s.bills[i].payments.map(\.due).min() ?? d.firstDue)
      s.bills[i].trackingSince = max(first, today)
      return "Added \(name)"
    case .editBillAmount(let id, let amount, let approximate, let from):
      let i = try index(s, id)
      let b = s.bills[i]
      guard amount.minor > 0, amount.minor <= ManualEntryDraft.maxMinor, amount.currency == b.amount.currency else {
        throw .invalidAmount
      }
      guard nearest(b, to: from) == from, from >= start(b) else { throw .invalidBill }
      if let end = b.endedOn, from > end { throw .invalidBill }
      if from <= b.nextDue {
        s.bills[i].amount = amount
        s.bills[i].approximate = approximate
        s.bills[i].nextAmount = nil
        s.bills[i].nextAmountFrom = nil
        s.bills[i].priceChangeFrom = nil
        s.bills[i].notices.removeAll { if case .priceChange = $0.kind { true } else { false } }
      } else {
        s.bills[i].nextAmount = amount
        s.bills[i].nextAmountFrom = from
      }
      return "\(b.name) amount changed"
    case .pauseBill(let id, let until):
      let i = try index(s, id)
      guard s.bills[i].state == .tracked else { throw .invalidBill }
      if let until, until <= today { throw .invalidBill }
      s.bills[i].state = .paused
      s.bills[i].pausedSince = today
      s.bills[i].pausedUntil = until
      return "Paused \(s.bills[i].name)"
    case .resumeBill(let id):
      let i = try index(s, id)
      guard s.bills[i].state == .paused else { throw .invalidBill }
      s.bills[i].state = .tracked
      s.bills[i].pausedSince = nil
      s.bills[i].pausedUntil = nil
      s.bills[i].nextDue = first(s.bills[i], onOrAfter: today)
      return "Resumed \(s.bills[i].name)"
    case .endBill(let id, let lastPayment):
      let i = try index(s, id)
      try end(&s.bills[i], lastPayment: lastPayment)
      return "Ended \(s.bills[i].name)"
    case .reactivateBill(let id):
      let i = try index(s, id)
      guard s.bills[i].state == .ended else { throw .invalidBill }
      s.bills[i].state = .tracked
      s.bills[i].endedOn = nil
      s.bills[i].notices.removeAll { if case .chargedAfterEnd = $0.kind { true } else { false } }
      s.bills[i].nextDue = first(s.bills[i], onOrAfter: today)
      return "Tracking \(s.bills[i].name) again"
    case .deleteBill(let id):
      let i = try index(s, id)
      s.bills[i].state = .dismissed
      return s.bills[i].source == .manual ? "Deleted \(s.bills[i].name)" : "\(s.bills[i].name) is not a bill"
    case .linkBillPayments(let id, let txns):
      let i = try index(s, id, expense: false)
      try link(&s, i, txns)
      return txns.count == 1 ? "Linked 1 payment" : "Linked \(txns.count) payments"
    case .reapplyBill(let id):
      let i = try index(s, id, expense: false)
      guard s.bills[i].notices.contains(where: { if case .changedOnTwoDevices = $0.kind { true } else { false } }) else {
        throw .notFound
      }
      s.bills[i].notices.removeAll { if case .changedOnTwoDevices = $0.kind { true } else { false } }
      return "Re-applied your change"
    case .dismissBillNotice(let id, let noticeID):
      guard let i = s.bills.firstIndex(where: { $0.id == id }), s.bills[i].notices.contains(where: { $0.id == noticeID })
      else { throw .notFound }
      s.bills[i].notices.removeAll { $0.id == noticeID }
      return nil
    case .editIncome(let id, let amount, let payday, let active):
      guard let i = s.bills.firstIndex(where: { $0.id == id && $0.isIncome }) else { throw .notFound }
      guard amount.minor > 0, amount.minor <= ManualEntryDraft.maxMinor else { throw .invalidAmount }
      guard (1...31).contains(payday) else { throw .invalidBill }
      let old = s.bills[i]
      s.bills[i].amount = amount
      s.bills[i].usualDay = payday
      s.bills[i].state = active ? .tracked : .ended
      s.bills[i].endedOn = active ? nil : today
      let ym = today.yearMonth
      let thisMonth = LocalDate(ym.year, ym.month, min(payday, ym.days))
      let next = ym.next
      s.bills[i].nextDue = thisMonth >= today ? thisMonth : LocalDate(next.year, next.month, min(payday, next.days))
      let removed = old.state == .tracked ? old.amount.minor : 0
      s.plan.income = .aed(max(0, s.plan.income.minor - removed + (active ? amount.minor : 0)))
      s.plan.payday = payday
      for m in s.plan.incomeByMonth.keys where m >= ym { s.plan.incomeByMonth[m] = nil }
      return "Income updated"
    default:
      throw .notFound
    }
  }
}
