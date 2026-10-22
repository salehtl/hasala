public enum BillDueDates {
  public static func shift(_ base: LocalDate, day: Int, cadence: BillCadence, every: Int, by n: Int) -> LocalDate {
    switch cadence {
    case .weekly:
      return base.adding(days: 7 * every * n)
    case .monthly, .yearly:
      let months = (cadence == .yearly ? 12 : 1) * every * n
      let index = base.year * 12 + (base.month - 1) + months
      let year = index >= 0 ? index / 12 : (index - 11) / 12
      let ym = YearMonth(year, index - year * 12 + 1)
      return LocalDate(ym.year, ym.month, min(max(1, day), ym.days))
    }
  }

  public static func shift(_ b: Bill, from base: LocalDate, by n: Int) -> LocalDate {
    shift(base, day: b.usualDay, cadence: b.cadence, every: max(1, b.every), by: n)
  }

  public static func nearest(_ b: Bill, to date: LocalDate) -> LocalDate {
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

  public static func first(_ b: Bill, onOrAfter date: LocalDate) -> LocalDate {
    let d = nearest(b, to: date)
    return d >= date ? d : shift(b, from: d, by: 1)
  }

  public static func start(_ b: Bill) -> LocalDate {
    ([b.trackingSince, b.payments.map(\.due).min(), b.history.min()].compactMap { $0 } + [b.nextDue]).min()
      ?? b.nextDue
  }

  public static func latestPaid(_ b: Bill) -> LocalDate? {
    if let due = b.payments.map(\.due).max() { return due }
    return b.history.max().map { nearest(b, to: $0) }
  }
}

public struct PastPayment: Sendable, Hashable, Identifiable {
  public var id: TxnID
  public var merchant: String
  public var date: LocalDate
  public var amount: Money
  public var due: LocalDate
  public var account: String?

  public init(id: TxnID, merchant: String, date: LocalDate, amount: Money, due: LocalDate, account: String?) {
    self.id = id
    self.merchant = merchant
    self.date = date
    self.amount = amount
    self.due = due
    self.account = account
  }
}

public struct RecentPayment: Sendable, Hashable, Identifiable {
  public var id: TxnID
  public var merchant: String
  public var date: LocalDate
  public var amount: Money
  public var glyph: Glyph
  public var hue: Hue

  public init(id: TxnID, merchant: String, date: LocalDate, amount: Money, glyph: Glyph, hue: Hue) {
    self.id = id
    self.merchant = merchant
    self.date = date
    self.amount = amount
    self.glyph = glyph
    self.hue = hue
  }
}

public struct SalaryTerms: Sendable, Hashable {
  public var id: BillID
  public var name: String
  public var amount: Money
  public var payday: Int
  public var active: Bool

  public init(id: BillID, name: String, amount: Money, payday: Int, active: Bool) {
    self.id = id
    self.name = name
    self.amount = amount
    self.payday = payday
    self.active = active
  }
}

extension BillsEngine {
  public static let pastPaymentLimit = 24
  public static let fixedToleranceBP: Int64 = 200
  public static let variableToleranceBP: Int64 = 5000

  public static func pastPayments(_ s: LedgerState, for b: Bill, limit: Int = pastPaymentLimit) -> [PastPayment] {
    let keys = Set(b.keys.map { $0.trimmedSpaces.lowercased() }.filter { !$0.isEmpty })
    guard !keys.isEmpty, limit > 0 else { return [] }
    let taken = Set(b.payments.compactMap(\.txnID))
    let linkedDues = Set(b.payments.filter { $0.link == .linked }.map(\.due))
    let bp = b.approximate ? variableToleranceBP : fixedToleranceBP
    var out: [PastPayment] = []
    for t in s.txns.sorted(by: { $0.postedAt > $1.postedAt }) {
      guard keys.contains(key(t)), eligible(t), t.billID == nil, !taken.contains(t.id) else { continue }
      let due = BillDueDates.nearest(b, to: t.postedAt.date)
      guard !linkedDues.contains(due) else { continue }
      let terms = amount(b, on: due)
      guard let minor = comparable(t, currency: terms.currency), within(minor, terms.minor, bp: bp) else { continue }
      out.append(PastPayment(id: t.id, merchant: t.merchant, date: t.postedAt.date, amount: t.amount, due: due,
                             account: s.account(t.accountID)?.shortName))
      if out.count == limit { break }
    }
    return out
  }

  public static func pastPayments(_ s: LedgerState, for d: BillDraft, limit: Int = pastPaymentLimit) -> [PastPayment] {
    pastPayments(s, for: bill(from: d), limit: limit)
  }

  public static func bill(from d: BillDraft) -> Bill {
    let name = d.trimmedName
    let keys = d.keys.map { $0.trimmedSpaces.lowercased() }.filter { !$0.isEmpty }
    return Bill(id: "draft", name: name, kind: "", categoryID: d.categoryID, amount: d.amount,
                approximate: d.approximate, usualDay: d.firstDue.day, nextDue: d.firstDue, accountID: d.accountID,
                source: .manual, cadence: d.cadence, every: max(1, d.every),
                keys: keys.isEmpty ? [name.lowercased()] : keys)
  }

  public static func recentPayments(_ s: LedgerState, now: LocalDateTime, days: Int = 120, limit: Int = 40)
    -> [RecentPayment]
  {
    let since = now.date.adding(days: -days)
    var seen = Set<String>()
    var out: [RecentPayment] = []
    for t in s.txns.sorted(by: { $0.postedAt > $1.postedAt }) {
      guard eligible(t), t.billID == nil, t.postedAt.date >= since, t.postedAt <= now,
            homeAmount(t) != nil, seen.insert(key(t)).inserted else { continue }
      let c = s.category(t.categoryID)
      out.append(RecentPayment(id: t.id, merchant: t.merchant, date: t.postedAt.date, amount: t.amount,
                               glyph: c?.glyph ?? .shopping, hue: c?.hue ?? .sand))
      if out.count == limit { break }
    }
    return out
  }

  public static func draft(from txn: TxnID, _ s: LedgerState, now: LocalDateTime) -> BillDraft? {
    guard let t = s.txn(txn), let minor = homeAmount(t) else { return nil }
    let paid = t.postedAt.date
    var first = BillDueDates.shift(paid, day: paid.day, cadence: .monthly, every: 1, by: 1)
    var steps = 1
    while first < now.date, steps < 600 {
      steps += 1
      first = BillDueDates.shift(paid, day: paid.day, cadence: .monthly, every: 1, by: steps)
    }
    let category = (t.categoryID ?? t.suggestion).flatMap { s.category($0) }.map(\.id) ?? defaultCategory(s)
    return BillDraft(name: t.merchant, keys: [key(t)], amount: .aed(minor), cadence: .monthly, every: 1,
                     firstDue: first, categoryID: category ?? "", accountID: t.accountID)
  }

  public static func defaultCategory(_ s: LedgerState) -> CategoryID? {
    billCategories(s).first?.id ?? s.categories.first { !$0.archived && $0.kind == .spending }?.id
  }

  public static func billCategories(_ s: LedgerState) -> [Category] {
    s.categories.filter { $0.role == .bill && !$0.archived }
  }

  public static func amountStarts(_ b: Bill, today: LocalDate) -> [LocalDate] {
    var dates: [LocalDate] = []
    let start = BillDueDates.start(b)
    if let paid = BillDueDates.latestPaid(b), paid >= start, paid < b.nextDue { dates.append(paid) }
    for n in 0..<6 { dates.append(BillDueDates.shift(b, from: b.nextDue, by: n)) }
    if let end = b.endedOn { dates = dates.filter { $0 <= end } }
    var seen = Set<LocalDate>()
    return dates.filter { seen.insert($0).inserted }.sorted()
  }

  public static func defaultAmountStart(_ b: Bill, today: LocalDate) -> LocalDate? {
    let choices = amountStarts(b, today: today)
    return choices.first { $0 == b.nextDue } ?? choices.last
  }

  public static func endChoices(_ b: Bill, today: LocalDate) -> [LocalDate] {
    let start = BillDueDates.start(b)
    var dates = b.payments.map(\.due).filter { $0 >= start && $0 <= today }
    if b.payments.isEmpty {
      dates = b.history.map { BillDueDates.nearest(b, to: $0) }.filter { $0 >= start && $0 <= today }
    }
    var seen = Set<LocalDate>()
    dates = dates.sorted(by: >).filter { seen.insert($0).inserted }
    dates = Array(dates.prefix(6))
    let fallback = max(today, start)
    if !dates.contains(fallback) { dates.append(fallback) }
    return dates.sorted(by: >)
  }

  public static func defaultEnd(_ b: Bill, today: LocalDate) -> LocalDate {
    let start = BillDueDates.start(b)
    if let paid = BillDueDates.latestPaid(b), paid >= start, paid <= today { return paid }
    return max(today, start)
  }

  public static func salary(_ s: LedgerState, bill id: BillID) -> SalaryTerms? {
    guard let b = s.bill(id), b.isIncome, b.state != .dismissed else { return nil }
    return SalaryTerms(id: b.id, name: b.name, amount: b.amount, payday: b.usualDay,
                       active: b.state == .tracked || b.state == .paused)
  }

  static func amount(_ b: Bill, on due: LocalDate) -> Money {
    if let next = b.nextAmount, let from = b.nextAmountFrom, due >= from { return next }
    return b.amount
  }

  static func key(_ t: Txn) -> String {
    (t.merchantKey ?? t.merchant).trimmedSpaces.lowercased()
  }

  static func eligible(_ t: Txn) -> Bool {
    t.direction == .out && !t.archived && !t.isTransfer && !t.isHeldCopy && !t.isRefund
  }

  static func homeAmount(_ t: Txn) -> Int64? {
    t.amount.currency == Money.home ? t.amount.minor : t.homeMinor
  }

  static func comparable(_ t: Txn, currency: String) -> Int64? {
    if t.amount.currency == currency { return t.amount.minor }
    return currency == Money.home ? t.homeMinor : nil
  }

  static func within(_ minor: Int64, _ expected: Int64, bp: Int64) -> Bool {
    guard expected > 0, minor > 0 else { return false }
    let gap = Int128(minor) - Int128(expected)
    return gap.magnitude * 10_000 <= UInt128(expected) * UInt128(bp)
  }
}
