import HasalaDesign
import HasalaModels
import Observation

@MainActor
@Observable
final class InsightsModel {
  enum Sheet: Hashable, Identifiable {
    case drill(InsightsTarget)

    var id: String {
      switch self {
      case .drill(let t): "drill.\(t)"
      }
    }
  }

  private let app: AppModel
  var lens: InsightsLens = .categories
  var showsAllCategories = false
  var showsTable = false
  var sheet: Sheet?
  @ObservationIgnored private var memo = Memo<Key, InsightsSnapshot>()

  private struct Key: Equatable {
    let revision: Int
    let months: ClosedRange<YearMonth>
    let now: LocalDateTime
  }

  init(app: AppModel) {
    self.app = app
  }

  var period: Period { app.period }
  var months: ClosedRange<YearMonth> { app.period.range }

  var now: LocalDateTime { app.store.now }
  var hidden: Bool { app.amountsHidden }
  var current: YearMonth { now.date.yearMonth }

  var earliest: YearMonth {
    app.store.state.txns.map(\.postedAt.date.yearMonth).min().map { min($0, current) } ?? current
  }

  var snapshot: InsightsSnapshot {
    let key = Key(revision: app.store.revision, months: months, now: now)
    return memo.value(for: key) { InsightsEngine.snapshot(app.store.state, months: months, now: now) }
  }

  func drill(_ target: InsightsTarget) -> InsightsDrill {
    InsightsEngine.drill(app.store.state, target: target, months: months, now: now)
  }

  func choosePeriod() { app.sheet = .period }

  func periodChanged() { showsAllCategories = false }

  func open(_ target: InsightsTarget) { sheet = .drill(target) }

  func openReport(_ kind: InsightsReport.Kind) {
    switch kind {
    case .netWorth: app.router.home.append(.accounts)
    case .inVsSpent, .ageOfMoney, .yearOnYear: app.say("This report isn't in this build yet", icon: .info)
    }
  }
}
