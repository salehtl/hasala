// The FX snapshot rule (replay/fx.ts, ported; spec §3.7): a row freezes its home
// amount at its own position against the live rate head, a later `rate_set`
// backfills only rows still null, `rate_unset` thaws nothing, and the home
// currency carries the implicit identity 1.000000.
//
// `convert` is `(amount * rate + 500000) / 1000000` in `Int128` (half-up,
// operands positive). A result outside Int64 cannot be stored: the row stays
// null and pending, and the fold records `money_overflow` (03c §1.3).
import OrderedCollections

public enum FX {
  /// The home amount of `amountMinor` at `rateMicro`, or nil when it does not fit Int64.
  public static func convert(_ amountMinor: Int64, _ rateMicro: Int64) -> Int64? {
    guard amountMinor >= 0, rateMicro >= 0 else { return nil }
    let wide = Int128(amountMinor) * Int128(rateMicro) + 500_000
    return Int64(exactly: wide / 1_000_000)
  }
}

extension State {
  /// state.ts `markPending`: files a live, unfrozen, parsed row under its currency.
  mutating func markPending(_ t: Txn) {
    if t.unparsed || t.amountHomeMinor != nil { return }
    pendingByCurrency[t.currency, default: []].append(t.id)
  }

  /// state.ts `clearPending`. Empty buckets are deleted.
  mutating func clearPending(_ t: Txn) {
    guard var set = pendingByCurrency[t.currency] else { return }
    set.remove(t.id)
    pendingByCurrency[t.currency] = set.isEmpty ? nil : set
  }

  mutating func onHomeCurrencySet(_ ccy: String, seq: Int64) {
    homeCurrency = ccy
    rates[ccy] = .some(homeIdentityMicro)
    backfill(ccy, homeIdentityMicro, seq: seq)
  }

  mutating func onRateSet(_ ccy: String, _ micro: Int64, seq: Int64) {
    rates[ccy] = .some(micro)
    backfill(ccy, micro, seq: seq)
  }

  mutating func onRateUnset(_ ccy: String) {
    rates[ccy] = .some(nil)
  }

  /// fx.ts `freezeIfPossible`: freezes `txns[id]` against the head live now.
  mutating func freezeIfPossible(_ id: String, seq: Int64) {
    guard let t = txns[id] else { return }
    if case .some(.some(let rate)) = rates[t.currency] {
      if let home = FX.convert(t.amountMinor, rate) {
        txns[id]!.amountHomeMinor = home
        clearPending(txns[id]!)
        return
      }
      anomaly(seq, "money_overflow", "\(id): the home amount does not fit int64")
    }
    txns[id]!.amountHomeMinor = nil
    markPending(txns[id]!)
  }

  private mutating func backfill(_ ccy: String, _ micro: Int64, seq: Int64) {
    guard let waiting = pendingByCurrency[ccy] else { return }
    pendingByCurrency[ccy] = nil
    var still: OrderedSet<String> = []
    for id in waiting {
      guard let t = txns[id] else { continue }
      if let home = FX.convert(t.amountMinor, micro) {
        txns[id]!.amountHomeMinor = home
      } else {
        anomaly(seq, "money_overflow", "\(id): the home amount does not fit int64")
        still.append(id)
      }
    }
    if !still.isEmpty { pendingByCurrency[ccy] = still }
  }
}
