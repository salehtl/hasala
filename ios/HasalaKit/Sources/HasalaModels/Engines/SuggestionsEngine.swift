public struct SuggestionRow: Sendable, Hashable, Identifiable {
  public var id: TxnID
  public var merchant: String
  public var postedAt: LocalDateTime
  public var amount: Money
  public var isIncome: Bool
  public var category: CategoryID
  public var source: String
  public var fromCloudflare: Bool

  public var dateLine: String { postedAt.date.short }
  public var detail: String { "\(dateLine) · \(source)" }
}

public struct SuggestionGroup: Sendable, Hashable, Identifiable {
  public var category: CategoryOption
  public var rows: [SuggestionRow]
  public var id: CategoryID { category.id }

  public var payments: Int { rows.count }
  public var merchants: Int { Set(rows.map { $0.merchant.lowercased() }).count }

  public var title: String {
    "\(category.name) · \(SuggestionsEngine.count(payments, "payment")) · \(SuggestionsEngine.count(merchants, "merchant"))"
  }
}

public struct SuggestionsSnapshot: Sendable, Hashable {
  public var groups: [SuggestionGroup]

  public init(groups: [SuggestionGroup]) {
    self.groups = groups
  }

  public static let empty = SuggestionsSnapshot(groups: [])

  public var rows: [SuggestionRow] { groups.flatMap(\.rows) }
  public var count: Int { groups.reduce(0) { $0 + $1.rows.count } }
  public var isEmpty: Bool { groups.isEmpty }
  public var allFromCloudflare: Bool { rows.allSatisfy(\.fromCloudflare) }

  public var lead: String {
    allFromCloudflare
      ? "Cloudflare's AI suggested these. Untick any that are wrong, then use the rest."
      : "These are suggestions. Untick any that are wrong, then use the rest."
  }
}

public enum SuggestionsEngine {
  public static func isModelSuggestion(_ t: Txn) -> Bool {
    guard case .model = t.categorySource, t.reviewSuggestion != nil else { return false }
    return t.activeReviewReason == nil
  }

  public static func snapshot(_ s: LedgerState) -> SuggestionsSnapshot {
    var byCategory: [CategoryID: [SuggestionRow]] = [:]
    for t in ReviewEngine.queue(s) where isModelSuggestion(t) {
      guard let c = t.reviewSuggestion, s.category(c) != nil, case .model(let tag) = t.categorySource else { continue }
      byCategory[c, default: []].append(
        SuggestionRow(
          id: t.id, merchant: t.title, postedAt: t.postedAt, amount: t.amount, isIncome: t.direction == .in, category: c,
          source: CategorySource.suggestionLabel(modelTag: tag, needsReview: true),
          fromCloudflare: tag?.hasPrefix(CategorySource.cloudflareModelPrefix) == true))
    }
    let groups = byCategory.compactMap { id, rows -> SuggestionGroup? in
      guard let c = s.category(id) else { return nil }
      let sorted = rows.sorted { $0.postedAt == $1.postedAt ? $0.id < $1.id : $0.postedAt > $1.postedAt }
      return SuggestionGroup(category: CategoryOption(c), rows: sorted)
    }
    .sorted { $0.payments == $1.payments ? $0.category.name < $1.category.name : $0.payments > $1.payments }
    return SuggestionsSnapshot(groups: groups)
  }

  public static func count(_ s: LedgerState) -> Int {
    ReviewEngine.queue(s).reduce(0) { n, t in
      guard isModelSuggestion(t), let c = t.reviewSuggestion, s.category(c) != nil else { return n }
      return n + 1
    }
  }

  public static func applies(_ u: SuggestionUse, to t: Txn) -> Bool {
    guard t.id == u.txn, t.needsReview, case .model = t.categorySource else { return false }
    return t.reviewSuggestion == u.category
  }

  public static func uses(_ snapshot: SuggestionsSnapshot, unticked: Set<TxnID>) -> [SuggestionUse] {
    snapshot.rows.filter { !unticked.contains($0.id) }.map { SuggestionUse(txn: $0.id, category: $0.category) }
  }

  public static func useLabel(_ n: Int) -> String { "Use \(count(n, "suggestion"))" }

  public static func usedLine(_ n: Int) -> String { "Used \(count(n, "suggestion"))" }

  static func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }
}
