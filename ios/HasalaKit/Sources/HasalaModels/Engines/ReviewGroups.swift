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

public struct ReviewGroupCardModel: Sendable, Hashable, Identifiable {
  public var group: MerchantGroupRef
  public var merchant: String
  public var monogram: String
  public var txnIDs: [TxnID]
  public var otherMonths: Int
  public var first: LocalDate
  public var last: LocalDate
  public var totals: [Money]
  public var estimate: HomeTotal?
  public var spellings: [String]
  public var repeatsMonthly: Bool
  public var suggestion: CategoryOption?
  public var suggestedBy: String?
  public var filedAs: [FiledCount]
  public var isMixed: Bool
  public var month: YearMonth
  public var leftOut: [ReviewLeftOut] = []
  public var isNewMerchant: Bool = false

  public var id: String { group.id }
  public var count: Int { txnIDs.count }
  public var total: Int { count + otherMonths }
  public var isIncome: Bool { group.direction == .in }
  public var verb: String { isIncome ? "Received" : "Spent" }
  public var metaLine: String { "\(verb) · \(ReviewEngine.payments(count)) · \(dateRange)" }

  public var leftOutLine: String? {
    guard let first = leftOut.first else { return nil }
    let n = leftOut.count
    let lead = n == 1 ? "1 more payment gets its own card." : "\(n) more payments get their own cards."
    guard Set(leftOut.map(\.reason)).count == 1, let reason = first.reason else { return lead }
    let why =
      switch reason {
      case .senderUnverified: n == 1 ? "Hasala couldn't verify its sender." : "Hasala couldn't verify their sender."
      case .probableCopy: n == 1 ? "It may be a copy." : "They may be copies."
      case .samePurchase: n == 1 ? "It may be the same purchase twice." : "Each may be the same purchase twice."
      }
    return "\(lead) \(why)"
  }

  public var countLine: String {
    let here = ReviewEngine.payments(count)
    guard otherMonths > 0 else { return here }
    return "\(here) · \(otherMonths) more in \(otherMonths == 1 ? "another month" : "other months")"
  }

  public var dateRange: String {
    if first == last { return first.dayMonth }
    if first.year == last.year { return "\(first.dayMonth) to \(last.dayMonth)" }
    return "\(first.dayMonth) \(first.year) to \(last.dayMonth) \(last.year)"
  }

  public var spokenDateRange: String {
    func say(_ d: LocalDate) -> String { "\(d.day) \(CivilCalendar.monthNames[d.month - 1])" }
    if first == last { return say(first) }
    if first.year == last.year { return "\(say(first)) to \(say(last))" }
    return "\(say(first)) \(first.year) to \(say(last)) \(last.year)"
  }

  public var amount: MoneyPhrase {
    var parts: [MoneyPhrase.Part] = []
    for (i, m) in totals.enumerated() {
      if i > 0 { parts.append(.text(" + ")) }
      parts.append(.text("\(m.currency) "))
      parts.append(.amount(m))
    }
    return MoneyPhrase(parts)
  }

  public var estimateLine: MoneyPhrase? {
    guard let estimate else { return nil }
    var parts: [MoneyPhrase.Part] = [.text("≈ \(Money.home) "), .amount(estimate.money), .text(" estimated")]
    if let left = estimate.mark?.line { parts.append(.text(" · \(left)")) }
    return MoneyPhrase(parts)
  }

  public var historyLine: String? {
    guard isMixed, !filedAs.isEmpty else { return nil }
    let names = filedAs.map { "\($0.category.name) (\($0.count))" }
    return "You sorted \(merchant) as " + ReviewEngine.list(names) + " before"
  }

  public func spoken(hidden: Bool) -> String {
    let payments = ReviewEngine.payments(count) + (isIncome ? " received" : "")
    let when = first == last ? "on \(spokenDateRange)" : "from \(spokenDateRange)"
    var line = "\(merchant), \(payments) \(when), \(isIncome ? "plus " : "")\(amount.spoken(hidden: hidden))"
    if let estimateLine { line += ", " + estimateLine.spoken(hidden: hidden) }
    if otherMonths > 0 { line += ", \(otherMonths) more in other months" }
    if repeatsMonthly { line += ", repeats monthly" }
    if isNewMerchant { line += ", new merchant" }
    line += "."
    if let leftOutLine { line += " " + leftOutLine }
    if let suggestion {
      let by = suggestedBy.map { ", " + $0.prefix(1).lowercased() + $0.dropFirst() } ?? ""
      line += " Looks like \(suggestion.name)\(by)."
    }
    return line
  }
}

