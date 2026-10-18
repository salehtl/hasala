import HasalaModels
import Observation
import SwiftUI

/// A pick sheet that is up: which card, and the direction it was sent ("Need · which one?").
struct ReviewPick: Identifiable, Hashable {
  let card: ReviewCardModel
  let choice: ReviewChoice
  var id: String { card.id + "." + choice.rawValue }
}

/// Review · Deck, Pick a need, All caught up (Paper 26H-0, 3SH-0, 4MY-0). One session runs
/// from opening the cover to closing it; "2 of 6" counts within it. Every sort is one
/// `LedgerEdit` through `AppModel.perform`, so it has its toast and its Undo.
@MainActor
protocol ReviewDeckModel: AnyObject, Observable {
  /// The cards still to sort, in this session's order, the top card first.
  var cards: [ReviewCardModel] { get }
  /// 1-based position of the top card in this session, and the session's size.
  var position: Int { get }
  var total: Int { get }
  /// What this session sorted, for All caught up.
  var sorted: [SortedLine] { get }
  var hidden: Bool { get }
  var needOnRight: Bool { get }
  var projects: [(id: ProjectID, name: String)] { get }
  /// The pick sheet that is up, if any. Setting nil closes it without sorting.
  var picking: ReviewPick? { get set }
  /// All caught up celebrates once a session (motion policy: a rare moment may delight).
  var celebrated: Bool { get set }
  func options(for choice: ReviewChoice, card: TxnID) -> [CategoryOption]
  /// A swipe or a pill sent the card one way: ask which category.
  func pick(_ card: TxnID, _ choice: ReviewChoice)
  @discardableResult func sort(_ card: TxnID, into category: CategoryID, alwaysUse: Bool, project: ProjectID?) -> Bool
  @discardableResult func useSuggestion(_ card: TxnID) -> Bool
  func skip(_ card: TxnID)
  @discardableResult func archive(_ card: TxnID) -> Bool
  func close(goToActivity: Bool)
}

@MainActor
@Observable
final class ReviewViewModel: ReviewDeckModel {
  private let app: AppModel
  private var sortedIDs: [TxnID] = []
  private var learned: Set<TxnID> = []
  /// The order this session reads the queue in: oldest first, or from the row that opened it.
  private let order: [TxnID]
  let total: Int
  var picking: ReviewPick?
  var celebrated = false
  @ObservationIgnored private var memo = Memo<Int, [ReviewCardModel]>()

  init(app: AppModel) {
    self.app = app
    let queue = ReviewEngine.queue(app.store.state).map(\.id)
    total = queue.count
    order = ReviewEngine.order(queue, startingAt: ReviewEntry.take(for: app))
    #if HASALA_MOCKS
      ReviewEntry.takeScript(for: app)?(self)
    #endif
  }

  /// The queue as it stands, in the session's order. A card that arrives mid-session goes
  /// last; a card that Undo puts back takes its old place.
  var cards: [ReviewCardModel] {
    memo.value(for: app.store.revision) {
      let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
      return ReviewEngine.cards(app.store.state).enumerated()
        .sorted { (rank[$0.element.id] ?? order.count + $0.offset) < (rank[$1.element.id] ?? order.count + $1.offset) }
        .map(\.element)
    }
  }

  var position: Int { min(total, max(1, total - cards.count + 1)) }
  var hidden: Bool { app.amountsHidden }
  var needOnRight: Bool { app.store.state.prefs.swipeNeedOnRight }

  var projects: [(id: ProjectID, name: String)] {
    app.store.state.projects.filter { !$0.complete }.map { ($0.id, $0.name) }
  }

  /// Sorted in this session and not undone since.
  var sorted: [SortedLine] {
    let s = app.store.state
    return sortedIDs.compactMap { id in
      guard let t = s.txn(id), !t.needsReview, let c = s.category(t.categoryID) else { return nil }
      return ReviewEngine.sortedLine(t, into: c, learnedRule: learned.contains(id))
    }
  }

  func options(for choice: ReviewChoice, card: TxnID) -> [CategoryOption] {
    let s = app.store.state
    var options = ReviewEngine.options(for: choice, s, txn: s.txn(card))
    // The suggestion leads its bucket's list (Paper "Pick a need": "Suggested").
    if let sug = s.txn(card)?.suggestion, let i = options.firstIndex(where: { $0.id == sug }) {
      options.insert(options.remove(at: i), at: 0)
    }
    return options
  }

  func pick(_ card: TxnID, _ choice: ReviewChoice) {
    guard let c = cards.first(where: { $0.id == card }) else { return }
    picking = ReviewPick(card: c, choice: choice)
  }

  @discardableResult
  func sort(_ card: TxnID, into category: CategoryID, alwaysUse: Bool, project: ProjectID?) -> Bool {
    let rulesBefore = app.store.state.rules.count
    guard app.perform(.categorize(card, category, learnRule: alwaysUse, project: project)) else { return false }
    record(card, learnedRule: app.store.state.rules.count > rulesBefore)
    return true
  }

  @discardableResult
  func useSuggestion(_ card: TxnID) -> Bool {
    guard let c = app.store.state.txn(card)?.suggestion else { return false }
    guard app.perform(.categorize(card, c, learnRule: false, project: nil)) else { return false }
    record(card, learnedRule: false)
    return true
  }

  func skip(_ card: TxnID) { app.perform(.skipReview(card)) }

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
    let next = cards.isEmpty ? "All caught up." : "\(position) of \(total)."
    return "Filed as \(filedAs). \(next)"
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

  /// Opens the deck, at `card` when given.
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
