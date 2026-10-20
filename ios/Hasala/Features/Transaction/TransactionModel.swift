import HasalaModels
import Observation

/// One group of the category picker: a bucket's overline and its categories.
struct CategoryGroup: Identifiable, Hashable {
  var id: Bucket { bucket }
  let bucket: Bucket
  let options: [CategoryOption]

  static func all(_ s: LedgerState) -> [CategoryGroup] {
    var groups = [Bucket.needs, .wants, .savings].map { CategoryGroup(bucket: $0, options: s.categories(in: $0).map(CategoryOption.init)) }
    let other = s.categories.filter { $0.kind != .spending && !$0.archived }.map(CategoryOption.init)
    groups.append(CategoryGroup(bucket: .other, options: other))
    return groups
  }
}

/// Transaction detail and its pushed editors (spec 04 §16.1 "Transaction detail", "Choose a category", "Split";
/// §16.2 T1). Every write is one `LedgerEdit` (03c §3.8).
@MainActor
protocol TransactionModel: AnyObject, Observable {
  var detail: TransactionDetail? { get }
  var hidden: Bool { get }
  var categoryGroups: [CategoryGroup] { get }
  var projects: [(id: ProjectID, name: String)] { get }
  /// The merchant as it is now ("Lulu Hypermarket"), for "Always use X for M".
  var merchantName: String { get }
  func choose(_ category: CategoryID, alwaysUse: Bool)
  func setNote(_ note: String)
  func rename(_ name: String)
  @discardableResult func saveSplit(_ lines: [SplitLine]) -> Bool
  func removeSplit()
  func toggleRefund()
  func markTransfer()
  func setArchived(_ archived: Bool)
}

@MainActor
@Observable
final class TransactionViewModel: TransactionModel {
  private let app: AppModel
  let id: TxnID
  @ObservationIgnored private var memo = Memo<Int, TransactionDetail?>()

  init(app: AppModel, id: TxnID) {
    self.app = app
    self.id = id
  }

  var detail: TransactionDetail? {
    memo.value(for: app.store.revision) { TransactionEngine.detail(id, app.store.state, now: app.store.now) }
  }
  var hidden: Bool { app.amountsHidden }
  var merchantName: String { app.store.state.txn(id)?.merchant ?? "" }

  var categoryGroups: [CategoryGroup] { CategoryGroup.all(app.store.state) }

  var projects: [(id: ProjectID, name: String)] {
    app.store.state.projects.filter { !$0.complete }.map { ($0.id, $0.name) }
  }

  func choose(_ category: CategoryID, alwaysUse: Bool) {
    app.perform(.categorize(id, category, learnRule: alwaysUse, project: nil))
  }

  func setNote(_ note: String) { app.perform(.setNote(id, note)) }
  func rename(_ name: String) { app.perform(.renameMerchant(id, name)) }
  @discardableResult func saveSplit(_ lines: [SplitLine]) -> Bool { app.perform(.split(id, lines)) }
  func removeSplit() { app.perform(.split(id, [])) }
  func toggleRefund() { app.perform(.markRefund(id)) }
  func markTransfer() { app.perform(.markTransfer(id)) }

  func setArchived(_ archived: Bool) {
    if app.perform(.archive(id, archived)), archived { app.sheet = nil }
  }
}
