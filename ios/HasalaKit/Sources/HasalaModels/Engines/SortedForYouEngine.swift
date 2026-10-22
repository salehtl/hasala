public struct SortResultRow: Sendable, Hashable, Identifiable {
  public var id: Int
  public var merchant: String
  public var count: Int
  public var category: CategoryOption?
  public var otherMonths: Int
  public var undo: UndoToken?
  public var ruleID: RuleID?

  public var line: String {
    "Sorted \(count) \(merchant) as \(category?.name ?? "Uncategorized")"
  }

  public var detail: String? {
    guard otherMonths > 0 else { return nil }
    return "including \(otherMonths) from \(otherMonths == 1 ? "another month" : "other months")"
  }

  public var spoken: String { [line, detail].compactMap { $0 }.joined(separator: ", ") + "." }

  public var canStopRule: Bool { ruleID != nil }
}

public enum SortResultEngine {
  public static func row(_ s: LedgerState, in window: ReviewWindow = .all) -> SortResultRow? {
    guard let r = s.sortReceipt else { return nil }
    let outside = r.txnIDs.reduce(0) { n, id in
      guard let t = s.txn(id) else { return n }
      return window.contains(t.postedAt.date) ? n : n + 1
    }
    let rule = s.rule(r.ruleID)?.id
    return SortResultRow(
      id: r.id, merchant: r.merchant, count: r.count, category: s.category(r.categoryID).map(CategoryOption.init),
      otherMonths: outside, undo: r.undo, ruleID: rule)
  }
}

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
