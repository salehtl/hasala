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
    let period: Period
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

  var earliest: YearMonth { app.earliestMonth.map { min($0, current) } ?? current }

  var snapshot: InsightsSnapshot {
    let period = period
    return memo.value(for: Key(revision: app.store.revision, period: period, now: now)) {
      var snap = InsightsEngine.snapshot(app.store.state, months: period.range, now: now)
      snap.title = period.title
      return snap
    }
  }

  func drill(_ target: InsightsTarget) -> InsightsDrill {
    InsightsEngine.drill(app.store.state, target: target, months: months, now: now)
  }

  func choosePeriod() { app.sheet = .period }

  func periodChanged() { showsAllCategories = false }

  func open(_ target: InsightsTarget) { sheet = .drill(target) }

  func openNotCounted(_ line: SpendHero.NotCounted) { app.openProjectsTab(line.projectID) }

  var reading: ReadingState? { app.store.state.reading }

  var importing: Bool { reading?.importing == true }

  var importLine: String? { Self.importLine(reading) }

  func hold(_ focus: YearMonth) -> ReadingHold? {
    let h = ReadingOnScreen.hold(reading, month: focus)
    return h?.warns == true ? h : nil
  }

  func openReading(_ link: ReadingHold.Link) { app.router.open(.profile, profile: [.bankAlerts]) }

  static func importLine(_ reading: ReadingState?) -> String? {
    guard case .importing(let read, let total, _, _, _)? = reading?.kind else { return nil }
    let count = total > 0 ? " · \(MoneyFormat.count(read)) of \(MoneyFormat.count(total))" : ""
    return "Reading your alerts\(count). Older months will change."
  }

  func openReport(_ kind: InsightsReport.Kind) {
    switch kind {
    case .netWorth: app.router.home.append(.accounts)
    case .inVsSpent, .ageOfMoney, .yearOnYear: app.say("This report isn't in this build yet", icon: .info)
    }
  }
}
