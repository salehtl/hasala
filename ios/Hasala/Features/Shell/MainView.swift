import HasalaDesign
import SwiftUI

/// The tabs (spec 04 §13.1): Home, Plan, Activity, and Search as the separate glass
/// circle at the trailing end of the iOS 26 Liquid Glass tab bar.
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
