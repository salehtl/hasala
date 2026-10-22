import HasalaDesign
import HasalaModels
import SwiftUI

struct ProjectsTabView: View {
  @Bindable var app: AppModel

  var body: some View {
    NavigationStack(path: Bindable(app.router).projects) {
      ProjectsListView(app: app, tabRoot: true)
        .navigationDestination(for: PlanRoute.self) { route in
          switch route {
          case .category(let id): CategoryDetailView(app: app, category: id)
          case .project(let id): ProjectDetailView(app: app, project: id)
          case .projects: ProjectsListView(app: app)
          case .addToProject(let id): ProjectAddTransactionsView(app: app, project: id)
          }
        }
    }
  }
}

struct PlanPage: View {
  @Bindable var app: AppModel
  @State private var model: PlanViewModel

  init(app: AppModel) {
    self.app = app
    _model = State(initialValue: PlanViewModel(app: app))
  }

  var body: some View {
    PlanDetailScreen(app: app, title: "Plan", wash: .onTrack) {
      MonthPill(month: model.snapshot.month)
        .padding(.horizontal, HSpacing.insetPage)
      PlanContent(model: model)
    }
  }
}
