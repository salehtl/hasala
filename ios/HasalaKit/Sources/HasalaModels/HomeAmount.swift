public struct HomeAmount: Sendable, Hashable, Codable {
  public var shown: Money
  public var estimate: Bool
  public var notCounted: Bool
  public var original: Money?
  public var rateMicro: Int64?

  public init(shown: Money, estimate: Bool = false, notCounted: Bool = false, original: Money? = nil, rateMicro: Int64? = nil) {
    self.shown = shown
    self.estimate = estimate
    self.notCounted = notCounted
    self.original = original
    self.rateMicro = rateMicro
  }

  public var estimateLine: String? {
    guard estimate, let rateMicro, let original else { return nil }
    return "Estimate at \(RateFormat.string(rateMicro)) \(Money.home) per \(original.currency). Your bank's charge can be a little higher."
  }
}

public enum RateFormat {
  public static func string(_ micro: Int64) -> String {
    let whole = micro / 1_000_000
    var fraction = String(micro % 1_000_000)
    fraction = String(repeating: "0", count: 6 - fraction.count) + fraction
    while fraction.count > 2, fraction.hasSuffix("0") { fraction.removeLast() }
    return "\(whole).\(fraction)"
  }
}

extension Txn {
  public var homeAmount: HomeAmount {
    let foreign = amount.currency != Money.home
    guard let home = homeMinor else {
      return HomeAmount(shown: amount, notCounted: true, original: foreign ? amount : nil)
    }
    return HomeAmount(
      shown: foreign ? .aed(home) : amount, estimate: isEstimate, original: foreign ? amount : nil,
      rateMicro: isEstimate ? homeRateMicro : nil)
  }
}

extension MiniTxnRow {
  public mutating func showHome(_ t: Txn, amount useHome: Bool = true) {
    let h = t.homeAmount
    if useHome { amount = h.shown }
    estimate = h.estimate
    notCounted = h.notCounted
  }
}

public struct TotalMark: Sendable, Hashable, Codable {
  public var estimate: Bool
  public var leftOut: [String: Int]

  public init(estimate: Bool = false, leftOut: [String: Int] = [:]) {
    self.estimate = estimate
    self.leftOut = leftOut
  }

  public var leftOutCount: Int { leftOut.values.reduce(0, +) }

  public var currency: String? { leftOut.count == 1 ? leftOut.keys.first : nil }

  public var line: String? {
    let n = leftOutCount
    guard n > 0 else { return nil }
    return currency.map { "Not counted: \(n) in \($0)" } ?? "Not counted: \(n) with no rate"
  }

  public var caption: String? {
    let n = leftOutCount
    return n > 0 ? "\(n) not counted" : nil
  }
}

public struct HomeTotal: Sendable, Hashable {
  public var minor: Int64
  public var mark: TotalMark?

  public init(minor: Int64, mark: TotalMark? = nil) {
    self.minor = minor
    self.mark = mark
  }

  public var money: Money { .aed(minor) }
  public var estimate: Bool { mark?.estimate ?? false }
  public var leftOutCount: Int { mark?.leftOutCount ?? 0 }
}

extension Money {
  public static func homeTotal(_ ms: some Sequence<Money>, rates: [CurrencyRate]) -> HomeTotal {
    var minor: Int64 = 0
    var estimate = false
    var leftOut: [String: Int] = [:]
    for m in ms {
      if let home = homeMinor(of: m) {
        minor += home
      } else if m.isZero {
        continue
      } else if let home = converted(m, rates: rates) {
        minor += home
        estimate = true
      } else {
        leftOut[m.currency, default: 0] += 1
      }
    }
    let mark = estimate || !leftOut.isEmpty ? TotalMark(estimate: estimate, leftOut: leftOut) : nil
    return HomeTotal(minor: minor, mark: mark)
  }

  static func converted(_ m: Money, rates: [CurrencyRate]) -> Int64? {
    guard let rate = rates.first(where: { $0.currency == m.currency })?.rateMicro,
      let magnitude = Int64(exactly: m.minor.magnitude),
      let home = ExchangeRates.convert(magnitude, rate)
    else { return nil }
    return m.isNegative ? -home : home
  }

  public static func apportion(home: Int64?, parts: [Int64]) -> [Int64]? {
    guard let home else { return nil }
    let n = parts.reduce(Int128(0)) { $0 + Int128($1) }
    guard n > 0 else { return nil }
    var cumulative: Int128 = 0
    var previous: Int128 = 0
    var out: [Int64] = []
    for p in parts {
      cumulative += Int128(p)
      let product = Int128(home) * cumulative
      let here = product >= 0 ? product / n : -((-product + n - 1) / n)
      guard let share = Int64(exactly: here - previous) else { return nil }
      out.append(share)
      previous = here
    }
    return out
  }
}

extension LedgerState {
  public func homeTotal(_ ms: some Sequence<Money>) -> HomeTotal {
    Money.homeTotal(ms, rates: rates)
  }
}
