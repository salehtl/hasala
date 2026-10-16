// Accounts · Net worth: the accounts add up to net worth, split into everyday money (counts
// in the plan) and tracking (net worth only), with the last 12 months when the ledger has
// them.

/// One account row (page 16 §14): a bank plate, the name, the balance and when it was last
/// checked.
public struct AccountRowModel: Sendable, Hashable, Identifiable {
  /// What the 40 plate shows: a bank's initials ("ENBD", "DIB", "S"), or the cash glyph.
  public enum Plate: Sendable, Hashable {
    case initials(String)
    case cash
  }

  public var id: AccountID
  /// "Emirates NBD Current".
  public var name: String
  public var plate: Plate
  public var hue: Hue
  /// Positive for money held, negative for money owed (card debt shows "−").
  public var balance: Money
  /// "···4412 · checked in 3 days ago · 6 since", "Updated by you".
  public var detail: String
}

/// The Last 12 months line (page 16 §14 chart card).
public struct NetWorthChart: Sendable, Hashable {
  /// Net worth at the end of each month, oldest first, the last one this month, as permille
  /// of the drawn range (geometry only; never an amount).
  public var points: [Int]
  /// Twelve month initials ending with this month ("N", "D", … "O").
  public var months: [String]
}

public struct AccountsSnapshot: Sendable, Hashable {
  public var netWorth: Money
  /// The change since the start of this month; nil when the ledger has no history for it.
  public var monthChange: Money?
  /// Nil when the ledger has no history (live has none yet: check-ins only set balances).
  public var chart: NetWorthChart?
  /// Counts in your plan.
  public var everyday: [AccountRowModel]
  public var everydayTotal: Money
  /// Counts in net worth, not in your plan.
  public var tracking: [AccountRowModel]
  /// How many accounts there are.
  public var count: Int
  /// Some account has a balance. Balances come from check-ins; without one, every account
  /// reads 0.00 and the screen would say nothing true.
  public var hasBalances: Bool
}

public enum AccountsEngine {
  public static func snapshot(_ s: LedgerState, now: LocalDateTime) -> AccountsSnapshot {
    let rows = s.accounts.map(row)
    let everyday = zip(s.accounts, rows).filter { $0.0.inPlan }.map(\.1)
    let tracking = zip(s.accounts, rows).filter { !$0.0.inPlan }.map(\.1)
    let history = s.netWorth.spark.isEmpty ? nil : s.netWorth
    return AccountsSnapshot(
      netWorth: .aed(s.accounts.reduce(0) { $0 + $1.balance.minor }),
      monthChange: history?.monthChange,
      chart: history.map { NetWorthChart(points: Array($0.spark.suffix(12)), months: months(ending: now.date.yearMonth)) },
      everyday: everyday,
      everydayTotal: .aed(s.accounts.filter(\.inPlan).reduce(0) { $0 + $1.balance.minor }),
      tracking: tracking,
      count: s.accounts.count,
      hasBalances: s.accounts.contains { !$0.balance.isZero }
    )
  }

  static func row(_ a: Account) -> AccountRowModel {
    let plate: AccountRowModel.Plate = a.kind == .cash ? .cash : .initials(initials(a.shortName))
    let detail = [a.last4.map { "···\($0)" }, a.detail.isEmpty ? nil : a.detail].compactMap { $0 }
      .joined(separator: " · ")
    return AccountRowModel(id: a.id, name: a.name, plate: plate, hue: hue(a.kind), balance: a.balance, detail: detail)
  }

  /// A bank's initials from its short name, as the plates draw them: its capitals ("Emirates
  /// NBD" → "ENBD", "DIB card" → "DIB", "Sarwa" → "S"), at most four.
  static func initials(_ name: String) -> String {
    let capitals = name.filter(\.isUppercase)
    return String((capitals.isEmpty ? String(name.prefix(1)).uppercased() : capitals).prefix(4))
  }

  /// The plate's hue says what kind of account it is: a current account sky, a card sand,
  /// cash mint, an investment lilac.
  static func hue(_ kind: AccountKind) -> Hue {
    switch kind {
    case .current: .sky
    case .credit: .sand
    case .cash: .mint
    case .investment: .lilac
    }
  }

  /// Twelve month initials ending with `month`.
  static func months(ending month: YearMonth) -> [String] {
    var out: [String] = []
    var m = month
    for _ in 0..<12 {
      out.insert(String(m.shortName.prefix(1)), at: 0)
      m = m.previous
    }
    return out
  }
}
