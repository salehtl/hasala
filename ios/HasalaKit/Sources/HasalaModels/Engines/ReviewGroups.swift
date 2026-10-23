public struct FiledCount: Sendable, Hashable, Identifiable {
  public var category: CategoryOption
  public var count: Int

  public init(category: CategoryOption, count: Int) {
    self.category = category
    self.count = count
  }

  public var id: CategoryID { category.id }
}

public struct ReviewLeftOut: Sendable, Hashable, Identifiable {
  public var txnID: TxnID
  public var reason: TxnReviewReason?

  public init(txnID: TxnID, reason: TxnReviewReason?) {
    self.txnID = txnID
    self.reason = reason
  }

  public var id: TxnID { txnID }
}

extension ReviewEngine {
  public static func displayName(_ rows: [Txn]) -> String {
    var counts: [String: Int] = [:]
    for t in rows { counts[t.merchant, default: 0] += 1 }
    let newest = rows.max { $0.postedAt < $1.postedAt }?.merchant ?? ""
    let ranked = counts.sorted { a, b in
      if a.value != b.value { return a.value > b.value }
      if (a.key == newest) != (b.key == newest) { return a.key == newest }
      return a.key < b.key
    }
    return ranked.first?.key ?? newest
  }

  public static func filedAs(_ ref: MerchantGroupRef, _ s: LedgerState) -> [FiledCount] {
    GroupIndex(s, windowQueue: [], only: ref).filedAs(ref, s)
  }

  public static func repeatsMonthly(_ ref: MerchantGroupRef, _ s: LedgerState) -> Bool {
    GroupIndex(s, windowQueue: [], only: ref).repeatsMonthly(ref)
  }

  public static func payments(_ n: Int) -> String { "\(n) payment\(n == 1 ? "" : "s")" }

  public static func reachTitle(count: Int, merchant: String, category: String, all: Bool = true) -> String {
    if count == 1 { return "\(category) for 1 \(merchant) payment" }
    return "\(category) for \(all ? "all " : "")\(count) \(merchant) payments"
  }
}

struct GroupIndex {
  var leftOut: [MerchantGroupRef: [ReviewLeftOut]] = [:]
  var filed: [MerchantGroupRef: [CategoryID: Int]] = [:]
  var keys: [MerchantGroupRef: Set<String>] = [:]
  var monthly: [Direction: Set<String>] = [:]

  init(_ s: LedgerState, windowQueue: [Txn], only: MerchantGroupRef? = nil) {
    let pairs = Set(s.txns.compactMap { $0.samePurchase?.of })
    for t in windowQueue where !t.reachable {
      guard let ref = t.groupRef, only == nil || only == ref else { continue }
      let reason = t.activeReviewReason ?? (pairs.contains(t.id) ? .samePurchase : nil)
      leftOut[ref, default: []].append(ReviewLeftOut(txnID: t.id, reason: reason))
    }
    for t in s.txns {
      guard let ref = t.groupRef, only == nil || only == ref else { continue }
      if let k = t.merchantKey { keys[ref, default: []].insert(k) }
      guard !t.archived, !t.inReview, t.splits.isEmpty, t.filedByPerson, let c = t.categoryID else { continue }
      filed[ref, default: [:]][c, default: 0] += 1
    }
    for b in s.bills where (b.state == .tracked || b.state == .paused) && b.cadence == .monthly && b.every == 1 {
      monthly[b.isIncome ? .in : .out, default: []].formUnion(b.keys)
    }
    for c in s.billCandidates where (26...35).contains(c.everyDays) {
      monthly[.out, default: []].insert(c.key ?? c.name.lowercased())
    }
  }

  func filedAs(_ ref: MerchantGroupRef, _ s: LedgerState) -> [FiledCount] {
    (filed[ref] ?? [:]).compactMap { id, n in s.category(id).map { FiledCount(category: CategoryOption($0), count: n) } }
      .sorted { $0.count == $1.count ? $0.category.name < $1.category.name : $0.count > $1.count }
  }

  func repeatsMonthly(_ ref: MerchantGroupRef) -> Bool {
    guard let covered = monthly[ref.direction] else { return false }
    return covered.contains(ref.key) || !(keys[ref] ?? []).isDisjoint(with: covered)
  }
}
