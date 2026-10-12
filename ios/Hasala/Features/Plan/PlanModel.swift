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

  @ObservationIgnored private var memo = Memo<Int, PlanSnapshot>()

  init(app: AppModel) { self.app = app }

  var snapshot: PlanSnapshot {
    memo.value(for: app.store.revision) { PlanEngine.snapshot(app.store.state, now: app.store.now) }
  }
  var hidden: Bool { app.amountsHidden }

  func editBudget(_ category: CategoryID) { app.sheet = .budget(category) }
  func moveMoney(to category: CategoryID?) { app.sheet = .moveMoney(to: category) }

  // TODO(03a §6.11, spec 04 §16.2 P2): Auto-assign funds targets first, then follows the
  // split, as one `budget_moved` batch with a preview sheet.
  // Debug only: a Release build doesn't show the button (`BuildSurface`).
  func autoAssign() { app.say("Auto-assign isn't in this build yet", systemImage: "wand.and.stars") }
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
  /// Where money can come from for `destination`, in 03a §6.13's order; the sheet shows
  /// the first four, then "Show all".
  func sources(to destination: CategoryID?) -> [MoveSource]
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

  var projected: Money? {
    guard let row, row.paced else { return nil }
    let now = app.store.now
    return .aed(Pace.projected(row.spent.minor, day: now.date.day, days: now.date.yearMonth.days) / 100 * 100)
  }

  var shortfall: Money? {
    guard let row, let projected, projected.minor > row.budget.minor else { return nil }
    return .aed(projected.minor - row.budget.minor)
  }

  /// 03a §6.13: Ready to assign when it is above zero; then wants, then needs, each the
  /// everyday categories on track with money left, most left first (ties keep the plan's
  /// order); then savings with money left. Bills, categories over pace or over budget,
  /// and the destination itself are never sources.
  func sources(to destination: CategoryID?) -> [MoveSource] {
    let p = plan
    var out: [MoveSource] = []
    if p.readyToAssign.minor > 0 {
      out.append(MoveSource(id: nil, name: "Ready to assign", available: p.readyToAssign,
                            detail: MoneyPhrase([.amount(p.readyToAssign), .text(" not in a budget yet")])))
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
        id: r.id, name: r.name, available: l,
        detail: MoneyPhrase([.amount(l), .text(r.spent.isZero ? " left · nothing spent yet" : " left")])
      ))
    }
    return out
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
    guard from != to else { return false }
    let ok = app.perform(.moveMoney(from: from, to: to, app.store.now.date.yearMonth, amount))
    if ok { close() }
    return ok
  }

  func close() { app.sheet = nil }
}
