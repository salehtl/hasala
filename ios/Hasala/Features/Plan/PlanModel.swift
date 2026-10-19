import HasalaDesign
import HasalaModels
import Observation

/// Plan · October (Paper board): Ready to assign, the split, the buckets and the projects.
/// Its rows push Plan · Dining and Plan · Japan trip; Assign opens Move money.
@MainActor
protocol PlanModel: AnyObject, Observable {
  var snapshot: PlanSnapshot { get }
  var hidden: Bool { get }
  func editBudget(_ category: CategoryID)
  func moveMoney(to category: CategoryID?)
  func autoAssign()
  /// Pushes the category's month (Plan · Dining).
  func open(_ category: CategoryID)
  /// Pushes the project (Plan · Japan trip).
  func open(project: ProjectID)
  func newProject()
  func openProjects()
}

@MainActor
@Observable
final class PlanViewModel: PlanModel {
  private let app: AppModel

  @ObservationIgnored private var memo = Memo<Int, PlanSnapshot>()

  init(app: AppModel) { self.app = app }

  var snapshot: PlanSnapshot {
    memo.value(for: app.store.revision) { PlanEngine.snapshot(app.store.state, now: app.store.now) }
  }
  var hidden: Bool { app.amountsHidden }

  func editBudget(_ category: CategoryID) { app.router.open(.budget(category)) }
  func moveMoney(to category: CategoryID?) { app.router.open(.moveMoney(to: category)) }
  func open(_ category: CategoryID) { app.router.plan.append(.category(category)) }
  func open(project: ProjectID) { app.router.plan.append(.project(project)) }

  // TODO(03a §6.11, spec 04 §16.2 P2): Auto-assign funds targets first, then follows the
  // split, as one `budget_moved` batch with a preview sheet.
  // Debug only: a Release build doesn't show the button (`BuildSurface`).
  func autoAssign() { app.say("Auto-assign isn't in this build yet", icon: .wand) }

  func newProject() { app.editProject(nil) }
  func openProjects() { app.router.plan.append(.projects) }
}

// MARK: - Plan · Dining

/// One category's month in depth (Paper "Plan · Dining"), pushed from Plan's rows, Home's
/// widgets and the bell. Its actions open the budget sheet and Move money over the tab.
@MainActor
protocol CategoryDetailModel: AnyObject, Observable {
  var detail: CategoryDetail? { get }
  var hidden: Bool { get }
  func changeBudget()
  func moveMoneyIn()
  /// A row of This month: the transaction sheet.
  func open(_ txn: TxnID)
  /// A rule row: Your profile › Categories and rules, where rules are paused and kept.
  func openRules()
  /// Debug only: rules are made from Review and the transaction sheet for now.
  func addRule()
}

@MainActor
@Observable
final class CategoryDetailViewModel: CategoryDetailModel {
  private let app: AppModel
  let category: CategoryID

  @ObservationIgnored private var memo = Memo<Int, CategoryDetail?>()

  init(app: AppModel, category: CategoryID) {
    self.app = app
    self.category = category
  }

  var detail: CategoryDetail? {
    memo.value(for: app.store.revision) { PlanEngine.category(category, app.store.state, now: app.store.now) }
  }
  var hidden: Bool { app.amountsHidden }

  func changeBudget() { app.router.open(.budget(category)) }
  func moveMoneyIn() { app.router.open(.moveMoney(to: category)) }
  func open(_ txn: TxnID) { app.open(txn) }
  func openRules() { app.router.open(.profile, profile: [.rules]) }

  // TODO(spec 12 §7): "Add a rule" needs a rule-making screen (Categories and rules).
  func addRule() { app.say("Adding a rule here isn't in this build yet", icon: .wand) }
}

// MARK: - Plan · Japan trip

