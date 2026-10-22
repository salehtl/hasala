import Foundation
import HasalaDesign
import HasalaModels
import Observation

@MainActor
@Observable
final class MonthlyPlanModel: Identifiable {
  enum Route: Hashable { case plan }

  @ObservationIgnored private let setup: SetupAuthoring
  @ObservationIgnored private let done: (_ held: SetupReadBack?) -> Void
  @ObservationIgnored private let saved: SetupReadBack
  var path: [Route] = []
  var busy = false
  var failure: SetupFailure?
  private var entry = AmountEntry()
  private var payday: PaydayChoice?
  private var split: StartingPlan?
  private(set) var incomeSkipped = false

  init(setup: SetupAuthoring, done: @escaping (_ held: SetupReadBack?) -> Void) {
    self.setup = setup
    self.done = done
    let readBack = setup.readBack()
    saved = readBack
    if let minor = readBack.incomeMinor, minor > 0 { entry = AmountEntry(minor: minor) }
    payday = readBack.payday.map { .day($0) }
    split = readBack.split
  }

  var today: LocalDate { (setup as? SetupClock)?.today() ?? LedgerToday.device() }

  var incomeEntry: AmountEntry {
    get { entry }
    set {
      guard !newValue.text.contains(".") || entry.text.contains(".") else { return }
      entry = newValue
    }
  }

  var paydayChoice: PaydayChoice {
    get { payday ?? .standard }
    set { payday = newValue }
  }

  var nextPayday: LocalDate { paydayChoice.next(onOrAfter: today) }

  var plan: StartingPlan {
    get { split ?? StartingPlan() }
    set { split = newValue }
  }

  var incomeMinor: Int64? {
    guard let minor = entry.minor, minor > 0 else { return nil }
    return minor
  }

  var savedIncomeMinor: Int64? { incomeSkipped ? nil : incomeMinor }

  func continueWithIncome() {
    guard incomeMinor != nil else { return }
    incomeSkipped = false
    failure = nil
    path = [.plan]
  }

  func skipIncome() {
    incomeSkipped = true
    failure = nil
    path = [.plan]
  }

  func savePlan(skip: Bool = false) async {
    guard !busy else { return }
    let income = savedIncomeMinor
    let values = SetupReadBack(
      incomeMinor: income, payday: income == nil ? nil : paydayChoice.opDay(today: today), split: skip ? nil : plan)
    guard values != SetupReadBack() else { return done(nil) }
    if values != saved {
      busy = true
      defer { busy = false }
      do {
        try await setup.savePlan(income: values.incomeMinor, payday: values.payday, plan: values.split)
      } catch {
        failure = error
        return
      }
    }
    done(values)
  }
}
