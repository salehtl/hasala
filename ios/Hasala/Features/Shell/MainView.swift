import HasalaDesign
import SwiftUI

/// The tab shell (spec 04 §13.1): Home, Plan, Activity, and Search as the system's
/// search-role tab, with the app's sheets and the review cover over them. Paper draws
/// Search as a separate 64 pt glass circle beside a 288 pt bar; on the iOS 27 simulator
/// `Tab(role: .search)` draws inline as a fourth tab, with or without
/// `.tabBarMinimizeBehavior(.never)`, and moving `.searchable` onto the TabView puts a
/// search field in every tab. Not yet checked on an iOS 26 runtime.
///
/// A Release build has no Search tab until the search engine exists (`BuildSurface`);
/// Activity's own search field finds transactions meanwhile.
struct MainView: View {
  @State private var app: AppModel
  @State private var home: HomeViewModel
  @State private var plan: PlanViewModel
  @State private var activity: ActivityViewModel

  init(app: AppModel) {
    _app = State(initialValue: app)
    _home = State(initialValue: HomeViewModel(app: app))
    _plan = State(initialValue: PlanViewModel(app: app))
    _activity = State(initialValue: ActivityViewModel(app: app))
  }

  var body: some View {
    TabView(selection: $app.tab) {
      Tab("Home", systemImage: "house.fill", value: AppTab.home) {
        HomeView(app: app, model: home)
      }
      Tab("Plan", image: "TabPlan", value: AppTab.plan) {
        PlanView(app: app, model: plan)
      }
      Tab("Activity", systemImage: "clock.arrow.circlepath", value: AppTab.activity) {
        ActivityView(app: app, model: activity)
      }
      // TODO(spec 04 §13.1): Search with direct answers; Debug keeps the placeholder tab.
      if BuildSurface.showsUnfinished {
        Tab(value: AppTab.search, role: .search) {
          SearchView(app: app)
        }
      }
    }
    .tabBarMinimizeBehavior(.never)
    // A main view that appears (again, after signing out and back in) starts with no
    // sheet or cover from the last time it was on screen.
    .onAppear {
      app.sheet = nil
      app.cover = nil
    }
    .sheet(item: $app.sheet) { route in
      switch route {
      case .transaction(let id):
        TransactionSheet(app: app, model: TransactionViewModel(app: app, id: id))
      case .budget(let id):
        BudgetEditSheet(model: BudgetSheetViewModel(app: app, category: id))
          .presentationDetents([.large])
      case .moveMoney(let id):
        MoveMoneySheet(model: BudgetSheetViewModel(app: app, category: id))
      case .profile:
        ProfileSheet(app: app)
      }
    }
    .fullScreenCover(item: $app.cover) { cover in
      switch cover {
      case .review: ReviewCover(app: app)
      }
    }
  }
}

/// The review cover keeps one session's view model while it is up.
private struct ReviewCover: View {
  @Bindable var app: AppModel
  @State private var model: ReviewViewModel

  init(app: AppModel) {
    self.app = app
    _model = State(initialValue: ReviewViewModel(app: app))
  }

  var body: some View { ReviewDeckView(app: app, model: model) }
}
