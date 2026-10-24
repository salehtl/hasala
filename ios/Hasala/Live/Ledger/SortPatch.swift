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

  static func picked(_ s: inout LedgerState, _ ref: MerchantGroupRef?, _ c: CategoryID?) {
    guard let ref else { return }
    for i in s.txns.indices where s.txns[i].groupRef == ref {
      s.txns[i].lastPick = s.txns[i].inReview ? c : nil
    }
  }

  static func carried(_ s: inout LedgerState, _ refs: some Sequence<MerchantGroupRef?>) {
    for ref in Set(refs.compactMap { $0 }) {
      picked(&s, ref, s.txns.first { $0.groupRef == ref && $0.lastPick != nil }?.lastPick)
    }
  }

  static func name(_ s: LedgerState, _ c: CategoryID) -> String { s.category(c)?.name ?? "Uncategorized" }

  static func ruled(_ s: LedgerState, _ ref: MerchantGroupRef) -> [Int] {
    s.txns.indices.filter { s.txns[$0].ruled && s.txns[$0].groupRef == ref }
  }

  static func reach(
    _ s: inout LedgerState, from old: Txn, ref: MerchantGroupRef, category c: CategoryID, at: LocalDateTime
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
    return ReviewEngine.reachTitle(count: filed.count, merchant: merchant, category: name(s, c), all: others.count == open.count)
  }

  static func returnToReview(_ s: inout LedgerState, _ ids: [TxnID], at: LocalDateTime) throws(ActionError) -> String {
    var seen: Set<TxnID> = []
    var returned = 0
    var settled = 0
    var refs: [MerchantGroupRef?] = []
    for id in ids where seen.insert(id).inserted {
      guard let i = s.txns.firstIndex(where: { $0.id == id }), s.txns[i].sortedForYou else { continue }
      let byRule = s.txns[i].filedByRule
      returned += 1
      refs.append(s.txns[i].groupRef)
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
      s.txns[i].reachable = s.txns[i].waits
    }
    carried(&s, refs)
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
