// 03b §4.5 `accountOf(t)` and 03c §3.9.2 link resolution, the derived parts of
// a projected transaction row that read more than the row itself.
import CoreReplay
import HasalaText

public enum Attribution {
  public enum How: String, Sendable { case explicit, card, ambiguous, none }

  /// 03b §4.5: explicit account, else the card link for (bank, last4), else ("", last4),
  /// else, with no bank, the one account all `mine` cards with that last4 share.
  public static func accountOf(_ t: Txn, cards: some Sequence<CardLink>) -> (account: String?, how: How) {
    if let a = t.annotation("account_id") { return (a, .explicit) }
    guard Grammar.isLast4(t.last4) else { return (nil, .none) }
    let mine = cards.filter { $0.state == "mine" && utf8Equal($0.last4, t.last4) }
    if let bank = t.bank, let c = mine.first(where: { $0.bank == bank }) { return (c.account, .card) }
    if let c = mine.first(where: { $0.bank == nil }) { return (c.account, .card) }
    if t.bank == nil {
      var accounts: [String] = []
      for c in mine { if let a = c.account, !accounts.contains(a) { accounts.append(a) } }
      if accounts.count == 1 { return (accounts[0], .card) }
      if accounts.count > 1 { return (nil, .ambiguous) }
    }
    return (nil, .none)
  }

  /// Follows `successor_id` from `id` to the row now standing for it.
  public static func resolve(_ id: String, in txns: OrderedDictionaryView) -> String? {
    var cur = id
    var steps = 0
    while let t = txns.txn(cur), let next = t.successorID, steps <= txns.count {
      cur = next
      steps += 1
    }
    return txns.txn(cur) == nil ? nil : cur
  }

  /// 03c §3.9.2 `refund_state`: ok iff this row is a live parsed credit and the
  /// target is a live parsed debit other than this row.
  public static func refundState(_ t: Txn, target: Txn?) -> String {
    guard let target, t.isLive, !t.unparsed, t.direction == "credit", target.isLive, !target.unparsed,
      target.direction == "debit", !utf8Equal(target.id, t.id)
    else { return "broken" }
    return "ok"
  }

  /// 03c §3.9.2 `transfer_state`.
  public static func transferState(_ t: Txn, target: Txn?, targetPeer: String?) -> String {
    guard let target, t.isLive, !t.unparsed, target.isLive, !target.unparsed, !utf8Equal(target.id, t.id),
      t.direction != target.direction
    else { return "broken" }
    guard let back = targetPeer else { return "one_sided" }
    return utf8Equal(back, t.id) ? "ok" : "broken"
  }
}

/// A read view over the folded transactions (lets the resolver run over State or a projection).
public struct OrderedDictionaryView: Sendable {
  let lookup: @Sendable (String) -> Txn?
  public let count: Int
  public init(count: Int, lookup: @escaping @Sendable (String) -> Txn?) {
    self.count = count
    self.lookup = lookup
  }
  public init(_ state: State) {
    let txns = state.txns
    self.init(count: txns.count) { txns[$0] }
  }
  public func txn(_ id: String) -> Txn? { lookup(id) }
}
