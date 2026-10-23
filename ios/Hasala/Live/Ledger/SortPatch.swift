import HasalaModels

nonisolated enum SortPatch {
  static func file(_ t: inout Txn, _ c: CategoryID, at: LocalDateTime) {
    t.categoryID = c
    t.categorySource = .user
    t.ruleID = nil
    t.needsReview = false
    t.isTransfer = c == "transfer"
    t.splits = []
    t.categorizedAt = at
    t.reachable = false
    t.ruled = false
    t.priorFiling = nil
  }

  static func name(_ s: LedgerState, _ c: CategoryID) -> String { s.category(c)?.name ?? "Uncategorized" }

  static func members(_ s: LedgerState, _ ref: MerchantGroupRef) -> [Int] {
    s.txns.indices.filter { s.txns[$0].reachable && s.txns[$0].groupRef == ref && !s.skippedReview.contains(s.txns[$0].id) }
  }

  static func waits(_ t: Txn) -> Bool {
    guard t.ruled, t.needsReview || t.categoryID == nil else { return false }
    switch t.categorySource {
    case .dictionary?, .rule?: return t.categoryID == nil
    default: return true
    }
  }

  static func ruled(_ s: LedgerState, _ ref: MerchantGroupRef) -> [Int] {
    s.txns.indices.filter { s.txns[$0].ruled && s.txns[$0].groupRef == ref }
  }

  static func reach(
    _ s: inout LedgerState, from old: Txn, ref: MerchantGroupRef, category c: CategoryID, at: LocalDateTime, receiptID: Int
  ) -> String? {
    let pool = ruled(s, ref).filter { s.txns[$0].id != old.id }
    let patterns = GroupRule.patterns(filed: old, members: pool.map { s.txns[$0] }, filing: c)
    guard !patterns.isEmpty else { return nil }
    let open = pool.filter { !s.txns[$0].settled(in: c) }
    let others = open.filter { GroupRule.reaches(s.txns[$0], patterns) }
    guard !others.isEmpty else { return nil }
    let named = [old] + others.map { s.txns[$0] }
    for i in others {
      s.txns[i].priorFiling = s.txns[i].filing
      s.txns[i].categoryID = c
      s.txns[i].categorySource = .rule(pattern: s.txns[i].spelling.lowercased())
      s.txns[i].ruleID = nil
      s.txns[i].needsReview = false
      s.txns[i].isTransfer = c == "transfer"
      s.txns[i].splits = []
      s.txns[i].categorizedAt = at
      s.txns[i].reachable = false
    }
    let filed = (old.settled(in: c) ? [] : [old.id]) + others.map { s.txns[$0].id }
    let merchant = ReviewEngine.displayName(named)
    s.sortReceipt = SortReceipt(id: receiptID, group: ref, merchant: merchant, categoryID: c, txnIDs: filed)
    return SortResultRow.reachTitle(count: filed.count, merchant: merchant, category: name(s, c), all: others.count == open.count)
  }

  static func sortGroup(
    _ s: inout LedgerState, _ ref: MerchantGroupRef, _ c: CategoryID, project: ProjectID?, at: LocalDateTime, receiptID: Int
  ) throws(ActionError) -> String {
    let idx = members(s, ref)
    guard !idx.isEmpty else { throw .notFound }
    let merchant = ReviewEngine.displayName(idx.map { s.txns[$0] })
    for i in idx {
      file(&s.txns[i], c, at: at)
      if let project { s.txns[i].projectID = project }
    }
    s.sortReceipt = SortReceipt(id: receiptID, group: ref, merchant: merchant, categoryID: c, txnIDs: idx.map { s.txns[$0].id })
    return SortResultRow.line(count: idx.count, merchant: merchant, category: name(s, c))
  }

  static func notThis(_ s: inout LedgerState, _ ref: MerchantGroupRef, _ c: CategoryID) throws(ActionError) -> String {
    let idx = s.txns.indices.filter { s.txns[$0].inGroup(ref.key) }
    guard !idx.isEmpty else { throw .notFound }
    let shown = idx.filter { s.txns[$0].direction == ref.direction }
    let merchant = ReviewEngine.displayName((shown.isEmpty ? idx : shown).map { s.txns[$0] })
    for i in idx {
      s.txns[i].rejectedCategories.insert(c)
      let t = s.txns[i]
      guard t.isModelSourced, t.categoryID == c || (t.categoryID == nil && t.suggestion == c) else { continue }
      s.txns[i].categoryID = nil
      s.txns[i].categorySource = nil
      s.txns[i].suggestion = nil
      s.txns[i].ruleID = nil
      s.txns[i].needsReview = true
      s.txns[i].isTransfer = false
    }
    return "Hasala won't suggest \(name(s, c)) for \(merchant) again"
  }

  static func returnToReview(_ s: inout LedgerState, _ ids: [TxnID], at: LocalDateTime) throws(ActionError) -> String {
    var seen: Set<TxnID> = []
    var returned = 0
    var settled = 0
    for id in ids where seen.insert(id).inserted {
      guard let i = s.txns.firstIndex(where: { $0.id == id }), s.txns[i].sortedForYou else { continue }
      let byRule = s.txns[i].filedByRule
      returned += 1
      if byRule, let prior = s.txns[i].priorFiling {
        s.txns[i].restore(prior)
        if !prior.needsReview { settled += 1 }
      } else {
        s.txns[i].needsReview = true
        s.txns[i].categorizedAt = at
        if byRule {
          s.txns[i].categoryID = nil
          s.txns[i].categorySource = nil
          s.txns[i].ruleID = nil
          s.txns[i].isTransfer = false
        }
      }
      s.txns[i].reachable = waits(s.txns[i])
    }
    guard returned > 0 else { throw .notFound }
    return SortedForYouItem.undoneLine(count: returned, settled: settled)
  }

  static func stopRule(_ s: inout LedgerState, _ id: RuleID) throws(ActionError) -> String {
    guard let i = s.rules.firstIndex(where: { $0.id == id }) else { throw .notFound }
    let rule = s.rules.remove(at: i)
    let byRule = s.txns.filter { $0.ruleID == id }
    let merchant = byRule.isEmpty ? (rule.patterns.first ?? "") : ReviewEngine.displayName(byRule)
    return "Stopped sorting \(merchant) as \(name(s, rule.categoryID))"
  }
}
