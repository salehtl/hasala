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

public struct ProjectChoice: Sendable, Hashable, Identifiable {
  public var id: ProjectID
  public var name: String
  public var glyph: Glyph
  public var suggested: Bool

  public init(_ p: Project, suggested: Bool) {
    id = p.id
    name = p.name
    glyph = p.glyph
    self.suggested = suggested
  }
}

extension Project {
  public func covers(_ d: LocalDate) -> Bool {
    (starts.map { d >= $0 } ?? true) && (ends.map { d <= $0 } ?? true)
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
  public var suggestedBy: String? = nil
  public var copyLine: String? = nil
  public var samePurchase: Bool = false
  public var month: YearMonth? = nil
  public var posted: LocalDate? = nil
  public var canAlwaysUse: Bool = false
  public var reasonLine: String? = nil
  public var fromText: Bool = false
}

public struct ReviewMonth: Sendable, Hashable, Identifiable {
  public var month: YearMonth
  public var title: String
  public var cards: [ReviewCardModel]
  public var id: YearMonth { month }
}

public struct ReviewElsewhere: Sendable, Hashable {
  public enum Side: Sendable, Hashable { case earlier, later, other }

  public var count: Int
  public var side: Side
  public var widened: Period

  public init(count: Int, side: Side, widened: Period) {
    self.count = count
    self.side = side
    self.widened = widened
  }

  public var line: String {
    let one = count == 1
    let months = switch side {
    case .earlier: one ? "an earlier month" : "earlier months"
    case .later: one ? "a later month" : "later months"
    case .other: one ? "another month" : "other months"
    }
    return "\(MoneyFormat.count(count)) more in \(months)"
  }
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
  public var notCounted: Bool = false
}

public struct ReviewWindow: Sendable, Hashable {
  public var from: LocalDate?
  public var to: LocalDate?

  public init(from: LocalDate?, to: LocalDate?) {
    self.from = from
    self.to = to
  }

  public init(_ period: Period) {
    self.init(from: period.first.firstDay, to: period.last.lastDay)
  }

  public static let all = ReviewWindow(from: nil, to: nil)

  public static func month(_ m: YearMonth) -> ReviewWindow { ReviewWindow(.month(m)) }

  public static func range(_ from: LocalDate, _ to: LocalDate) -> ReviewWindow {
    from <= to ? ReviewWindow(from: from, to: to) : ReviewWindow(from: to, to: from)
  }

  public func contains(_ d: LocalDate) -> Bool {
    (from.map { d >= $0 } ?? true) && (to.map { d <= $0 } ?? true)
  }

  public var label: String {
    guard let from, let to else {
      if let from { return "Since \(from.dayMonth) \(from.year)" }
      if let to { return "Until \(to.dayMonth) \(to.year)" }
      return "All time"
    }
    if from.day == 1, to.year == from.year, to.month == from.month, to.day == from.yearMonth.days {
      return from.yearMonth.title
    }
    return from.year == to.year
      ? "\(from.dayMonth) – \(to.dayMonth) \(to.year)"
      : "\(from.dayMonth) \(from.year) – \(to.dayMonth) \(to.year)"
  }
}

extension Txn {
  public var inReview: Bool {
    if archived { return false }
    if isHeldCopy { return true }
    if samePurchase != nil { return true }
    if isTransfer { return false }
    if needsReview || modelGuessRejected { return true }
    return categoryID == nil && splits.isEmpty
  }

  public var reviewSuggestion: CategoryID? { lastPick ?? modelSuggestion }

  public var modelSuggestion: CategoryID? {
    let guess: CategoryID?
    if let suggestion {
      guess = suggestion
    } else if case .model = categorySource {
      guess = categoryID
    } else {
      guess = nil
    }
    guard let guess, !rejectedCategories.contains(guess) else { return nil }
    return guess
  }

  public var reviewSuggestionLabel: String? {
    guard reviewSuggestion != nil else { return nil }
    if lastPick != nil { return CategorySource.lastPickLabel }
    return categorySource?.suggestionLabel(needsReview: needsReview)
  }
}

extension ReviewCardModel {
  public var senderUnverified: Bool { reviewReason == .senderUnverified }
}

public enum ReviewOrder: String, CaseIterable, Identifiable, Sendable {
  case newestFirst = "newest"
  case oldestFirst = "oldest"

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .newestFirst: "Newest first"
    case .oldestFirst: "Oldest first"
    }
  }
}

public enum ReviewEngine {
  /// The queue without today's skips, whatever the period, strictly by posted time.
  public static func queue(_ s: LedgerState, in window: ReviewWindow = .all, order: ReviewOrder = .newestFirst) -> [Txn] {
    let open = s.txns.filter { $0.inReview && window.contains($0.postedAt.date) && !s.skippedReview.contains($0.id) }
    let oldest = open.sorted { $0.postedAt == $1.postedAt ? $0.id < $1.id : $0.postedAt < $1.postedAt }
    return order == .oldestFirst ? oldest : oldest.reversed()
  }

