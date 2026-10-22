public enum CategoryLimits {
  public static let maxActiveCustom = 20
  public static let maxName = 24
  public static let systemIDs: Set<CategoryID> = ["transfer", "refunds", "salary"]
  public static let parentIDs: [CategoryID] = [
    "rent", "utilities", "groceries", "transport", "healthcare", "insurance", "dining", "entertainment", "shopping", "travel",
    "subscriptions", "savings", "investments", "debt", "salary", "freelance",
  ]
  public static let glyphs: [Glyph] = [
    .tag, .rent, .utilities, .groceries, .transport, .healthcare, .insurance, .dining, .entertainment, .shopping, .travel,
    .subscriptions, .savingsJar, .investments, .debt, .salary, .freelance, .transfer, .refunds, .flag,
  ]

  public static let goalUses = "A goal uses this category. Finish or change the goal first."
  public static let atCap = "You have \(maxActiveCustom) categories. Archive one to add another."
  public static let addAtCap = "Archive one to add another"
  public static let nameEmpty = "Enter a name."
  public static let nameTooLong = "Use \(maxName) characters or fewer."
  public static let parentNotAllowed = "Choose a category from the list for it to count as."
  public static let unknown = "This category no longer exists."
  public static let builtinLocked = "A built-in category keeps its type."
  public static let systemCannotHide = "This category is needed and cannot be hidden."

  public static func nameTaken(_ name: String) -> String { "You already have a category named \(name)." }

  public static func isSystem(_ id: CategoryID) -> Bool { systemIDs.contains(id) }

  public static func isParent(_ id: CategoryID) -> Bool { parentIDs.contains(id) }

  public static func glyphName(_ g: Glyph) -> String {
    switch g {
    case .tag: "Tag"
    case .rent: "House"
    case .utilities: "Bolt"
    case .groceries: "Basket"
    case .transport: "Car"
    case .healthcare: "Health"
    case .insurance: "Shield"
    case .dining: "Fork and knife"
    case .entertainment: "Ticket"
    case .shopping: "Bag"
    case .travel: "Plane"
    case .subscriptions: "Repeat"
    case .savingsJar: "Jar"
    case .investments: "Trend"
    case .debt: "Card"
    case .salary: "Briefcase"
    case .freelance: "Laptop"
    case .transfer: "Arrows"
    case .refunds: "Receipt"
    case .flag: "Flag"
    default: g.rawValue
    }
  }
}

public struct CategoryRowModel: Sendable, Hashable, Identifiable {
  public var id: CategoryID
  public var name: String
  public var glyph: Glyph
  public var hue: Hue
  public var supporting: String?
  public var hidden: Bool
  public var builtin: Bool
}

public struct CategorySectionModel: Sendable, Hashable, Identifiable {
  public var id: String { title }
  public var title: String
  public var rows: [CategoryRowModel]
}

public struct CategoriesSnapshot: Sendable, Hashable {
  public var customCount: Int
  public var capLine: String
  public var canAdd: Bool
  public var sections: [CategorySectionModel]
  public var archived: [CategoryRowModel]
}

public struct CategoryImpact: Sendable, Hashable {
  public var name: String
  public var section: String
  public var transactions: Int
  public var rules: Int
  public var assigned: Money
  public var blockedByGoal: Bool

  public func lines(hidden: Bool) -> [String] {
    var out: [String] = []
    switch transactions {
    case 0: out.append("No transactions use it.")
    case 1: out.append("1 transaction keeps it and still counts in \(section).")
    default: out.append("\(transactions) transactions keep it and still count in \(section).")
    }
    if rules == 1 { out.append("1 rule stops matching.") }
    if rules > 1 { out.append("\(rules) rules stop matching.") }
    if assigned.minor > 0 {
      out.append(
        hidden
          ? "The money assigned this month goes to Ready to assign."
          : "AED \(MoneyFormat.string(assigned.minor)) assigned this month goes to Ready to assign.")
    }
    return out
  }
}

public enum CategoriesEngine {
  static let sectionOrder: [Bucket] = [.needs, .wants, .savings, .income, .other]

  public static func section(_ bucket: Bucket) -> String {
    switch bucket {
    case .needs: "Needs"
    case .wants: "Wants"
    case .savings: "Savings"
    case .income: "Income"
    case .project, .other: "Not spending"
    }
  }

  public static func activeCustomCount(_ s: LedgerState) -> Int {
    s.categories.filter { !$0.builtin && !$0.archived }.count
  }

  public static func capLine(_ n: Int) -> String { "\(n) of \(CategoryLimits.maxActiveCustom) custom categories" }

