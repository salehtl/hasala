import HasalaModels
import Observation
import SwiftUI

/// A pick sheet that is up: which card, and the direction it was sent ("Need · which one?").
struct ReviewPick: Identifiable, Hashable {
  let card: ReviewCardModel
  let choice: ReviewChoice
  var group: ReviewGroupCardModel? = nil
  var id: String { (group.map { "group." + $0.id } ?? card.id) + "." + choice.rawValue }
}

struct RejectedNote: Hashable {
  let line: String
  let undo: UndoToken?
}

/// Review · Deck, Pick a need, All caught up (Paper 26H-0, 3SH-0, 4MY-0). One session runs
/// from opening the cover to closing it; "2 of 6" counts within it. Every sort is one
/// `LedgerEdit` through `AppModel.perform`, so it has its toast and its Undo.
@MainActor
protocol ReviewDeckModel: AnyObject, Observable {
  /// The cards still to sort, in this session's order, the top card first.
  var cards: [ReviewCardModel] { get }
  var items: [ReviewItem] { get }
  var result: SortResultRow? { get }
  var sortingEach: ReviewGroupCardModel? { get set }
  var notes: [String: RejectedNote] { get }
  func pickGroup(_ group: ReviewGroupCardModel, _ choice: ReviewChoice)
  @discardableResult func sortGroup(_ group: ReviewGroupCardModel, into category: CategoryID, alwaysUse: Bool, project: ProjectID?) -> Bool
  @discardableResult func useGroup(_ group: ReviewGroupCardModel) -> Bool
  @discardableResult func notThis(_ item: ReviewItem) -> Bool
  func undoNotThis(_ itemID: String)
  func skipItem(_ item: ReviewItem)
  func groupRows(_ group: ReviewGroupCardModel) -> [ReviewCardModel]
  func group(_ id: String) -> ReviewGroupCardModel?
  func undoResult()
  func stopResultRule()
  func dismissResult()
  /// 1-based position of the top card in this session, and the session's size.
  var position: Int { get }
  var total: Int { get }
  var waitingForCloud: Int { get }
  /// What this session sorted, for All caught up.
  var sorted: [SortedLine] { get }
  var hidden: Bool { get }
  var needOnRight: Bool { get }
  /// The pick sheet that is up, if any. Setting nil closes it without sorting.
  var picking: ReviewPick? { get set }
  /// All caught up celebrates once a session (motion policy: a rare moment may delight).
  var celebrated: Bool { get set }
  var periodTitle: String { get }
  var isThisMonth: Bool { get }
  var elsewhere: ReviewElsewhere? { get }
  func periodChanged()
  func showElsewhere()
  func options(for choice: ReviewChoice, card: TxnID) -> [CategoryOption]
  func projects(for card: TxnID) -> [ProjectChoice]
  /// A swipe or a pill sent the card one way: ask which category.
  func pick(_ card: TxnID, _ choice: ReviewChoice)
  @discardableResult func sort(_ card: TxnID, into category: CategoryID, alwaysUse: Bool, project: ProjectID?) -> Bool
  @discardableResult func useSuggestion(_ card: TxnID) -> Bool
  func skip(_ card: TxnID)
  @discardableResult func resolveCopy(_ card: TxnID, merge: Bool) -> Bool
  @discardableResult func resolveSamePurchase(_ card: TxnID, same: Bool) -> Bool
  @discardableResult func archive(_ card: TxnID) -> Bool
  func close(goToActivity: Bool)
}

@MainActor
@Observable
final class ReviewViewModel: ReviewDeckModel {
  private let app: AppModel
  private var sortedIDs: [TxnID] = []
  private var learned: Set<TxnID> = []
  /// The order this session reads the queue in: the Review tab's, or from the row that opened it.
  private var order: [TxnID]
  private(set) var total: Int
  private var window: ReviewWindow
  var picking: ReviewPick?
  var sortingEach: ReviewGroupCardModel?
  private(set) var notes: [String: RejectedNote] = [:]
  var celebrated = false
  @ObservationIgnored private var memo = Memo<CardsKey, [ReviewItem]>()

  private struct CardsKey: Equatable {
    let revision: Int
    let window: ReviewWindow
  }

  init(app: AppModel) {
    self.app = app
    let start = ReviewEntry.take(for: app)
    let window = app.reviewWindow
    self.window = window
    let items = ReviewEngine.items(app.store.state, in: window)
    total = items.count
    order = ReviewEngine.itemOrder(items.map(\.id), startingAt: start, in: items)
    #if HASALA_MOCKS
      ReviewEntry.takeScript(for: app)?(self)
    #endif
  }

  /// The queue as it stands, in the session's order. A card that arrives mid-session goes
  /// last; a card that Undo puts back takes its old place.
  var items: [ReviewItem] {
    let ordered = memo.value(for: CardsKey(revision: app.store.revision, window: window)) {
      let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
      return ReviewEngine.items(app.store.state, in: window).enumerated()
        .sorted { (rank[$0.element.id] ?? order.count + $0.offset) < (rank[$1.element.id] ?? order.count + $1.offset) }
        .map(\.element)
    }
    return Self.holdingBack(ordered, waiting: cloudPending)
  }

