import HasalaModels
import Observation

/// A `LedgerStore` that applies edits to an in-memory `LedgerState` (spec 04 §15.3:
/// "MayaLedger is mutable: actions change its in-memory state and emit new snapshots,
/// so UI tests can walk flows without a server"). Debug builds, previews and tests only.
///
/// The live store (TODO spec 04 §15.2) authors the same edits as ops through
/// `OpAuthor` + `Outbox` and reads `state` back from the projection.
@MainActor
@Observable
public final class InMemoryLedger: LedgerStore {
  public private(set) var state: LedgerState
  public private(set) var now: LocalDateTime

  /// What an undo puts back: the records an edit touched, as they were before it.
  private struct UndoRecord {
    var txns: [Txn] = []
    var plan: PlanState?
    var bills: [Bill]?
    var candidates: [BillCandidate]?
    var rules: [Rule]?
  }

  private var undoRecords: [Int: UndoRecord] = [:]
  private var nextToken = 1

  public init(state: LedgerState = MayaLedger.state, now: LocalDateTime = MayaLedger.now) {
    self.state = state
    self.now = now
  }

  @discardableResult
  public func apply(_ edit: LedgerEdit) throws(ActionError) -> UndoToken? {
    var s = state
    var record = UndoRecord()
    let title: String?

    func editTxn(_ id: TxnID, _ change: (inout Txn) -> Void) throws(ActionError) {
      guard let i = s.txns.firstIndex(where: { $0.id == id }) else { throw .notFound }
      record.txns.append(s.txns[i])
      change(&s.txns[i])
    }

    func categoryName(_ id: CategoryID) -> String { s.category(id)?.name ?? "Uncategorized" }

    switch edit {
    case .categorize(let id, let c, let learnRule, let project):
      guard s.category(c) != nil else { throw .notFound }
      try editTxn(id) { t in
        t.categoryID = c
        t.categorySource = .user
        t.needsReview = false
        t.isTransfer = c == "transfer"
        t.splits = []
        if let project { t.projectID = project }
      }
      if learnRule, let t = s.txn(id), !s.rules.contains(where: { $0.matches(t.merchant) }) {
        record.rules = s.rules
        s.rules.append(Rule(id: "learned-\(id)", patterns: [t.merchant.lowercased()], categoryID: c,
                            learnedToday: true))
      }
      title = "Sorted into \(categoryName(c))"
    case .markTransfer(let id):
      try editTxn(id) { t in
        t.categoryID = "transfer"
        t.categorySource = .user
        t.isTransfer = true
        t.needsReview = false
      }
      title = "Marked as a transfer"
    case .markRefund(let id):
      try editTxn(id) { t in
        t.isRefund.toggle()
        t.direction = t.isRefund ? .in : .out
      }
      title = s.txn(id)?.isRefund == true ? "Marked as a refund" : "No longer a refund"
    case .setNote(let id, let note):
      try editTxn(id) { $0.note = note.trimmedSpaces }
      title = nil
    case .renameMerchant(let id, let name):
      let name = name.trimmedSpaces
      guard !name.isEmpty, let old = s.txn(id)?.merchant else { throw .notFound }
      for i in s.txns.indices where s.txns[i].merchant == old {
        record.txns.append(s.txns[i])
        s.txns[i].merchant = name
      }
      title = "Renamed to \(name)"
    case .split(let id, let lines):
      guard let t = s.txn(id) else { throw .notFound }
      if !lines.isEmpty, !TransactionEngine.splitAddsUp(lines, total: t.amount) { throw .splitDoesNotAddUp }
      try editTxn(id) { t in
        t.splits = lines
        if let first = lines.first { t.categoryID = first.categoryID }
        t.needsReview = false
      }
      title = lines.isEmpty ? "Split removed" : "Split into \(lines.count) categories"
    case .archive(let id, let archived):
      try editTxn(id) { $0.archived = archived }
      title = archived ? "Archived" : "Restored"
    case .skipReview(let id):
      s.skippedReview.insert(id)
      title = nil

    case .setBudget(let c, let month, let amount):
      guard amount.minor >= 0 else { throw .invalidAmount }
      record.plan = s.plan
      s.plan.budgets[PlanState.key(c, month)] = amount
      title = "\(categoryName(c)) budget changed"
    case .moveMoney(let from, let to, let month, let amount):
      guard amount.minor > 0 else { throw .invalidAmount }
      let plan = PlanEngine.snapshot(s, now: now)
      if let from {
        let left = s.plan.budget(from, month).minor - s.spent(from, in: month).minor
        guard left >= amount.minor else { throw .insufficientFunds }
      } else {
        guard plan.readyToAssign.minor >= amount.minor else { throw .insufficientFunds }
      }
      record.plan = s.plan
      if let from {
        s.plan.budgets[PlanState.key(from, month)] = .aed(s.plan.budget(from, month).minor - amount.minor)
      }
      s.plan.budgets[PlanState.key(to, month)] = .aed(s.plan.budget(to, month).minor + amount.minor)
      title = "Moved to \(categoryName(to))"

    case .trackCandidate(let id):
      guard let c = s.billCandidates.first(where: { $0.id == id }) else { throw .notFound }
      record.candidates = s.billCandidates
      record.bills = s.bills
      s.billCandidates.removeAll { $0.id == id }
      let next = c.last.adding(days: c.everyDays)
      s.bills.append(Bill(id: "bill-\(id)", name: c.name, kind: categoryName(c.categoryID), categoryID: c.categoryID,
                          amount: c.amount, usualDay: c.last.day, nextDue: next, history: [c.last]))
      title = "Tracking \(c.name)"
    case .dismissCandidate(let id):
      guard s.billCandidates.contains(where: { $0.id == id }) else { throw .notFound }
      record.candidates = s.billCandidates
      s.billCandidates.removeAll { $0.id == id }
      title = "Dismissed"
    case .markBillPaid(let id):
      guard let i = s.bills.firstIndex(where: { $0.id == id }) else { throw .notFound }
      record.bills = s.bills
      let due = s.bills[i].nextDue
      let next = due.yearMonth.next
      s.bills[i].history.insert(due, at: 0)
      s.bills[i].nextDue = LocalDate(next.year, next.month, min(s.bills[i].usualDay, next.days))
      title = "\(s.bills[i].name) marked paid"
    case .acceptBillAmount(let id):
      guard let i = s.bills.firstIndex(where: { $0.id == id }) else { throw .notFound }
      record.bills = s.bills
      s.bills[i].priceChangeFrom = nil
      title = "New amount accepted"
    case .stopTrackingBill(let id):
      guard let i = s.bills.firstIndex(where: { $0.id == id }) else { throw .notFound }
      record.bills = s.bills
      s.bills[i].state = .dismissed
      title = "Stopped tracking \(s.bills[i].name)"

    case .setRuleEnabled(let id, let enabled):
      guard let i = s.rules.firstIndex(where: { $0.id == id }) else { throw .notFound }
      s.rules[i].enabled = enabled
      title = nil
    case .setNotifications(let level):
      s.prefs.notifications = level
      title = nil
    case .setFaceIDLock(let on):
      s.prefs.faceIDLock = on
      title = nil
    }

    state = s
    guard let title else { return nil }
    let token = UndoToken(id: nextToken, title: title)
    nextToken += 1
    undoRecords[token.id] = record
    return token
  }

  public func undo(_ token: UndoToken) {
    guard let r = undoRecords.removeValue(forKey: token.id) else { return }
    var s = state
    // Restore in reverse so a record that touched a row twice ends at its oldest value.
    for old in r.txns.reversed() {
      if let i = s.txns.firstIndex(where: { $0.id == old.id }) { s.txns[i] = old }
    }
    if let plan = r.plan { s.plan = plan }
    if let bills = r.bills { s.bills = bills }
    if let candidates = r.candidates { s.billCandidates = candidates }
    if let rules = r.rules { s.rules = rules }
    state = s
  }

  /// Moves the clock (UI tests and previews of other days).
  public func setNow(_ now: LocalDateTime) { self.now = now }
}
