// Review · Deck, Pick a need and All caught up: the
// daily sorting ritual. Right for Need, left for Want, down for Save, up for Transfer
// (the horizontal pair follows `prefs.swipeNeedOnRight`, spec 04 §14.9).

/// The four sorting directions of the deck.
public enum ReviewChoice: String, Sendable, Hashable, CaseIterable, Codable {
  case need, want, save, transfer

  public var label: String {
    switch self {
    case .need: "Need"
    case .want: "Want"
    case .save: "Save"
    case .transfer: "Transfer"
    }
  }

  /// The bucket whose categories the pick sheet offers; `nil` for Transfer.
  public var bucket: Bucket? {
    switch self {
    case .need: .needs
    case .want: .wants
    case .save: .savings
    case .transfer: nil
    }
  }

  public var hue: Hue {
    switch self {
    case .need: .sand
    case .want: .lilac
    case .save: .mint
    case .transfer: .sky
    }
  }

  /// The hue of the direction's pill dot, active pill and glow (Paper "Review · Deck":
  /// Transfer is the not-spending grey, not the sky of income).
  public var pillHue: Hue { self == .transfer ? .other : hue }

  /// The direction a category files under: its bucket's, and Transfer for everything that
  /// isn't spending or saving (transfers, refunds, income). "Use" sends the card that way.
  public init(filing bucket: Bucket) {
    switch bucket {
    case .needs: self = .need
    case .wants: self = .want
    case .savings: self = .save
    case .income, .project, .other: self = .transfer
    }
  }
}

/// A screen direction of a swipe.
public enum SwipeEdge: String, Sendable, Hashable, CaseIterable {
  case left, right, up, down
}

/// The deck's gesture physics, ported from the PWA (`lib/swipe.ts`, `lib/gesture.ts`;
/// spec 04 §14.7). Geometry only: these are points and points per second.
public enum SwipePhysics {
  /// Travel before a direction is chosen at all.
  public static let threshold: Double = 80
  /// Travel past which a release commits, on either axis.
  public static let commitDistance: Double = 100
  /// Speed past which a release commits regardless of distance.
  public static let commitVelocity: Double = 520
  /// A flick still needs this much travel on its axis to read as intentional.
  public static let flickMinDistance: Double = 24
  /// Preview strength is reported in this many steps.
  public static let previewSteps: Double = 10

  public static func detect(dx: Double, dy: Double, threshold: Double = threshold) -> SwipeEdge? {
    let ax = abs(dx), ay = abs(dy)
    if ax < threshold && ay < threshold { return nil }
    if ax >= ay { return dx < 0 ? .left : .right }
    return dy < 0 ? .up : .down
  }

  /// The direction the card leans toward while dragging (20 pt is enough to hint).
  public static func preview(dx: Double, dy: Double) -> SwipeEdge? { detect(dx: dx, dy: dy, threshold: 20) }

  /// 0…1 strength of the lean, unquantised: the glow and the pill follow the finger
  /// frame by frame.
  public static func strength(dx: Double, dy: Double) -> Double {
    min(1, max(abs(dx), abs(dy)) / commitDistance)
  }

  /// The edge the card is past the commit point toward, while it is dragged (no flick):
  /// its pill turns active and a light haptic plays as it crosses.
  public static func pastCommit(dx: Double, dy: Double) -> SwipeEdge? {
    detect(dx: dx, dy: dy, threshold: commitDistance)
  }

  /// The live card's tilt in degrees: it follows the horizontal drag and reaches
  /// `atCommit` at the commit point, never more.
  public static func tilt(dx: Double, atCommit: Double) -> Double {
    max(-atCommit, min(atCommit, dx / commitDistance * atCommit))
  }

  /// 0…1 strength of the lean, quantised to tenths so the deck redraws in steps.
  public static func progress(dx: Double, dy: Double) -> Double {
    let p = min(1, max(abs(dx), abs(dy)) / commitDistance)
    return (p * previewSteps).rounded() / previewSteps
  }

  static func flicked(_ offset: Double, _ velocity: Double) -> Bool {
    abs(offset) >= flickMinDistance && (offset < 0) == (velocity < 0) && velocity != 0
      && abs(velocity) >= commitVelocity
  }

  /// Where a release goes: far enough, or flicked fast enough, on the stronger axis.
  public static func commit(dx: Double, dy: Double, vx: Double, vy: Double) -> SwipeEdge? {
    let horizontal = abs(dx) >= commitDistance || flicked(dx, vx)
    let vertical = abs(dy) >= commitDistance || flicked(dy, vy)
    if !horizontal && !vertical { return nil }
    let preferHorizontal = horizontal && (!vertical || abs(dx) >= abs(dy))
    if preferHorizontal { return dx > 0 ? .right : .left }
    return dy > 0 ? .down : .up
  }

  /// Which sort a screen direction means.
  public static func choice(for edge: SwipeEdge, needOnRight: Bool = true) -> ReviewChoice {
    switch edge {
    case .right: needOnRight ? .need : .want
    case .left: needOnRight ? .want : .need
    case .down: .save
    case .up: .transfer
    }
  }