public enum ReviewItem: Sendable, Hashable, Identifiable {
  case single(ReviewCardModel)
  case group(ReviewGroupCardModel)

  public var id: String {
    switch self {
    case .single(let c): c.id
    case .group(let g): "group." + g.id
    }
  }

  public var merchant: String {
    switch self {
    case .single(let c): c.merchant
    case .group(let g): g.merchant
    }
  }

  public var payments: Int {
    switch self {
    case .single: 1
    case .group(let g): g.count
    }
  }

  public var txnIDs: [TxnID] {
    switch self {
    case .single(let c): [c.id]
    case .group(let g): g.txnIDs
    }
  }

  public var month: YearMonth? {
    switch self {
    case .single(let c): c.month
    case .group(let g): g.month
    }
  }

  public var group: MerchantGroupRef? {
    switch self {
    case .single(let c): c.group
    case .group(let g): g.group
    }
  }
}

public struct ReviewItemMonth: Sendable, Hashable, Identifiable {
  public var month: YearMonth
  public var title: String
  public var items: [ReviewItem]
  public var id: YearMonth { month }
}

extension ReviewEngine {
  public static func items(_ s: LedgerState, in window: ReviewWindow = .all) -> [ReviewItem] {
    var reachable: [MerchantGroupRef: [Txn]] = [:]
    for t in queue(s) where t.reachable {
      guard let ref = t.groupRef else { continue }
      reachable[ref, default: []].append(t)
    }
    let inWindow = queue(s, in: window)
    let index = GroupIndex(s, windowQueue: inWindow)
    var out: [ReviewItem] = []
    var emitted: Set<MerchantGroupRef> = []
    for t in inWindow {
      if t.reachable, let ref = t.groupRef, let rows = reachable[ref], rows.count >= 2 {
        guard emitted.insert(ref).inserted else { continue }
        out.append(.group(groupCard(ref, rows: rows, s, in: window, index: index)))
      } else {
        out.append(.single(card(t, s)))
      }
    }
    return out.enumerated().sorted { a, b in
      let am = a.element.month, bm = b.element.month
      if am != bm, let am, let bm { return am > bm }
      if a.element.payments != b.element.payments { return a.element.payments > b.element.payments }
      return a.offset < b.offset
    }.map(\.element)
  }

  public static func groupCard(_ ref: MerchantGroupRef, _ s: LedgerState, in window: ReviewWindow = .all)
    -> ReviewGroupCardModel?
  {
    let rows = queue(s).filter { $0.reachable && $0.groupRef == ref }
    guard rows.contains(where: { window.contains($0.postedAt.date) }) else { return nil }
    let index = GroupIndex(s, windowQueue: queue(s, in: window), only: ref)
    return groupCard(ref, rows: rows, s, in: window, index: index)
  }

  static func groupCard(
    _ ref: MerchantGroupRef, rows: [Txn], _ s: LedgerState, in window: ReviewWindow, index: GroupIndex
  ) -> ReviewGroupCardModel {
    let inside = rows.filter { window.contains($0.postedAt.date) }
    let shown = inside.isEmpty ? rows : inside
    let dates = shown.map(\.postedAt.date)
    let merchant = displayName(shown)
    let totals = currencyTotals(shown)
    let estimate: HomeTotal? = totals.count >= 2 ? homeEstimate(shown) : nil
    let guesses = rows.map(\.reviewSuggestion)
    let suggestions = Set(guesses.compactMap { $0 })
    let common = guesses.first.flatMap { g in guesses.allSatisfy { $0 == g } ? g : nil }
    let suggested = common.flatMap { s.category($0) }
    let suggestedBy = suggested.flatMap { c in
      mostCommon(rows.filter { $0.reviewSuggestion == c.id }.compactMap { $0.categorySource?.suggestionLabel(needsReview: true) })
    }
    let history = index.filedAs(ref, s)
    let mixedIDs = Set(history.map(\.id)).union(suggestions)
    return ReviewGroupCardModel(
      group: ref, merchant: merchant, monogram: String(merchant.prefix(1)).uppercased(),
      txnIDs: inside.map(\.id), otherMonths: rows.count - inside.count,
      first: dates.min() ?? LocalDate(1970, 1, 1), last: dates.max() ?? LocalDate(1970, 1, 1),
      totals: totals, estimate: estimate, spellings: spellings(rows), repeatsMonthly: index.repeatsMonthly(ref),
      suggestion: suggested.map(CategoryOption.init), suggestedBy: suggestedBy, filedAs: history,
      isMixed: mixedIDs.count >= 2, month: shown.first?.postedAt.date.yearMonth ?? LocalDate(1970, 1, 1).yearMonth,
      leftOut: index.leftOut[ref] ?? [], isNewMerchant: rows.contains(where: \.isNewMerchant))
  }

