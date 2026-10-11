import HasalaModels
import Observation

/// Review · Deck, Pick a need, All caught up (spec 04 §16.1 "Review · Deck", "Pick a need", "All caught up").
/// One session runs from opening the cover to closing it; "2 of 6" counts within it.
@MainActor
protocol ReviewDeckModel: AnyObject, Observable {
  /// The cards still to sort, the top card first.
  var cards: [ReviewCardModel] { get }
  /// 1-based position of the top card in this session, and the session's size.
  var position: Int { get }
  var total: Int { get }
  /// What this session sorted, for All caught up.
  var sorted: [SortedLine] { get }
  var hidden: Bool { get }
  var needOnRight: Bool { get }
  var projects: [(id: ProjectID, name: String)] { get }
  func options(for choice: ReviewChoice, card: TxnID) -> [CategoryOption]
  func sort(_ card: TxnID, into category: CategoryID, alwaysUse: Bool, project: ProjectID?)
  func useSuggestion(_ card: TxnID)
  func skip(_ card: TxnID)
  func close(goToActivity: Bool)
}

@MainActor
@Observable
final class ReviewViewModel: ReviewDeckModel {
  private let app: AppModel
  private var sortedIDs: [TxnID] = []
  private var learned: Set<TxnID> = []
  let total: Int

  init(app: AppModel) {
    self.app = app
    total = ReviewEngine.queue(app.store.state).count
  }

  var cards: [ReviewCardModel] { ReviewEngine.cards(app.store.state) }
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
    // The suggestion leads its bucket's list (Paper "Pick a need" board: "Suggested").
    if let sug = s.txn(card)?.suggestion, let i = options.firstIndex(where: { $0.id == sug }) {
      options.insert(options.remove(at: i), at: 0)
    }
    return options
  }

  func sort(_ card: TxnID, into category: CategoryID, alwaysUse: Bool, project: ProjectID?) {
    let rulesBefore = app.store.state.rules.count
    guard app.perform(.categorize(card, category, learnRule: alwaysUse, project: project)) else { return }
    record(card, learnedRule: app.store.state.rules.count > rulesBefore)
  }

  func useSuggestion(_ card: TxnID) {
    guard let c = app.store.state.txn(card)?.suggestion else { return }
    guard app.perform(.categorize(card, c, learnRule: false, project: nil)) else { return }
    record(card, learnedRule: false)
  }

  func skip(_ card: TxnID) { app.perform(.skipReview(card)) }

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
