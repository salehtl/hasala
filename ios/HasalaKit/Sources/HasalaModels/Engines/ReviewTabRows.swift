public struct ReviewTabRow: Sendable, Hashable, Identifiable {
  public enum Tone: Sendable, Hashable { case suggestion, decide, reason }

  public var id: String
  public var item: String
  public var identifier: String
  public var monogram: String
  public var title: String
  public var subtitle: String
  public var tone: Tone
  public var amount: MoneyPhrase
  public var isIncome: Bool
  public var detail: String
  public var spokenAmount: MoneyPhrase
  public var spokenDetail: String
  public var reason: TxnReviewReason? = nil

  public func spoken(hidden: Bool) -> String {
    [title, spokenDetail, spokenAmount.spoken(hidden: hidden), subtitle.prefix(1).lowercased() + subtitle.dropFirst()]
      .filter { !$0.isEmpty }.joined(separator: ", ")
  }
}

extension ReviewGroupCardModel {
  public var useAllLabel: String { total == 1 ? "Use" : "Use for all \(total)" }

  public func useAllSpoken(_ category: String) -> String { total == 1 ? "Use \(category)" : "Use \(category) for all \(total)" }

  public func sortAllLabel(_ category: String) -> String { ReviewEngine.sortAllLabel(total, as: category) }

  public func sortAllSpoken(_ category: String) -> String {
    total == 1 ? "Sort the \(merchant) payment as \(category)" : "Sort all \(total) \(merchant) payments as \(category)"
  }

  public var fullMetaLine: String {
    guard otherMonths > 0 else { return metaLine }
    return "\(verb) · \(countLine) · \(dateRange)"
  }

  public var spellingChip: String? {
    guard let first = spellings.first else { return nil }
    let more = spellings.count - 1
    guard more > 0 else { return first }
    return "\(first) · +\(more) spelling\(more == 1 ? "" : "s")"
  }

  public var canAlwaysUse: Bool { spellings.contains { GroupRule.pattern($0) != nil } }

  public var shownAmount: MoneyPhrase {
    guard totals.count >= 2, let estimate else { return amount }
    return MoneyPhrase([.text("≈ "), .amount(estimate.money)])
  }

  public var estimateBreakdown: MoneyPhrase? {
    guard totals.count >= 2 else { return nil }
    var parts: [MoneyPhrase.Part] = [.text("Estimate · ")]
    for (i, m) in totals.enumerated() {
      if i > 0 { parts.append(.text(" + ")) }
      parts.append(.text("\(m.currency) "))
      parts.append(.amount(m))
    }
    return MoneyPhrase(parts)
  }
}

extension ReviewCardModel {
  public var canAlwaysUse: Bool { GroupRule.pattern(rawMerchant ?? merchant) != nil }
}

extension ReviewEngine {
  public static func tabRow(_ item: ReviewItem, _ s: LedgerState) -> ReviewTabRow {
    switch item {
    case .single(let c):
      let tone: ReviewTabRow.Tone = c.reviewReason != nil ? .reason : c.suggestion == nil ? .decide : .suggestion
      let date = s.txn(c.id)?.postedAt.date
      let amount = MoneyPhrase([.amount(c.amount)])
      return ReviewTabRow(
        id: item.id, item: c.id, identifier: "review.tab.row.\(c.id)", monogram: c.monogram, title: c.merchant,
        subtitle: rowSupporting(c), tone: tone, amount: amount, isIncome: c.isIncome, detail: date?.short ?? "",
        spokenAmount: MoneyPhrase([.text("\(c.amount.currency) "), .amount(c.amount)]),
        spokenDetail: c.spokenWhen, reason: c.reviewReason)
    case .group(let g):
      let tone: ReviewTabRow.Tone = g.suggestion == nil ? .decide : .suggestion
      let amount: MoneyPhrase
      if g.totals.count >= 2, let estimate = g.estimate {
        amount = MoneyPhrase([.text("≈ "), .amount(estimate.money)])
      } else if let m = g.totals.first, m.currency != Money.home {
        amount = MoneyPhrase([.text("\(m.currency) "), .amount(m)])
      } else {
        amount = MoneyPhrase(g.totals.map { .amount($0) })
      }
      let subtitle = g.suggestion.map { "Looks like \($0.name)" } ?? (g.isIncome ? "Income or a transfer?" : "You decide")
      return ReviewTabRow(
        id: item.id, item: item.id, identifier: "review.tab.group.\(g.id)", monogram: g.monogram, title: g.merchant,
        subtitle: subtitle, tone: tone, amount: amount, isIncome: g.isIncome, detail: payments(g.count),
        spokenAmount: g.totals.count >= 2 ? (g.estimateLine ?? g.amount) : g.amount, spokenDetail: payments(g.count))
    }
  }

  public static func rowSupporting(_ c: ReviewCardModel) -> String {
    if let reason = c.reviewReason { return "\(reason.label) · you decide" }
    if let s = c.suggestion { return "Looks like \(s.name)" }
    if c.isIncome { return "Income or a transfer?" }
    return c.isNewMerchant ? "New merchant · you decide" : "You decide"
  }

  public static func toSortSpoken(_ items: [ReviewItem]) -> String? {
    guard let first = items.first else { return nil }
    let n = payments(items)
    let lead = "\(n) payment\(n == 1 ? "" : "s") to sort"
    if items.count == 1 { return "\(lead), from \(first.merchant)" }
    return "\(lead), from \(first.merchant) and \(items.count - 1) more merchant\(items.count == 2 ? "" : "s")"
  }

  public static func item(_ id: String, in items: [ReviewItem]) -> ReviewItem? {
    items.first { $0.id == id || $0.txnIDs.contains(id) }
  }

  public static func itemOrder(_ ids: [String], startingAt start: String?, in items: [ReviewItem]) -> [String] {
    guard let start, let hit = item(start, in: items), let i = ids.firstIndex(of: hit.id) else { return ids }
    return Array(ids[i...]) + Array(ids[..<i])
  }

  public static func groupRows(_ ref: MerchantGroupRef, _ s: LedgerState) -> [ReviewCardModel] {
    queue(s).filter { $0.reachable && $0.groupRef == ref }
      .sorted { $0.postedAt == $1.postedAt ? $0.id < $1.id : $0.postedAt > $1.postedAt }
      .map { card($0, s) }
  }
}
