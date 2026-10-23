import CoreCategorize
import CoreDomain
import CoreProjection
import CoreReplay
import CoreTime
import HasalaModels

extension LiveLedgerStore {
  func categoryRefusal(_ edit: LedgerEdit) throws(ActionError) -> String? {
    switch edit {
    case .addCategory, .addCategoryAndSort, .editCategory, .archiveCategory, .restoreCategory: break
    default: return nil
    }
    let view: TaxonomyView
    do { view = try reader.taxonomy() } catch { throw .notFound }
    return LedgerEditAuthor.categoryRefusal(edit, view: view, state: state) ?? Self.shownRefusal(edit, in: state)
  }

  static func shownRefusal(_ edit: LedgerEdit, in s: LedgerState) -> String? {
    switch edit {
    case .addCategory(var d), .addCategoryAndSort(var d, _, _, _):
      d.name = UserText.normalize(d.name)
      return CategoriesEngine.refusal(.addCategory(d), in: s)
    default:
      return nil
    }
  }
}

extension LedgerEditAuthor {
  nonisolated static func icon(_ glyph: Glyph) -> String { LedgerStateMapper.icon(glyph) }

  nonisolated static func changedParent(_ d: CategoryDraft, of c: CategoryInfo?) -> String? {
    guard let c, !c.builtin, let p = d.parent, p != c.parent else { return nil }
    return p
  }

  nonisolated static func categoryRefusal(_ edit: LedgerEdit, view: TaxonomyView, state: LedgerState) -> String? {
    let rules = CategoryRules(view)
    switch edit {
    case .addCategory(let d), .addCategoryAndSort(let d, _, _, _):
      if let id = d.id, !OpAuthor.isNewCategoryID(id) || view.info(id) != nil { return CategoryLimits.cannotAdd }
      return rules.checkCreate(name: d.name, parent: d.parent ?? "", icon: icon(d.glyph))?.message
    case .editCategory(let id, let d):
      return rules.checkEdit(id: id, name: d.name, icon: icon(d.glyph), parent: changedParent(d, of: view.info(id)))?.message
    case .archiveCategory(let id, let moveTo):
      if let r = rules.checkSetActive(id: id, active: false) { return r.message }
      guard let c = state.category(id) else { return CategoryRefusal.unknownCategory.message }
      return CategoriesEngine.archiveRefusal(c, moveTo: moveTo, in: state)
    case .restoreCategory(let id):
      return rules.checkSetActive(id: id, active: true)?.message
    default:
      return nil
    }
  }

  nonisolated func authorCategory(_ edit: LedgerEdit, today: LocalDate) async throws {
    let view = try reader.taxonomy()
    switch edit {
    case .addCategory(let d):
      guard let parent = d.parent else { throw Failure.refused(CategoryRefusal.parentNotAllowed.message) }
      try await build { a throws(AuthorError) in
        _ = try a.createCategory(id: d.id, name: d.name, parent: parent, icon: Self.icon(d.glyph), in: view)
      }
    case .editCategory(let id, let d):
      let parent = Self.changedParent(d, of: view.info(id))
      try await build { a throws(AuthorError) in
        try a.editCategory(id: id, name: d.name, icon: Self.icon(d.glyph), parent: parent, in: view)
      }
    case .restoreCategory(let id):
      try await build { a throws(AuthorError) in try a.setCategoryActive(id: id, active: true, in: view) }
    case .archiveCategory(let id, let moveTo):
      try await archiveCategory(id, moveTo: moveTo, view: view, today: today)
    default:
      return
    }
  }

  nonisolated func addCategoryAndSort(
    _ d: CategoryDraft, txn id: String, alwaysUse: Bool, project: String?, receiptID: Int?
  ) async throws -> [Inverse] {
    guard let category = d.id else { throw Failure.notFound }
    guard let parent = d.parent else { throw Failure.refused(CategoryRefusal.parentNotAllowed.message) }
    guard let row = try reader.txn(id) else { throw Failure.notFound }
    let view = try reader.taxonomy()
    let icon = Self.icon(d.glyph)
    let inverses: [Inverse]
    if alwaysUse, Self.reaches(row) {
      inverses = try await categorizeReaching(row, category: category, project: project, receiptID: receiptID) {
        a throws(AuthorError) in
        _ = try a.createCategory(id: category, name: d.name, parent: parent, icon: icon, in: view)
      }
    } else {
      try await build { a throws(AuthorError) in
        try a.createCategoryAndFile(
          id: category, name: d.name, parent: parent, icon: icon, in: view, txnID: id, parentVersion: row.version, project: project)
      }
      inverses = row.split ? [] : [Self.refile(row, written: row.version + 1)]
    }
    return inverses + noteCorrection(row, to: category)
  }

  nonisolated private func archiveCategory(_ id: String, moveTo: String?, view: TaxonomyView, today: LocalDate) async throws {
    guard let m = CivilMonth(year: today.year, month: today.month),
      let day = CivilDate(year: today.year, month: today.month, day: today.day)
    else { throw Failure.refused("month") }
    let engine = try reader.planEngine(month: m, today: day)
    let assigned = engine.assigned(m, id)
    let next = m.adding(months: 1)
    let onward = next.map { engine.assigned($0, id) } ?? 0
    let budgetTo = moveTo.flatMap { view.info($0)?.kind == .spending ? $0 : nil }
    let rows = moveTo == nil ? [] : try reader.categoryMembers(id)
    let ctx = try await observer.authorContext()
    let blobs = try observer.stamps.authoring {
      (floor: Int64?) throws(AuthorError) -> (value: [AuthoredBlob], lastMs: Int64?) in
      var c = ctx.raised(to: floor)
      var out: [AuthoredBlob] = []
      var a = OpAuthor(c)
      func flush() throws(AuthorError) {
        let b = try a.build()
        out.append(b)
        c.ownLastMs = b.lastAuthoredMs
        a = OpAuthor(c)
      }
      for row in rows {
        if a.count >= Sweep.maxOpsPerBlob { try flush() }
        a.categorize(txnID: row.id, parentVersion: row.version, category: moveTo, needsReview: row.needsReview)
      }
      if a.count + 3 > Sweep.maxOpsPerBlob { try flush() }
      if assigned > 0 { a.moveMoney(month: m, from: id, to: budgetTo, amountMinor: assigned) }
      if onward > 0, let next { a.setBudget(category: id, month: next, amountMinor: 0) }
      try a.setCategoryActive(id: id, active: false, in: view)
      out.append(try a.build())
      return (out, out.last?.lastAuthoredMs)
    }
    for b in blobs { try await outbox.enqueue(b.ops) }
    try await observer.reproject()
  }
}