  var cards: [ReviewCardModel] {
    items.compactMap { if case .single(let c) = $0 { c } else { nil } }
  }

  var result: SortResultRow? { app.sortResult }

  var waitingForCloud: Int {
    let pending = cloudPending
    guard !pending.isEmpty else { return 0 }
    return items.lazy.filter { $0.txnIDs.allSatisfy(pending.contains) }.count
  }

  private var cloudPending: Set<TxnID> {
    guard let status = app.cloudSort?.status else { return [] }
    switch status.phase {
    case .running, .paused: return status.pendingTxnIDs
    case .off, .idle, .done: return []
    }
  }

  nonisolated static func holdingBack(_ cards: [ReviewCardModel], waiting: Set<TxnID>) -> [ReviewCardModel] {
    guard !waiting.isEmpty else { return cards }
    return cards.filter { !waiting.contains($0.id) } + cards.filter { waiting.contains($0.id) }
  }

  nonisolated static func holdingBack(_ items: [ReviewItem], waiting: Set<TxnID>) -> [ReviewItem] {
    guard !waiting.isEmpty else { return items }
    let held = { (i: ReviewItem) in i.txnIDs.allSatisfy(waiting.contains) }
    return items.filter { !held($0) } + items.filter(held)
  }

  var position: Int { min(total, max(1, total - items.count + 1)) }
  var periodTitle: String { app.period.title }
  var isThisMonth: Bool { app.period == .month(app.store.now.date.yearMonth) }
  var elsewhere: ReviewElsewhere? { app.reviewElsewhere }

  func periodChanged() {
    restart()
  }

  func showElsewhere() {
    guard let elsewhere else { return }
    app.period = elsewhere.widened
    restart()
  }

  private func restart() {
    let top = items.first?.id
    window = app.reviewWindow
    let fresh = ReviewEngine.items(app.store.state, in: window)
    total = fresh.count
    order = ReviewEngine.itemOrder(fresh.map(\.id), startingAt: top, in: fresh)
    memo = Memo()
  }

  var hidden: Bool { app.amountsHidden }
  var needOnRight: Bool { app.store.state.prefs.swipeNeedOnRight }

  func projects(for card: TxnID) -> [ProjectChoice] {
    let s = app.store.state
    guard let date = s.txn(card)?.postedAt.date else { return [] }
    return ReviewEngine.projectChoices(s, on: date)
  }

  /// Sorted in this session and not undone since.
  var sorted: [SortedLine] {
    let s = app.store.state
    return sortedIDs.compactMap { id in
      guard let t = s.txn(id), !t.inReview, let c = s.category(t.categoryID) else { return nil }
      return ReviewEngine.sortedLine(t, into: c, learnedRule: learned.contains(id))
    }
  }

  func options(for choice: ReviewChoice, card: TxnID) -> [CategoryOption] {
    let s = app.store.state
    var options = ReviewEngine.options(for: choice, s, txn: s.txn(card))
    // The suggestion leads its bucket's list (Paper "Pick a need": "Suggested").
    if let sug = s.txn(card)?.reviewSuggestion, let i = options.firstIndex(where: { $0.id == sug }) {
      options.insert(options.remove(at: i), at: 0)
    }
    return options
  }

  func pick(_ card: TxnID, _ choice: ReviewChoice) {
    guard let c = cards.first(where: { $0.id == card }) ?? app.store.state.txn(card).map({ ReviewEngine.card($0, app.store.state) })
    else { return }
    picking = ReviewPick(card: c, choice: choice)
  }

  func pickGroup(_ group: ReviewGroupCardModel, _ choice: ReviewChoice) {
    let s = app.store.state
    guard let first = group.txnIDs.first ?? groupRows(group).first?.id, let t = s.txn(first) else { return }
    picking = ReviewPick(card: ReviewEngine.card(t, s), choice: choice, group: group)
  }

  func group(_ id: String) -> ReviewGroupCardModel? {
    for item in items { if case .group(let g) = item, g.id == id { return g } }
    return nil
  }

  func groupRows(_ group: ReviewGroupCardModel) -> [ReviewCardModel] {
    let s = app.store.state
    return ReviewEngine.groupRows(group.group, s).filter { !s.skippedReview.contains($0.id) }
  }

  @discardableResult
  func sortGroup(_ group: ReviewGroupCardModel, into category: CategoryID, alwaysUse: Bool, project: ProjectID?) -> Bool {
    guard case .some = app.performQuietly(.sortGroup(group.group, category, alwaysUse: alwaysUse, project: project)) else {
      return false
    }
    for id in group.txnIDs { record(id, learnedRule: alwaysUse) }
    return true
  }

  @discardableResult
  func useGroup(_ group: ReviewGroupCardModel) -> Bool {
    guard let c = group.suggestion?.id else { return false }
    return sortGroup(group, into: c, alwaysUse: false, project: nil)
  }

