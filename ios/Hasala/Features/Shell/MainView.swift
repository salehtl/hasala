import HasalaDesign
import SwiftUI

/// The tabs (spec 04 §13.1): Home, Plan, Activity, and Search as the system's
/// search-role tab. Paper draws Search as a separate 64 pt glass circle beside a 288 pt
/// bar; on the iOS 27 simulator `Tab(role: .search)` draws inline as a fourth tab, with
/// or without `.tabBarMinimizeBehavior(.never)`, and moving `.searchable` onto the
/// TabView puts a search field in every tab. Not yet checked on an iOS 26 runtime.
enum AppTab: Hashable {
  case home, plan, activity, search
}

struct MainView: View {
  @State private var tab: AppTab = .home
  @State private var app: AppModel

  init(app: AppModel) {
    _app = State(initialValue: app)
  }

  var body: some View {
    TabView(selection: $tab) {
      Tab("Home", systemImage: "house.fill", value: AppTab.home) {
        HomeView(app: app)
      }
      Tab("Plan", image: "TabPlan", value: AppTab.plan) {
        PlanView(app: app)
      }
      Tab("Activity", systemImage: "clock.arrow.circlepath", value: AppTab.activity) {
        ActivityView(app: app)
      }
      Tab(value: AppTab.search, role: .search) {
        SearchView(app: app)
      }
    }
    .tabBarMinimizeBehavior(.never)
    .sheet(isPresented: $app.showingProfile) {
      ProfileSheet(app: app)
    }
  }
}
