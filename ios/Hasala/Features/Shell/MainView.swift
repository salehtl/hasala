import HasalaDesign
import HasalaModels
import SwiftUI

/// The tab shell (Paper "13 · Navigation · Tab bar and search"): Home, Plan, Review with
/// its to-sort badge, Activity, and Search as the system's search-role tab, with the app's
/// sheets and the review cover over them. Paper draws Search as a separate 64 pt glass
/// circle beside a 288 pt bar; on the iOS 27 simulator `Tab(role: .search)` draws inline,
/// with or without `.tabBarMinimizeBehavior(.never)`, and moving `.searchable` onto the
/// TabView puts a search field in every tab. Not yet checked on an iOS 26 runtime.
///
/// A Release build has no Search tab until the search engine exists (`BuildSurface`);
/// Activity's own search field finds transactions meanwhile.
///
/// Routing is `app.router`'s: the tab bar, the sheet and the cover bind to it, and each
/// sheet's view model lives in a small holder view with `@State`, so a body pass here can't
/// build it again.
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

  /// Tapping the selected tab again goes back to its root.
  private var selection: Binding<AppTab> {
    Binding(
      get: { app.router.tab },
      set: { tab in
        if tab == app.router.tab { app.router.popToRoot(tab) } else { app.router.tab = tab }
      })
  }

  var body: some View {
    TabView(selection: selection) {
      Tab("Home", systemImage: "house.fill", value: AppTab.home) {
        HomeView(app: app, model: home)
      }
      Tab("Plan", image: "TabPlan", value: AppTab.plan) {
        PlanView(app: app, model: plan)
      }
      // TODO(spec 02 page 13): the stacked-cards glyph from spec 01 appendix B (TabReview).
      Tab("Review", systemImage: "rectangle.stack.fill", value: AppTab.review) {
        ReviewTabView(app: app)
      }
      .badge(app.reviewCount)
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
    // sheet or cover from the last time it was on screen; a Debug launch's screen then
    // opens over it.
    .onAppear {
      app.router.clearPresentation()
      applyPendingLaunch()
    }
    .sheet(item: Bindable(app.router).sheet, onDismiss: { app.router.sheetDismissed() }) { route in
      switch route {
      case .transaction(let id):
        TransactionHost(app: app, id: id)
      case .budget(let id):
        BudgetHost(app: app, category: id)
          .presentationDetents([.large])
      case .moveMoney(let id):
        MoveMoneyHost(app: app, category: id)
      case .profile:
        ProfileSheet(app: app)
      case .notifications:
        NotificationsSheet(app: app)
      case .connectGmail(let offer):
        GmailConnectSheet(app: app, offer: offer)
      }
    }
    .fullScreenCover(item: Bindable(app.router).cover) { cover in
      switch cover {
      case .review: ReviewCover(app: app)
      }
    }
  }

  private func applyPendingLaunch() {
    #if HASALA_MOCKS
      guard let launch = app.router.pendingLaunch else { return }
      app.router.pendingLaunch = nil
      app.router.profile = launch.profile
      app.router.transaction = launch.transaction
      app.router.sheet = launch.sheet
      app.router.cover = launch.cover
    #endif
  }
}

/// The transaction sheet keeps one view model while it is up.
private struct TransactionHost: View {
  let app: AppModel
  @State private var model: TransactionViewModel

  init(app: AppModel, id: TxnID) {
    self.app = app
    _model = State(initialValue: TransactionViewModel(app: app, id: id))
  }

  var body: some View { TransactionSheet(app: app, model: model) }
}

/// Change a budget keeps one view model while it is up.
private struct BudgetHost: View {
  @State private var model: BudgetSheetViewModel

  init(app: AppModel, category: CategoryID) {
    _model = State(initialValue: BudgetSheetViewModel(app: app, category: category))
  }

  var body: some View { BudgetEditSheet(model: model) }
}

/// Move money keeps one view model while it is up.
private struct MoveMoneyHost: View {
  @State private var model: BudgetSheetViewModel

  init(app: AppModel, category: CategoryID?) {
    _model = State(initialValue: BudgetSheetViewModel(app: app, category: category))
  }

  var body: some View { MoveMoneySheet(model: model) }
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
