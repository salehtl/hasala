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
    var unread: (before: [UnreadMail], after: [UnreadMail])?
    var receipt: SortReceipt??
  }

  private var undoRecords: [Int: UndoRecord] = [:]
  private var nextToken = 1
  private var nextManual = 1
  private var nextBill = 1
  private var nextCategory = 1

  public init(state: LedgerState = MayaLedger.state, now: LocalDateTime = MayaLedger.now) {
    var state = state
    for i in state.txns.indices where state.txns[i].merchantKey == nil {
      state.txns[i].merchantKey = state.txns[i].merchant.lowercased()
    }
    MockReach.refresh(&state)
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
    var touchedUnread = false
    var title: String?
    var receipt: SortReceipt?

    func editTxn(_ id: TxnID, _ change: (inout Txn) -> Void) throws(ActionError) {
      guard let i = s.txns.firstIndex(where: { $0.id == id }) else { throw .notFound }
      touched.insert(id)
      change(&s.txns[i])
    }

    func categoryName(_ id: CategoryID) -> String { s.category(id)?.name ?? "Uncategorized" }

    let today = now.date
    let at = now

    func fileByPerson(_ t: inout Txn, _ c: CategoryID) {
      t.categoryID = c
      t.categorySource = .user
      t.ruleID = nil
      t.needsReview = false
      t.isTransfer = c == "transfer"
      t.splits = []
      t.categorizedAt = at
    }

    func reachBack(_ rule: Rule, group ref: MerchantGroupRef?, except: Set<TxnID>) throws(ActionError) -> [TxnID] {
      guard let ref else { return [] }
      let hits = s.txns.filter { t in
        t.reachable && t.groupRef == ref && !s.skippedReview.contains(t.id) && !except.contains(t.id)
          && rule.matches(GroupRule.pattern(t.spelling) ?? t.spelling)
      }.map(\.id)
      for id in hits {
        try editTxn(id) { t in
          t.categoryID = rule.categoryID
          t.categorySource = .rule(pattern: rule.patterns.first ?? "")
          t.ruleID = rule.id
          t.needsReview = false
          t.isTransfer = rule.categoryID == "transfer"
          t.splits = []
          t.categorizedAt = at
        }
      }
      return hits
    }

    func billIndex(_ id: BillID) throws(ActionError) -> Int {
      guard let i = s.bills.firstIndex(where: { $0.id == id }), s.bills[i].state != .dismissed else { throw .notFound }
      touchedBills = true
      return i
    }

    func expenseIndex(_ id: BillID) throws(ActionError) -> Int {
      let i = try billIndex(id)
      if s.bills[i].isIncome { throw .invalidBill }
      return i
    }

    func link(_ i: Int, _ ids: [TxnID]) throws(ActionError) {
      guard !ids.isEmpty, Set(ids).count == ids.count else { throw .invalidBill }
      let b = s.bills[i]
      var dues = Set<LocalDate>()
      var planned: [(TxnID, LocalDate, Money)] = []
      for id in ids {
        guard let t = s.txn(id) else { throw .notFound }
        if t.archived || t.isTransfer || t.isHeldCopy || t.isRefund { throw .invalidBill }
        if t.direction != (b.isIncome ? .in : .out) { throw .invalidBill }
        if let other = t.billID, other != b.id { throw .invalidBill }
        let due = BillDueDates.nearest(b, to: t.postedAt.date)
        if !dues.insert(due).inserted { throw .invalidBill }
        if b.payments.contains(where: { $0.due == due && $0.link == .linked && $0.txnID != id }) { throw .invalidBill }
        planned.append((id, due, t.amount))
      }
      for (id, due, amount) in planned {
        try editTxn(id) { $0.billID = b.id }
        s.bills[i].payments.removeAll { $0.due == due || $0.txnID == id }
        s.bills[i].payments.append(BillPayment(due: due, txnID: id, amount: amount, link: .linked))
        if let day = s.txn(id)?.postedAt.date, !s.bills[i].history.contains(day) { s.bills[i].history.append(day) }
        if due >= s.bills[i].nextDue { s.bills[i].nextDue = BillDueDates.shift(s.bills[i], from: due, by: 1) }
      }
      s.bills[i].payments.sort { $0.due > $1.due }
      s.bills[i].history.sort(by: >)
    }

    switch edit {
    case .addTransaction(let d):
      if let refusal = d.refusal { throw refusal }
      if let c = d.categoryID, s.category(c) == nil { throw .notFound }
      if let a = d.accountID, !s.accounts.contains(where: { $0.id == a }) { throw .notFound }
      var t = d.txn(id: "manual-\(nextManual)")
      t.merchantKey = t.merchant.lowercased()
      s.txns.append(t)
      nextManual += 1
      title = nil
    case .categorize(let id, let c, let learnRule, let project):
      guard s.category(c) != nil else { throw .notFound }
      try editTxn(id) { t in
        fileByPerson(&t, c)
        if let project { t.projectID = project }
      }
      title = "Sorted into \(categoryName(c))"
      if learnRule, let t = s.txn(id),
        !s.rules.contains(where: { $0.matches(t.groupRef == nil ? t.merchant : GroupRule.pattern(t.spelling) ?? t.spelling) })
      {
        let members = s.txns.filter { $0.reachable && $0.groupRef == t.groupRef && $0.id != id && !s.skippedReview.contains($0.id) }
        let patterns = t.groupRef == nil ? [t.merchant.lowercased()] : GroupRule.patterns(filed: t, members: members)
        guard !patterns.isEmpty else { break }
        touchedRules = true
        let taken = Set(s.rules.map(\.id)).union(s.txns.compactMap(\.ruleID))
        let base = "learned-\(id)"
        let ruleID = taken.contains(base) ? "\(base)-\(nextToken)" : base
        let rule = Rule(
          id: ruleID, patterns: patterns, match: t.groupRef == nil ? .contains : .exact, categoryID: c, learnedToday: true)
        s.rules.append(rule)
        let reached = try reachBack(rule, group: t.groupRef, except: [id])
        if !reached.isEmpty {
          let filed = [id] + reached
          let merchant = ReviewEngine.displayName(filed.compactMap { s.txn($0) })
          receipt = SortReceipt(id: nextToken, group: t.groupRef, merchant: merchant, categoryID: c, txnIDs: filed,
                                ruleID: rule.id)
          title = "Sorted \(filed.count) \(merchant) as \(categoryName(c))"
        }
      }
    case .sortGroup(let ref, let c, let alwaysUse, let project):
      guard s.category(c) != nil else { throw .notFound }
      if let project, s.project(project) == nil { throw .notFound }
      let members = s.txns.filter { $0.reachable && $0.groupRef == ref && !s.skippedReview.contains($0.id) }
      guard !members.isEmpty else { throw .notFound }
      for t in members {
        try editTxn(t.id) { t in
          fileByPerson(&t, c)
          if let project { t.projectID = project }
        }
      }
      var filed = members.map(\.id)
      var ruleID: RuleID?
      let patterns = alwaysUse ? GroupRule.patterns(filed: nil, members: members) : []
      if !patterns.isEmpty {
        let rule = Rule(id: "group-\(nextToken)", patterns: patterns, match: .exact, categoryID: c, learnedToday: true)
        touchedRules = true
        s.rules.append(rule)
        ruleID = rule.id
        filed += try reachBack(rule, group: ref, except: Set(filed))
      }
      let merchant = ReviewEngine.displayName(members)
      receipt = SortReceipt(id: nextToken, group: ref, merchant: merchant, categoryID: c, txnIDs: filed, ruleID: ruleID)
      title = "Sorted \(filed.count) \(merchant) as \(categoryName(c))"
    case .notThis(let ref, let c):
      guard s.category(c) != nil else { throw .notFound }
      let rows = s.txns.filter { $0.inGroup(ref.key) }
      guard !rows.isEmpty else { throw .notFound }
      for row in rows {
        try editTxn(row.id) { t in
          t.rejectedCategories.insert(c)
          guard t.isModelSourced, t.categoryID == c || (t.categoryID == nil && t.suggestion == c) else { return }
          t.categoryID = nil
          t.categorySource = nil
          t.suggestion = nil
          t.ruleID = nil
          t.needsReview = true
          t.isTransfer = false
          t.categorizedAt = at
        }
      }
      let shown = rows.filter { $0.direction == ref.direction }
      let merchant = ReviewEngine.displayName(shown.isEmpty ? rows : shown)
      title = "Hasala won't suggest \(categoryName(c)) for \(merchant) again"
    case .returnToReview(let ids):
      var seen: Set<TxnID> = []
      var returned = 0
      for id in ids where seen.insert(id).inserted {
        guard let t = s.txn(id), t.sortedForYou else { continue }
        let byRule = t.filedByRule
        try editTxn(id) { t in
          t.needsReview = true
          t.categorizedAt = at
          guard byRule else { return }
          t.categoryID = nil
          t.categorySource = nil
          t.ruleID = nil
          t.isTransfer = false
        }
        returned += 1
      }
      guard returned > 0 else { throw .notFound }
      title = returned == 1 ? "1 payment back in Review" : "\(returned) payments back in Review"
    case .stopRule(let id):
      guard let i = s.rules.firstIndex(where: { $0.id == id }) else { throw .notFound }
      touchedRules = true
      let rule = s.rules.remove(at: i)
      let byRule = s.txns.filter { $0.ruleID == id }
      let hit = byRule.isEmpty ? s.txns.filter { rule.matches($0.spelling) || rule.matches($0.merchant) } : byRule
      let merchant = hit.isEmpty ? rule.patterns.first ?? "" : ReviewEngine.displayName(hit)
      title = "Stopped sorting \(merchant) as \(categoryName(rule.categoryID))"
    case .dismissSortReceipt:
      s.sortReceipt = nil
      title = nil
    case .useSuggestions(let uses):
      var used = 0
      var seen: Set<TxnID> = []
      for u in uses where seen.insert(u.txn).inserted && s.txn(u.txn).map({ SuggestionsEngine.applies(u, to: $0) }) == true {
        try editTxn(u.txn) { t in fileByPerson(&t, u.category) }
        used += 1
      }
      guard used > 0 else { throw .notFound }
      title = SuggestionsEngine.usedLine(used)
    case .markTransfer(let id):
      try editTxn(id) { t in
        t.categoryID = "transfer"
        t.categorySource = .user
        t.ruleID = nil
        t.isTransfer = true
        t.needsReview = false
        t.categorizedAt = at
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
      if archived, s.unreadMail.contains(where: { $0.id == id }) {
        touchedUnread = true
        s.unreadMail.removeAll { $0.id == id }
        title = "Dismissed"
      } else {
        try editTxn(id) { $0.archived = archived }
        title = archived ? "Archived" : "Restored"
      }
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
      let cadence: BillCadence = c.everyDays <= 10 ? .weekly : c.everyDays >= 300 ? .yearly : .monthly
      s.bills.append(Bill(id: "bill-\(id)", name: c.name, kind: categoryName(c.categoryID), categoryID: c.categoryID,
                          amount: c.amount, usualDay: c.last.day, nextDue: next, history: [c.last],
                          source: .detected, cadence: cadence, every: cadence == .weekly ? max(1, c.everyDays / 7) : 1,
                          trackingSince: today,
                          payments: [BillPayment(due: c.last, amount: c.amount, link: .matched)],
                          keys: [c.key ?? c.name.lowercased()]))
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
      s.bills[i].payments.removeAll { $0.due == due }
      s.bills[i].payments.insert(BillPayment(due: due, amount: s.bills[i].amount, link: .marked), at: 0)
      s.bills[i].nextDue = LocalDate(next.year, next.month, min(s.bills[i].usualDay, next.days))
      title = "\(s.bills[i].name) marked paid"
    case .acceptBillAmount(let id):
      guard let i = s.bills.firstIndex(where: { $0.id == id }),
            s.bills[i].notices.contains(where: { if case .priceChange = $0.kind { true } else { false } })
      else { throw .notFound }
      touchedBills = true
      s.bills[i].priceChangeFrom = nil
      s.bills[i].notices.removeAll { if case .priceChange = $0.kind { true } else { false } }
      title = "New amount accepted"
    case .stopTrackingBill(let id):
      let i = try billIndex(id)
      try Self.end(&s.bills[i], lastPayment: today)
      title = "Stopped tracking \(s.bills[i].name)"
    case .addBill(let d):
      if let refusal = d.refusal { throw refusal }
      guard s.category(d.categoryID) != nil else { throw .notFound }
      if let a = d.accountID, !s.accounts.contains(where: { $0.id == a }) { throw .notFound }
      let name = d.trimmedName
      let keys = d.keys.map { $0.trimmedSpaces.lowercased() }.filter { !$0.isEmpty }
      touchedBills = true
      s.bills.append(Bill(
        id: "bill-manual-\(nextBill)", name: name, kind: categoryName(d.categoryID), categoryID: d.categoryID,
        amount: d.amount, approximate: d.approximate, usualDay: d.firstDue.day, nextDue: d.firstDue,
        accountID: d.accountID, source: .manual, cadence: d.cadence, every: d.every, trackingSince: today,
        keys: keys.isEmpty ? [name.lowercased()] : keys))
      nextBill += 1
      let i = s.bills.count - 1
      if !d.linkTxns.isEmpty { try link(i, d.linkTxns) }
      let start = min(d.firstDue, s.bills[i].payments.map(\.due).min() ?? d.firstDue)
      s.bills[i].trackingSince = max(start, today)
      title = "Added \(name)"
    case .editBillAmount(let id, let amount, let approximate, let from):
      let i = try expenseIndex(id)
      let b = s.bills[i]
      guard amount.minor > 0, amount.minor <= ManualEntryDraft.maxMinor, amount.currency == b.amount.currency else {
        throw .invalidAmount
      }
      guard BillDueDates.nearest(b, to: from) == from, from >= BillDueDates.start(b) else { throw .invalidBill }
      if let end = b.endedOn, from > end { throw .invalidBill }
      if from <= b.nextDue {
        s.bills[i].amount = amount
        s.bills[i].approximate = approximate
        s.bills[i].nextAmount = nil
        s.bills[i].nextAmountFrom = nil
        s.bills[i].priceChangeFrom = nil
        s.bills[i].notices.removeAll { if case .priceChange = $0.kind { true } else { false } }
      } else {
        s.bills[i].nextAmount = amount
        s.bills[i].nextAmountFrom = from
      }
      title = "\(b.name) amount changed"
    case .pauseBill(let id, let until):
      let i = try expenseIndex(id)
      guard s.bills[i].state == .tracked else { throw .invalidBill }
      let from = Self.pauseStart(s.bills[i], today: today)
      if let until, until <= from { throw .invalidBill }
      s.bills[i].state = .paused
      s.bills[i].pausedSince = from
      s.bills[i].pausedUntil = until
      title = "Paused \(s.bills[i].name)"
    case .resumeBill(let id):
      let i = try expenseIndex(id)
      guard s.bills[i].state == .paused else { throw .invalidBill }
      s.bills[i].state = .tracked
      s.bills[i].pausedSince = nil
      s.bills[i].pausedUntil = nil
      s.bills[i].nextDue = BillDueDates.first(s.bills[i], onOrAfter: today)
      title = "Resumed \(s.bills[i].name)"
    case .endBill(let id, let lastPayment):
      let i = try expenseIndex(id)
      try Self.end(&s.bills[i], lastPayment: lastPayment)
      title = "Ended \(s.bills[i].name)"
    case .reactivateBill(let id):
      let i = try expenseIndex(id)
      guard s.bills[i].state == .ended else { throw .invalidBill }
      s.bills[i].state = .tracked
      s.bills[i].endedOn = nil
      s.bills[i].trackingSince = max(s.bills[i].trackingSince ?? today, today)
      s.bills[i].notices.removeAll { if case .chargedAfterEnd = $0.kind { true } else { false } }
      s.bills[i].nextDue = BillDueDates.first(s.bills[i], onOrAfter: today)
      title = "Tracking \(s.bills[i].name) again"
    case .deleteBill(let id):
      let i = try expenseIndex(id)
      s.bills[i].state = .dismissed
      title = s.bills[i].source == .manual ? "Deleted \(s.bills[i].name)" : "\(s.bills[i].name) is not a bill"
    case .linkBillPayments(let id, let txns):
      let i = try billIndex(id)
      try link(i, txns)
      title = txns.count == 1 ? "Linked 1 payment" : "Linked \(txns.count) payments"
    case .reapplyBill(let id):
      let i = try billIndex(id)
      guard let n = s.bills[i].notices.firstIndex(where: {
        if case .changedOnTwoDevices = $0.kind { true } else { false }
      }) else { throw .notFound }
      s.bills[i].notices.remove(at: n)
      title = "Re-applied your change"
    case .dismissBillNotice(let id, let noticeID):
      guard let i = s.bills.firstIndex(where: { $0.id == id }),
            s.bills[i].notices.contains(where: { $0.id == noticeID }) else { throw .notFound }
      s.bills[i].notices.removeAll { $0.id == noticeID }
      title = nil
    case .editIncome(let id, let amount, let payday, let active):
      guard let i = s.bills.firstIndex(where: { $0.id == id && $0.isIncome }) else { throw .notFound }
      guard amount.minor > 0, amount.minor <= ManualEntryDraft.maxMinor else { throw .invalidAmount }
      guard (1...31).contains(payday) else { throw .invalidBill }
      touchedBills = true
      touchedPlan = true
      s.bills[i].amount = amount
      s.bills[i].usualDay = payday
      s.bills[i].state = active ? .tracked : .ended
      s.bills[i].endedOn = active ? nil : today
      let ym = today.yearMonth
      let thisMonth = LocalDate(ym.year, ym.month, min(payday, ym.days))
      let next = ym.next
      s.bills[i].nextDue = thisMonth >= today ? thisMonth : LocalDate(next.year, next.month, min(payday, next.days))
      s.plan.income = active ? amount : Money(minor: 0, currency: amount.currency)
      s.plan.payday = payday
      for m in s.plan.incomeByMonth.keys where m >= ym { s.plan.incomeByMonth[m] = nil }
      title = "Income updated"

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
    case .addCategory(var d):
      if let why = CategoriesEngine.refusal(edit, in: s) { throw .refused(why) }
      if d.id == nil { d.id = newCategoryID() }
      CategoriesEngine.apply(.addCategory(d), to: &s, month: now.date.yearMonth)
      title = nil
    case .editCategory, .archiveCategory, .restoreCategory:
      if let why = CategoriesEngine.refusal(edit, in: s) { throw .refused(why) }
      CategoriesEngine.apply(edit, to: &s, month: now.date.yearMonth)
      title = nil
    case .addCategoryAndSort(let d, let id, let alwaysUse, let project):
      return try addCategoryAndSort(d, txn: id, alwaysUse: alwaysUse, project: project)
    case .setNotifications(let level):
      s.prefs.notifications = level
      title = nil
    case .setFaceIDLock(let on):
      s.prefs.faceIDLock = on
      title = nil
    case .setDisplayName(let name):
      s.profile.displayName = name
      title = nil
    }

    if var receipt, let title {
      receipt.undo = UndoToken(id: nextToken, title: title)
      s.sortReceipt = receipt
    }
    MockReach.refresh(&s)
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
    if touchedUnread { record.unread = (before.unreadMail, s.unreadMail) }
    if receipt != nil { record.receipt = .some(before.sortReceipt) }
    let token = UndoToken(id: nextToken, title: title)
    nextToken += 1
    undoRecords[token.id] = record
    return token
  }

  public func newCategoryID() -> CategoryID {
    while state.category("c_mock\(nextCategory)") != nil { nextCategory += 1 }
    defer { nextCategory += 1 }
    return "c_mock\(nextCategory)"
  }

  private func addCategoryAndSort(_ d: CategoryDraft, txn id: TxnID, alwaysUse: Bool, project: ProjectID?) throws(ActionError)
    -> UndoToken?
  {
    var draft = d
    if draft.id == nil { draft.id = newCategoryID() }
    guard let category = draft.id else { throw .notFound }
    if let why = CategoriesEngine.refusal(.addCategory(draft), in: state) { throw .refused(why) }
    guard state.txn(id) != nil else { throw .notFound }
    if let project, state.project(project) == nil { throw .notFound }
    let saved = state
    try apply(.addCategory(draft))
    do {
      return try apply(.categorize(id, category, learnRule: alwaysUse, project: project))
    } catch {
      state = saved
      revision += 1
      throw error
    }
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
      if s.plan.income == new.income { s.plan.income = old.income }
      if s.plan.payday == new.payday { s.plan.payday = old.payday }
      for m in Set(old.incomeByMonth.keys).union(new.incomeByMonth.keys)
      where s.plan.incomeByMonth[m] == new.incomeByMonth[m] {
        s.plan.incomeByMonth[m] = old.incomeByMonth[m]
      }
    }
    if let (old, new) = r.bills { Self.revertElements(&s.bills, before: old, after: new) }
    if let (old, new) = r.candidates { Self.revertElements(&s.billCandidates, before: old, after: new) }
    if let (old, new) = r.rules { Self.revertElements(&s.rules, before: old, after: new) }
    if let (old, new) = r.projects { Self.revertElements(&s.projects, before: old, after: new) }
    if let (old, new) = r.unread { Self.revertElements(&s.unreadMail, before: old, after: new) }
    if s.sortReceipt?.id == token.id {
      let previous = r.receipt ?? nil
      s.sortReceipt = previous.flatMap { undoRecords[$0.id] != nil ? $0 : nil }
    }
    MockReach.refresh(&s)
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
    field(\.ruleID)
    field(\.suggestion)
    t.rejectedCategories.subtract(after.rejectedCategories.subtracting(before.rejectedCategories))
    t.rejectedCategories.formUnion(before.rejectedCategories.subtracting(after.rejectedCategories))
    field(\.categorizedAt)
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
    field(\.billID)
  }

  static func pauseStart(_ b: Bill, today: LocalDate) -> LocalDate {
    let paid = Set(b.payments.map(\.due))
    let from = max(today, BillDueDates.start(b))
    var due = BillDueDates.first(b, onOrAfter: from)
    guard paid.contains(due) else { return from }
    var steps = 0
    while paid.contains(due), steps < 5_000 {
      due = BillDueDates.shift(b, from: due, by: 1)
      steps += 1
    }
    return due
  }

  private static func end(_ b: inout Bill, lastPayment: LocalDate) throws(ActionError) {
    guard b.state == .tracked || b.state == .paused else { throw .invalidBill }
    guard lastPayment >= BillDueDates.start(b) else { throw .invalidBill }
    b.state = .ended
    b.endedOn = lastPayment
    b.pausedSince = nil
    b.pausedUntil = nil
    if let from = b.nextAmountFrom, from > lastPayment {
      b.nextAmount = nil
      b.nextAmountFrom = nil
    }
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