/// A project (Paper "Plan · Japan trip (project)"), pushed from Plan and from Your profile.
@MainActor
protocol ProjectDetailModel: AnyObject, Observable {
  var detail: ProjectDetail? { get }
  var hidden: Bool { get }
  func open(_ txn: TxnID)
  func addTransactions()
  func setCountInPlan(_ on: Bool)
  func setComplete(_ done: Bool)
  func edit()
  func remove()
}

@MainActor
@Observable
final class ProjectDetailViewModel: ProjectDetailModel {
  private let app: AppModel
  let project: ProjectID

  @ObservationIgnored private var memo = Memo<Int, ProjectDetail?>()

  init(app: AppModel, project: ProjectID) {
    self.app = app
    self.project = project
  }

  var detail: ProjectDetail? {
    memo.value(for: app.store.revision) { PlanEngine.project(project, app.store.state, now: app.store.now) }
  }
  var hidden: Bool { app.amountsHidden }

  func open(_ txn: TxnID) { app.open(txn) }
  func addTransactions() { app.addToProject(project) }
  func setCountInPlan(_ on: Bool) { app.perform(.setProjectCountInPlan(project, on)) }
  func setComplete(_ done: Bool) { app.perform(.completeProject(project, done)) }
  func edit() { app.editProject(project) }

  func remove() {
    let name = app.store.state.project(project)?.name ?? "Project"
    guard app.perform(.removeProject(project)) else { return }
    app.say("\(name) removed")
    app.leaveProject(project)
  }
}

// MARK: - The budget sheet and Move money

/// One place money can come from in Move money and the budget sheet's "Take it from".
struct MoveSource: Identifiable, Hashable {
  /// `nil` is Ready to assign.
  let id: CategoryID?
  let name: String
  let glyph: Glyph
  let hue: Hue
  let available: Money
  /// "1,000.00 not in a budget yet", "2,500.00 left · nothing spent yet".
  let detail: MoneyPhrase
}

/// Change a budget (Paper "Plan · Change Dining's budget") and Move money over one category.
@MainActor
protocol BudgetSheetModel: AnyObject, Observable {
  var hidden: Bool { get }
  var plan: PlanSnapshot { get }
  var row: PlanRowModel? { get }
  /// Where the month ends at today's pace, for "Cover the pace".
  var projected: Money? { get }
  /// Projected minus budget, in whole units, when the pace runs past the budget.
  var shortfall: Money? { get }
  /// Last month's name and what the category spent in it, for "Match September" (Debug only:
  /// nothing reads last month's spending for live yet).
  var lastMonth: (name: String, spent: Money)? { get }
  /// Where money can come from for `destination`, in 03a §6.13's order; the sheet shows
  /// the first four, then "Show all".
  func sources(to destination: CategoryID?) -> [MoveSource]
  var destinations: [CategoryOption] { get }
  /// Sets the budget; any rise comes from Ready to assign.
  func setBudget(_ amount: Money) -> Bool
  /// Sets the budget to `amount`. A rise is taken from `source` (Ready to assign when nil) as
  /// Move money from it; a cut, or a rise from Ready to assign, sets the budget. Closes the
  /// sheet when it is done.
  func setBudget(_ amount: Money, takingFrom source: CategoryID?) -> Bool
  /// Why `amount` can't come from `source`, said before anything is sent; nil when it can.
  func refusal(moving amount: Money, from source: CategoryID?) -> String?
  func move(_ amount: Money, from: CategoryID?, to: CategoryID) -> Bool
  func close()
}

@MainActor
@Observable
final class BudgetSheetViewModel: BudgetSheetModel {
  private let app: AppModel
  let category: CategoryID?
  @ObservationIgnored private var memo = Memo<Int, PlanSnapshot>()

  init(app: AppModel, category: CategoryID?) {
    self.app = app
    self.category = category
  }

  var hidden: Bool { app.amountsHidden }
  var plan: PlanSnapshot {
    memo.value(for: app.store.revision) { PlanEngine.snapshot(app.store.state, now: app.store.now) }
  }
  var row: PlanRowModel? { category.flatMap { plan.row($0) } }
  private var month: YearMonth { app.store.now.date.yearMonth }