  public static func snapshot(_ s: LedgerState) -> CategoriesSnapshot {
    let count = activeCustomCount(s)
    let shown = s.categories.filter { $0.builtin || !$0.archived }
    let sections = sectionOrder.compactMap { b -> CategorySectionModel? in
      let rows = shown.filter { sectionBucket($0) == b }.map { row($0, s) }
      return rows.isEmpty ? nil : CategorySectionModel(title: section(b), rows: rows)
    }
    let archived = s.categories.filter { !$0.builtin && $0.archived }.map { row($0, s) }
    return CategoriesSnapshot(
      customCount: count, capLine: capLine(count), canAdd: count < CategoryLimits.maxActiveCustom, sections: sections,
      archived: archived)
  }

  static func sectionBucket(_ c: Category) -> Bucket { c.bucket == .project ? .other : c.bucket }

  static func row(_ c: Category, _ s: LedgerState) -> CategoryRowModel {
    let supporting: String? =
      if !c.builtin, let p = c.parent, let parent = s.category(p) { "Counts as \(parent.name)" } else { nil }
    return CategoryRowModel(
      id: c.id, name: c.name, glyph: c.glyph, hue: c.hue, supporting: supporting, hidden: c.builtin && c.archived,
      builtin: c.builtin)
  }

  public static func parentGroups(_ s: LedgerState) -> [CategorySectionModel] {
    let parents = s.categories.filter { isOfferedParent($0.id, in: s) }
    return sectionOrder.compactMap { b in
      let rows = parents.filter { sectionBucket($0) == b }.map { row($0, s) }
      return rows.isEmpty ? nil : CategorySectionModel(title: section(b), rows: rows)
    }
  }

  public static func moveTargets(_ s: LedgerState, from id: CategoryID) -> [CategorySectionModel] {
    guard let from = s.category(id) else { return [] }
    let targets = s.categories.filter { $0.id != id && !$0.archived && $0.kind == from.kind }
    return sectionOrder.compactMap { b in
      let rows = targets.filter { sectionBucket($0) == b }.map { row($0, s) }
      return rows.isEmpty ? nil : CategorySectionModel(title: section(b), rows: rows)
    }
  }

  public static func movableCount(_ s: LedgerState, _ id: CategoryID) -> Int {
    s.txns.filter { $0.categoryID == id && $0.splits.isEmpty && !$0.archived }.count
  }

  public static func impact(_ s: LedgerState, _ id: CategoryID, month: YearMonth) -> CategoryImpact? {
    guard let c = s.category(id) else { return nil }
    let txns = s.txns.filter { t in !t.archived && (t.categoryID == id || t.splits.contains { $0.categoryID == id }) }
    return CategoryImpact(
      name: c.name, section: section(sectionBucket(c)), transactions: txns.count,
      rules: s.rules.filter { $0.categoryID == id && $0.enabled }.count, assigned: s.plan.budget(id, month),
      blockedByGoal: s.goals.contains { $0.categoryID == id })
  }

  public static func refusal(_ edit: LedgerEdit, in s: LedgerState) -> String? {
    switch edit {
    case .addCategory(let d):
      if let r = nameRefusal(d.trimmedName, in: s, excluding: nil) { return r }
      guard let p = d.parent, isOfferedParent(p, in: s) else { return CategoryLimits.parentNotAllowed }
      return activeCustomCount(s) < CategoryLimits.maxActiveCustom ? nil : CategoryLimits.atCap
    case .editCategory(let id, let d):
      guard let c = s.category(id) else { return CategoryLimits.unknown }
      if d.trimmedName != c.name, let r = nameRefusal(d.trimmedName, in: s, excluding: id) { return r }
      if let p = d.parent, p != c.parent {
        if c.builtin { return CategoryLimits.builtinLocked }
        if !isOfferedParent(p, in: s) { return CategoryLimits.parentNotAllowed }
      }
      return nil
    case .archiveCategory(let id, let moveTo):
      guard let c = s.category(id) else { return CategoryLimits.unknown }
      return archiveRefusal(c, moveTo: moveTo, in: s)
    case .restoreCategory(let id):
      guard let c = s.category(id) else { return CategoryLimits.unknown }
      if !c.archived { return nil }
      if let clash = nameClash(c.name, in: s, excluding: id) { return CategoryLimits.nameTaken(clash.name) }
      if c.builtin { return nil }
      return activeCustomCount(s) < CategoryLimits.maxActiveCustom ? nil : CategoryLimits.atCap
    default:
      return nil
    }
  }