  public static func window(_ period: Period, today: YearMonth) -> ReviewWindow {
    if period.isAllTime { return .all }
    var w = ReviewWindow(period)
    if period.last >= today { w.to = nil }
    return w
  }

  public static func elsewhere(_ s: LedgerState, in period: Period, today: YearMonth) -> ReviewElsewhere? {
    if period.isAllTime { return nil }
    let months = queue(s).map { min($0.postedAt.date.yearMonth, today) }.filter { !period.contains($0) }
    guard let first = months.min(), let last = months.max() else { return nil }
    let side: ReviewElsewhere.Side = last < period.first ? .earlier : first > period.last ? .later : .other
    let widened = Period(min(first, period.first), max(last, period.last))
    return ReviewElsewhere(count: months.count, side: side, widened: widened)
  }

  public static func unreadMail(_ s: LedgerState) -> [UnreadMail] {
    s.unreadMail.sorted { $0.receivedOn == $1.receivedOn ? $0.id > $1.id : $0.receivedOn > $1.receivedOn }
  }

  public static func notDownloaded(_ s: LedgerState) -> Int { max(0, s.mailbox.unreadable) }

  public static func unreadCount(_ s: LedgerState) -> Int { s.unreadMail.count + notDownloaded(s) }

  public static func unreadLine(_ n: Int) -> String {
    "\(MoneyFormat.count(n)) bank email\(n == 1 ? "" : "s") we couldn't read"
  }

  public static func notDownloadedLine(_ n: Int) -> String {
    "\(MoneyFormat.count(n)) more email\(n == 1 ? "" : "s") couldn't be downloaded."
  }

  public static func unreadTitle(_ m: UnreadMail) -> String {
    m.bank.map { "\($0) email" } ?? "Bank email"
  }

  public static func unreadDetail(_ m: UnreadMail, today: LocalDate) -> String {
    let when = m.receivedOn == today ? "Received today" : "Received \(m.receivedOn.short(today: today))"
    guard let provider = m.provider else { return when }
    return "\(when) · in \(provider.appName)"
  }

  public static func unreadTexts(_ s: LedgerState) -> [UnreadText] {
    s.unreadTexts.sorted { $0.receivedAt == $1.receivedAt ? $0.id > $1.id : $0.receivedAt > $1.receivedAt }
  }

  public static func unreadTextLine(_ n: Int) -> String {
    "\(MoneyFormat.count(n)) bank text\(n == 1 ? "" : "s") we couldn't read"
  }

  public static func unreadTextTitle(_ m: UnreadText) -> String {
    m.bank.map { "Text from \($0)" } ?? "Bank text"
  }

  public static func unreadTextWhen(_ m: UnreadText, today: LocalDate) -> String {
    m.receivedAt.date == today ? m.receivedAt.time : "\(m.receivedAt.time) on \(m.receivedAt.date.short(today: today))"
  }

  public static func unreadTextDetail(_ m: UnreadText, today: LocalDate) -> String {
    m.receivedAt.date == today ? "Received today, \(m.receivedAt.time)" : "Received \(m.receivedAt.date.short(today: today)), \(m.receivedAt.time)"
  }

  public static func unreadTextBody(_ m: UnreadText, today: LocalDate, canPaste: Bool) -> String {
    let from = m.bank.map { "the text from \($0)" } ?? "the text"
    let find = "Find \(from) at \(unreadTextWhen(m, today: today)) in Messages"
    return canPaste
      ? "Hasala couldn't read this bank text. \(find), copy it and paste it here, or add the payment yourself."
      : "Hasala couldn't read this bank text. \(find) and add the payment yourself."
  }

  public static func months(_ cards: [ReviewCardModel], now: LocalDateTime) -> [ReviewMonth] {
    var out: [ReviewMonth] = []
    for card in cards {
      let m = card.month ?? now.date.yearMonth
      if out.last?.month == m {
        out[out.count - 1].cards.append(card)
      } else {
        out.append(ReviewMonth(month: m, title: monthTitle(m, now: now), cards: [card]))
      }
    }
    return out
  }

  public static func monthTitle(_ m: YearMonth, now: LocalDateTime) -> String {
    let today = now.date.yearMonth
    if m == today { return "This month" }
    return m.year == today.year ? m.name : m.title
  }

  public static func cards(
    _ s: LedgerState, in window: ReviewWindow = .all, order: ReviewOrder = .newestFirst, today: LocalDate? = nil
  ) -> [ReviewCardModel] {
    queue(s, in: window, order: order).map { card($0, s, today: today) }
  }

  /// A session's order when it starts at one card (a To sort row): that card, the ones
  /// after it, then the ones before it, so the deck reads on down the list.
  public static func order(_ ids: [TxnID], startingAt start: TxnID?) -> [TxnID] {
    guard let start, let i = ids.firstIndex(of: start) else { return ids }
    return Array(ids[i...] + ids[..<i])
  }

