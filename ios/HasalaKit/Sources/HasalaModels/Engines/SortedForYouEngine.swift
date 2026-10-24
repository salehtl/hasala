public struct SortedForYouItem: Sendable, Hashable, Identifiable {
  public enum Source: Sendable, Hashable {
    case rule(RuleID?)
    case cloudflare
  }

  public var id: String
  public var merchant: String
  public var category: CategoryOption
  public var source: Source
  public var txnIDs: [TxnID]
  public var latest: LocalDateTime
  public var group: MerchantGroupRef?
  public var ruleID: RuleID?

  public var count: Int { txnIDs.count }
  public var canStopRule: Bool { ruleID != nil }

  public var sourceLine: String {
    switch source {
    case .rule: "Sorted by your rule"
    case .cloudflare: CategorySource.suggestionLabel(modelTag: CategorySource.cloudflareModelPrefix, needsReview: false)
    }
  }

  public var detail: String { "\(ReviewEngine.payments(count)) · \(category.name)" }

  public var undoAllLabel: String { count == 1 ? "Undo" : "Undo all \(count)" }

  public var undoAll: LedgerEdit { .returnToReview(txnIDs) }

  public static func undoneLine(count: Int, settled: Int) -> String {
    let payments = count == 1 ? "1 payment" : "\(count) payments"
    return settled == 0 ? "\(payments) back in Review" : "\(payments) put back as \(count == 1 ? "it was" : "they were")"
  }
}

public struct SortedForYouSnapshot: Sendable, Hashable {
  public var items: [SortedForYouItem]

  public init(items: [SortedForYouItem]) {
    self.items = items
  }

  public static let empty = SortedForYouSnapshot(items: [])

  public var payments: Int { items.reduce(0) { $0 + $1.count } }
  public var isEmpty: Bool { items.isEmpty }

  public var homeLine: String? {
    guard payments > 0 else { return nil }
    return "\(payments) sorted for you this week"
  }
}

extension Txn {
  public var sortedForYou: Bool { !archived && splits.isEmpty && (filedByRule || autoFiledByCloudflare) }

  public var autoSourceLabel: String? {
    guard !inReview, splits.isEmpty else { return nil }
    if filedByRule { return "Your rule" }
    if autoFiledByCloudflare { return "Cloudflare AI" }
    return nil
  }

  public var autoSourceSpoken: String? {
    guard let label = autoSourceLabel else { return nil }
    return "sorted by " + (label == "Your rule" ? "your rule" : label)
  }
}

extension SortedForYouItem {
  public var sourceName: String {
    switch source {
    case .rule: "Your rule"
    case .cloudflare: "Cloudflare AI"
    }
  }

  public var overline: String { "\(sourceName) · \(latest.date.short)".uppercased() }

  public var title: String { "\(merchant) → \(category.name)" }

  public var spokenHeader: String {
    "\(sourceName), \(ReviewEngine.spokenDay(latest.date)). \(merchant) to \(category.name), \(ReviewEngine.payments(count))."
  }
}

extension SortedForYouSnapshot {
  public static let footnote =
    "Payments Hasala's merchant list sorts are not listed here. You can still change any of them in Activity."
  public static let intro = "What Hasala filed on its own this week. Tap a category to fix one."
  public static let emptyLine = "Nothing sorted for you in the last 7 days."

  public var homeSpoken: String? {
    guard payments > 0 else { return nil }
    return "\(payments) payment\(payments == 1 ? "" : "s") sorted for you this week. Look."
  }
}

public enum SortedForYouEngine {
  public static let days = 7

  public static func since(_ now: LocalDateTime) -> LocalDateTime {
    LocalDateTime(date: now.date.adding(days: -days), hour: now.hour, minute: now.minute)
  }

  public static func snapshot(_ s: LedgerState, now: LocalDateTime) -> SortedForYouSnapshot {
    let from = since(now)
    struct Key: Hashable {
      var source: String
      var group: String
      var category: CategoryID
    }
    var rows: [Key: [Txn]] = [:]
    var order: [Key] = []
    for t in s.txns where t.sortedForYou {
      guard let at = t.categorizedAt, at >= from, at <= now, let c = t.categoryID else { continue }
      let source: String
      if case .rule(let pattern) = t.categorySource {
        source = "rule:" + (t.ruleID ?? pattern)
      } else {
        source = "cloudflare"
      }
      let key = Key(source: source, group: t.merchantGroup ?? t.merchantKey ?? t.merchant.lowercased(), category: c)
      if rows[key] == nil { order.append(key) }
      rows[key, default: []].append(t)
    }
    let items = order.compactMap { key -> SortedForYouItem? in
      guard let list = rows[key], let first = list.first, let c = s.category(key.category) else { return nil }
      let sorted = list.sorted { $0.postedAt == $1.postedAt ? $0.id < $1.id : $0.postedAt > $1.postedAt }
      let latest = list.compactMap(\.categorizedAt).max() ?? now
      let isRule = key.source.hasPrefix("rule:")
      let rule = isRule ? s.rule(first.ruleID)?.id : nil
      return SortedForYouItem(
        id: "\(key.source)|\(key.group)|\(key.category)", merchant: ReviewEngine.displayName(list),
        category: CategoryOption(c), source: isRule ? .rule(first.ruleID) : .cloudflare, txnIDs: sorted.map(\.id),
        latest: latest, group: first.groupRef, ruleID: rule)
    }
    .sorted { $0.latest == $1.latest ? $0.id < $1.id : $0.latest > $1.latest }
    return SortedForYouSnapshot(items: items)
  }
}
