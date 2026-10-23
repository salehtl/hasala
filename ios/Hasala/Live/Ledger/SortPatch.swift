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
  }

  static func name(_ s: LedgerState, _ c: CategoryID) -> String { s.category(c)?.name ?? "Uncategorized" }

  static func members(_ s: LedgerState, _ ref: MerchantGroupRef) -> [Int] {
    s.txns.indices.filter { s.txns[$0].reachable && s.txns[$0].groupRef == ref && !s.skippedReview.contains(s.txns[$0].id) }
  }

  static func reach(
    _ s: inout LedgerState, from old: Txn, ref: MerchantGroupRef, category c: CategoryID, at: LocalDateTime, receiptID: Int
  ) -> String? {
    let others = members(s, ref).filter { s.txns[$0].id != old.id }
    guard !others.isEmpty else { return nil }
    let filed = [old] + others.map { s.txns[$0] }
    for i in others {
      s.txns[i].categoryID = c
      s.txns[i].categorySource = .rule(pattern: s.txns[i].spelling.lowercased())
      s.txns[i].ruleID = nil
      s.txns[i].needsReview = false
      s.txns[i].isTransfer = c == "transfer"
      s.txns[i].splits = []
      s.txns[i].categorizedAt = at
      s.txns[i].reachable = false
    }
    let merchant = ReviewEngine.displayName(filed)
    s.sortReceipt = SortReceipt(id: receiptID, group: ref, merchant: merchant, categoryID: c, txnIDs: filed.map(\.id))
    return "Sorted \(filed.count) \(merchant) as \(name(s, c))"
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
    return "Sorted \(idx.count) \(merchant) as \(name(s, c))"
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
    for id in ids where seen.insert(id).inserted {
      guard let i = s.txns.firstIndex(where: { $0.id == id }), s.txns[i].sortedForYou else { continue }
      let byRule = s.txns[i].filedByRule
      s.txns[i].needsReview = true
      s.txns[i].categorizedAt = at
      if byRule {
        s.txns[i].categoryID = nil
        s.txns[i].categorySource = nil
        s.txns[i].ruleID = nil
        s.txns[i].isTransfer = false
      }
      returned += 1
    }
    guard returned > 0 else { throw .notFound }
    return returned == 1 ? "1 payment back in Review" : "\(returned) payments back in Review"
  }

  static func stopRule(_ s: inout LedgerState, _ id: RuleID) throws(ActionError) -> String {
    guard let i = s.rules.firstIndex(where: { $0.id == id }) else { throw .notFound }
    let rule = s.rules.remove(at: i)
    let byRule = s.txns.filter { $0.ruleID == id }
    let merchant = byRule.isEmpty ? (rule.patterns.first ?? "") : ReviewEngine.displayName(byRule)
    return "Stopped sorting \(merchant) as \(name(s, rule.categoryID))"
  }
}
