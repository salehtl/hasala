// Transaction detail: one sheet with all of a transaction's actions and the
// bank email it came from.

public struct EmbeddedPace: Sendable, Hashable {
  /// "Groceries this month".
  public var title: String
  public var left: Money
  public var budget: Money
  public var progress: Permille
  public var today: Permille?
  public var verdict: Verdict
  /// "on course for 2,518".
  public var projection: MoneyPhrase?
}

/// Why a transaction has its category ("Sorted by your rule" · "carrefour → Groceries").
public struct SortedBy: Sendable, Hashable {
  public var title: String
  public var detail: String

  public init(title: String, detail: String) {
    self.title = title
    self.detail = detail
  }
}

public struct TransactionDetail: Sendable, Hashable, Identifiable {
  public var id: TxnID
  public var merchant: String
  public var glyph: Glyph
  public var hue: Hue
  public var monogram: String?
  public var amount: Money
  public var isIncome: Bool
  /// "Fri 9 Oct, 19:12 · Emirates NBD ···4412".
  public var meta: String
  public var category: CategoryOption?
  public var pace: EmbeddedPace?
  public var account: String?
  public var note: String
  public var provenance: Provenance?
  /// "Sorted by your rule" / "carrefour → Groceries".
  public var sortedBy: SortedBy?
  public var splits: [SplitLineModel]
  public var isRefund: Bool
  public var isTransfer: Bool
  public var archived: Bool
  public var needsReview: Bool
  public var project: String?
  /// A row of the App Review sample: no bank email is behind it.
  public var isSample: Bool = false
  /// The pipeline's guess for a row still in review ("Suggested: Groceries").
  public var suggestion: CategoryOption?
  /// One of the person's rules sorted it, so the provenance row opens the rules.
  public var sortedByRule: Bool = false
}

public struct SplitLineModel: Sendable, Hashable, Identifiable {
  public var id: Int
  public var category: CategoryOption
  public var amount: Money
  public var note: String
}

public enum TransactionEngine {
  public static func detail(_ id: TxnID, _ s: LedgerState, now: LocalDateTime) -> TransactionDetail? {
    guard let t = s.txn(id) else { return nil }
    let c = s.category(t.categoryID)
    var meta = "\(t.postedAt.date.short), \(t.postedAt.time)"
    if let a = s.account(t.accountID) { meta += " · \(a.label)" }

    var pace: EmbeddedPace?
    if let c, c.kind == .spending, t.countsInPlan, t.postedAt.date.yearMonth == now.date.yearMonth {
      let month = now.date.yearMonth
      let budget = s.plan.budget(c.id, month).minor
      let spent = s.spent(c.id, in: month).minor
      let paced = c.role == .everyday
      let verdict = Pace.verdict(spent: spent, budget: budget, day: now.date.day, days: month.days, paced: paced)
      if budget > 0 {
        let projected = Pace.projected(spent, day: now.date.day, days: month.days)
        pace = EmbeddedPace(
          title: "\(c.name) this month", left: .aed(budget - spent), budget: .aed(budget),
          progress: Permille.ratio(spent, of: budget),
          today: paced ? Pace.monthGone(day: now.date.day, days: month.days) : nil, verdict: verdict,
          projection: paced ? MoneyPhrase([.text("on course for "), .amount(.aed(projected), .rounded)]) : nil
        )
      }
    }

    var sortedBy: SortedBy?
    switch t.categorySource {
    case .rule(let pattern): sortedBy = SortedBy(title: "Sorted by your rule", detail: "\(pattern) → \(c?.name ?? "")")
    case .dictionary: sortedBy = SortedBy(title: "Sorted by Hasala's merchant list", detail: "\(t.merchant) → \(c?.name ?? "")")
    case .model: sortedBy = SortedBy(title: "Suggested on this iPhone", detail: "\(t.merchant) → \(c?.name ?? "")")
    case .user: sortedBy = SortedBy(title: "Sorted by you", detail: c?.name ?? "")
    case .manual: sortedBy = SortedBy(title: "Added by you", detail: c?.name ?? "")
    case nil: sortedBy = nil
    }

    let splits = t.splits.compactMap { line in
      s.category(line.categoryID).map {
        SplitLineModel(id: line.id, category: CategoryOption($0), amount: line.amount, note: line.note)
      }
    }

    return TransactionDetail(
      id: t.id, merchant: t.title, glyph: t.isTransfer ? .transfer : (c?.glyph ?? .review),
      hue: c?.hue ?? .other, monogram: c == nil ? String(t.merchant.prefix(1)).uppercased() : nil,
      amount: t.amount, isIncome: t.direction == .in, meta: meta, category: c.map(CategoryOption.init),
      pace: pace, account: s.account(t.accountID)?.label, note: t.note, provenance: t.provenance,
      sortedBy: sortedBy, splits: splits, isRefund: t.isRefund, isTransfer: t.isTransfer, archived: t.archived,
      needsReview: t.inReview, project: s.project(t.projectID)?.name, isSample: t.isSample,
      suggestion: t.inReview ? s.category(t.reviewSuggestion).map(CategoryOption.init) : nil,
      sortedByRule: { if case .rule = t.categorySource { true } else { false } }()
    )
  }

  /// Whether split lines add up to the transaction (`validateSplitDraft`, simplified).
  /// TODO(spec 04 §16.2 T4): over/under edge states with their own copy.
  public static func splitAddsUp(_ lines: [SplitLine], total: Money) -> Bool {
    lines.count >= 2 && lines.allSatisfy { $0.amount.minor > 0 }
      && lines.reduce(Int64(0), { $0 + $1.amount.minor }) == total.minor
  }

  /// What the split editor says under the amount while lines are typed (`nil` is a line
  /// with no amount yet). Only `.addsUp` may be saved, and it means `splitAddsUp` holds:
  /// a line that is empty or zero never "adds up exactly", even when the others do.
  public static func splitDraftVerdict(_ amounts: [Int64?], total: Money) -> SplitDraftVerdict {
    let placed = amounts.reduce(Int64(0)) { $0 + ($1 ?? 0) }
    if placed < total.minor { return .leftToPlace(.aed(total.minor - placed)) }
    if placed > total.minor { return .over(.aed(placed - total.minor)) }
    if amounts.count < 2 || amounts.contains(where: { ($0 ?? 0) <= 0 }) { return .emptyLine }
    return .addsUp
  }
}

public enum SplitDraftVerdict: Sendable, Hashable {
  case addsUp
  case leftToPlace(Money)
  case over(Money)
  /// The amounts add up, but a line has nothing on it.
  case emptyLine
}