  var projected: Money? {
    guard let row, row.paced else { return nil }
    let now = app.store.now
    return .aed(Pace.projected(row.spent.minor, day: now.date.day, days: now.date.yearMonth.days) / 100 * 100)
  }

  var shortfall: Money? {
    guard let row, let projected, projected.minor > row.budget.minor else { return nil }
    return .aed(projected.minor - row.budget.minor)
  }

  var lastMonth: (name: String, spent: Money)? {
    guard let category else { return nil }
    let previous = month.previous
    let spent = app.store.state.spent(category, in: previous)
    return spent.minor > 0 ? (previous.name, spent) : nil
  }

  /// 03a §6.13: Ready to assign when it is above zero; then wants, then needs, each the
  /// everyday categories on track with money left, most left first (ties keep the plan's
  /// order); then savings with money left. Bills, categories over pace or over budget,
  /// and the destination itself are never sources.
  func sources(to destination: CategoryID?) -> [MoveSource] {
    let p = plan
    var out: [MoveSource] = []
    if p.readyToAssign.minor > 0 {
      out.append(MoveSource(id: nil, name: "Ready to assign", glyph: .wallet, hue: .mint, available: p.readyToAssign,
                            detail: MoneyPhrase([.amount(p.readyToAssign, hidden: 3), .text(" not in a budget yet")])))
    }
    func left(_ r: PlanRowModel) -> Int64 { r.budget.minor - r.spent.minor }
    func rows(_ bucket: Bucket) -> [PlanRowModel] {
      p.sections.first { $0.bucket == bucket }?.rows.filter { $0.id != destination && left($0) > 0 } ?? []
    }
    let everyday = [Bucket.wants, .needs].flatMap { bucket in
      rows(bucket).enumerated()
        .filter { $0.element.paced && $0.element.verdict == .onTrack }
        .sorted { (left($0.element), -$0.offset) > (left($1.element), -$1.offset) }
        .map(\.element)
    }
    for r in everyday + rows(.savings) {
      let l = Money.aed(left(r))
      out.append(MoveSource(
        id: r.id, name: r.name, glyph: r.glyph, hue: r.hue, available: l,
        detail: MoneyPhrase([.amount(l, hidden: 3), .text(r.spent.isZero ? " left · nothing spent yet" : " left")])
      ))
    }
    return out
  }

  var destinations: [CategoryOption] {
    let s = app.store.state
    return [Bucket.needs, .wants, .savings].flatMap { s.categories(in: $0) }.map(CategoryOption.init)
  }

  func setBudget(_ amount: Money) -> Bool { setBudget(amount, takingFrom: nil) }

  func setBudget(_ amount: Money, takingFrom source: CategoryID?) -> Bool {
    guard let category, let row else { return false }
    let rise = amount.minor - row.budget.minor
    let ok: Bool
    if let source, source != category, rise > 0 {
      ok = app.perform(.moveMoney(from: source, to: category, month, .aed(rise)))
    } else {
      ok = app.perform(.setBudget(category, month, amount))
    }
    if ok { close() }
    return ok
  }

  func refusal(moving amount: Money, from source: CategoryID?) -> String? {
    guard amount.minor > 0 else { return nil }
    guard let source else {
      return amount.minor > plan.readyToAssign.minor ? "Ready to assign doesn't have that much" : nil
    }
    guard let r = plan.row(source) else { return nil }
    return amount.minor > r.budget.minor - r.spent.minor ? "\(r.name) doesn't have that much left" : nil
  }

  func move(_ amount: Money, from: CategoryID?, to: CategoryID) -> Bool {
    guard from != to else { return false }
    let ok = app.perform(.moveMoney(from: from, to: to, month, amount))
    if ok { close() }
    return ok
  }

  func close() { app.sheet = nil }
}
