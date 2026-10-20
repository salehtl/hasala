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

extension Spending {
  public static func hasEstimate(_ s: LedgerState, in period: Period) -> Bool {
    s.txns.contains { t in
      t.isEstimate && period.contains(t.postedAt.date) && carvedOut(t, in: s) == nil && !measured(t, in: s).isEmpty
    }
  }
}

extension Money {
  public static func homeTotal(_ ms: some Sequence<Money>) -> Int64 {
    ms.reduce(Int64(0)) { $0 + (homeMinor(of: $1) ?? 0) }
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
