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
  public private(set) var revision = 0

  /// What an undo puts back: the records an edit touched, as they were before it and
  /// right after it. Undo reverts only what is still as the edit left it, so a later
  /// edit to another field (a note added after a categorise) survives (03c §3.8: the
  /// inverse ops touch only the fields the edit set).
  private struct UndoRecord {
    var txnsBefore: [TxnID: Txn] = [:]
    var txnsAfter: [TxnID: Txn] = [:]
    var plan: (before: PlanState, after: PlanState)?
    var bills: (before: [Bill], after: [Bill])?
    var candidates: (before: [BillCandidate], after: [BillCandidate])?
    var rules: (before: [Rule], after: [Rule])?
    var projects: (before: [Project], after: [Project])?
  }

  private var undoRecords: [Int: UndoRecord] = [:]
  private var nextToken = 1

  public init(state: LedgerState = MayaLedger.state, now: LocalDateTime = MayaLedger.now) {
    self.state = state
    self.now = now
  }

  @discardableResult
  public func apply(_ edit: LedgerEdit) throws(ActionError) -> UndoToken? {
    let before = state
    var s = state
    var touched = Set<TxnID>()
    var touchedPlan = false, touchedBills = false, touchedCandidates = false, touchedRules = false
    var touchedProjects = false
    let title: String?

    func editTxn(_ id: TxnID, _ change: (inout Txn) -> Void) throws(ActionError) {
      guard let i = s.txns.firstIndex(where: { $0.id == id }) else { throw .notFound }
      touched.insert(id)
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
        touchedRules = true
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
        touched.insert(s.txns[i].id)
        s.txns[i].merchant = name
      }
      title = "Renamed to \(name)"
    case .split(let id, let lines):
      guard let t = s.txn(id) else { throw .notFound }
      if !lines.isEmpty, !TransactionEngine.splitAddsUp(lines, total: t.amount) { throw .splitDoesNotAddUp }
      try editTxn(id) { t in
        t.splits = t.apportioned(lines)
        if let first = lines.first { t.categoryID = first.categoryID }
        t.needsReview = false
      }
      title = lines.isEmpty ? "Split removed" : "Split into \(lines.count) categories"
    case .archive(let id, let archived):
      try editTxn(id) { $0.archived = archived }
      title = archived ? "Archived" : "Restored"
    case .resolveCopy(let id, let merge):
      guard let i = s.txns.firstIndex(where: { $0.id == id }), s.txns[i].isHeldCopy else { throw .notFound }
      touched.insert(id)
      if merge {
        s.txns.remove(at: i)
        title = "Merged"
      } else {
        s.txns[i].heldCopy = nil
        title = "Kept both"
      }
    case .resolveSamePurchase(let id, let same):
      guard let a = s.txn(id), let match = a.samePurchase, let f = s.txn(match.of) else { throw .notFound }
      try editTxn(id) { t in
        t.samePurchase = nil
        if same {
          t.archived = true
          t.note = SamePurchaseText.note(f.amount)
        }
      }
      if same {
        try editTxn(f.id) { $0.homeMinor = a.amount.minor }
      }
      title = same ? "Counted once" : "Kept both"
    case .skipReview(let id):
      s.skippedReview.insert(id)
      title = nil

    case .setBudget(let c, let month, let amount):
      guard amount.minor >= 0 else { throw .invalidAmount }
      touchedPlan = true
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
      touchedPlan = true
      if let from {
        s.plan.budgets[PlanState.key(from, month)] = .aed(s.plan.budget(from, month).minor - amount.minor)
      }
      s.plan.budgets[PlanState.key(to, month)] = .aed(s.plan.budget(to, month).minor + amount.minor)
      title = "Moved to \(categoryName(to))"

    case .trackCandidate(let id):
      guard let c = s.billCandidates.first(where: { $0.id == id }) else { throw .notFound }
      touchedCandidates = true
      touchedBills = true
      s.billCandidates.removeAll { $0.id == id }
      let next = c.last.adding(days: c.everyDays)
      s.bills.append(Bill(id: "bill-\(id)", name: c.name, kind: categoryName(c.categoryID), categoryID: c.categoryID,
                          amount: c.amount, usualDay: c.last.day, nextDue: next, history: [c.last]))
      title = "Tracking \(c.name)"
    case .dismissCandidate(let id):
      guard s.billCandidates.contains(where: { $0.id == id }) else { throw .notFound }
      touchedCandidates = true
      s.billCandidates.removeAll { $0.id == id }
      title = "Dismissed"
    case .markBillPaid(let id):
      guard let i = s.bills.firstIndex(where: { $0.id == id }) else { throw .notFound }
      touchedBills = true
      let due = s.bills[i].nextDue
      let next = due.yearMonth.next
      s.bills[i].history.insert(due, at: 0)
      s.bills[i].nextDue = LocalDate(next.year, next.month, min(s.bills[i].usualDay, next.days))
      title = "\(s.bills[i].name) marked paid"
    case .acceptBillAmount(let id):
      guard let i = s.bills.firstIndex(where: { $0.id == id }) else { throw .notFound }
      touchedBills = true
      s.bills[i].priceChangeFrom = nil
      title = "New amount accepted"
    case .stopTrackingBill(let id):
      guard let i = s.bills.firstIndex(where: { $0.id == id }) else { throw .notFound }
      touchedBills = true
      s.bills[i].state = .dismissed
      title = "Stopped tracking \(s.bills[i].name)"

    case .saveProject(let id, let draft):
      guard draft.refusal == nil else { throw .invalidProject }
      let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
      if let i = s.projects.firstIndex(where: { $0.id == id }) {
        let old = s.projects[i]
        s.projects[i] = Project(
          id: id, name: name, glyph: draft.glyph, budget: draft.budget, starts: draft.starts, ends: draft.ends,
          countInPlan: draft.countInPlan, complete: old.complete, completedOn: old.completedOn,
          startVerb: draft.glyph == .travel ? "flies" : "starts")
      } else {
        s.projects.append(Project(
          id: id, name: name, glyph: draft.glyph, budget: draft.budget, starts: draft.starts, ends: draft.ends,
          countInPlan: draft.countInPlan, startVerb: draft.glyph == .travel ? "flies" : "starts"))
      }
      title = nil
    case .setProjectCountInPlan(let id, let on):
      guard let i = s.projects.firstIndex(where: { $0.id == id }) else { throw .notFound }
      touchedProjects = true
      s.projects[i].countInPlan = on
      title = on ? "Counted in your monthly plan" : "Kept out of your monthly plan"
    case .completeProject(let id, let done):
      guard let i = s.projects.firstIndex(where: { $0.id == id }) else { throw .notFound }
      touchedProjects = true
      s.projects[i].complete = done
      s.projects[i].completedOn = done ? now.date : nil
      title = done ? "\(s.projects[i].name) marked complete" : "\(s.projects[i].name) reopened"
    case .removeProject(let id):
      guard let i = s.projects.firstIndex(where: { $0.id == id }) else { throw .notFound }
      touchedProjects = true
      s.projects.remove(at: i)
      for k in s.txns.indices where s.txns[k].projectID == id { s.txns[k].projectID = nil }
      title = nil
    case .assignProject(let ids, let project):
      if let project, s.project(project) == nil { throw .notFound }
      guard !ids.isEmpty else { throw .notFound }
      for id in ids { try editTxn(id) { $0.projectID = project } }
      let name = s.project(project)?.name ?? ""
      title = project == nil ? "Taken out of the project"
        : ids.count == 1 ? "Added to \(name)" : "Added \(ids.count) to \(name)"

    case .setRuleEnabled(let id, let enabled):
      guard let i = s.rules.firstIndex(where: { $0.id == id }) else { throw .notFound }
      s.rules[i].enabled = enabled
      title = nil
    case .setRate(let currency, let micro):
      guard ExchangeRates.isSettable(currency, micro) else { throw .invalidAmount }
      s.setRate(currency, micro: micro)
      title = nil
    case .unsetRate(let currency):
      guard ExchangeRates.isSettable(currency, nil) else { throw .invalidAmount }
      s.unsetRate(currency)
      title = nil
    case .setNotifications(let level):
      s.prefs.notifications = level
      title = nil
    case .setFaceIDLock(let on):
      s.prefs.faceIDLock = on
      title = nil
    }

    state = s
    revision += 1
    guard let title else { return nil }
    var record = UndoRecord()
    for id in touched {
      record.txnsBefore[id] = before.txn(id)
      record.txnsAfter[id] = s.txn(id)
    }
    if touchedPlan { record.plan = (before.plan, s.plan) }
    if touchedBills { record.bills = (before.bills, s.bills) }
    if touchedCandidates { record.candidates = (before.billCandidates, s.billCandidates) }
    if touchedRules { record.rules = (before.rules, s.rules) }
    if touchedProjects { record.projects = (before.projects, s.projects) }
    let token = UndoToken(id: nextToken, title: title)
    nextToken += 1
    undoRecords[token.id] = record
    return token
  }

  public func undo(_ token: UndoToken) {
    guard let r = undoRecords.removeValue(forKey: token.id) else { return }
    var s = state
    for (id, old) in r.txnsBefore {
      guard let new = r.txnsAfter[id], let i = s.txns.firstIndex(where: { $0.id == id }) else { continue }
      Self.revertFields(&s.txns[i], before: old, after: new)
    }
    if let (old, new) = r.plan {
      for key in Set(old.budgets.keys).union(new.budgets.keys) where s.plan.budgets[key] == new.budgets[key] {
        s.plan.budgets[key] = old.budgets[key]
      }
    }
    if let (old, new) = r.bills { Self.revertElements(&s.bills, before: old, after: new) }
    if let (old, new) = r.candidates { Self.revertElements(&s.billCandidates, before: old, after: new) }
    if let (old, new) = r.rules { Self.revertElements(&s.rules, before: old, after: new) }
    if let (old, new) = r.projects { Self.revertElements(&s.projects, before: old, after: new) }
    state = s
    revision += 1
  }

  /// Moves the clock (UI tests and previews of other days).
  public func setNow(_ now: LocalDateTime) {
    self.now = now
    revision += 1
  }

  /// Puts back each field an edit changed, unless something since has changed it again.
  private static func revertFields(_ t: inout Txn, before: Txn, after: Txn) {
    func field<V: Equatable>(_ kp: WritableKeyPath<Txn, V>) {
      if t[keyPath: kp] == after[keyPath: kp] { t[keyPath: kp] = before[keyPath: kp] }
    }
    field(\.merchant)
    field(\.categoryID)
    field(\.categorySource)
    field(\.needsReview)
    field(\.isTransfer)
    field(\.isRefund)
    field(\.direction)
    field(\.splits)
    field(\.projectID)
    field(\.note)
    field(\.archived)
    field(\.homeMinor)
    field(\.samePurchase)
    field(\.heldCopy)
  }

  /// Element by element: an element still as the edit left it goes back to how it was
  /// (or away, if the edit added it; or back in at its old place, if the edit removed it).
  private static func revertElements<E: Identifiable & Equatable>(_ list: inout [E], before: [E], after: [E]) {
    let afterByID = Dictionary(after.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    let beforeIDs = Set(before.map(\.id))
    for (offset, old) in before.enumerated() {
      let new = afterByID[old.id]
      guard new != old else { continue }
      if let new {
        if let i = list.firstIndex(where: { $0.id == old.id }), list[i] == new { list[i] = old }
      } else if !list.contains(where: { $0.id == old.id }) {
        list.insert(old, at: min(offset, list.count))
      }
    }
    for new in after where !beforeIDs.contains(new.id) {
      list.removeAll { $0.id == new.id && $0 == new }
    }
  }
}