  static func mostCommon(_ labels: [String]) -> String? {
    var counts: [String: Int] = [:]
    for l in labels { counts[l, default: 0] += 1 }
    return counts.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }?.key
  }

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

  static func currencyTotals(_ rows: [Txn]) -> [Money] {
    var byCurrency: [String: Int64] = [:]
    for t in rows { byCurrency[t.amount.currency, default: 0].add(t.amount.minor) }
    return byCurrency.map { Money(minor: $0.value, currency: $0.key) }.sorted {
      ($0.currency == Money.home ? 0 : 1, $0.currency) < ($1.currency == Money.home ? 0 : 1, $1.currency)
    }
  }

  static func homeEstimate(_ rows: [Txn]) -> HomeTotal {
    var minor: Int64 = 0
    var estimate = false
    var leftOut: [String: Int] = [:]
    for t in rows {
      guard let home = t.homeMinor else {
        leftOut[t.amount.currency, default: 0] += 1
        continue
      }
      minor.add(home)
      if t.amount.currency != Money.home { estimate = true }
    }
    let mark = estimate || !leftOut.isEmpty ? TotalMark(estimate: estimate, leftOut: leftOut) : nil
    return HomeTotal(minor: minor, mark: mark)
  }

  static func spellings(_ rows: [Txn]) -> [String] {
    var seen: Set<String> = []
    return rows.map(\.spelling).filter { seen.insert($0).inserted }.sorted()
  }

  public static func filedAs(_ ref: MerchantGroupRef, _ s: LedgerState) -> [FiledCount] {
    GroupIndex(s, windowQueue: [], only: ref).filedAs(ref, s)
  }

  public static func repeatsMonthly(_ ref: MerchantGroupRef, _ s: LedgerState) -> Bool {
    GroupIndex(s, windowQueue: [], only: ref).repeatsMonthly(ref)
  }

  public static func itemMonths(_ items: [ReviewItem], now: LocalDateTime) -> [ReviewItemMonth] {
    var out: [ReviewItemMonth] = []
    var index: [YearMonth: Int] = [:]
    for item in items {
      let m = item.month ?? now.date.yearMonth
      if let i = index[m] {
        out[i].items.append(item)
      } else {
        index[m] = out.count
        out.append(ReviewItemMonth(month: m, title: monthTitle(m, now: now), items: [item]))
      }
    }
    return out.sorted { $0.month > $1.month }
  }

  public static func payments(_ items: [ReviewItem]) -> Int { items.reduce(0) { $0 + $1.payments } }

  public static func payments(_ n: Int) -> String { "\(n) payment\(n == 1 ? "" : "s")" }

  public static func toSortLine(_ items: [ReviewItem]) -> String? {
    guard let first = items.first else { return nil }
    let lead = items.count == 1 ? first.merchant : "\(first.merchant) and \(items.count - 1) more"
    return "\(lead) · \(payments(payments(items)))"
  }

  public static func sortAllLabel(_ count: Int, as category: String) -> String {
    count == 1 ? "Sort as \(category)" : "Sort all \(count) as \(category)"
  }

  public static let sortEachLabel = "Sort each one"

  public static func groupFiledAnnouncement(count: Int, merchant: String, category: String, left: Int) -> String {
    let next = left == 0 ? "All caught up." : "\(left) left."
    return "Filed \(count) \(merchant) payment\(count == 1 ? "" : "s") as \(category). \(next)"
  }

  public static func notThisLine(merchant: String, category: String) -> String {
    "Hasala won't suggest \(category) for \(merchant) again."
  }

  static func list(_ names: [String]) -> String {
    switch names.count {
    case 0: ""
    case 1: names[0]
    case 2: "\(names[0]) and \(names[1])"
    default: names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
    }
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
