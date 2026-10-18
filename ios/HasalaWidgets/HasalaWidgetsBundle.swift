import HasalaDesign
import SwiftUI
import WidgetKit

@main
struct HasalaWidgetsBundle: WidgetBundle {
  init() {
    HasalaFonts.register()
  }

  var body: some Widget {
    SpentSoFarHomeWidget()
    BudgetPaceHomeWidget()
    CategoryWatchHomeWidget()
    NextBillHomeWidget()
    NetWorthHomeWidget()
    ComingUpHomeWidget()
    ProjectHomeWidget()
    GoalHomeWidget()
    ToReviewHomeWidget()
    TodayHomeWidget()
  }
}
