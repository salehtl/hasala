import HasalaDesign
import HasalaModels
import SwiftUI

/// The tab shell (Paper "13 · Navigation · Tab bar and search"): Home, Plan, Review with
/// its to-sort badge, Activity, and Search as the system's search-role tab, with the app's
/// sheets and the review cover over them. Search is the separate glass circle beside the bar
/// (Paper); on iOS 27 the system draws it apart only when the search tab activates search.
///
/// Search is in every build: it finds transactions, categories and rules in this iPhone's
/// own ledger, with no server call. Its direct answers (spec 04 §13.1) are not built.
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
      // The tab glyphs are Paper's (spec 01 appendix B), as template images: the house with
      // its door cut out, the two-piece pie, the stacked cards (0.45 / 0.7 / 1) and the
      // history clock. The bar is the system's, so selection does not animate here.
      Tab("Home", image: "TabHome", value: AppTab.home) {
        HomeView(app: app, model: home)
      }
      Tab("Plan", image: "TabPlan", value: AppTab.plan) {
        PlanView(app: app, model: plan)
      }
      Tab("Review", image: "TabReview", value: AppTab.review) {
        ReviewTabView(app: app)
      }
      // Transactions to sort; it never follows the period, and is hidden at zero.
      .badge(app.reviewCount)
      Tab("Activity", image: "TabActivity", value: AppTab.activity) {
        ActivityView(app: app, model: activity)
      }
      // TODO(spec 04 §13.1): direct answers; the results as you type are the ledger's own.
      Tab(value: AppTab.search, role: .search) {
        SearchView(app: app)
      }
    }
    .tabBarMinimizeBehavior(.never)
    .tabViewSearchActivation(.searchTabSelection)
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
      case .period:
        PeriodSheet(app: app)
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
