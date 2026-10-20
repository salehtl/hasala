import Foundation

public struct CurrencyRate: Sendable, Hashable, Codable, Identifiable {
  public var currency: String
  public var rateMicro: Int64?
  public var updatedAt: String?

  public var id: String { currency }

  public init(currency: String, rateMicro: Int64?, updatedAt: String? = nil) {
    self.currency = currency
    self.rateMicro = rateMicro
    self.updatedAt = updatedAt
  }
}

public enum ExchangeRates {
  public static let pegs: [String: Int64] = [
    "USD": 3_672_500,
    "SAR": 979_333,
    "QAR": 1_008_929,
    "OMR": 9_551_365,
    "BHD": 9_767_287,
  ]

  public static let maxRateMicro: Int64 = 1_000_000_000_000

  public static func convert(_ amountMinor: Int64, _ rateMicro: Int64) -> Int64? {
    guard amountMinor >= 0, rateMicro >= 0 else { return nil }
    let wide = Int128(amountMinor) * Int128(rateMicro) + 500_000
    return Int64(exactly: wide / 1_000_000)
  }

  public static func isCurrencyCode(_ code: String) -> Bool {
    code.utf8.count == 3 && code.utf8.allSatisfy { $0 >= 0x41 && $0 <= 0x5A }
  }

  public static func isSettable(_ currency: String, _ rateMicro: Int64?) -> Bool {
    guard isCurrencyCode(currency), currency != Money.home else { return false }
    guard let rateMicro else { return true }
    return rateMicro > 0 && rateMicro <= maxRateMicro
  }

  public static func normalizedCode(_ typed: String) -> String {
    typed.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
  }

  public static func parse(_ typed: String) -> Int64? {
    let text = typed.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
    let parts = text.split(separator: ".", omittingEmptySubsequences: false)
    guard (1...2).contains(parts.count) else { return nil }
    let whole = parts[0], fraction = parts.count == 2 ? parts[1] : ""
    guard !(whole.isEmpty && fraction.isEmpty), whole.count <= 7, fraction.count <= 6,
      whole.allSatisfy(\.isASCII), whole.allSatisfy(\.isNumber),
      fraction.allSatisfy(\.isASCII), fraction.allSatisfy(\.isNumber)
    else { return nil }
    let w = Int64(whole.isEmpty ? "0" : String(whole)) ?? 0
    let f = Int64(fraction.padding(toLength: 6, withPad: "0", startingAt: 0)) ?? 0
    let micro = w * 1_000_000 + f
    guard micro > 0, micro <= maxRateMicro else { return nil }
    return micro
  }

  public static func format(_ micro: Int64) -> String {
    let whole = micro / 1_000_000
    var fraction = String(micro % 1_000_000)
    fraction = String(repeating: "0", count: 6 - fraction.count) + fraction
    while fraction.count > 2, fraction.hasSuffix("0") { fraction.removeLast() }
    return "\(whole).\(fraction)"
  }

  public struct Row: Sendable, Hashable, Identifiable {
    public var currency: String
    public var rateMicro: Int64?
    public var peg: Int64?
    public var notCounted: Int

    public var id: String { currency }
    public var isPeg: Bool { rateMicro != nil && rateMicro == peg }
  }

  public struct Page: Sendable, Hashable {
    public var rates: [Row]
    public var missing: [Row]
  }

  public static func page(_ s: LedgerState) -> Page {
    var counts: [String: Int] = [:]
    for t in s.txns where !t.archived && t.homeMinor == nil && t.amount.currency != Money.home {
      counts[t.amount.currency, default: 0] += 1
    }
    var rates: [Row] = []
    var missing: [Row] = []
    var seen = Set<String>()
    for r in s.rates where r.currency != Money.home {
      seen.insert(r.currency)
      let row = Row(currency: r.currency, rateMicro: r.rateMicro, peg: pegs[r.currency], notCounted: counts[r.currency] ?? 0)
      if r.rateMicro == nil { missing.append(row) } else { rates.append(row) }
    }
    for (ccy, n) in counts where !seen.contains(ccy) {
      seen.insert(ccy)
      missing.append(Row(currency: ccy, rateMicro: nil, peg: pegs[ccy], notCounted: n))
    }
    let amounts = s.accounts.map(\.balance) + s.bills.filter { $0.state == .tracked }.map(\.amount)
    for m in amounts where m.currency != Money.home && !m.isZero && !seen.contains(m.currency) {
      seen.insert(m.currency)
      missing.append(Row(currency: m.currency, rateMicro: nil, peg: pegs[m.currency], notCounted: 0))
    }
    rates.sort { $0.currency < $1.currency }
    missing.sort { ($0.notCounted, $1.currency) > ($1.notCounted, $0.currency) }
    return Page(rates: rates, missing: missing)
  }
}

public extension LedgerState {
  mutating func setRate(_ currency: String, micro: Int64) {
    if let i = rates.firstIndex(where: { $0.currency == currency }) {
      rates[i].rateMicro = micro
    } else {
      rates.append(CurrencyRate(currency: currency, rateMicro: micro))
    }
    for i in txns.indices where txns[i].amount.currency == currency && txns[i].homeMinor == nil {
      guard let home = ExchangeRates.convert(txns[i].amount.minor, micro) else { continue }
      txns[i].homeMinor = home
      txns[i].homeSource = .rate
      txns[i].homeRateMicro = micro
      for k in txns[i].splits.indices where txns[i].splits[k].homeMinor == nil {
        txns[i].splits[k].homeMinor = ExchangeRates.convert(txns[i].splits[k].amount.minor, micro)
      }
    }
  }

  mutating func unsetRate(_ currency: String) {
    if let i = rates.firstIndex(where: { $0.currency == currency }) {
      rates[i].rateMicro = nil
    } else {
      rates.append(CurrencyRate(currency: currency, rateMicro: nil))
    }
  }
}