  @discardableResult
  func notThis(_ item: ReviewItem) -> Bool {
    let s = app.store.state
    let suggestion: CategoryID?
    let ref: MerchantGroupRef?
    switch item {
    case .single(let c):
      suggestion = c.suggestion?.id
      ref = s.txn(c.id)?.rejectionRef
    case .group(let g):
      suggestion = g.suggestion?.id
      ref = g.group
    }
    guard let suggestion, let ref, let name = s.category(suggestion)?.name else { return false }
    guard case .some(let token) = app.performQuietly(.notThis(ref, suggestion)) else { return false }
    notes[item.id] = RejectedNote(line: ReviewEngine.notThisLine(merchant: item.merchant, category: name), undo: token)
    return true
  }

  func undoNotThis(_ itemID: String) {
    guard let note = notes.removeValue(forKey: itemID), let undo = note.undo else { return }
    app.store.undo(undo)
  }

  func skipItem(_ item: ReviewItem) {
    for id in item.txnIDs { app.perform(.skipReview(id)) }
  }

  func undoResult() { app.undoSortResult() }

  func stopResultRule() { app.stopSortResultRule() }

  func dismissResult() { app.dismissSortResult() }

  @discardableResult
  func sort(_ card: TxnID, into category: CategoryID, alwaysUse: Bool, project: ProjectID?) -> Bool {
    var edits: [LedgerEdit] = []
    if app.store.state.txn(card)?.isHeldCopy == true { edits.append(.resolveCopy(card, merge: false)) }
    if app.store.state.txn(card)?.samePurchase != nil { edits.append(.resolveSamePurchase(card, same: false)) }
    edits.append(.categorize(card, category, learnRule: alwaysUse, project: project))
    guard app.perform(edits) else { return false }
    record(card, learnedRule: alwaysUse)
    return true
  }

  @discardableResult
  func useSuggestion(_ card: TxnID) -> Bool {
    guard let c = app.store.state.txn(card)?.reviewSuggestion else { return false }
    guard app.perform(.categorize(card, c, learnRule: false, project: nil)) else { return false }
    record(card, learnedRule: false)
    return true
  }

  func skip(_ card: TxnID) { app.perform(.skipReview(card)) }

  @discardableResult
  func resolveCopy(_ card: TxnID, merge: Bool) -> Bool { app.perform(.resolveCopy(card, merge: merge)) }

  @discardableResult
  func resolveSamePurchase(_ card: TxnID, same: Bool) -> Bool { app.perform(.resolveSamePurchase(card, same: same)) }

  @discardableResult
  func archive(_ card: TxnID) -> Bool { app.perform(.archive(card, true)) }

  func close(goToActivity: Bool) {
    app.cover = nil
    if goToActivity { app.tab = .activity }
  }

  private func record(_ id: TxnID, learnedRule: Bool) {
    sortedIDs.removeAll { $0 == id }
    sortedIDs.append(id)
    if learnedRule { learned.insert(id) } else { learned.remove(id) }
  }
}

extension ReviewDeckModel {
  /// What VoiceOver hears once a card is filed (Paper 16 · 06): "Filed as Need. 3 of 6.",
  /// or "Filed as Need. All caught up." for the last one.
  func filedAnnouncement(_ filedAs: String) -> String {
    let next = items.isEmpty ? "All caught up." : "\(position) of \(total)."
    return "Filed as \(filedAs). \(next)"
  }

  func groupFiledAnnouncement(_ group: ReviewGroupCardModel, as category: String) -> String {
    ReviewEngine.groupFiledAnnouncement(count: group.total, merchant: group.merchant, category: category, left: items.count)
  }
}

/// Where the next review session starts. A To sort row asks for its own card first; the
/// cover's route has no payload (`CoverRoute.review`, plan B7.2), so the request waits here
/// for the session the cover makes. (Stage I kept this rather than give the route a payload,
/// `requests/p6.md` 1: it works, its tests pass, and the change would touch every opener.)
@MainActor
enum ReviewEntry {
  private static weak var requester: AppModel?
  private static var start: TxnID?

  /// Opens the deck, at `card` when given, in the app's period.
  static func open(_ app: AppModel, at card: TxnID?) {
    request(app, at: card)
    app.startReview()
  }

  /// The next session for `app` starts at `card` (the cover opens it).
  static func request(_ app: AppModel, at card: TxnID?) {
    requester = app
    start = card
  }

  /// The card a new session for `app` starts at; the request is used up.
  static func take(for app: AppModel) -> TxnID? {
    defer {
      requester = nil
      start = nil
    }
    return requester === app ? start : nil
  }

  #if HASALA_MOCKS
    private static var script: ((ReviewViewModel) -> Void)?
    private static weak var scriptOwner: AppModel?

    /// Debug screen launches (`ScreenLaunch+Activity`): the steps a person takes once the
    /// deck is up (sort, use, open a pick sheet), run on the session's own model.
    static func onNextSession(of app: AppModel, _ steps: @escaping (ReviewViewModel) -> Void) {
      scriptOwner = app
      script = steps
    }

    static func takeScript(for app: AppModel) -> ((ReviewViewModel) -> Void)? {
      defer {
        script = nil
        scriptOwner = nil
      }
      return scriptOwner === app ? script : nil
    }
  #endif
}