  public static func archiveRefusal(_ c: Category, moveTo: CategoryID?, in s: LedgerState) -> String? {
    if c.builtin && CategoryLimits.isSystem(c.id) { return CategoryLimits.systemCannotHide }
    if s.goals.contains(where: { $0.categoryID == c.id }) { return CategoryLimits.goalUses }
    if let t = moveTo {
      guard t != c.id, let target = s.category(t), !target.archived else { return CategoryLimits.unknown }
    }
    return nil
  }

  static func nameRefusal(_ name: String, in s: LedgerState, excluding id: CategoryID?) -> String? {
    if name.isEmpty { return CategoryLimits.nameEmpty }
    if name.unicodeScalars.count > CategoryLimits.maxName { return CategoryLimits.nameTooLong }
    if let clash = nameClash(name, in: s, excluding: id) { return CategoryLimits.nameTaken(clash.name) }
    return nil
  }

  static func nameClash(_ name: String, in s: LedgerState, excluding id: CategoryID?) -> Category? {
    let key = name.trimmedSpaces.lowercased()
    return s.categories.first { !$0.archived && $0.id != id && $0.name.trimmedSpaces.lowercased() == key }
  }

  public static func isOfferedParent(_ id: CategoryID, in s: LedgerState) -> Bool {
    guard CategoryLimits.isParent(id), let c = s.category(id) else { return false }
    return c.builtin && !c.archived
  }

  static func classOf(_ parent: Category) -> (CategoryKind, Bucket, CategoryRole) {
    switch parent.kind {
    case .spending: (.spending, parent.bucket, parent.bucket == .savings ? .saving : .everyday)
    case .income: (.income, .income, .none)
    case .excluded: (.excluded, .other, .none)
    }
  }

  static func place(_ c: Category, in s: inout LedgerState) {
    s.categories.removeAll { $0.id == c.id }
    guard let p = c.parent, let i = s.categories.firstIndex(where: { $0.id == p }) else {
      s.categories.append(c)
      return
    }
    var j = i + 1
    while j < s.categories.count, !s.categories[j].builtin, s.categories[j].parent == p { j += 1 }
    s.categories.insert(c, at: j)
  }

  public static func apply(_ edit: LedgerEdit, to s: inout LedgerState, newID: CategoryID, month: YearMonth) {
    switch edit {
    case .addCategory(let d):
      guard let p = d.parent, let parent = s.category(p) else { return }
      let (kind, bucket, role) = classOf(parent)
      place(
        Category(
          id: newID, name: d.trimmedName, kind: kind, bucket: bucket, glyph: d.glyph, role: role, parent: p, builtin: false),
        in: &s)
    case .editCategory(let id, let d):
      guard var c = s.category(id) else { return }
      c.name = d.trimmedName
      c.glyph = d.glyph
      if !c.builtin, let p = d.parent, p != c.parent, let parent = s.category(p) {
        (c.kind, c.bucket, c.role) = classOf(parent)
        c.parent = p
        place(c, in: &s)
      } else if let i = s.categories.firstIndex(where: { $0.id == id }) {
        s.categories[i] = c
      }
    case .archiveCategory(let id, let moveTo):
      guard let i = s.categories.firstIndex(where: { $0.id == id }) else { return }
      s.categories[i].archived = true
      let key = PlanState.key(id, month)
      let assigned = s.plan.budget(id, month)
      if assigned.minor > 0 {
        s.plan.budgets[key] = nil
        if let t = moveTo, s.category(t)?.kind == .spending {
          s.plan.budgets[PlanState.key(t, month)] = .aed(s.plan.budget(t, month).minor + assigned.minor)
        }
      }
      if let t = moveTo {
        for k in s.txns.indices where s.txns[k].categoryID == id && s.txns[k].splits.isEmpty && !s.txns[k].archived {
          s.txns[k].categoryID = t
          s.txns[k].categorySource = .user
          s.txns[k].isTransfer = t == "transfer"
          s.txns[k].isRefund = t == "refunds"
        }
      }
    case .restoreCategory(let id):
      guard let i = s.categories.firstIndex(where: { $0.id == id }) else { return }
      s.categories[i].archived = false
    default:
      return
    }
  }

  public static func toast(_ edit: LedgerEdit, before: LedgerState) -> String? {
    switch edit {
    case .addCategory(let d): return "\(d.trimmedName) added"
    case .editCategory: return "Category saved"
    case .archiveCategory(let id, let moveTo):
      guard let c = before.category(id) else { return nil }
      if let t = moveTo, let target = before.category(t) { return "Moved to \(target.name) and archived \(c.name)" }
      return c.builtin ? "\(c.name) hidden" : "\(c.name) archived"
    case .restoreCategory(let id):
      guard let c = before.category(id) else { return nil }
      return c.builtin ? "\(c.name) shown again" : "\(c.name) restored"
    default: return nil
    }
  }
}