  public static func card(_ t: Txn, _ s: LedgerState, today: LocalDate? = nil) -> ReviewCardModel {
    let verb = t.direction == .in ? "Received" : "Spent"
    var meta = "\(verb) · " + t.joined(t.postedAt.date.short, t.postedTime, separator: ", ")
    if let a = s.account(t.accountID) { meta += " · \(a.label)" }
    let d = t.postedAt.date
    let when = "\(verb.lowercased()) \(spokenDay(d))"
    var card = ReviewCardModel(
      id: t.id, merchant: merchantName(t), monogram: monogram(t.merchant),
      isNewMerchant: t.isNewMerchant && t.lastPick == nil, reviewReason: t.activeReviewReason,
      rawMerchant: t.provenance.flatMap { $0.rawMerchant.isEmpty ? nil : $0.rawMerchant }, amount: t.amount,
      isIncome: t.direction == .in, meta: meta, spokenWhen: when,
      suggestion: suggestion(t, s).map(CategoryOption.init)
    )
    card.copyLine = copyLine(t, s) ?? samePurchaseLine(t, s, today: today)
    if card.suggestion != nil { card.suggestedBy = t.reviewSuggestionLabel }
    card.samePurchase = t.samePurchase != nil && !t.isHeldCopy
    card.month = d.yearMonth
    card.posted = d
    card.canAlwaysUse = t.canAlwaysUse
    if t.activeReviewReason == .mayRepeat { card.reasonLine = t.mayRepeat?.line }
    card.fromText = t.fromText
    return card
  }

  public static let unknownMerchant = "Unknown merchant"

  public static func merchantName(_ t: Txn) -> String {
    t.merchant.allSatisfy(\.isWhitespace) ? unknownMerchant : t.title
  }

  public static let copyNameLimit = 24

  public static func copyName(_ t: Txn) -> String {
    let name = merchantName(t)
    guard name.count > copyNameLimit else { return name }
    var cut = name.prefix(copyNameLimit - 1)
    while cut.last?.isWhitespace == true { cut.removeLast() }
    return cut + "…"
  }

  public static func monogram(_ merchant: String) -> String {
    merchant.first(where: \.isLetter).map { String($0).uppercased() } ?? ""
  }

  public static func suggestion(_ t: Txn, _ s: LedgerState) -> Category? {
    s.category(t.reviewSuggestion).flatMap { $0.archived ? nil : $0 }
  }

  public static func copyLine(_ t: Txn, _ s: LedgerState) -> String? {
    guard let held = t.heldCopy else { return nil }
    let other = s.txn(held.of) ?? t
    let amount = "\(other.amount.currency) \(MoneyFormat.string(other.amount))"
    let name = copyName(other)
    return held.fromOtherInbox
      ? "Looks like a copy of \(name) \(amount) from your other inbox"
      : "Looks like a copy of \(name) \(amount) you already have"
  }

  public static func samePurchaseLine(_ t: Txn, _ s: LedgerState, today: LocalDate? = nil) -> String? {
    guard let match = t.samePurchase, let f = s.txn(match.of) else { return nil }
    var amount = "\(f.amount.currency) \(MoneyFormat.string(f.amount))"
    if let home = f.homeMinor { amount += " (about \(Money.home) \(MoneyFormat.string(home)))" }
    var line = "Same purchase as \(amount) at \(copyName(f)) on \(today.map { f.postedAt.date.short(today: $0) } ?? f.postedAt.date.short)?"
    if match.merchantMissing { line += " This alert has no merchant." }
    return line
  }

  /// Monday first, as `LocalDate.weekday` counts.
  public static let weekdayNames = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]

  static func spokenDay(_ d: LocalDate) -> String { "\(weekdayNames[d.weekday]) \(d.day) \(d.yearMonth.name)" }

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

  public static func projectChoices(_ s: LedgerState, on date: LocalDate) -> [ProjectChoice] {
    s.projects.filter(\.isOpen).map { ProjectChoice($0, suggested: $0.covers(date)) }
  }

  /// The line for All caught up once `txn` is sorted into `category`.
  public static func sortedLine(_ t: Txn, into category: Category, learnedRule: Bool) -> SortedLine {
    let counts = category.kind == .spending && t.direction == .out
    return SortedLine(
      id: t.id, merchant: t.title,
      detail: category.name + (learnedRule ? " · new rule" : ""),
      amount: t.amount, isIncome: t.direction == .in, glyph: category.glyph, hue: category.hue,
      counted: counts ? t.homeMinor ?? 0 : 0, learnedRule: learnedRule, notCounted: counts && t.homeMinor == nil
    )
  }
}

public enum SamePurchaseText {
  public static func note(_ foreign: Money) -> String {
    "Settled the \(foreign.currency) \(MoneyFormat.string(foreign.minor)) purchase"
  }

  public static let restoreRefused = "This alert is counted in the foreign purchase. Restoring it would count it twice."
}
