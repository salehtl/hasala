import HasalaDesign
import HasalaModels
import Observation

/// Activity · Overview and Filtered (Paper 1QG-0, 7LT-0). Views bind to this protocol;
/// `ActivityViewModel` is the one implementation, over any `LedgerStore` (the Maya mock in
/// Debug, the projection in every real build).
@MainActor
protocol ActivityModel: AnyObject, Observable {
  var snapshot: ActivitySnapshot { get }
  var hidden: Bool { get }
  var searchText: String { get }
  var exportRows: [ExportRow] { get }
  func select(_ kind: TxnFilter.Kind)
  func search(_ text: String)
  /// Narrows the list to one category ("Activity · Filtered"); nil goes back to everything.
  func show(category: CategoryID?)
  /// Shows exactly this filter (a request from Search).
  func apply(_ filter: TxnFilter)
  func choosePeriod()
  func backToThisMonth()
  func open(_ txn: TxnID)
  func openBill(_ bill: BillID)
  func startReview()
  func addTransaction()
}

@MainActor
@Observable
final class ActivityViewModel: ActivityModel {
  private let app: AppModel
  private(set) var filter: TxnFilter
  @ObservationIgnored private var memo = Memo<[AnyHashable], ActivitySnapshot>()
  @ObservationIgnored private var exportMemo = Memo<[AnyHashable], [ExportRow]>()

  init(app: AppModel, filter: TxnFilter = .all) {
    self.app = app
    self.filter = filter
  }

  var snapshot: ActivitySnapshot {
    let period = app.period
    return memo.value(for: [app.store.revision, filter, period]) {
      ActivityEngine.snapshot(app.store.state, now: app.store.now, filter: filter, period: period)
    }
  }
  var hidden: Bool { app.amountsHidden }
  var searchText: String { filter.text }

  /// The rows "Export" shares: what the list shows.
  var exportRows: [ExportRow] {
    exportMemo.value(for: [app.store.revision, filter, app.period]) {
      let s = app.store.state
      let snap = snapshot
      let ids = Set(snap.days.flatMap(\.rows).map(\.id) + snap.rows.map(\.id))
      return s.txns.filter { ids.contains($0.id) }.map { ExportRow($0, s) }
    }
  }

  func select(_ kind: TxnFilter.Kind) { filter.kind = kind }
  func search(_ text: String) { filter.text = text }

  func show(category: CategoryID?) {
    filter = TxnFilter(kind: .all, category: category, text: "")
  }

  func apply(_ filter: TxnFilter) { self.filter = filter }

  func choosePeriod() { app.sheet = .period }
  func backToThisMonth() { app.period = .month(app.store.now.date.yearMonth) }

  func open(_ txn: TxnID) { app.open(txn) }
  func openBill(_ bill: BillID) { app.router.activity.append(.bill(bill)) }
  func startReview() { ReviewEntry.open(app, at: nil) }

  func addTransaction() { app.router.open(.addTransaction) }
}

/// Asks the Activity tab to show a filter from elsewhere (Search's category row, a Debug
/// screen launch). The Activity view model lives in the shell (`MainView`, frozen), so a
/// request waits here until the Activity screen applies it.
@MainActor
@Observable
final class ActivityRequests {
  static let shared = ActivityRequests()

  private(set) var pending: (app: ObjectIdentifier, filter: TxnFilter)?

  /// Switches to Activity, at its root, showing `filter` (a category, or a search's text).
  func show(_ filter: TxnFilter, in app: AppModel) {
    pending = (ObjectIdentifier(app), filter)
    app.router.activity = []
    app.tab = .activity
  }

  /// The filter waiting for `app`'s Activity screen; the request is used up.
  func take(for app: AppModel) -> TxnFilter? {
    guard let p = pending, p.app == ObjectIdentifier(app) else { return nil }
    pending = nil
    return p.filter
  }
}
