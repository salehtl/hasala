import HasalaModels
import Observation

/// Activity · Overview and Filtered (spec 04 §16.1 "Activity · Overview", "Activity · Filtered"; §15.1 pattern).
/// Views bind to this protocol; `ActivityViewModel` is the one implementation, over any
/// `LedgerStore` (the Maya mock now, the projection later).
@MainActor
protocol ActivityModel: AnyObject, Observable {
  var snapshot: ActivitySnapshot { get }
  var hidden: Bool { get }
  var searchText: String { get }
  var exportRows: [ExportRow] { get }
  func select(_ kind: TxnFilter.Kind)
  func search(_ text: String)
  func open(_ txn: TxnID)
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
    memo.value(for: [app.store.revision, filter]) {
      ActivityEngine.snapshot(app.store.state, now: app.store.now, filter: filter)
    }
  }
  var hidden: Bool { app.amountsHidden }
  var searchText: String { filter.text }

  /// The rows "Export" shares: what the list shows.
  var exportRows: [ExportRow] {
    exportMemo.value(for: [app.store.revision, filter]) {
      let s = app.store.state
      let ids = Set(snapshot.days.flatMap(\.rows).map(\.id))
      return s.txns.filter { ids.contains($0.id) }.map { ExportRow($0, s) }
    }
  }

  func select(_ kind: TxnFilter.Kind) { filter.kind = kind }
  func search(_ text: String) { filter.text = text }
  func open(_ txn: TxnID) { app.open(txn) }
  func startReview() { app.startReview() }

  // TODO(spec 04 §16.1 "Add transaction"): AddTransactionSheet (keypad, merchant, category, date,
  // paid with) authoring `txn_ingested` with entry_method manual.
  func addTransaction() {
    app.say("Adding by hand arrives in a later build", systemImage: "plus")
  }
}
