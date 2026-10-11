import HasalaModels
import Observation

/// Plan · October, Change a budget, Move money (spec 04 §16.1 "Plan · October", "Change a budget", "Move money").
@MainActor
protocol PlanModel: AnyObject, Observable {
  var snapshot: PlanSnapshot { get }
  var hidden: Bool { get }
  func editBudget(_ category: CategoryID)
  func moveMoney(to category: CategoryID?)
  func autoAssign()
}

@MainActor
@Observable
final class PlanViewModel: PlanModel {
  private let app: AppModel

  init(app: AppModel) { self.app = app }

  var snapshot: PlanSnapshot { PlanEngine.snapshot(app.store.state, now: app.store.now) }
  var hidden: Bool { app.amountsHidden }

  func editBudget(_ category: CategoryID) { app.sheet = .budget(category) }
  func moveMoney(to category: CategoryID?) { app.sheet = .moveMoney(to: category) }

  // TODO(03a §6.11, spec 04 §16.2 P2): Auto-assign funds targets first, then follows the
  // split, as one `budget_moved` batch with a preview sheet.
  func autoAssign() { app.say("Auto-assign arrives in a later build", systemImage: "wand.and.stars") }
}

/// One place money can come from in Move money.
struct MoveSource: Identifiable, Hashable {
  /// `nil` is Ready to assign.
  let id: CategoryID?
  let name: String
  let available: Money
  /// "1,000.00 not in a budget yet", "2,500.00 left · nothing spent yet".
  let detail: MoneyPhrase
}

/// Change a budget and Move money over one category.
@MainActor
protocol BudgetSheetModel: AnyObject, Observable {
  var hidden: Bool { get }
  var plan: PlanSnapshot { get }
  var row: PlanRowModel? { get }
  /// Where the month ends at today's pace, for "Cover the pace".
  var projected: Money? { get }
  /// Projected minus budget, in whole units, when the pace runs past the budget.
  var shortfall: Money? { get }
  var sources: [MoveSource] { get }
  var destinations: [CategoryOption] { get }
  func setBudget(_ amount: Money) -> Bool
  func move(_ amount: Money, from: CategoryID?, to: CategoryID) -> Bool
  func close()
}

@MainActor
@Observable
final class BudgetSheetViewModel: BudgetSheetModel {
  private let app: AppModel
  let category: CategoryID?

  init(app: AppModel, category: CategoryID?) {
    self.app = app
    self.category = category
  }

  var hidden: Bool { app.amountsHidden }
  var plan: PlanSnapshot { PlanEngine.snapshot(app.store.state, now: app.store.now) }
  var row: PlanRowModel? { category.flatMap { plan.row($0) } }

  var projected: Money? {
    guard let row, row.paced else { return nil }
    let now = app.store.now
    return .aed(Pace.projected(row.spent.minor, day: now.date.day, days: now.date.yearMonth.days) / 100 * 100)
  }

  var shortfall: Money? {
    guard let row, let projected, projected.minor > row.budget.minor else { return nil }
    return .aed(projected.minor - row.budget.minor)
  }

  var sources: [MoveSource] {
    let p = plan
    var out = [MoveSource(id: nil, name: "Ready to assign", available: p.readyToAssign,
                          detail: MoneyPhrase([.amount(p.readyToAssign), .text(" not in a budget yet")]))]
    let rows = p.sections.filter { $0.bucket != .savings }.flatMap(\.rows)
      .filter { $0.id != category && $0.paced }
    for r in rows {
      guard case .left(let left) = r.trailing, left.minor > 0 else { continue }
      out.append(MoveSource(
        id: r.id, name: r.name, available: left,
        detail: MoneyPhrase([.amount(left), .text(r.spent.isZero ? " left · nothing spent yet" : " left")])
      ))
    }
    return Array(out.prefix(1)) + out.dropFirst().sorted { $0.available.minor > $1.available.minor }.prefix(4)
  }

  var destinations: [CategoryOption] {
    let s = app.store.state
    return [Bucket.needs, .wants, .savings].flatMap { s.categories(in: $0) }.map(CategoryOption.init)
  }

  func setBudget(_ amount: Money) -> Bool {
    guard let category else { return false }
    let ok = app.perform(.setBudget(category, app.store.now.date.yearMonth, amount))
    if ok { close() }
    return ok
  }

  func move(_ amount: Money, from: CategoryID?, to: CategoryID) -> Bool {
    let ok = app.perform(.moveMoney(from: from, to: to, app.store.now.date.yearMonth, amount))
    if ok { close() }
    return ok
  }

  func close() { app.sheet = nil }
}
