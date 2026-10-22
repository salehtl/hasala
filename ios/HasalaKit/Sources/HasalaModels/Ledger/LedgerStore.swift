import Foundation
import Observation

// The write surface and the read seam every screen view model uses (spec 04 §15.1:
// `XSource` reads, `LedgerActions` writes). One `LedgerEdit` per user gesture; the
// live store maps each to the ops of 03a/03b/03c (one blob per edit, 03c §3.8) and
// returns an undo token where Paper shows Undo. The Maya mock applies them in memory.
//
// TODO(spec 04 §2.2): these move to the HasalaContracts module once it exists; they
// live in HasalaModels so the app and HasalaMocks can share them without a new target.

/// One user gesture that changes the ledger.
public enum LedgerEdit: Sendable, Hashable {
  // Transactions (03c §3.8).
  case addTransaction(ManualEntryDraft)
  /// `txn_categorized` (+ learned `rule_added` when `learnRule`, + `txn_annotated{project_id}`).
  case categorize(TxnID, CategoryID, learnRule: Bool, project: ProjectID?)
  case useSuggestions([SuggestionUse])
  /// `txn_categorized{transfer}`.
  case markTransfer(TxnID)
  /// `txn_categorized{refunds}` + `txn_annotated{refund_of}`.
  case markRefund(TxnID)
  /// `txn_annotated{note}`.
  case setNote(TxnID, String)
  /// `merchant_named{key, name}`.
  case renameMerchant(TxnID, String)
  /// `txn_split{parts}`; an empty array removes the split.
  case split(TxnID, [SplitLine])
  /// `txn_annotated{archived}`.
  case archive(TxnID, Bool)
  case resolveCopy(TxnID, merge: Bool)
  case resolveSamePurchase(TxnID, same: Bool)
  /// Review "Skip for now": device-local until the next local midnight (no op).
  case skipReview(TxnID)

  case saveProject(ProjectID, ProjectDraft)
  case setProjectCountInPlan(ProjectID, Bool)
  case completeProject(ProjectID, Bool)
  case removeProject(ProjectID)
  case assignProject([TxnID], ProjectID?)

  // Plan (03a §3.2, §3.3).
  /// `budget_set`.
  case setBudget(CategoryID, YearMonth, Money)
  /// `budget_moved`; `from == nil` takes it from Ready to assign.
  case moveMoney(from: CategoryID?, to: CategoryID, YearMonth, Money)

  // Bills (03b §3.2, §3.3).
  /// `bill_set` from a detector proposal.
  case trackCandidate(String)
  /// Dismiss a detector proposal (device-local until the detector re-proposes).
  case dismissCandidate(String)
  /// `bill_occurrence_set{paid}` for the current occurrence.
  case markBillPaid(BillID)
  /// `bill_set{amount}`: accept the new amount after a price change.
  case acceptBillAmount(BillID)
  /// `bill_set{stopped}`.
  case stopTrackingBill(BillID)

  // Rules (03c §5.5).
  /// `rule_added{enabled}`.
  case setRuleEnabled(RuleID, Bool)

  case addCategory(CategoryDraft)
  case editCategory(CategoryID, CategoryDraft)
  case archiveCategory(CategoryID, moveTo: CategoryID?)
  case restoreCategory(CategoryID)

  case setRate(currency: String, rateMicro: Int64)
  case unsetRate(currency: String)

  // Device preferences (spec 04 §4.5; never synced).
  case setNotifications(DevicePrefs.NotificationLevel)
  case setFaceIDLock(Bool)

  case setDisplayName(String)
}

public struct SuggestionUse: Sendable, Hashable {
  public var txn: TxnID
  public var category: CategoryID

  public init(txn: TxnID, category: CategoryID) {
    self.txn = txn
    self.category = category
  }
}

public struct ManualEntryDraft: Sendable, Hashable {
  public var amount: Money
  public var direction: Direction
  public var merchant: String
  public var categoryID: CategoryID?
  public var postedAt: LocalDateTime
  public var accountID: AccountID?

  public init(
    amount: Money, direction: Direction = .out, merchant: String, categoryID: CategoryID?, postedAt: LocalDateTime,
    accountID: AccountID? = nil
  ) {
    self.amount = amount
    self.direction = direction
    self.merchant = merchant
    self.categoryID = categoryID
    self.postedAt = postedAt
    self.accountID = accountID
  }

  public static let maxMerchantLength = 80
  public static let maxMinor: Int64 = 999_999_999_99

  public var trimmedMerchant: String { merchant.trimmedSpaces }

  public var refusal: ActionError? {
    if amount.minor <= 0 || amount.minor > Self.maxMinor { return .invalidAmount }
    if trimmedMerchant.isEmpty || trimmedMerchant.count > Self.maxMerchantLength { return .invalidMerchant }
    return nil
  }

  public func txn(id: TxnID) -> Txn {
    Txn(
      id: id, merchant: trimmedMerchant, amount: amount, direction: direction, postedAt: postedAt, accountID: accountID,
      categoryID: categoryID, categorySource: categoryID == nil ? nil : .user, isRefund: categoryID == "refunds",
      isTransfer: categoryID == "transfer")
  }
}

/// An edit the person can take back from the toast (spec 04 §14.6: 5 s window).
public struct UndoToken: Sendable, Hashable, Identifiable {
  public var id: Int
  /// The toast's line: "Sorted into Groceries".
  public var title: String

  public init(id: Int, title: String) {
    self.id = id
    self.title = title
  }
}

/// A content-free refusal (spec 04 §15.1 `ActionError`).
public enum ActionError: Error, Sendable, Hashable {
  case notFound
  /// Split lines do not add up to the transaction (`validateSplitDraft`).
  case splitDoesNotAddUp
  /// Not enough money in the source to move.
  case insufficientFunds
  case invalidAmount
  case invalidProject
  case invalidMerchant
  case refused(String)
}

public struct CategoryDraft: Sendable, Hashable {
  public var name: String
  public var glyph: Glyph
  public var parent: CategoryID?

  public init(name: String, glyph: Glyph = .tag, parent: CategoryID? = nil) {
    self.name = name
    self.glyph = glyph
    self.parent = parent
  }

  public var trimmedName: String { name.trimmedSpaces }
}

/// The ledger the screens read and write. `state` changes on every projection commit
/// (live) or every applied edit (mock), and Observation tracks it.
@MainActor
public protocol LedgerStore: AnyObject, Observable {
  var state: LedgerState { get }
  /// "Now" in the fixed local clock (spec 04 §15.5).
  var now: LocalDateTime { get }
  /// Changes whenever `state` or `now` does. Screens key their derived snapshots by it, so an
  /// engine runs once per ledger change rather than once per read (spec 04 §18.3).
  var revision: Int { get }
  /// Applies one edit; returns an undo token when the edit can be undone from a toast.
  @discardableResult
  func apply(_ edit: LedgerEdit) throws(ActionError) -> UndoToken?
  /// Reverts the edit behind `token` (03c §3.8 "Undo (toast)": inverse ops).
  func undo(_ token: UndoToken)
  func newProjectID() -> ProjectID
}

public extension LedgerStore {
  var month: YearMonth { now.date.yearMonth }
  func newProjectID() -> ProjectID { "p-" + UUID().uuidString.lowercased() }
}
