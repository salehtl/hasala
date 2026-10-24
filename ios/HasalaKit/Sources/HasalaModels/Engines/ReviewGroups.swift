public struct FiledCount: Sendable, Hashable, Identifiable {
  public var category: CategoryOption
  public var count: Int

  public init(category: CategoryOption, count: Int) {
    self.category = category
    self.count = count
  }

  public var id: CategoryID { category.id }
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
    GroupIndex(s, only: ref).filedAs(ref, s)
  }

  public static func repeatsMonthly(_ ref: MerchantGroupRef, _ s: LedgerState) -> Bool {
    GroupIndex(s, only: ref).repeatsMonthly(ref)
  }

  public static func fillLastPicks(_ s: inout LedgerState, sortOrder: [TxnID: Int] = [:]) {
    let index = GroupIndex(s, picking: true, sortOrder: sortOrder)
    for i in s.txns.indices {
      let t = s.txns[i]
      let pick = t.inReview ? t.groupRef.flatMap(index.lastPick) : nil
      if t.lastPick != pick { s.txns[i].lastPick = pick }
    }
  }

  public static func payments(_ n: Int) -> String { "\(n) payment\(n == 1 ? "" : "s")" }

  public static func reachTitle(count: Int, merchant: String, category: String, all: Bool = true) -> String {
    if count == 1 { return "\(category) for 1 \(merchant) payment" }
    return "\(category) for \(all ? "all " : "")\(count) \(merchant) payments"
  }
}

extension Txn {
  public var countsAsPick: Bool { categorySource == .user && !needsReview && categoryID != nil && splits.isEmpty }
}

struct GroupIndex {
  var filed: [MerchantGroupRef: [CategoryID: Int]] = [:]
  var keys: [MerchantGroupRef: Set<String>] = [:]
  var monthly: [Direction: Set<String>] = [:]
  var picks: [MerchantGroupRef: Txn] = [:]
  var sortOrder: [TxnID: Int] = [:]

  init(_ s: LedgerState, only: MerchantGroupRef? = nil, picking: Bool = false, sortOrder: [TxnID: Int] = [:]) {
    self.sortOrder = sortOrder
    for t in s.txns {
      guard let ref = t.groupRef, only == nil || only == ref else { continue }
      if let k = t.merchantKey { keys[ref, default: []].insert(k) }
      if picking, t.countsAsPick, picks[ref].map({ newer(t, than: $0) }) ?? true { picks[ref] = t }
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

  func newer(_ a: Txn, than b: Txn) -> Bool {
    let at = a.categorizedAt ?? a.postedAt, bt = b.categorizedAt ?? b.postedAt
    if at != bt { return at > bt }
    let ao = sortOrder[a.id] ?? -1, bo = sortOrder[b.id] ?? -1
    if ao != bo { return ao > bo }
    if a.postedAt != b.postedAt { return a.postedAt > b.postedAt }
    return a.id > b.id
  }

  func lastPick(_ ref: MerchantGroupRef) -> CategoryID? { picks[ref]?.categoryID }

  func repeatsMonthly(_ ref: MerchantGroupRef) -> Bool {
    guard let covered = monthly[ref.direction] else { return false }
    return covered.contains(ref.key) || !(keys[ref] ?? []).isDisjoint(with: covered)
  }
}
