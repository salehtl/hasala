import HasalaDesign
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
  /// The pick sheet that is up, if any. Setting nil closes it without sorting.
  var picking: ReviewPick? { get set }
  var holding: TxnID? { get set }
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
  func newCategory(for choice: ReviewChoice, card: TxnID) -> CountsAsOption?
  func newCategoryRefusal(_ card: TxnID, _ choice: ReviewChoice, name: String, glyph: Glyph) -> String?
  @discardableResult func createAndSort(
    _ card: TxnID, _ choice: ReviewChoice, name: String, glyph: Glyph, alwaysUse: Bool, project: ProjectID?
  ) -> Bool
  @discardableResult func useSuggestion(_ card: TxnID, shown: CategoryID?) -> Bool
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
  var holding: TxnID?
  var celebrated = false
  @ObservationIgnored private var shown: TxnID?
  @ObservationIgnored private var memo = Memo<CardsKey, [ReviewCardModel]>()

  private struct CardsKey: Equatable {
    let revision: Int
    let window: ReviewWindow
    let held: TxnID?
  }

  init(app: AppModel) {
    self.app = app
    let start = ReviewEntry.take(for: app)
    let window = app.reviewWindow
    self.window = window
    let queue = ReviewEngine.queue(app.store.state, in: window).map(\.id)
    total = queue.count
    order = ReviewEngine.order(queue, startingAt: start)
    #if HASALA_MOCKS
      ReviewEntry.takeScript(for: app)?(self)
    #endif
  }

  var cards: [ReviewCardModel] {
    let held = picking?.card.id ?? holding
    return memo.value(for: CardsKey(revision: app.store.revision, window: window, held: held)) {
      let s = app.store.state
      let out = Self.steady(order, waiting: ReviewEngine.queue(s, in: window), held: held, shown: shown, s)
      if let top = out.first?.id { shown = top }
      return out
    }
  }

  nonisolated static func steady(
    _ order: [TxnID], waiting: [Txn], held: TxnID?, shown: TxnID?, _ s: LedgerState
  ) -> [ReviewCardModel] {
    let open = Dictionary(waiting.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    var out = order.compactMap { id in (open[id] ?? (id == shown ? s.txn(id) : nil)).map { ReviewEngine.card($0, s) } }
    guard let held, order.contains(held), let t = s.txn(held) else { return out }
    out.removeAll { $0.id == held }
    out.insert(ReviewEngine.card(t, s), at: 0)
    return out
  }

  var position: Int {
    guard let top = cards.first, let i = order.firstIndex(of: top.id) else { return total }
    return i + 1
  }

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
    let top = cards.first?.id
    window = app.reviewWindow
    let queue = ReviewEngine.queue(app.store.state, in: window).map(\.id)
    total = queue.count
    order = ReviewEngine.order(queue, startingAt: top)
    shown = nil
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
    return ReviewEngine.options(for: choice, s, txn: s.txn(card))
  }

  func pick(_ card: TxnID, _ choice: ReviewChoice) {
    guard let c = cards.first(where: { $0.id == card }) ?? app.store.state.txn(card).map({ ReviewEngine.card($0, app.store.state) })
    else { return }
    picking = ReviewPick(card: c, choice: choice)
  }

  @discardableResult
  func sort(_ card: TxnID, into category: CategoryID, alwaysUse: Bool, project: ProjectID?) -> Bool {
    guard app.perform(settling(card) + [.categorize(card, category, learnRule: alwaysUse, project: project)]) else {
      return false
    }
    filed(card, learnedRule: alwaysUse)
    return true
  }

  func newCategory(for choice: ReviewChoice, card: TxnID) -> CountsAsOption? {
    let s = app.store.state
    guard CategoriesEngine.activeCustomCount(s) < CategoryLimits.maxActiveCustom else { return nil }
    return Self.parentOffer(for: choice, card: card, s)
  }

  private static func parentOffer(for choice: ReviewChoice, card: TxnID, _ s: LedgerState) -> CountsAsOption? {
    guard let bucket = choice.bucket, s.txn(card)?.direction == .out else { return nil }
    return CategoriesEngine.countsAsOptions(s, keeping: []).first { $0.bucket == bucket }
  }

  func newCategoryRefusal(_ card: TxnID, _ choice: ReviewChoice, name: String, glyph: Glyph) -> String? {
    guard case .failure(let error) = newCategoryEdit(card, choice, name: name, glyph: glyph, alwaysUse: false, project: nil)
    else { return nil }
    return AppModel.message(for: error)
  }

  @discardableResult
  func createAndSort(
    _ card: TxnID, _ choice: ReviewChoice, name: String, glyph: Glyph, alwaysUse: Bool, project: ProjectID?
  ) -> Bool {
    switch newCategoryEdit(card, choice, name: name, glyph: glyph, alwaysUse: alwaysUse, project: project) {
    case .failure(let error):
      app.say(AppModel.message(for: error), icon: .info)
      return false
    case .success(let edit):
      guard app.perform(settling(card) + [edit]) else { return false }
      filed(card, learnedRule: alwaysUse)
      return true
    }
  }

  private func newCategoryEdit(
    _ card: TxnID, _ choice: ReviewChoice, name: String, glyph: Glyph, alwaysUse: Bool, project: ProjectID?
  ) -> Result<LedgerEdit, ActionError> {
    let s = app.store.state
    guard s.txn(card) != nil else { return .failure(.notFound) }
    guard let parent = Self.parentOffer(for: choice, card: card, s)?.parent else {
      return .failure(.refused(CategoryLimits.cannotAdd))
    }
    let edit = LedgerEdit.addCategoryAndSort(
      CategoryDraft(name: name, glyph: glyph, parent: parent), card, alwaysUse: alwaysUse, project: project)
    do {
      if let why = try app.store.categoryRefusal(edit) { return .failure(.refused(why)) }
    } catch {
      return .failure(error)
    }
    return .success(edit)
  }

  private func settling(_ card: TxnID) -> [LedgerEdit] {
    let t = app.store.state.txn(card)
    var edits: [LedgerEdit] = []
    if t?.isHeldCopy == true { edits.append(.resolveCopy(card, merge: false)) }
    if t?.samePurchase != nil { edits.append(.resolveSamePurchase(card, same: false)) }
    return edits
  }

  private func filed(_ card: TxnID, learnedRule: Bool) {
    follow(card)
    passed(card)
    record(card, learnedRule: learnedRule)
  }

  @discardableResult
  func useSuggestion(_ card: TxnID, shown: CategoryID?) -> Bool {
    let s = app.store.state
    guard let t = s.txn(card), let c = ReviewEngine.suggestion(t, s)?.id, shown == nil || shown == c else { return false }
    guard app.perform(.categorize(card, c, learnRule: false, project: nil)) else { return false }
    filed(card, learnedRule: false)
    return true
  }

  private func follow(_ card: TxnID) {
    let s = app.store.state
    guard let ref = s.txn(card)?.groupRef else { return }
    let next = Self.following(order, after: card, ref: ref, waiting: ReviewEngine.queue(s, in: window))
    guard next != order else { return }
    order = next
    memo = Memo()
  }

  nonisolated static func following(_ order: [TxnID], after card: TxnID, ref: MerchantGroupRef, waiting: [Txn]) -> [TxnID] {
    guard let i = order.firstIndex(of: card) else { return order }
    let same = Set(waiting.filter { $0.groupRef == ref && $0.id != card }.map(\.id))
    let rest = order[(i + 1)...]
    let next = rest.filter { same.contains($0) }
    guard !next.isEmpty else { return order }
    return Array(order[...i]) + next + rest.filter { !same.contains($0) }
  }

  func skip(_ card: TxnID) { passed(card, app.perform(.skipReview(card))) }

  @discardableResult
  func resolveCopy(_ card: TxnID, merge: Bool) -> Bool { passed(card, app.perform(.resolveCopy(card, merge: merge))) }

  @discardableResult
  func resolveSamePurchase(_ card: TxnID, same: Bool) -> Bool {
    passed(card, app.perform(.resolveSamePurchase(card, same: same)))
  }

  @discardableResult
  func archive(_ card: TxnID) -> Bool { passed(card, app.perform(.archive(card, true))) }

  func close(goToActivity: Bool) {
    app.cover = nil
    if goToActivity { app.tab = .activity }
  }

  @discardableResult
  private func passed(_ card: TxnID, _ done: Bool = true) -> Bool {
    if done, shown == card {
      shown = nil
      memo = Memo()
    }
    return done
  }

  private func record(_ id: TxnID, learnedRule: Bool) {
    sortedIDs.removeAll { $0 == id }
    sortedIDs.append(id)
    if learnedRule { learned.insert(id) } else { learned.remove(id) }
  }
}

extension ReviewDeckModel {
  @discardableResult func useSuggestion(_ card: TxnID) -> Bool { useSuggestion(card, shown: nil) }

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