  public static func edge(for choice: ReviewChoice, needOnRight: Bool = true) -> SwipeEdge {
    SwipeEdge.allCases.first { self.choice(for: $0, needOnRight: needOnRight) == choice } ?? .right
  }
}

public struct CategoryOption: Sendable, Hashable, Identifiable {
  public var id: CategoryID
  public var name: String
  public var glyph: Glyph
  public var hue: Hue
  public var bucket: Bucket

  public init(_ c: Category) {
    id = c.id
    name = c.name
    glyph = c.glyph
    hue = c.hue
    bucket = c.bucket
  }
}

public struct ReviewCardModel: Sendable, Hashable, Identifiable {
  public var id: TxnID
  public var merchant: String
  public var monogram: String
  public var isNewMerchant: Bool
  public var reviewReason: TxnReviewReason?
  public var rawMerchant: String?
  public var amount: Money
  public var isIncome: Bool
  /// "Spent · Fri 9 Oct, 18:42 · DIB card ···8891".
  public var meta: String
  /// The same moment as VoiceOver says it: "spent Friday 9 October".
  public var spokenWhen: String
  /// "Looks like Groceries".
  public var suggestion: CategoryOption?
  public var copyLine: String? = nil
}

/// One line of the All caught up list.
public struct SortedLine: Sendable, Hashable, Identifiable {
  public var id: TxnID
  public var merchant: String
  /// "Groceries · new rule".
  public var detail: String
  public var amount: Money
  public var isIncome: Bool
  public var glyph: Glyph
  public var hue: Hue
  /// Money now counted in the plan by this sort (spending only).
  public var counted: Int64
  public var learnedRule: Bool
}

public enum ReviewEngine {
  /// The queue, oldest first, without today's skips.
  public static func queue(_ s: LedgerState) -> [Txn] {
    s.txns.filter { ($0.needsReview || $0.isHeldCopy) && !$0.archived && !s.skippedReview.contains($0.id) }
      .sorted { $0.postedAt < $1.postedAt }
  }

  public static func cards(_ s: LedgerState) -> [ReviewCardModel] {
    queue(s).map { card($0, s) }
  }

  /// A session's order when it starts at one card (a To sort row): that card, the ones
  /// after it, then the ones before it, so the deck reads on down the list.
  public static func order(_ ids: [TxnID], startingAt start: TxnID?) -> [TxnID] {
    guard let start, let i = ids.firstIndex(of: start) else { return ids }
    return Array(ids[i...] + ids[..<i])
  }

  public static func card(_ t: Txn, _ s: LedgerState) -> ReviewCardModel {
    let verb = t.direction == .in ? "Received" : "Spent"
    var meta = "\(verb) · \(t.postedAt.date.short), \(t.postedAt.time)"
    if let a = s.account(t.accountID) { meta += " · \(a.label)" }
    let d = t.postedAt.date
    let when = "\(verb.lowercased()) \(weekdayNames[d.weekday]) \(d.day) \(CivilCalendar.monthNames[d.month - 1])"
    var card = ReviewCardModel(
      id: t.id, merchant: t.title, monogram: String(t.merchant.prefix(1)).uppercased(),
      isNewMerchant: t.isNewMerchant, reviewReason: t.activeReviewReason, rawMerchant: t.provenance?.rawMerchant, amount: t.amount,
      isIncome: t.direction == .in, meta: meta, spokenWhen: when,
      suggestion: s.category(t.suggestion).map(CategoryOption.init)
    )
    card.copyLine = copyLine(t, s)
    return card
  }

  public static func copyLine(_ t: Txn, _ s: LedgerState) -> String? {
    guard let held = t.heldCopy else { return nil }
    let other = s.txn(held.of) ?? t
    let amount = "\(other.amount.currency) \(MoneyFormat.string(other.amount.minor))"
    return held.fromOtherInbox
      ? "Looks like a copy of \(other.title) \(amount) from your other inbox"
      : "Looks like a copy of \(other.title) \(amount) you already have"
  }

  /// Monday first, as `LocalDate.weekday` counts.
  static let weekdayNames = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]

  /// The categories a pick sheet offers for a direction. Transfer offers the
  /// not-spending categories, and income ones for money in (PWA `panelGroups`).
  public static func options(for choice: ReviewChoice, _ s: LedgerState, txn: Txn? = nil) -> [CategoryOption] {
    if let bucket = choice.bucket {
      return s.categories(in: bucket).map(CategoryOption.init)
    }
    let excluded = s.categories.filter { $0.kind == .excluded && !$0.archived }
    let income = txn?.direction == .in ? s.categories.filter { $0.kind == .income && !$0.archived } : []
    return (income + excluded).map(CategoryOption.init)
  }

  /// The line for All caught up once `txn` is sorted into `category`.
  public static func sortedLine(_ t: Txn, into category: Category, learnedRule: Bool) -> SortedLine {
    let counts = category.kind == .spending && t.direction == .out
    return SortedLine(
      id: t.id, merchant: t.title,
      detail: category.name + (learnedRule ? " · new rule" : ""),
      amount: t.amount, isIncome: t.direction == .in, glyph: category.glyph, hue: category.hue,
      counted: counts ? t.amount.minor : 0, learnedRule: learnedRule
    )
  }
}
